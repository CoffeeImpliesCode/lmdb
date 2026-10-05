//! An out-of-tree consumer of the LMDB facade.
//!
//! This program is the proof that the library's published module is enough on
//! its own: the only thing it knows about the library is `@import("lmdb")`,
//! which the package resolves through `dep.module("lmdb")`. It names no include
//! directory, links no system library, and reaches for `lmdb.c` only where the
//! raw ABI is genuinely part of what it is checking.
//!
//! It uses **both** routes on purpose. The typed facade stores and reads most
//! of the records, and the raw route — `lmdb.c`, which in a runtime-loading
//! build is the generated dispatch and in a linked build the translated header
//! — stores one record in the middle of the same transaction and reads the
//! whole database back afterwards. The raw answers are compared against the
//! typed answers *and* against a hand-written order, so a raw route that
//! silently answered from somewhere else could not pass.
//!
//! ## Where the database lives
//!
//! The caller supplies it: `--scratch <dir>` on this program's command line, or
//! `LMDB_TEST_SCRATCH` in the environment. There is no default. `TMPDIR` is not
//! consulted, `/tmp` is never touched, and nothing is written into the source
//! tree. The program creates one randomly named directory *inside* the directory
//! it was given and removes that child and nothing else, so a caller can point
//! it at a scratch mount and be sure nothing above the child is touched.
//!
//! `mdb_env_open` needs an absolute path and does not create the directory —
//! there is no `mkdir` anywhere in `mdb.c` — so the path handed over is made
//! absolute against the working directory when it is relative.
//!
//! ## Persistence, not a round trip
//!
//! It writes one set of records and abandons another, releases the
//! environment, opens the directory again from scratch with a new handle and a
//! new map, and then requires the exact bytes of the committed records and the
//! exact absence of the abandoned ones. A same-code round trip inside one handle
//! would prove only that the code agrees with itself.
//!
//! ## One provider, one set of handles
//!
//! In a runtime-loading build the provider is named by `--provider <path>` or
//! by `LMDB_TEST_PROVIDER` and loaded once, before anything else. Nothing is
//! loaded by default and no other file is tried.
//!
//! Every native handle this program touches comes from one environment, and
//! every handle it frees is freed through the same route that produced it: the
//! typed wrapper owns the environment and the transaction and frees both, and
//! the only raw call that allocates anything here is `mdb_cursor_open`, whose
//! result goes straight back to `mdb_cursor_close`. Nothing raw is ever handed
//! to a typed release and nothing typed is ever released by a raw call, because
//! a handle from one provider must never be freed by another.
//!
//! `zig build run -- --scratch <dir>` executes it; a disagreement exits
//! non-zero.

const std = @import("std");
const lmdb = @import("lmdb");

/// A shared object exporting the `mdb_*` entry points of
/// `libraries/liblmdb/lmdb.h`, named in a runtime-loading build.
const provider_variable = "LMDB_TEST_PROVIDER";

/// The directory the caller wants the scratch environment created under.
const scratch_variable = "LMDB_TEST_SCRATCH";

/// Everything this program can stop for, named.
const Failure = error{
    /// An observation did not match what the library promises.
    Disagreed,
    /// A committed record came back with different bytes.
    WrongValue,
    /// A record that was never committed is in the database.
    UnexpectedRecord,
    /// A runtime-loading build was not told which provider to open.
    NoProviderConfigured,
    /// A build of any kind was not told where to put the database.
    NoScratchConfigured,
    /// A raw `lmdb.c` call returned a non-zero status.
    RawCallFailed,
    /// Reading the command line met an error the platform did not document.
    ///
    /// `std.process.Args.toSlice` declares `std.posix.UnexpectedError` beside
    /// `OutOfMemory`, because the WASI branch reports whatever errno
    /// `args_sizes_get`/`args_get` returned (Args.zig:511-523). That error is
    /// in the declared set on every target even where the branch that can
    /// raise it is never taken, so it is carried here rather than folded into
    /// `NoProviderConfigured` or `NoScratchConfigured`: this process was told
    /// nothing about the provider or the scratch directory, and a program that
    /// cannot read its own arguments is not the same as one that was not told.
    Unexpected,
} || std.mem.Allocator.Error;

const Record = struct { key: []const u8, value: []const u8 };

/// Committed and abandoned in the same environment, and in the same order, so
/// the only difference between them is which transaction was committed.
const committed = [_]Record{
    .{ .key = "alpha", .value = "one" },
    .{ .key = "beta", .value = "two" },
    .{ .key = "gamma", .value = "three" },
};

/// Written through the raw route inside the committing transaction, so the two
/// routes are known to have written the same tree rather than two trees.
const through_raw = Record{ .key = "delta", .value = "four" };

/// Abandoned: one overwrite of a committed record and one new record.
const abandoned = [_]Record{
    .{ .key = "alpha", .value = "clobbered" },
    .{ .key = "epsilon", .value = "five" },
};

/// Every record that must be in the file after the run, in the order a forward
/// walk must produce it: byte-lexicographic with the shorter item first
/// (mdb.c:6659-6675), which is *not* the order above — "delta" sorts between
/// "beta" and "gamma" — and is not derived by running this program.
const expected_order = [_]Record{
    .{ .key = "alpha", .value = "one" },
    .{ .key = "beta", .value = "two" },
    .{ .key = "delta", .value = "four" },
    .{ .key = "gamma", .value = "three" },
};

// ------------------------------------------------------------------- plumbing

fn require(ok: bool, what: []const u8) Failure!void {
    if (!ok) {
        std.debug.print("consumer: disagreed: {s}\n", .{what});
        return error.Disagreed;
    }
}

/// An `MDB_val` describing the caller's bytes, passed to the C unchanged.
fn rawValue(bytes: []const u8) lmdb.c.MDB_val {
    return .{ .mv_size = bytes.len, .mv_data = @ptrCast(@constCast(bytes.ptr)) };
}

/// The bytes an `MDB_val` describes. Borrowed from the map, never copied.
fn rawBytes(val: lmdb.c.MDB_val) []const u8 {
    if (val.mv_size == 0) return "";
    const bytes: [*]const u8 = @ptrCast(val.mv_data.?);
    return bytes[0..val.mv_size];
}

/// A raw call's status, checked against upstream's own success value rather
/// than folded into a facade error: this program is exercising `lmdb.c`, and the
/// raw route is what an outside C caller would see.
fn checkStatus(what: []const u8, rc: c_int) Failure!void {
    if (rc == lmdb.c.MDB_SUCCESS) return;
    std.debug.print("consumer: {s} returned {d}: {s}\n", .{ what, rc, lmdb.strerror(rc) });
    return error.RawCallFailed;
}

// ------------------------------------------------------- the scratch directory

/// One isolated directory below a caller-supplied root.
///
/// LMDB does not create the environment directory, so this does, and it hands
/// `mdb_env_open` an absolute path because the C requires one.
const Scratch = struct {
    parent: std.Io.Dir,
    sub_path: [sub_path_len]u8,
    path: [:0]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init(io: std.Io, gpa: std.mem.Allocator, root: []const u8) !Scratch {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        // A relative root is taken against the working directory, because the
        // C is handed an absolute path and the caller's own root is left as it
        // was given.
        const absolute_root = if (std.fs.path.isAbsolute(root))
            try gpa.dupeZ(u8, root)
        else blk: {
            const cwd = try std.process.currentPathAlloc(io, gpa);
            defer gpa.free(cwd);
            break :blk try std.fs.path.joinZ(gpa, &.{ @as([]const u8, cwd), root });
        };
        defer gpa.free(absolute_root);

        // The root is made when it is not there yet. Only the random child made
        // below it belongs to this program, and only that one is removed.
        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, absolute_root, .{});
        errdefer parent.close(io);
        try parent.createDirPath(io, &sub_path);

        const path = std.fs.path.joinZ(gpa, &.{ @as([]const u8, absolute_root), &sub_path }) catch |err| {
            // The child is there from here on, so a path that cannot be built
            // must not leave it behind.
            parent.deleteTree(io, &sub_path) catch {};
            return err;
        };

        return .{ .parent = parent, .sub_path = sub_path, .path = path };
    }

    fn deinit(self: *Scratch, io: std.Io, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.parent.deleteTree(io, &self.sub_path) catch {};
        self.parent.close(io);
    }
};

// ------------------------------------------------------------------- arguments

/// The provider a runtime-loading build should open, from `--provider <path>`
/// or from `LMDB_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location, and a build
/// that was not told which file to open says so rather than loading something
/// else or falling back to a linked copy.
fn providerRequest(init: std.process.Init.Minimal, gpa: std.mem.Allocator) Failure![]const u8 {
    const args = try init.args.toSlice(gpa);
    if (valueAfter(args, "--provider")) |path| return path;
    return init.environ.getAlloc(gpa, provider_variable) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableMissing, error.InvalidWtf8 => return noProvider(),
    };
}

fn noProvider() Failure {
    std.debug.print(
        "consumer: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export " ++ provider_variable ++ " with a shared object exporting " ++
            "the mdb_* entry points of libraries/liblmdb/lmdb.h. Nothing is " ++
            "loaded by default and no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// The directory the caller wants the environment under, from
/// `--scratch <dir>` or from `LMDB_TEST_SCRATCH`.
///
/// There is deliberately no third answer. A consumer that invented a location
/// would put an LMDB data file somewhere the caller never agreed to, and the
/// two places such a program usually picks are exactly the two nobody wants a
/// database in.
fn scratchRequest(init: std.process.Init.Minimal, gpa: std.mem.Allocator) Failure![]const u8 {
    const args = try init.args.toSlice(gpa);
    if (valueAfter(args, "--scratch")) |path| return path;
    return init.environ.getAlloc(gpa, scratch_variable) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableMissing, error.InvalidWtf8 => return noScratch(),
    };
}

fn noScratch() Failure {
    std.debug.print(
        "consumer: no database location. Pass --scratch <dir>, or export " ++
            scratch_variable ++ " with a directory this program may create one " ++
            "randomly named child of. TMPDIR is not consulted, /tmp is never " ++
            "touched, and nothing is written into the source tree.\n",
        .{},
    );
    return error.NoScratchConfigured;
}

/// The value that follows `flag`, or null when the flag is not there or has
/// nothing after it.
fn valueAfter(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    // `args[0]` is this program's own path.
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], flag)) {
            if (index + 1 >= args.len) return null;
            return args[index + 1];
        }
    }
    return null;
}

// ------------------------------------------------------------------------ main

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    // In a runtime-loading build nothing below can run until a provider is
    // loaded, and the load is the one explicit step the contract asks for. In a
    // linked build this is a no-op at comptime and the module is already
    // usable.
    if (comptime lmdb.runtime_loaded) {
        try lmdb.load(.{ .path = try providerRequest(init, gpa) });
    }

    var scratch = try Scratch.init(io, gpa, try scratchRequest(init, gpa));
    defer scratch.deinit(io, gpa);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;

    try out.print("lmdb consumer\n", .{});
    try out.print("{s} LMDB library {s}\n", .{
        if (lmdb.runtime_loaded) "loaded" else "linked",
        lmdb.versionString(),
    });
    try out.print("environment {s}\n", .{scratch.path});

    try writeAndCommit(scratch.path);
    try writeAndAbandon(scratch.path);
    try readBackThroughBothRoutes(scratch.path, out);

    try out.print("committed records persisted, abandoned ones did not, " ++
        "both routes agreed\n", .{});
    try out.flush();
}

// ---------------------------------------------------------------- the database

/// Write the committed records, one of them through the raw route, and commit.
///
/// Only the unnamed database is opened, so the environment is asked for no
/// named-database slots: `mdb_env_set_maxdbs` would have to be repeated on every
/// later handle, and nothing here needs it.
fn writeAndCommit(path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{ .path = path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    for (committed) |record| try txn.put(db, record.key, record.value);

    // The raw route, on the same native transaction the typed wrapper above is
    // holding: `mdb_put` takes the `MDB_txn *` and the `MDB_dbi` the typed
    // call just produced, so this record lands in the same tree as the others
    // and in the same commit.
    var raw_key = rawValue(through_raw.key);
    var raw_data = rawValue(through_raw.value);
    try checkStatus("mdb_put", lmdb.c.mdb_put(txn.handle.?, db.dbi, &raw_key, &raw_data, 0));

    try txn.commit();
    try env.sync(true);
}

/// Write records in a second transaction and abandon it.
///
/// Overwriting a committed record and adding a new one, in the transaction that
/// is then dropped, is what a later reader must not see.
fn writeAndAbandon(path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{ .path = path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    for (abandoned) |record| try txn.put(db, record.key, record.value);
    try require(
        std.mem.eql(u8, "clobbered", try txn.get(db, "alpha")),
        "the abandoned transaction sees its own write",
    );
    txn.abort();
}

/// Open the directory again — a new handle, a new mapping, a new transaction —
/// and check the file through the typed route and the raw one.
fn readBackThroughBothRoutes(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    // Asked for one key at a time, so what is compared is the value that key
    // was stored with and not whatever the walks below are standing on.
    for (expected_order) |record| {
        const found = txn.get(db, record.key) catch |err| {
            std.debug.print("consumer: {s} is missing after the reopen: error.{s}\n", .{
                record.key,
                @errorName(err),
            });
            return error.WrongValue;
        };
        if (!std.mem.eql(u8, record.value, found)) {
            std.debug.print("consumer: {s} came back as {s}, expected {s}\n", .{
                record.key,
                found,
                record.value,
            });
            return error.WrongValue;
        }
    }

    // "clobbered" must not have replaced "one", and the record the abandoned
    // transaction added must not be there at all. `delta` is deliberately not
    // in this list: it was committed, through the raw route, and is required
    // above.
    try require(
        std.mem.eql(u8, "one", try txn.get(db, "alpha")),
        "the abandoned overwrite never reached the file",
    );
    try require(
        if (txn.get(db, "epsilon")) |_| false else |err| err == error.NotFound,
        "the record the abandoned transaction added is absent",
    );

    try walkThroughTypedRoute(&txn, db);
    try walkThroughRawRoute(&txn, db, out);
}

/// Walk the whole database with the typed cursor and require exactly the
/// records the file should hold.
fn walkThroughTypedRoute(txn: *lmdb.Transaction, db: lmdb.Database) !void {
    var cursor = try txn.openCursor(db);
    defer cursor.close();

    var seen: usize = 0;
    var entry = try cursor.first();
    while (true) {
        if (seen >= expected_order.len) return error.UnexpectedRecord;
        if (!std.mem.eql(u8, expected_order[seen].key, entry.key)) {
            return error.UnexpectedRecord;
        }
        if (!std.mem.eql(u8, expected_order[seen].value, entry.value)) return error.WrongValue;
        seen += 1;
        const next = cursor.next();
        if (next) |following| {
            entry = following;
        } else |err| {
            try require(err == error.NotFound, "the typed walk ends with NotFound");
            break;
        }
    }
    try require(seen == expected_order.len, "the typed walk found every committed record and no more");
}

/// Walk the whole database again through `lmdb.c`, on the same transaction and
/// the same database handle, and require the same bytes.
///
/// This is the raw route doing real work on real data rather than reporting a
/// version: `mdb_get` for each key, `mdb_cursor_open` for the walk, and
/// `mdb_cursor_get` with `MDB_FIRST` and `MDB_NEXT`. The cursor this opens is
/// closed by the same call that opened it, so nothing here is left for the
/// typed wrapper — or for a different provider — to release.
fn walkThroughRawRoute(txn: *lmdb.Transaction, db: lmdb.Database, out: *std.Io.Writer) !void {
    for (expected_order) |record| {
        var key = rawValue(record.key);
        var data: lmdb.c.MDB_val = undefined;
        try checkStatus("mdb_get", lmdb.c.mdb_get(txn.handle.?, db.dbi, &key, &data));
        if (!std.mem.eql(u8, record.value, rawBytes(data))) return error.WrongValue;
    }

    var raw_cursor: ?*lmdb.c.MDB_cursor = null;
    try checkStatus(
        "mdb_cursor_open",
        lmdb.c.mdb_cursor_open(txn.handle.?, db.dbi, &raw_cursor),
    );
    const handle = raw_cursor orelse return error.RawCallFailed;
    defer lmdb.c.mdb_cursor_close(handle);

    var seen: usize = 0;
    var op: lmdb.c.MDB_cursor_op = @intCast(lmdb.c.MDB_FIRST);
    while (true) {
        var key: lmdb.c.MDB_val = .{ .mv_size = 0, .mv_data = undefined };
        var data: lmdb.c.MDB_val = .{ .mv_size = 0, .mv_data = undefined };
        const rc = lmdb.c.mdb_cursor_get(handle, &key, &data, op);
        if (rc == lmdb.c.MDB_NOTFOUND) break;
        try checkStatus("mdb_cursor_get", rc);

        if (seen >= expected_order.len) return error.UnexpectedRecord;
        if (!std.mem.eql(u8, expected_order[seen].key, rawBytes(key))) {
            return error.UnexpectedRecord;
        }
        if (!std.mem.eql(u8, expected_order[seen].value, rawBytes(data))) {
            return error.WrongValue;
        }
        seen += 1;
        op = @intCast(lmdb.c.MDB_NEXT);
    }
    try require(seen == expected_order.len, "the raw walk found every committed record and no more");

    // The record the abandoned transaction added is absent through the raw route
    // as well, which is a second answer to the same question rather than a
    // restatement of the first.
    var key = rawValue("epsilon");
    var data: lmdb.c.MDB_val = undefined;
    try require(
        lmdb.c.mdb_get(txn.handle.?, db.dbi, &key, &data) == lmdb.c.MDB_NOTFOUND,
        "the raw route agrees the abandoned record is absent",
    );

    try out.print("both routes walked {d} records in the same order\n", .{seen});
}
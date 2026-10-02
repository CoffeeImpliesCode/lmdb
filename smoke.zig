//! A runnable demonstration of the LMDB facade, and a check of it.
//!
//! Every value below is fixed, so the output is the same on every host and a
//! change in it is a change in behaviour rather than in timing or in a random
//! seed. The one exception is the width of the main database's catalogue
//! record, which is the width of the core's own `MDB_db` and so follows the
//! word size of the target; it is printed because it is also checked. The
//! program fails — non-zero, with the observation that disagreed named on
//! stderr — the moment an expectation is not met, so `zig build smoke` is a
//! check and not a demo that always succeeds.
//!
//! What it exercises that `tests.zig` does not is the whole lifecycle in one
//! process, in order: create, configure, open, write, commit, sync, close,
//! reopen read-only, walk, and release. The library version is printed at the
//! top so the output names the upstream it exercised; it is read back out of
//! the compiled core rather than taken from a constant.
//!
//! The environment lives in a directory of its own under the temporary root
//! the process was started with — `TMPDIR`, and on Windows `TEMP` then `TMP`
//! — and that directory is removed on the way out. A host that names no
//! temporary root gets `.zig-cache/tmp/<random>`, the convention
//! `std.testing.tmpDir` uses.

const std = @import("std");
const lmdb = @import("lmdb");
const builtin = @import("builtin");

/// The upstream release the C in this tree is pinned to; the version *number*
/// checked below comes from the compiled library itself.
const upstream_tag = "LMDB_1.0.1";

/// A failed observation, named.
fn require(ok: bool, what: []const u8) error{Disagreed}!void {
    if (!ok) {
        std.debug.print("smoke: disagreed: {s}\n", .{what});
        return error.Disagreed;
    }
}

/// The same, for an observation whose expectation is an error rather than a
/// value.
fn requireError(expected: anyerror, result: anytype, what: []const u8) error{Disagreed}!void {
    if (result) |_| {
        std.debug.print("smoke: disagreed: {s}: expected error.{s}, found a value\n", .{
            what,
            @errorName(expected),
        });
        return error.Disagreed;
    } else |actual| {
        if (actual != expected) {
            std.debug.print("smoke: disagreed: {s}: expected error.{s}, found error.{s}\n", .{
                what,
                @errorName(expected),
                @errorName(actual),
            });
            return error.Disagreed;
        }
    }
}

/// The environment variables that name a temporary root, in the order they are
/// consulted: `TMPDIR` on every platform, the Windows spellings after it.
/// A variable that is unset or empty names no directory.
const temp_root_vars: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "TMPDIR", "TEMP", "TMP" }
else
    &.{"TMPDIR"};

/// The directory a scratch environment is created under, as an absolute path:
/// what the temporary root variable names — taken against the working
/// directory when it is relative, because `mdb_env_open` is handed an absolute
/// path — or `.zig-cache/tmp` under the working directory when the environment
/// names no temporary root at all, which is what `std.testing.tmpDir` uses and
/// what keeps a host that configures none portable.
fn scratchRootAlloc(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ) ![:0]u8 {
    for (temp_root_vars) |name| {
        const value = environ.getAlloc(gpa, name) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // Not set, or not a name this platform can spell: try the next.
            error.EnvironmentVariableMissing, error.InvalidWtf8 => continue,
        };
        defer gpa.free(value);
        if (value.len == 0) continue;
        if (std.fs.path.isAbsolute(value)) return try gpa.dupeZ(u8, value);
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        return try std.fs.path.joinZ(gpa, &.{ @as([]const u8, cwd), value });
    }

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return try std.fs.path.joinZ(gpa, &.{ @as([]const u8, cwd), ".zig-cache", "tmp" });
}

/// One temporary directory holding one LMDB environment directory.
///
/// `std.testing.tmpDir` is compiled only into test binaries, so this mirrors
/// it: a random name under the temporary root, an absolute path for
/// `mdb_env_open` — which needs one, and which does not create the directory
/// itself, because `mdb.c` contains no `mkdir` — and a recursive removal of
/// that random child and nothing else, which leaves the root and every other
/// name in it as they were.
const Scratch = struct {
    parent: std.Io.Dir,
    sub_path: [sub_path_len]u8,
    path: [:0]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ) !Scratch {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        const root = try scratchRootAlloc(io, gpa, environ);
        defer gpa.free(root);

        // The root is made when it is not there yet. Only the random child
        // made below it belongs to this program, and only that one is removed.
        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
        errdefer parent.close(io);
        try parent.createDirPath(io, &sub_path);

        const path = std.fs.path.joinZ(gpa, &.{ @as([]const u8, root), &sub_path }) catch |err| {
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

const Record = struct { key: []const u8, value: []const u8 };

/// The records the demonstration stores, in a write order that is not the
/// order they sort into.
const records = [_]Record{
    .{ .key = "gamma", .value = "third" },
    .{ .key = "alpha", .value = "first" },
    .{ .key = "beta", .value = "second" },
};

/// The name the duplicates database below is opened under.
const sorted_name = "sorted";

/// The key the main database catalogues that name under.
///
/// `mdb_dbi_open` measures the name as a C string and then stores that many
/// bytes of it (mdb.c:12302, :12327-12328), so the key is the name with a
/// terminator the name does not itself spell.
const sorted_catalog_key = sorted_name ++ "\x00";

/// The order a forward walk of the main database must produce, written out
/// with the value each key was stored with rather than keyed against itself:
/// byte-lexicographic with the shorter item first (mdb.c:6659-6675), and not
/// the write order above.
const expected_order = [_]Record{
    .{ .key = "alpha", .value = "first" },
    .{ .key = "beta", .value = "second" },
    .{ .key = "gamma", .value = "third" },
};

/// The duplicates written under one key, again out of order for the same
/// reason, and the order they must come back in.
const duplicates = [_][]const u8{ "delta", "alpha", "gamma", "beta" };
const expected_duplicates = [_][]const u8{ "alpha", "beta", "delta", "gamma" };

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.heap.page_allocator;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;

    const version = lmdb.version();
    try out.print("lmdb smoke\n", .{});
    try out.print("upstream tag {s}\n", .{upstream_tag});
    try out.print("linked library version {d}.{d}.{d}\n", .{
        version.major,
        version.minor,
        version.patch,
    });

    var scratch = try Scratch.init(io, gpa, init.environ);
    defer scratch.deinit(io, gpa);
    try out.print("environment {s}\n", .{scratch.path});

    try out.print("\nwrite, commit, sync, reopen\n", .{});
    try writeAndCommit(scratch.path);
    try readBackAndWalk(scratch.path, out);
    try duplicatesUnderOneKey(scratch.path, out);
    try boundariesAndErrors(scratch.path, out);
    try borrowFromTheMap(scratch.path, out);

    try out.print("\nall observations agreed\n", .{});
    try out.flush();
}

/// Create, configure and open the environment, write the records and the
/// duplicates, commit, and release everything. The reopen in the next step is
/// what proves the commit reached the file.
fn writeAndCommit(path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{
        .path = path,
        .max_dbs = 1,
        .map_size = 4 << 20,
    });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();

    const database = try txn.openDatabase(null, .{});
    for (records) |record| try txn.put(database, record.key, record.value);

    const sorted = try txn.openDatabase(sorted_name, .{ .dupsort = true, .create = true });
    for (duplicates) |value| try txn.put(sorted, "key", value);

    try txn.commit();
    try env.sync(true);
}

/// Reopen read-only — a different environment handle, a different mapping of
/// the lock file and a different transaction — and check that exactly the
/// committed bytes came back, in exactly the order the C collates them.
fn readBackAndWalk(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    // Asked for one key at a time, so what is compared is the value that key
    // was stored with and not whatever the walk below is standing on.
    for (records) |record| {
        try require(
            std.mem.eql(u8, record.value, try txn.get(db, record.key)),
            "a committed value survives a reopen byte for byte",
        );
    }

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    var entry = try cursor.first();
    for (expected_order, 0..) |record, index| {
        try require(std.mem.eql(u8, record.key, entry.key), "the forward walk yields the collated key");
        try require(std.mem.eql(u8, record.value, entry.value), "the forward walk yields the record's own value");
        if (index + 1 < expected_order.len) entry = try cursor.next();
    }

    // A named database is catalogued in the main database, so the walk of the
    // main database reaches that record as well: 's' collates after 'g', so it
    // comes last. It is required rather than stepped over, because it is what
    // the main database holds and a walk that hid it would be walking over
    // less than the database contains.
    const catalog = try cursor.next();
    try require(
        std.mem.eql(u8, sorted_catalog_key, catalog.key),
        "the main database catalogues the named database under its own name",
    );

    try require(
        if (cursor.next()) |_| false else |err| err == error.NotFound,
        "the forward walk stops after the last record",
    );

    try out.print("cursor walk", .{});
    for (expected_order) |record| try out.print(" {s}={s}", .{ record.key, record.value });
    try out.print(" {s}\\0=catalogued, {d} opaque bytes\n", .{ sorted_name, catalog.value.len });
}

/// A `DUPSORT` database keeps its duplicates sorted. Walk them from both ends
/// and check the count agrees with what was written.
fn duplicatesUnderOneKey(path: [:0]const u8, out: *std.Io.Writer) !void {
    // The slot table is not part of the environment file: `mdb_env_create`
    // sizes it to the two databases upstream keeps for itself (mdb.c:5028)
    // and only `mdb_env_set_maxdbs` grows it, so this reopen asks again
    // exactly as `writeAndCommit` did (lmdb.h:1326-1327, mdb.c:12316-12318).
    var env = try lmdb.Environment.init(.{
        .path = path,
        .max_dbs = 1,
        .flags = .{ .rdonly = true },
    });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(sorted_name, .{});

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    // FIRST_DUP and LAST_DUP are EINVAL until the cursor is on a key
    // (mdb.c:8467-8469), so the walk starts from the key itself.
    try requireError(
        error.InvalidArgument,
        cursor.firstDup(),
        "firstDup on an unpositioned cursor",
    );
    const on_key = try cursor.set("key");
    try require(std.mem.eql(u8, "key", on_key.key), "the seek lands on the key it was given");
    try require(std.mem.eql(u8, "alpha", on_key.value), "the seek yields the key's first value");

    var entry = try cursor.firstDup();
    try require(std.mem.eql(u8, "", entry.key), "firstDup returns no key for a key that carries duplicates");
    try require(std.mem.eql(u8, "alpha", entry.value), "firstDup yields the sorted first value");
    try require(std.mem.eql(u8, "key", (try cursor.current()).key), "the key is still readable while on a duplicate");
    try require(
        (try cursor.count()) == expected_duplicates.len,
        "the duplicate count matches what was written",
    );

    for (expected_duplicates, 0..) |value, index| {
        try require(std.mem.eql(u8, value, entry.value), "the duplicate walk yields the sorted value");
        if (index + 1 < expected_duplicates.len) {
            entry = try cursor.nextDup();
        } else {
            try requireError(
                error.NotFound,
                cursor.nextDup(),
                "the duplicate walk past the last value",
            );
        }
    }

    entry = try cursor.lastDup();
    var index = expected_duplicates.len;
    while (index > 0) {
        index -= 1;
        try require(std.mem.eql(u8, expected_duplicates[index], entry.value), "the reverse walk is the mirror");
        if (index == 0) {
            try requireError(
                error.NotFound,
                cursor.prevDup(),
                "the reverse walk before the first value",
            );
        } else {
            entry = try cursor.prevDup();
        }
    }

    try out.print("duplicates", .{});
    for (expected_duplicates) |value| try out.print(" {s}", .{value});
    try out.print("\n", .{});
}

/// The boundaries that are errors rather than values.
fn boundariesAndErrors(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    try require(
        if (txn.get(db, "absent")) |_| false else |err| err == error.NotFound,
        "a key that was never stored reports NotFound",
    );
    try require(
        if (txn.putNoOverwrite(db, "alpha", "second")) |_| false else |err| err == error.KeyExists,
        "putNoOverwrite on a stored key reports KeyExists",
    );
    try require(
        std.mem.eql(u8, "first", try txn.get(db, "alpha")),
        "the rejected write left the stored value alone",
    );
    try require(
        if (txn.put(db, "", "value")) |_| false else |err| err == error.EmptyKey,
        "an empty key is refused before it reaches the core",
    );
    try txn.put(db, "delta", "");
    try require(
        std.mem.eql(u8, "", try txn.get(db, "delta")),
        "an empty value is stored and read back as itself",
    );
    try txn.delete(db, "delta");

    // Abandon everything and release the handle. The deferred abort that
    // follows is a no-op, which is the point of clearing the handle in both
    // commit and abort rather than only in one of them.
    txn.abort();
    try require(
        if (txn.get(db, "alpha")) |_| false else |err| err == error.TransactionClosed,
        "a released transaction refuses further use",
    );

    var reader = try env.beginReadOnly();
    defer reader.abort();
    const read_db = try reader.openDatabase(null, .{});
    try require(
        std.mem.eql(u8, "first", try reader.get(read_db, "alpha")),
        "the abandoned write never reached the database",
    );
    try require(
        if (reader.put(read_db, "alpha", "clobber")) |_| false else |err| err == error.IsReadOnly,
        "a read-only transaction refuses a write",
    );

    var read_cursor = try reader.openCursor(read_db);
    defer read_cursor.close();
    try require(
        if (read_cursor.putCurrent("alpha", "clobber")) |_| false else |err| err == error.IsReadOnly,
        "a read-only cursor refuses a write",
    );
    try require(
        if (read_cursor.deleteCurrent()) |_| false else |err| err == error.IsReadOnly,
        "a read-only cursor refuses a delete",
    );

    try out.print("boundaries NotFound KeyExists EmptyKey TransactionClosed IsReadOnly\n", .{});
}

/// The borrowing rule the header states in prose (lmdb.h:1521-1526): the bytes
/// a read returns belong to the map, so two reads with nothing written between
/// them hand back the same address rather than a fresh copy, and they are
/// still there after other keys have been read.
fn borrowFromTheMap(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    const first = try txn.get(db, "alpha");
    try require(std.mem.eql(u8, "first", first), "the borrowed bytes are the stored ones");

    // A read of another key may fault pages in; it must not invalidate or
    // relocate the slice already handed out.
    const other = try txn.get(db, "gamma");
    try require(std.mem.eql(u8, "third", other), "the other key reads back too");
    try require(std.mem.eql(u8, "first", first), "the first slice still reads correctly afterwards");

    const second = try txn.get(db, "alpha");
    try require(
        first.ptr == second.ptr and first.len == second.len,
        "two reads with nothing written between them borrow the same map bytes",
    );

    try out.print("borrowed {d} bytes at 0x{x} survive an unrelated read\n", .{
        first.len,
        @intFromPtr(first.ptr),
    });
}

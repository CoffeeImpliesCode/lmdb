//! Out-of-tree consumer of LMDB's typed facade and raw C API.
//! Checks persisted transactions after reopening the environment.
//! Requires an explicit scratch root; runtime builds also require a provider.

const std = @import("std");
const lmdb = @import("lmdb");

/// Environment variable naming the runtime provider.
const provider_variable = "LMDB_TEST_PROVIDER";

/// The directory the caller wants the scratch environment created under.
const scratch_variable = "LMDB_TEST_SCRATCH";

/// Everything this program can stop for, named.
const Failure = error{
    /// A facade or raw observation did not match.
    Disagreed,
    /// A committed record has different bytes.
    WrongValue,
    /// The database contains an unexpected record.
    UnexpectedRecord,
    /// A runtime build has no provider path.
    NoProviderConfigured,
    /// No scratch directory was supplied.
    NoScratchConfigured,
    /// A raw LMDB call returned an error status.
    RawCallFailed,
    /// Platform argument parsing returned an unexpected error.
    Unexpected,
} || std.mem.Allocator.Error;

const Record = struct { key: []const u8, value: []const u8 };

/// Records written and committed by the fixture transaction.
const committed = [_]Record{
    .{ .key = "alpha", .value = "one" },
    .{ .key = "beta", .value = "two" },
    .{ .key = "gamma", .value = "three" },
};

/// Record inserted through the raw route inside the committed transaction.
const through_raw = Record{ .key = "delta", .value = "four" };

/// Records written only by the abandoned transaction.
const abandoned = [_]Record{
    .{ .key = "alpha", .value = "clobbered" },
    .{ .key = "epsilon", .value = "five" },
};

/// Expected byte-lexicographic cursor order (`mdb.c:6659-6675`).
const expected_order = [_]Record{
    .{ .key = "alpha", .value = "one" },
    .{ .key = "beta", .value = "two" },
    .{ .key = "delta", .value = "four" },
    .{ .key = "gamma", .value = "three" },
};

fn require(ok: bool, what: []const u8) Failure!void {
    if (!ok) {
        std.debug.print("consumer: disagreed: {s}\n", .{what});
        return error.Disagreed;
    }
}

/// Describe caller-owned bytes for a raw C call.
fn rawValue(bytes: []const u8) lmdb.c.MDB_val {
    return .{ .mv_size = bytes.len, .mv_data = @ptrCast(@constCast(bytes.ptr)) };
}

/// Return borrowed bytes from an `MDB_val`; no copy is made.
fn rawBytes(val: lmdb.c.MDB_val) []const u8 {
    if (val.mv_size == 0) return "";
    const bytes: [*]const u8 = @ptrCast(val.mv_data.?);
    return bytes[0..val.mv_size];
}

/// Require an `MDB_SUCCESS` status from a raw call.
fn checkStatus(what: []const u8, rc: c_int) Failure!void {
    if (rc == lmdb.c.MDB_SUCCESS) return;
    std.debug.print("consumer: {s} returned {d}: {s}\n", .{ what, rc, lmdb.strerror(rc) });
    return error.RawCallFailed;
}

/// Own one generated child directory under the caller's scratch root.
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

        // LMDB requires an absolute path.
        const absolute_root = if (std.fs.path.isAbsolute(root))
            try gpa.dupeSentinel(u8, root, 0)
        else blk: {
            const cwd = try std.process.currentPathAlloc(io, gpa);
            defer gpa.free(cwd);
            break :blk try std.fs.path.joinZ(gpa, &.{ @as([]const u8, cwd), root });
        };
        defer gpa.free(absolute_root);

        // The parent is caller-owned; cleanup removes only this random child.
        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, absolute_root, .{});
        errdefer parent.close(io);
        try parent.createDirPath(io, &sub_path);

        const path = std.fs.path.joinZ(gpa, &.{ @as([]const u8, absolute_root), &sub_path }) catch |err| {
            // Remove the child if its returned path cannot be built.
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

/// Require the explicit provider path for runtime-loading builds.
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

/// Require an explicit scratch root; no default location is used.
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

/// Return the argument following `flag`, or null when absent.
fn valueAfter(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    // Argument zero is the executable path.
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], flag)) {
            if (index + 1 >= args.len) return null;
            return args[index + 1];
        }
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    // Runtime builds load the explicit provider before any LMDB call.
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

/// Write committed fixture records, including one raw C insertion.
fn writeAndCommit(path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{ .path = path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    for (committed) |record| try txn.put(db, record.key, record.value);

    // Use the typed transaction and database handle for the raw insertion.
    var raw_key = rawValue(through_raw.key);
    var raw_data = rawValue(through_raw.value);
    try checkStatus("mdb_put", lmdb.c.mdb_put(txn.handle.?, db.dbi, &raw_key, &raw_data, 0));

    try txn.commit();
    try env.sync(true);
}

/// Write an overwrite and new record in a transaction that is abandoned.
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

/// Reopen the environment and check both typed and raw routes.
fn readBackThroughBothRoutes(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    // Compare each key independently of cursor iteration.
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

    // The abandoned overwrite and added record must not persist.
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

/// Require the typed cursor to return exactly the expected records.
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

/// Check records through the raw C API on the same transaction; close its cursor through C.
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

    // The raw route must also omit the abandoned record.
    var key = rawValue("epsilon");
    var data: lmdb.c.MDB_val = undefined;
    try require(
        lmdb.c.mdb_get(txn.handle.?, db.dbi, &key, &data) == lmdb.c.MDB_NOTFOUND,
        "the raw route agrees the abandoned record is absent",
    );

    try out.print("both routes walked {d} records in the same order\n", .{seen});
}

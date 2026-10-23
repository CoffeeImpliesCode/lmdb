//! Deterministic smoke check for the LMDB facade, covering create through read-only reopen.
//! It checks each observation and removes its temporary environment.
//! Runtime-loaded builds need `--provider <path>` or `LMDB_TEST_PROVIDER`; linked builds do not.

const std = @import("std");
const lmdb = @import("lmdb");
const builtin = @import("builtin");

/// Runtime provider environment variable for a shared object exporting `mdb_*`.
const provider_variable = "LMDB_TEST_PROVIDER";

/// Provider-selection errors, including allocation failures.
const ConfigurationError = error{ NoProviderConfigured, Unexpected } || std.mem.Allocator.Error;

/// Select the provider from `--provider <path>` or `LMDB_TEST_PROVIDER`.
fn providerRequest(
    init: std.process.Init.Minimal,
    arena: std.mem.Allocator,
) ConfigurationError![]const u8 {
    const args = try init.args.toSlice(arena);
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ.getAlloc(arena, provider_variable) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableMissing, error.InvalidWtf8 => return noProvider(),
    };
}

/// Return the missing-provider error with its configuration hint.
fn noProvider() ConfigurationError {
    std.debug.print(
        "smoke: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export " ++ provider_variable ++ " with a shared object exporting " ++
            "the mdb_* entry points of libraries/liblmdb/lmdb.h. Nothing is " ++
            "loaded by default and no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// Pinned upstream release; the checked version comes from the compiled library.
const upstream_tag = "LMDB_1.0.1";

/// Fail with a named observation when its expectation is false.
fn require(ok: bool, what: []const u8) error{Disagreed}!void {
    if (!ok) {
        std.debug.print("smoke: disagreed: {s}\n", .{what});
        return error.Disagreed;
    }
}

/// Fail with a named observation when the result does not match `expected`.
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

/// Temporary-root variables, checked in order; unset or empty values are skipped.
const temp_root_vars: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "TMPDIR", "TEMP", "TMP" }
else
    &.{"TMPDIR"};

/// Return an absolute scratch root from the environment or `.zig-cache/tmp`.
/// Resolve relative roots against the working directory for `mdb_env_open`.
fn scratchRootAlloc(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ) ![:0]u8 {
    for (temp_root_vars) |name| {
        const value = environ.getAlloc(gpa, name) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.EnvironmentVariableMissing, error.InvalidWtf8 => continue,
        };
        defer gpa.free(value);
        if (value.len == 0) continue;
        if (std.fs.path.isAbsolute(value)) return try gpa.dupeSentinel(u8, value, 0);
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        return try std.fs.path.joinZ(gpa, &.{ @as([]const u8, cwd), value });
    }

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return try std.fs.path.joinZ(gpa, &.{ @as([]const u8, cwd), ".zig-cache", "tmp" });
}

/// Temporary root and random child holding one LMDB environment.
/// Cleanup removes only the child.
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

        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
        errdefer parent.close(io);
        try parent.createDirPath(io, &sub_path);

        const path = std.fs.path.joinZ(gpa, &.{ @as([]const u8, root), &sub_path }) catch |err| {
            // Remove the child if constructing its path fails.
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

/// Records inserted out of their sorted order.
const records = [_]Record{
    .{ .key = "gamma", .value = "third" },
    .{ .key = "alpha", .value = "first" },
    .{ .key = "beta", .value = "second" },
};

/// Named-database name.
const sorted_name = "sorted";

/// LMDB stores a named database's catalogue key as its NUL-terminated name.
const sorted_catalog_key = sorted_name ++ "\x00";

/// Expected main-database cursor order under upstream byte collation.
const expected_order = [_]Record{
    .{ .key = "alpha", .value = "first" },
    .{ .key = "beta", .value = "second" },
    .{ .key = "gamma", .value = "third" },
};

/// Duplicate values and their expected sorted order.
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

    if (comptime lmdb.runtime_loaded) {
        try lmdb.load(.{ .path = try providerRequest(init, gpa) });
    }

    const version = lmdb.version();
    try out.print("lmdb smoke\n", .{});
    try out.print("upstream tag {s}\n", .{upstream_tag});
    const route = if (lmdb.runtime_loaded) "loaded" else "linked";
    try out.print("{s} library version {s}\n", .{ route, lmdb.versionString() });
    try out.print("library reports {d}.{d}.{d}; MDB_NOTFOUND is \"{s}\"\n", .{
        version.major,
        version.minor,
        version.patch,
        lmdb.strerror(lmdb.c.MDB_NOTFOUND),
    });

    var scratch = try Scratch.init(io, gpa, init.environ);
    defer scratch.deinit(io, gpa);
    try out.print("environment {s}\n", .{scratch.path});

    try out.print("\nwrite, commit, sync, reopen\n", .{});
    try writeAndCommit(scratch.path);
    try readBackAndWalk(scratch.path, out);
    try borrowFromTheMap(scratch.path, out);
    try duplicatesUnderOneKey(scratch.path, out);
    try boundariesAndErrors(scratch.path, out);
    try twoPhaseCommit(scratch.path, out);

    try out.print("\nall observations agreed\n", .{});
    try out.flush();
}

/// Write records and duplicates, commit, then release the environment.
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

/// Prepare then commit or abort transactions, checking which writes become visible.
fn twoPhaseCommit(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path });
    defer env.close();

    var kept = try env.beginWrite();
    defer kept.abort();
    const kept_db = try kept.openDatabase(null, .{});
    try kept.put(kept_db, "prepared-and-committed", "kept");
    try kept.prepare();
    try requireError(
        error.TxnPending,
        kept.get(kept_db, "prepared-and-committed"),
        "a prepared transaction answers only commit and abort",
    );
    try kept.commit();

    var lost = try env.beginWrite();
    defer lost.abort();
    const lost_db = try lost.openDatabase(null, .{});
    try lost.put(lost_db, "prepared-and-abandoned", "lost");
    try lost.prepare();
    lost.abort();

    var reader = try env.beginReadOnly();
    defer reader.abort();
    const db = try reader.openDatabase(null, .{});
    try require(
        std.mem.eql(u8, "kept", try reader.get(db, "prepared-and-committed")),
        "the prepared transaction's pages reached the database when it committed",
    );
    try require(
        if (reader.get(db, "prepared-and-abandoned")) |_| false else |err| err == error.NotFound,
        "the abandoned prepared transaction left no record",
    );

    try out.print("prepared: committed record kept, abandoned record absent\n", .{});
}

/// Reopen read-only and verify committed records in cursor order.
fn readBackAndWalk(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

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

    // Named databases also appear as catalogue records in the main-database walk.
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

/// Check sorted traversal and count for duplicate values.
fn duplicatesUnderOneKey(path: [:0]const u8, out: *std.Io.Writer) !void {
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

/// Check boundary errors from the native facade.
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

    // Aborting spends the handle, so later operations return `TransactionClosed`.
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

/// Verify that reads borrow stable memory-map bytes until an update or transaction end.
fn borrowFromTheMap(path: [:0]const u8, out: *std.Io.Writer) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    const first = try txn.get(db, "alpha");
    try require(std.mem.eql(u8, "first", first), "the borrowed bytes are the stored ones");

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

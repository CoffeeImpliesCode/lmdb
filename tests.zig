//! Behavioral tests for the LMDB facade, using a hand-ordered corpus and native LMDB.
//! Each test creates an isolated sandbox; named databases require `.max_dbs`.
//! Runtime-loaded builds require `LMDB_TEST_PROVIDER`; linked builds do not.

const std = @import("std");
const lmdb = @import("lmdb");
const builtin = @import("builtin");

const io = std.testing.io;
const gpa = std.testing.allocator;

/// Runtime provider environment variable for a shared object exporting `mdb_*`.
const provider_variable = "LMDB_TEST_PROVIDER";

/// Load the explicit provider once when runtime loading is enabled; linked builds need no load.
fn nativeReady() void {
    if (comptime !lmdb.runtime_loaded) return;
    if (lmdb.loadedSource() != null) return;

    var buffer: [4096]u8 = undefined;
    const value = std.testing.environ.getAlloc(gpa, provider_variable) catch
        missingProvider();
    defer gpa.free(value);
    if (value.len == 0 or value.len > buffer.len) missingProvider();
    @memcpy(buffer[0..value.len], value);
    lmdb.load(.{ .path = buffer[0..value.len] }) catch |err| {
        std.debug.print(
            "tests.zig: loading " ++ provider_variable ++ " = \"{s}\" failed: {t}\n",
            .{ buffer[0..value.len], err },
        );
        @panic("tests.zig: the provider named by " ++ provider_variable ++
            " did not load; nothing below this line ran");
    };
}

fn missingProvider() noreturn {
    @panic(
        "tests.zig: this is a runtime-loading build and " ++ provider_variable ++
            " is not set. Point it at a shared object exporting the mdb_* " ++
            "entry points of libraries/liblmdb/lmdb.h, for example the one " ++
            "`zig build -Dlinkage=dynamic` installs, and export it for the " ++
            "whole `zig build` invocation: the build cannot inject a path " ++
            "into a run step's environment.",
    );
}

/// Read the borrowed bytes from an `MDB_val` in comparator tests.
fn valBytes(val: lmdb.c.MDB_val) []const u8 {
    if (val.mv_size == 0) return "";
    const bytes: [*]const u8 = @ptrCast(val.mv_data.?);
    return bytes[0..val.mv_size];
}

/// Temporary-root variables, checked in order; unset or empty values are skipped.
const temp_root_vars: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "TMPDIR", "TEMP", "TMP" }
else
    &.{"TMPDIR"};

/// Return an absolute sandbox root from the process environment or `.zig-cache/tmp`.
/// Relative roots are resolved against the working directory for `mdb_env_open`.
fn scratchRootAlloc(environ: std.process.Environ) ![:0]u8 {
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

/// One temporary root and a random child holding one LMDB environment.
/// Cleanup removes only that child, not the root or neighboring entries.
const Sandbox = struct {
    parent: std.Io.Dir,
    sub_path: [sub_path_len]u8,
    path: [:0]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    /// Create the sandbox and load the provider once when runtime loading is enabled.
    /// Only the random child is owned and removed by this test.
    fn init() !Sandbox {
        nativeReady();
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        const root = try scratchRootAlloc(std.testing.environ);
        defer gpa.free(root);

        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
        errdefer parent.close(io);
        try parent.createDirPath(io, &sub_path);

        const path = std.fs.path.joinZ(gpa, &.{ @as([]const u8, root), &sub_path }) catch |err| {
            // Remove the created child if constructing its path fails.
            parent.deleteTree(io, &sub_path) catch {};
            return err;
        };

        return .{ .parent = parent, .sub_path = sub_path, .path = path };
    }

    fn deinit(self: *Sandbox) void {
        gpa.free(self.path);
        self.parent.deleteTree(io, &self.sub_path) catch {};
        self.parent.close(io);
    }
};

/// The embedded record corpus.
const Corpus = struct {
    /// Insert order, deliberately different from sorted cursor order.
    insert: []const Record,
    /// Expected forward cursor order, recorded by hand.
    expect: []const Record,

    const Record = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Fixture section markers.
    const insert_block = "[insert]";
    const expect_block = "[expect]";

    /// Parse tab-separated records; ignore blank and `#` comment lines.
    /// Returned slices borrow `text`; `scratch` owns only the record lists.
    fn parse(scratch: std.mem.Allocator, text: []const u8) !Corpus {
        var insert: std.ArrayList(Record) = .empty;
        var expect: std.ArrayList(Record) = .empty;
        var in_expect = false;

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            if (std.mem.eql(u8, line, insert_block)) continue;
            if (std.mem.eql(u8, line, expect_block)) {
                in_expect = true;
                continue;
            }
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse
                return error.MalformedCorpus;
            const record = Record{ .key = line[0..tab], .value = line[tab + 1 ..] };
            if (in_expect) {
                try expect.append(scratch, record);
            } else {
                try insert.append(scratch, record);
            }
        }

        if (insert.items.len == 0 or expect.items.len == 0) return error.MalformedCorpus;
        return .{
            .insert = try insert.toOwnedSlice(scratch),
            .expect = try expect.toOwnedSlice(scratch),
        };
    }
};

/// The embedded fixture text.
const corpus_text = @embedFile("testdata/corpus.txt");

/// Insert corpus records in fixture order.
fn writeCorpus(txn: *lmdb.Transaction, db: lmdb.Database, corpus: Corpus) !void {
    for (corpus.insert) |record| {
        try txn.put(db, record.key, record.value);
    }
}

/// Check a forward cursor walk and its end-of-walk result.
fn expectForwardWalk(txn: *lmdb.Transaction, db: lmdb.Database, want: []const Corpus.Record) !void {
    var cursor = try txn.openCursor(db);
    defer cursor.close();

    var entry = try cursor.first();
    for (want, 0..) |record, index| {
        try std.testing.expectEqualStrings(record.key, entry.key);
        try std.testing.expectEqualStrings(record.value, entry.value);
        if (index + 1 < want.len) entry = try cursor.next();
    }
    try std.testing.expectError(error.NotFound, cursor.next());
}

test "a committed write survives reopening the environment and an aborted one does not" {
    var box = try Sandbox.init();
    defer box.deinit();

    {
        var env = try lmdb.Environment.init(.{ .path = box.path });
        defer env.close();

        var kept = try env.beginWrite();
        defer kept.abort();
        const kept_db = try kept.openDatabase(null, .{});
        try kept.put(kept_db, "kept", "committed");
        try kept.commit();

        var dropped = try env.beginWrite();
        defer dropped.abort();
        const dropped_db = try dropped.openDatabase(null, .{});
        try dropped.put(dropped_db, "dropped", "aborted");
        try std.testing.expectEqualStrings("aborted", try dropped.get(dropped_db, "dropped"));
        dropped.abort();
    }

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    try std.testing.expectEqualStrings("committed", try txn.get(db, "kept"));
    try std.testing.expectError(error.NotFound, txn.get(db, "dropped"));
}

test "putNoOverwrite reports KeyExists on a stored key and leaves its value alone" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    try txn.putNoOverwrite(db, "alpha", "first");
    try std.testing.expectError(error.KeyExists, txn.putNoOverwrite(db, "alpha", "second"));
    try std.testing.expectEqualStrings("first", try txn.get(db, "alpha"));

    try txn.putNoOverwrite(db, "beta", "second");
    try std.testing.expectEqualStrings("second", try txn.get(db, "beta"));
}

test "get and delete report NotFound for a key that was never stored" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    try std.testing.expectError(error.NotFound, txn.get(db, "absent"));
    try std.testing.expectError(error.NotFound, txn.delete(db, "absent"));

    try txn.put(db, "present", "here");
    try txn.delete(db, "present");
    try std.testing.expectError(error.NotFound, txn.get(db, "present"));
    try std.testing.expectError(error.NotFound, txn.delete(db, "present"));
}

test "a read-only transaction refuses a write" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    {
        var seed = try env.beginWrite();
        defer seed.abort();
        const db = try seed.openDatabase(null, .{});
        try seed.put(db, "alpha", "first");
        try seed.commit();
    }

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    try std.testing.expectEqualStrings("first", try txn.get(db, "alpha"));
    try std.testing.expectError(error.IsReadOnly, txn.put(db, "beta", "second"));
    try std.testing.expectError(error.IsReadOnly, txn.putNoOverwrite(db, "gamma", "third"));
    try std.testing.expectError(error.IsReadOnly, txn.delete(db, "alpha"));
    try std.testing.expectEqualStrings("first", try txn.get(db, "alpha"));
}

test "a read-only snapshot keeps its value until it is renewed, while the writer moves on" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    {
        var seed = try env.beginWrite();
        defer seed.abort();
        const db = try seed.openDatabase(null, .{});
        try seed.put(db, "colour", "amber");
        try seed.commit();
    }

    var reader = try env.beginReadOnly();
    defer reader.abort();
    const read_db = try reader.openDatabase(null, .{});
    try std.testing.expectEqualStrings("amber", try reader.get(read_db, "colour"));

    {
        var writer = try env.beginWrite();
        defer writer.abort();
        const write_db = try writer.openDatabase(null, .{});
        try writer.put(write_db, "colour", "violet");
        try writer.commit();
    }

    try std.testing.expectEqualStrings("amber", try reader.get(read_db, "colour"));

    try reader.reset();
    try reader.renew();
    try std.testing.expectEqualStrings("violet", try reader.get(read_db, "colour"));
}

test "a dupsort database returns duplicates in sorted order in both directions" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase("sorted", .{ .dupsort = true, .create = true });

    for ([_][]const u8{ "delta", "alpha", "gamma", "beta" }) |value| {
        try txn.put(db, "key", value);
    }

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    try std.testing.expectError(error.InvalidArgument, cursor.firstDup());
    try std.testing.expectEqualStrings("alpha", (try cursor.set("key")).value);

    var entry = try cursor.firstDup();
    try std.testing.expectEqualStrings("", entry.key);
    try std.testing.expectEqualStrings("alpha", entry.value);
    try std.testing.expectEqualStrings("key", (try cursor.current()).key);
    try std.testing.expectEqual(@as(lmdb.Size, 4), try cursor.count());

    entry = try cursor.nextDup();
    try std.testing.expectEqualStrings("key", entry.key);
    try std.testing.expectEqualStrings("beta", entry.value);
    entry = try cursor.nextDup();
    try std.testing.expectEqualStrings("delta", entry.value);
    entry = try cursor.nextDup();
    try std.testing.expectEqualStrings("gamma", entry.value);
    try std.testing.expectError(error.NotFound, cursor.nextDup());

    entry = try cursor.lastDup();
    try std.testing.expectEqualStrings("gamma", entry.value);
    entry = try cursor.prevDup();
    try std.testing.expectEqualStrings("key", entry.key);
    try std.testing.expectEqualStrings("delta", entry.value);
    entry = try cursor.firstDup();
    try std.testing.expectEqualStrings("alpha", entry.value);
    try std.testing.expectError(error.NotFound, cursor.prevDup());

    entry = try cursor.getBoth("key", "gamma");
    try std.testing.expectEqualStrings("gamma", entry.value);
    try std.testing.expectError(error.NotFound, cursor.getBoth("key", "epsilon"));

    entry = try cursor.getBothRange("key", "bb");
    try std.testing.expectEqualStrings("beta", entry.value);
}

test "a named open needs a slot the environment must be asked for" {
    var box = try Sandbox.init();
    defer box.deinit();

    {
        var env = try lmdb.Environment.init(.{ .path = box.path });
        defer env.close();

        var txn = try env.beginWrite();
        defer txn.abort();
        try std.testing.expectError(error.DbsFull, txn.openDatabase("named", .{ .create = true }));

        const main = try txn.openDatabase(null, .{});
        try txn.put(main, "alpha", "first");
        try std.testing.expectError(error.NotFound, txn.get(main, "named"));
    }

    {
        var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
        defer env.close();

        var txn = try env.beginWrite();
        defer txn.abort();
        const db = try txn.openDatabase("named", .{ .create = true });
        try txn.put(db, "alpha", "first");
        try txn.commit();
    }

    {
        var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
        defer env.close();

        var txn = try env.beginReadOnly();
        defer txn.abort();
        const db = try txn.openDatabase("named", .{});
        try std.testing.expectEqualStrings("first", try txn.get(db, "alpha"));
    }
}

test "deleteValue removes one duplicate and deleteAllDuplicates removes the key" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase("sorted", .{ .dupsort = true, .create = true });

    for ([_][]const u8{ "alpha", "beta", "gamma" }) |value| try txn.put(db, "key", value);
    try std.testing.expectError(error.KeyExists, txn.putNoDupData(db, "key", "beta"));
    try txn.putNoDupData(db, "key", "delta");

    try txn.deleteValue(db, "key", "beta");
    try std.testing.expectError(error.NotFound, txn.deleteValue(db, "key", "beta"));

    var cursor = try txn.openCursor(db);
    _ = try cursor.set("key");
    const entry = try cursor.firstDup();
    try std.testing.expectEqualStrings("alpha", entry.value);
    try std.testing.expectEqual(@as(lmdb.Size, 3), try cursor.count());

    try cursor.deleteAllDuplicates();
    try std.testing.expectError(error.NotFound, cursor.first());
    cursor.close();

    try std.testing.expectError(error.NotFound, txn.get(db, "key"));
}

test "cursor traversal reports NotFound at both ends and setRange lands at or after" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    for ([_][]const u8{ "alpha", "gamma", "omega" }) |key| try txn.put(db, key, key);

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    try std.testing.expectError(error.InvalidArgument, cursor.current());

    var entry = try cursor.prev();
    try std.testing.expectEqualStrings("omega", entry.key);
    try std.testing.expectError(error.NotFound, cursor.next());

    entry = try cursor.first();
    try std.testing.expectEqualStrings("alpha", entry.key);
    try std.testing.expectEqualStrings("alpha", (try cursor.current()).key);
    try std.testing.expectError(error.NotFound, cursor.prev());

    entry = try cursor.nextNoDup();
    try std.testing.expectEqualStrings("gamma", entry.key);
    entry = try cursor.nextNoDup();
    try std.testing.expectEqualStrings("omega", entry.key);
    try std.testing.expectError(error.NotFound, cursor.nextNoDup());

    entry = try cursor.last();
    try std.testing.expectEqualStrings("omega", entry.key);
    try std.testing.expectError(error.NotFound, cursor.next());

    entry = try cursor.prevNoDup();
    try std.testing.expectEqualStrings("gamma", entry.key);

    try std.testing.expectError(error.NotFound, cursor.set("beta"));
    entry = try cursor.set("gamma");
    try std.testing.expectEqualStrings("gamma", entry.key);
    entry = try cursor.setRange("beta");
    try std.testing.expectEqualStrings("gamma", entry.key);
    entry = try cursor.setRange("gamma");
    try std.testing.expectEqualStrings("gamma", entry.key);
    try std.testing.expectError(error.NotFound, cursor.setRange("zulu"));
}

test "deleting through a cursor leaves the cursor in place for the next item" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    for ([_][]const u8{ "alpha", "beta", "gamma" }) |key| try txn.put(db, key, key);

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    try std.testing.expectError(error.InvalidArgument, cursor.deleteCurrent());
    _ = try cursor.first();
    const entry = try cursor.next();
    try std.testing.expectEqualStrings("beta", entry.key);
    try cursor.deleteCurrent();
    const after = try cursor.next();
    try std.testing.expectEqualStrings("gamma", after.key);
    try std.testing.expectError(error.NotFound, cursor.next());

    try std.testing.expectError(error.NotFound, txn.get(db, "beta"));
    try std.testing.expectEqualStrings("alpha", try txn.get(db, "alpha"));
    try std.testing.expectEqualStrings("gamma", try txn.get(db, "gamma"));
}

test "putCurrent replaces the value the cursor is on without moving it" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    try txn.put(db, "alpha", "first");
    try txn.put(db, "beta", "second");

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    const entry = try cursor.set("alpha");
    try std.testing.expectEqualStrings("first", entry.value);

    try cursor.putCurrent("alpha", "fifth");
    try std.testing.expectEqualStrings("fifth", (try cursor.current()).value);
    try std.testing.expectEqualStrings("fifth", try txn.get(db, "alpha"));

    try std.testing.expectEqualStrings("beta", (try cursor.next()).key);
    try std.testing.expectEqualStrings("alpha", (try cursor.prev()).key);
}

test "a committed nested transaction's writes become the parent's and an aborted one's do not" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    {
        var child = try txn.beginNested();
        defer child.abort();
        const child_db = try child.openDatabase(null, .{});
        try child.put(child_db, "kept", "merged");
        try child.commit();
    }

    {
        var child = try txn.beginNested();
        defer child.abort();
        const child_db = try child.openDatabase(null, .{});
        try child.put(child_db, "dropped", "discarded");
        child.abort();
    }

    try std.testing.expectEqualStrings("merged", try txn.get(db, "kept"));
    try std.testing.expectError(error.NotFound, txn.get(db, "dropped"));

    try txn.commit();

    var reader = try env.beginReadOnly();
    defer reader.abort();
    const read_db = try reader.openDatabase(null, .{});
    try std.testing.expectEqualStrings("merged", try reader.get(read_db, "kept"));
    try std.testing.expectError(error.NotFound, reader.get(read_db, "dropped"));
}

test "commit releases the transaction and aborts again afterwards are harmless" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    const db = try txn.openDatabase(null, .{});
    try txn.put(db, "alpha", "first");
    try txn.commit();

    try std.testing.expectError(error.TransactionClosed, txn.get(db, "alpha"));
    try std.testing.expectError(error.TransactionClosed, txn.put(db, "beta", "second"));
    try std.testing.expectError(error.TransactionClosed, txn.delete(db, "alpha"));
    try std.testing.expectError(error.TransactionClosed, txn.openDatabase(null, .{}));
    try std.testing.expectError(error.TransactionClosed, txn.openCursor(db));
    try std.testing.expectError(error.TransactionClosed, txn.beginNested());
    try std.testing.expectError(error.TransactionClosed, txn.commit());
    try std.testing.expectError(error.TransactionClosed, txn.reset());
    try std.testing.expectError(error.TransactionClosed, txn.renew());
    txn.abort();
    txn.abort();
}

test "reset and renew are refused on the wrong kind of transaction" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var writer = try env.beginWrite();
    defer writer.abort();
    try std.testing.expectError(error.TransactionNotResettable, writer.reset());
    try std.testing.expectError(error.TransactionNotReset, writer.renew());

    var reader = try env.beginReadOnly();
    defer reader.abort();
    try std.testing.expectError(error.TransactionNotReset, reader.renew());

    const db = try reader.openDatabase(null, .{});
    try reader.reset();
    try std.testing.expectError(error.TransactionNotResettable, reader.reset());
    try std.testing.expectError(error.TransactionReset, reader.get(db, "alpha"));
    try std.testing.expectError(error.TransactionReset, reader.openDatabase(null, .{}));

    try reader.renew();
    try std.testing.expectError(error.NotFound, reader.get(db, "alpha"));
    try std.testing.expectError(error.TransactionNotReset, reader.renew());
}

test "a read cursor closes before teardown and stays closed after its parent ends" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    {
        var seed = try env.beginWrite();
        defer seed.abort();
        const db = try seed.openDatabase(null, .{});
        try seed.put(db, "alpha", "first");
        try seed.commit();
    }

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    var cursor = try txn.openCursor(db);
    defer cursor.close();
    try std.testing.expectEqualStrings("alpha", (try cursor.first()).key);

    cursor.close();
    try std.testing.expectError(error.CursorClosed, cursor.first());
    txn.abort();
    try std.testing.expectError(error.CursorClosed, cursor.first());
    cursor.close();
}

test "closing a write cursor hands its pointer to the transaction" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    var cursor = try txn.openCursor(db);
    var dup = try txn.openCursor(db);
    try txn.put(db, "alpha", "first");
    try std.testing.expectEqualStrings("alpha", (try cursor.first()).key);

    cursor.close();
    try std.testing.expectError(error.CursorClosed, cursor.first());
    cursor.close();

    try txn.commit();
    dup.close();
}

test "create and open are the two halves init performs in one call" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.create();
    defer env.close();
    try env.setMaxReaders(11);
    try env.setMapSize(1 << 20);
    try std.testing.expectError(error.EnvironmentClosed, env.sync(true));

    try env.open(box.path, .{}, 0o664);
    try std.testing.expectEqual(@as(u32, 11), try env.maxReaders());
    try env.sync(true);

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    try txn.put(db, "alpha", "first");
    try txn.commit();
}

test "closing the environment twice is safe and a later call is refused" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    env.close();
    env.close();

    try std.testing.expectError(error.EnvironmentClosed, env.sync(true));
    try std.testing.expectError(error.EnvironmentClosed, env.beginWrite());
    try std.testing.expectError(error.EnvironmentClosed, env.beginReadOnly());
    try std.testing.expectError(error.EnvironmentClosed, env.setMaxDbs(4));
    try std.testing.expectError(error.EnvironmentClosed, env.setMapSize(1 << 20));
    try std.testing.expectError(error.EnvironmentClosed, env.maxReaders());
}

test "opening an environment twice reports EnvironmentAlreadyOpen" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    try std.testing.expectError(error.EnvironmentAlreadyOpen, env.open(box.path, .{}, 0o664));
    try std.testing.expectError(error.EnvironmentAlreadyOpen, env.open(box.path, .{}, 0o664));
}

test "the reader count reaches the environment and zero readers is refused" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.create();
    defer env.close();

    try std.testing.expectError(error.InvalidArgument, env.setMaxReaders(0));

    const configured = 37;
    try env.setMaxReaders(configured);
    try env.open(box.path, .{}, 0o664);
    try std.testing.expectEqual(@as(u32, configured), try env.maxReaders());

    var txn = try env.beginReadOnly();
    txn.abort();
}

test "named databases are addressed by name and the limit is enforced" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 2 });
    defer env.close();

    var stored: lmdb.Database = undefined;

    {
        var txn = try env.beginWrite();
        defer txn.abort();

        try std.testing.expectError(error.NotFound, txn.openDatabase("one", .{}));

        const one = try txn.openDatabase("one", .{ .create = true });
        const two = try txn.openDatabase("two", .{ .create = true });
        try txn.put(one, "alpha", "in one");
        try txn.put(two, "alpha", "in two");

        const again = try txn.openDatabase("one", .{});
        try std.testing.expectEqualStrings("in one", try txn.get(again, "alpha"));

        try std.testing.expectError(error.DbsFull, txn.openDatabase("three", .{ .create = true }));
        stored = one;
        try txn.commit();
    }

    {
        var txn = try env.beginReadOnly();
        defer txn.abort();
        const one = try txn.openDatabase("one", .{});
        try std.testing.expectEqualStrings("in one", try txn.get(one, "alpha"));
    }

    env.closeDatabase(stored);
    env.closeDatabase(stored);

    {
        var txn = try env.beginReadOnly();
        defer txn.abort();
        const one = try txn.openDatabase("one", .{});
        try std.testing.expectEqualStrings("in one", try txn.get(one, "alpha"));
    }
}

test "an empty key is refused before it reaches the core" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    try std.testing.expectError(error.EmptyKey, txn.put(db, "", "value"));
    try std.testing.expectError(error.EmptyKey, txn.putNoOverwrite(db, "", "value"));
    try std.testing.expectError(error.EmptyKey, txn.get(db, ""));
    try std.testing.expectError(error.EmptyKey, txn.delete(db, ""));

    try txn.put(db, "alpha", "");
    try std.testing.expectEqualStrings("", try txn.get(db, "alpha"));

    var cursor = try txn.openCursor(db);
    defer cursor.close();
    try std.testing.expectError(error.EmptyKey, cursor.set(""));
    _ = try cursor.set("alpha");
    try cursor.putCurrent("alpha", "no longer empty");
    try std.testing.expectEqualStrings("no longer empty", try txn.get(db, "alpha"));
}

test "a file that is not an environment is refused, and the handle is spent by the attempt" {
    var box = try Sandbox.init();
    defer box.deinit();

    const data_path = try gpa.printSentinel("{s}/data.mdb", .{box.path}, 0);
    defer gpa.free(data_path);
    const junk: [1024]u8 = @splat(0xff);
    const not_an_env = try std.Io.Dir.createFileAbsolute(io, data_path, .{});
    try not_an_env.writeStreamingAll(io, &junk);
    not_an_env.close(io);

    var env = try lmdb.Environment.create();
    defer env.close();
    try std.testing.expectError(error.Invalid, env.open(box.path, .{}, 0o664));

    try std.testing.expectError(error.OpenFailed, env.open(box.path, .{}, 0o664));
    try std.testing.expectError(error.EnvironmentClosed, env.beginWrite());

    var second = try lmdb.Environment.create();
    defer second.close();
    try std.testing.expectError(error.Invalid, second.open(box.path, .{}, 0o664));

    env.close();
    try std.testing.expectError(error.EnvironmentClosed, env.open(box.path, .{}, 0o664));
}

test "the corpus round-trips through a write, a commit, a reopen and a cursor walk" {
    var box = try Sandbox.init();
    defer box.deinit();

    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const corpus = try Corpus.parse(scratch_state.allocator(), corpus_text);
    try std.testing.expect(corpus.insert.len == corpus.expect.len);

    {
        var env = try lmdb.Environment.init(.{ .path = box.path });
        defer env.close();

        var txn = try env.beginWrite();
        defer txn.abort();
        const db = try txn.openDatabase(null, .{});
        try writeCorpus(&txn, db, corpus);

        for (corpus.expect, 0..) |record, index| {
            for (corpus.expect[index + 1 ..]) |other| {
                try std.testing.expect(!std.mem.eql(u8, record.key, other.key));
            }
            try std.testing.expectEqualStrings(record.value, try txn.get(db, record.key));
        }

        try expectForwardWalk(&txn, db, corpus.expect);
        try txn.commit();
    }

    {
        var env = try lmdb.Environment.init(.{ .path = box.path, .flags = .{ .rdonly = true } });
        defer env.close();

        var txn = try env.beginReadOnly();
        defer txn.abort();
        const db = try txn.openDatabase(null, .{});
        try expectForwardWalk(&txn, db, corpus.expect);
    }
}

test "reverse keys sort from the end of the string" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase("reversed", .{ .reversekey = true, .create = true });

    for ([_][]const u8{ "abc", "abd", "xbc" }) |key| try txn.put(db, key, key);

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    var entry = try cursor.first();
    try std.testing.expectEqualStrings("abc", entry.key);
    entry = try cursor.next();
    try std.testing.expectEqualStrings("xbc", entry.key);
    entry = try cursor.next();
    try std.testing.expectEqualStrings("abd", entry.key);
    try std.testing.expectError(error.NotFound, cursor.next());
}

test "a prepared transaction answers only commit and abort until one of them runs" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    try txn.put(db, "alpha", "prepared");

    try txn.prepare();

    try std.testing.expectError(error.TxnPending, txn.get(db, "alpha"));
    try std.testing.expectError(error.TxnPending, txn.put(db, "beta", "second"));
    try std.testing.expectError(error.TxnPending, txn.delete(db, "alpha"));
    try std.testing.expectError(error.TxnPending, txn.openDatabase(null, .{}));
    try std.testing.expectError(error.TxnPending, txn.openCursor(db));
    try std.testing.expectError(error.TxnPending, txn.beginNested());
    try std.testing.expectError(error.TxnPending, txn.prepare());

    try txn.commit();

    var reader = try env.beginReadOnly();
    defer reader.abort();
    const read_db = try reader.openDatabase(null, .{});
    try std.testing.expectEqualStrings("prepared", try reader.get(read_db, "alpha"));
}

test "a prepared transaction that is abandoned leaves no record a later reader can find" {
    var box = try Sandbox.init();
    defer box.deinit();

    {
        var env = try lmdb.Environment.init(.{ .path = box.path });
        defer env.close();

        var keep = try env.beginWrite();
        const keep_db = try keep.openDatabase(null, .{});
        try keep.put(keep_db, "kept", "committed");
        try keep.commit();

        var lost = try env.beginWrite();
        const lost_db = try lost.openDatabase(null, .{});
        try lost.put(lost_db, "lost", "written but never committed");
        try lost.prepare();
        lost.abort();
    }

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();
    var reader = try env.beginReadOnly();
    defer reader.abort();
    const db = try reader.openDatabase(null, .{});
    try std.testing.expectEqualStrings("committed", try reader.get(db, "kept"));
    try std.testing.expectError(error.NotFound, reader.get(db, "lost"));
}

test "the newest commit can be rolled back and an older or unknown one cannot" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var first_id: lmdb.Size = 0;
    var second_id: lmdb.Size = 0;
    {
        var first = try env.beginWrite();
        const db = try first.openDatabase(null, .{});
        try first.put(db, "alpha", "first");
        first_id = try first.id();
        try first.commit();
    }
    {
        var second = try env.beginWrite();
        const db = try second.openDatabase(null, .{});
        try second.put(db, "beta", "second");
        second_id = try second.id();
        try second.commit();
    }

    try std.testing.expect(second_id > first_id);
    const newest = try env.info();
    try std.testing.expectEqual(second_id, newest.last_txn);

    try std.testing.expectError(error.CantRollback, env.rollback(newest.last_txn + 1));
    try std.testing.expectError(error.CantRollback, env.rollback(0));

    try env.rollback(newest.last_txn);

    var reopened = try lmdb.Environment.init(.{ .path = box.path });
    defer reopened.close();
    var reader = try reopened.beginReadOnly();
    defer reader.abort();
    const db = try reader.openDatabase(null, .{});
    try std.testing.expectEqualStrings("first", try reader.get(db, "alpha"));
    try std.testing.expectError(error.NotFound, reader.get(db, "beta"));
}

// ----------------------------------------------------- callbacks and ordering

/// C-ABI reverse-byte comparator; arguments borrow map data for the call.
fn compareKeysFromTheEnd(
    a: [*c]const lmdb.c.MDB_val,
    b: [*c]const lmdb.c.MDB_val,
) callconv(.c) c_int {
    const left = valBytes(a.*);
    const right = valBytes(b.*);
    const shared = @min(left.len, right.len);
    var index: usize = shared;
    while (index > 0) {
        index -= 1;
        if (left[index] != right[index]) {
            return if (left[index] < right[index]) @as(c_int, -1) else 1;
        }
    }
    if (left.len == right.len) return 0;
    return if (left.len < right.len) @as(c_int, -1) else 1;
}

test "a caller-supplied key comparator decides the order the walk produces" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    try txn.setKeyComparator(db, compareKeysFromTheEnd);
    for ([_][]const u8{ "abc", "abd", "xbc" }) |key| try txn.put(db, key, key);

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    try std.testing.expectEqualStrings("abc", (try cursor.first()).key);
    try std.testing.expectEqualStrings("xbc", (try cursor.next()).key);
    try std.testing.expectEqualStrings("abd", (try cursor.next()).key);
    try std.testing.expectError(error.NotFound, cursor.next());

    try std.testing.expect((try txn.compareKeys(db, "abc", "abd")) < 0);
    try std.testing.expect((try txn.compareKeys(db, "abd", "xbc")) > 0);
    try std.testing.expectEqual(@as(c_int, 0), try txn.compareKeys(db, "abc", "abc"));
}

test "a database without duplicates still answers the duplicate comparison" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 2 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const duplicates = try txn.openDatabase("duplicates", .{ .create = true, .dupsort = true });
    const plain = try txn.openDatabase("plain", .{ .create = true });

    try txn.setValueComparator(plain, compareKeysFromTheEnd);
    try std.testing.expect((try txn.compareValues(plain, "alpha", "beta")) > 0);
    try std.testing.expect((try txn.compareValues(plain, "a", "alpha")) < 0);

    try std.testing.expect((try txn.compareValues(duplicates, "alpha", "beta")) < 0);
    try std.testing.expect((try txn.compareValues(duplicates, "beta", "alpha")) > 0);
    try std.testing.expectEqual(@as(c_int, 0), try txn.compareValues(duplicates, "alpha", "alpha"));
    try std.testing.expect((try txn.compareValues(duplicates, "a", "alpha")) < 0);

    try txn.setValueComparator(duplicates, compareKeysFromTheEnd);
    try std.testing.expect((try txn.compareValues(duplicates, "alpha", "beta")) > 0);
    try std.testing.expect((try txn.compareValues(duplicates, "a", "alpha")) < 0);
}

test "a walk of the main database tells catalogue records from user records" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const main = try txn.openDatabase(null, .{});
    try txn.put(main, "alpha", "first");
    _ = try txn.openDatabase("sorted", .{ .create = true });

    var unpositioned = try txn.openCursor(main);
    try std.testing.expect(!try unpositioned.onNamedDatabase());
    unpositioned.close();

    var cursor = try txn.openCursor(main);
    defer cursor.close();

    try std.testing.expectEqualStrings("alpha", (try cursor.first()).key);
    try std.testing.expect(!try cursor.onNamedDatabase());
    try std.testing.expectEqual(main.dbi, try cursor.database());
    try std.testing.expectEqual(txn.handle.?, try cursor.transaction());

    const catalogue = try cursor.next();
    try std.testing.expectEqualStrings("sorted\x00", catalogue.key);
    try std.testing.expect(try cursor.onNamedDatabase());
    try std.testing.expectError(error.NotFound, cursor.next());

    try std.testing.expect(try cursor.onNamedDatabase());
    try std.testing.expectEqualStrings("sorted\x00", (try cursor.current()).key);
}

test "the raw page-at-a-time cursor operation hands back a whole leaf of duplicates" {
    var box = try Sandbox.init();
    defer box.deinit();

    // `max_dbs` is a precondition of the named open below.
    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const fixed = try txn.openDatabase("fixed", .{
        .dupsort = true,
        .dupfixed = true,
        .create = true,
    });
    for ([_][]const u8{ "aaaa", "bbbb", "cccc" }) |value| try txn.put(fixed, "key", value);

    var cursor = try txn.openCursor(fixed);
    defer cursor.close();
    _ = try cursor.set("key");
    _ = try cursor.firstDup();

    var key: lmdb.c.MDB_val = .{ .mv_size = 0, .mv_data = undefined };
    var data: lmdb.c.MDB_val = .{ .mv_size = 0, .mv_data = undefined };
    try std.testing.expectEqual(
        @as(c_int, 0),
        lmdb.c.mdb_cursor_get(
            cursor.handle.?,
            &key,
            &data,
            @intCast(lmdb.c.MDB_GET_MULTIPLE),
        ),
    );
    try std.testing.expectEqual(@as(lmdb.Size, 12), data.mv_size);
    const page: [*]const u8 = @ptrCast(data.mv_data.?);
    try std.testing.expectEqualStrings("aaaabbbbcccc", page[0..12]);

    const plain = try txn.openDatabase(null, .{});
    try txn.put(plain, "alpha", "first");
    var plain_cursor = try txn.openCursor(plain);
    defer plain_cursor.close();
    _ = try plain_cursor.first();
    try std.testing.expectEqual(
        lmdb.c.MDB_INCOMPATIBLE,
        lmdb.c.mdb_cursor_get(
            plain_cursor.handle.?,
            &key,
            &data,
            @intCast(lmdb.c.MDB_GET_MULTIPLE),
        ),
    );
}

test "the key size limit is exactly the boundary upstream draws" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();

    const limit = try env.maxKeySize();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    const at_limit = try gpa.alloc(u8, @intCast(limit));
    defer gpa.free(at_limit);
    @memset(at_limit, 'k');
    const past_it = try gpa.alloc(u8, @as(usize, limit) + 1);
    defer gpa.free(past_it);
    @memset(past_it, 'k');

    try txn.put(db, at_limit, "at the limit");
    try std.testing.expectEqualStrings("at the limit", try txn.get(db, at_limit));
    try std.testing.expectError(error.BadValSize, txn.put(db, past_it, "past it"));
    try std.testing.expectEqualStrings("at the limit", try txn.get(db, at_limit));
}

test "an environment copied to another directory opens and holds the same records" {
    var source_box = try Sandbox.init();
    defer source_box.deinit();
    var target_box = try Sandbox.init();
    defer target_box.deinit();

    {
        var env = try lmdb.Environment.init(.{ .path = source_box.path });
        defer env.close();
        var txn = try env.beginWrite();
        defer txn.abort();
        const db = try txn.openDatabase(null, .{});
        for ([_][]const u8{ "alpha", "beta", "gamma" }) |key| try txn.put(db, key, key);
        try txn.commit();
    }

    {
        var env = try lmdb.Environment.init(.{ .path = source_box.path });
        defer env.close();
        try env.copy(target_box.path);
    }

    var copy = try lmdb.Environment.init(.{ .path = target_box.path });
    defer copy.close();
    var reader = try copy.beginReadOnly();
    defer reader.abort();
    const db = try reader.openDatabase(null, .{});
    var cursor = try reader.openCursor(db);
    defer cursor.close();

    var entry = try cursor.first();
    try std.testing.expectEqualStrings("alpha", entry.key);
    try std.testing.expectEqualStrings("alpha", entry.value);
    entry = try cursor.next();
    try std.testing.expectEqualStrings("beta", entry.key);
    entry = try cursor.next();
    try std.testing.expectEqualStrings("gamma", entry.key);
    try std.testing.expectError(error.NotFound, cursor.next());
}

/// Number of reader-list callback invocations.
var reader_lines: usize = 0;

/// Count one reader-table line and continue; its message is borrowed for the call.
fn countReaderLine(_: [*c]const u8, _: ?*anyopaque) callconv(.c) c_int {
    reader_lines += 1;
    return 0;
}

test "the reader table reports the readers that are open and reclaims none of them" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_readers = 8 });
    defer env.close();

    {
        var writer = try env.beginWrite();
        defer writer.abort();
        const db = try writer.openDatabase(null, .{});
        try writer.put(db, "alpha", "first");
        try writer.commit();
    }

    reader_lines = 0;
    try std.testing.expect(try env.listReaders(countReaderLine, null) >= 0);
    try std.testing.expect(reader_lines >= 1);

    var reader = try env.beginReadOnly();
    defer reader.abort();
    const db = try reader.openDatabase(null, .{});
    try std.testing.expectEqualStrings("first", try reader.get(db, "alpha"));

    reader_lines = 0;
    try std.testing.expect(try env.listReaders(countReaderLine, null) >= 0);
    try std.testing.expectEqual(@as(usize, 2), reader_lines);

    try std.testing.expectEqual(@as(c_int, 0), try env.clearStaleReaders());
}

const ReaderCallbackResult = struct {
    result: c_int,
    calls: usize = 0,

    fn callback(_: [*c]const u8, context: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return self.result;
    }
};

test "a negative reader callback result aborts before the reader entry" {
    var box = try Sandbox.init();
    defer box.deinit();
    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();
    var reader = try env.beginReadOnly();
    defer reader.abort();

    var callback_result: ReaderCallbackResult = .{ .result = -1 };
    try std.testing.expectEqual(@as(c_int, -1), try env.listReaders(ReaderCallbackResult.callback, &callback_result));
    try std.testing.expectEqual(@as(usize, 1), callback_result.calls);
}

test "a positive reader callback result continues listing without becoming an errno" {
    var box = try Sandbox.init();
    defer box.deinit();
    var env = try lmdb.Environment.init(.{ .path = box.path });
    defer env.close();
    var reader = try env.beginReadOnly();
    defer reader.abort();

    var callback_result: ReaderCallbackResult = .{ .result = 13 };
    try std.testing.expectEqual(@as(c_int, 13), try env.listReaders(ReaderCallbackResult.callback, &callback_result));
    try std.testing.expectEqual(@as(usize, 2), callback_result.calls);
}

test "dropping a named database removes it from the environment's catalogue" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    {
        var writer = try env.beginWrite();
        defer writer.abort();
        const db = try writer.openDatabase("doomed", .{ .create = true });
        try writer.put(db, "alpha", "first");
        try writer.commit();
    }

    {
        var writer = try env.beginWrite();
        defer writer.abort();
        const db = try writer.openDatabase("doomed", .{});
        try writer.drop(db, true);
        try writer.commit();
    }

    var reader = try env.beginReadOnly();
    defer reader.abort();
    try std.testing.expectError(error.NotFound, reader.openDatabase("doomed", .{}));
}

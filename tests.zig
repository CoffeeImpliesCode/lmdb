//! Behavioural tests for the LMDB facade in `zig/root.zig`.
//!
//! Every test here states a contract and observes it. The contracts are
//! upstream's, read out of `libraries/liblmdb/lmdb.h` and `mdb.c`; the
//! observations are of the compiled core reached through the facade. Nothing
//! here asserts on the facade's own bookkeeping, on a version string, on a
//! forwarded member, or on a call merely not failing.
//!
//! Two things outside the facade supply the expectations:
//!
//!   * `testdata/corpus.txt`, embedded at compile time, whose cursor order is
//!     written down by hand rather than derived by the test, and
//!   * the C library's collation rule — `memcmp` on the common prefix with the
//!     shorter item first (mdb.c:6659-6675), and reversed-bytes for
//!     `MDB_REVERSEKEY` (mdb.c:6678-6699) — which the ordering tests exercise
//!     rather than re-implement.
//!
//! Each test gets its own environment in a randomly named directory under the
//! temporary root the test process was started with — `TMPDIR`, and on Windows
//! `TEMP` then `TMP` — so the suite is safe to run beside itself, keeps its
//! environments out of the working directory, and leaves nothing behind. LMDB
//! does not create the environment directory — there is no `mkdir` anywhere in
//! `mdb.c` — so the sandbox does, and hands `mdb_env_open` an absolute path.
//! A *named* database needs `.max_dbs`: `mdb_env_create` sizes the slot
//! table to the two databases upstream keeps for itself (mdb.c:5028,
//! `CORE_DBS` at mdb.c:1352), `mdb_dbi_open` refuses any name once that
//! table is full (mdb.c:12316-12318), and lmdb.h:1326-1327 makes
//! `mdb_env_set_maxdbs` a precondition of the call. The limit belongs to the
//! handle, not to the file, so every environment that will open a name has
//! to ask for it — including a reopen of one that is already there.

const std = @import("std");
const lmdb = @import("lmdb");
const builtin = @import("builtin");

const io = std.testing.io;
const gpa = std.testing.allocator;

/// The environment variables that name a temporary root, in the order they are
/// consulted: `TMPDIR` on every platform, the Windows spellings after it.
/// A variable that is unset or empty names no directory.
const temp_root_vars: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "TMPDIR", "TEMP", "TMP" }
else
    &.{"TMPDIR"};

/// The directory a sandbox is created under, as an absolute path: what the
/// temporary root variable names — taken against the working directory when
/// it is relative, because `mdb_env_open` is handed an absolute path — or
/// `.zig-cache/tmp` under the working directory when the environment names no
/// temporary root at all, which is what `std.testing.tmpDir` uses and what
/// keeps a host that configures none portable.
fn scratchRootAlloc(environ: std.process.Environ) ![:0]u8 {
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
/// `std.testing.tmpDir` puts its directory under the working directory
/// whatever the environment says, so the temporary root is read here instead,
/// from `std.testing.environ`: the environment the test runner itself was
/// started with. Only the random child is removed, which leaves the root and
/// every other name in it as they were.
const Sandbox = struct {
    parent: std.Io.Dir,
    sub_path: [sub_path_len]u8,
    path: [:0]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init() !Sandbox {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        const root = try scratchRootAlloc(std.testing.environ);
        defer gpa.free(root);

        // The root is made when it is not there yet. Only the random child
        // made below it belongs to this test, and only that one is removed.
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

    fn deinit(self: *Sandbox) void {
        gpa.free(self.path);
        self.parent.deleteTree(io, &self.sub_path) catch {};
        self.parent.close(io);
    }
};

/// The embedded record corpus.
const Corpus = struct {
    /// The order the records are written in, which is deliberately not the
    /// order they sort into.
    insert: []const Record,
    /// The order a forward cursor walk must produce. Written down by hand.
    expect: []const Record,

    const Record = struct {
        key: []const u8,
        value: []const u8,
    };

    /// The two blocks the fixture declares, introduced by these tokens.
    const insert_block = "[insert]";
    const expect_block = "[expect]";

    /// Parse a fixture. Records are `key<TAB>value`; `#` starts a comment and
    /// blank lines are ignored. The record slices point into `text`, which for
    /// the embedded fixture is compile-time data with static lifetime.
    ///
    /// `scratch` is used only for the two slices of records.
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

/// The fixture as written, and the expected order the test compares against.
const corpus_text = @embedFile("testdata/corpus.txt");

/// Write every record of the corpus in its recorded insert order.
fn writeCorpus(txn: *lmdb.Transaction, db: lmdb.Database, corpus: Corpus) !void {
    for (corpus.insert) |record| {
        try txn.put(db, record.key, record.value);
    }
}

/// Walk the whole database forward and check it against `want`, including the
/// seam after the last record.
fn expectForwardWalk(txn: *lmdb.Transaction, db: lmdb.Database, want: []const Corpus.Record) !void {
    var cursor = try txn.openCursor(db);
    defer cursor.close();

    var entry = try cursor.first();
    for (want, 0..) |record, index| {
        try std.testing.expectEqualStrings(record.key, entry.key);
        try std.testing.expectEqualStrings(record.value, entry.value);
        if (index + 1 < want.len) entry = try cursor.next();
    }
    // `expectForwardWalk` is only called with a non-empty expectation.
    try std.testing.expectError(error.NotFound, cursor.next());
}

// ----------------------------------------------------------------- contracts

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

    // The same call on a key that is not there is the whole point of the flag.
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

    // And once it exists, the delete lands and the second one does not.
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
    // mdb.c:11120-11121 answers MDB_IS_READONLY here, whatever the C header's
    // older prose says about EACCES, and the facade reports what it was told.
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

    // The reader is still on the snapshot it opened, so it cannot see it.
    try std.testing.expectEqualStrings("amber", try reader.get(read_db, "colour"));

    // Renewing takes the newest committed snapshot through the same handle.
    try reader.reset();
    try reader.renew();
    try std.testing.expectEqualStrings("violet", try reader.get(read_db, "colour"));
}

test "a dupsort database returns duplicates in sorted order in both directions" {
    var box = try Sandbox.init();
    defer box.deinit();

    // `max_dbs` is a precondition of the named open below; see the module
    // comment and lmdb.h:1326-1327.
    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase("sorted", .{ .dupsort = true, .create = true });

    // Inserted in an order that is not the one they sort into.
    for ([_][]const u8{ "delta", "alpha", "gamma", "beta" }) |value| {
        try txn.put(db, "key", value);
    }

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    // FIRST_DUP and LAST_DUP are EINVAL on a cursor that has never been
    // positioned (mdb.c:8467-8469), so the walk starts from the key.
    try std.testing.expectError(error.InvalidArgument, cursor.firstDup());
    try std.testing.expectEqualStrings("alpha", (try cursor.set("key")).value);

    // This key carries duplicate data, so `firstDup` and `lastDup` hand back
    // the data and no key: that is the exit where upstream writes the data
    // alone (mdb.c:8492). The key is still there for `current`.
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
    // The list ends at the key, not at the database.
    try std.testing.expectError(error.NotFound, cursor.nextDup());

    entry = try cursor.lastDup();
    try std.testing.expectEqualStrings("gamma", entry.value);
    entry = try cursor.prevDup();
    try std.testing.expectEqualStrings("key", entry.key);
    try std.testing.expectEqualStrings("delta", entry.value);
    entry = try cursor.firstDup();
    try std.testing.expectEqualStrings("alpha", entry.value);
    try std.testing.expectError(error.NotFound, cursor.prevDup());

    // GET_BOTH matches the key and the value together: the pair that is there
    // is found by its value, and a value the key does not carry is absent.
    entry = try cursor.getBoth("key", "gamma");
    try std.testing.expectEqualStrings("gamma", entry.value);
    try std.testing.expectError(error.NotFound, cursor.getBoth("key", "epsilon"));

    // "bb" sorts between "alpha" and "beta", so the nearest at-or-after is "beta".
    entry = try cursor.getBothRange("key", "bb");
    try std.testing.expectEqualStrings("beta", entry.value);
}

test "a named open needs a slot the environment must be asked for" {
    var box = try Sandbox.init();
    defer box.deinit();

    {
        // No `.max_dbs`, so the slot table holds only the two databases
        // upstream keeps for itself (mdb.c:5028, `CORE_DBS` at mdb.c:1352).
        var env = try lmdb.Environment.init(.{ .path = box.path });
        defer env.close();

        var txn = try env.beginWrite();
        defer txn.abort();
        try std.testing.expectError(error.DbsFull, txn.openDatabase("named", .{ .create = true }));

        // The refusal is about the slot table and nothing else: the unnamed
        // database opens in the same transaction, and the refused name left
        // nothing behind for a later open to find.
        const main = try txn.openDatabase(null, .{});
        try txn.put(main, "alpha", "first");
        try std.testing.expectError(error.NotFound, txn.get(main, "named"));
    }

    {
        // The limit belongs to the handle rather than to the file, so this
        // open has to ask for the slot again, and the name then opens.
        var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
        defer env.close();

        var txn = try env.beginWrite();
        defer txn.abort();
        const db = try txn.openDatabase("named", .{ .create = true });
        try txn.put(db, "alpha", "first");
        try txn.commit();
    }

    {
        // A read-only handle needs the slot just as much to find the name.
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

    // `max_dbs` is a precondition of the named open below; see the module
    // comment and lmdb.h:1326-1327.
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

    // The key is gone from the database, not just from the cursor.
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

    // An unpositioned cursor has no current item, and says so with EINVAL.
    try std.testing.expectError(error.InvalidArgument, cursor.current());

    // `next` and `prev` are not errors there: upstream falls back to the first
    // and the last item respectively (mdb.c:8425-8426, :8730-8741).
    var entry = try cursor.prev();
    try std.testing.expectEqualStrings("omega", entry.key);
    try std.testing.expectError(error.NotFound, cursor.next());

    entry = try cursor.first();
    try std.testing.expectEqualStrings("alpha", entry.key);
    try std.testing.expectEqualStrings("alpha", (try cursor.current()).key);
    // The cursor is built from a single leaf page, so there is no sibling to
    // step onto and the walk ends where it started.
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

    // `set` demands the exact key; `setRange` takes the next one instead.
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

    // A cursor that was never positioned has nothing to delete.
    try std.testing.expectError(error.InvalidArgument, cursor.deleteCurrent());

    _ = try cursor.first();
    const entry = try cursor.next();
    try std.testing.expectEqualStrings("beta", entry.key);
    try cursor.deleteCurrent();
    // The cursor is still usable, and `next` continues past the hole rather
    // than returning the item that was deleted.
    const after = try cursor.next();
    try std.testing.expectEqualStrings("gamma", after.key);
    try std.testing.expectError(error.NotFound, cursor.next());

    try std.testing.expectError(error.NotFound, txn.get(db, "beta"));
    // The neighbours are untouched.
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

    // Upstream's intended use of MDB_CURRENT is a replacement of the same
    // size, which stays in place rather than becoming a delete and an insert
    // (lmdb.h:1717-1722).
    try cursor.putCurrent("alpha", "fifth");
    try std.testing.expectEqualStrings("fifth", (try cursor.current()).value);
    try std.testing.expectEqualStrings("fifth", try txn.get(db, "alpha"));

    // The keys around it are undisturbed and the cursor has not moved.
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

    // The parent is usable again once both children have finished.
    try std.testing.expectEqualStrings("merged", try txn.get(db, "kept"));
    try std.testing.expectError(error.NotFound, txn.get(db, "dropped"));

    // And the child's merge is only durable when the parent commits.
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

    // The handle is the C's and commit freed it, so anything else that reaches
    // for it has to be refused rather than followed into freed memory.
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
    // Between reset and renew the reader lock is gone and the C has finished
    // the transaction, so no data operation may reach it.
    try std.testing.expectError(error.TransactionNotResettable, reader.reset());
    try std.testing.expectError(error.TransactionReset, reader.get(db, "alpha"));
    try std.testing.expectError(error.TransactionReset, reader.openDatabase(null, .{}));

    // Renewing takes a fresh snapshot through the same handle and the same
    // database handle, which the C rebuilds from the environment's table.
    try reader.renew();
    try std.testing.expectError(error.NotFound, reader.get(db, "alpha"));
    try std.testing.expectError(error.TransactionNotReset, reader.renew());
}

test "a read cursor is closed by the caller after its transaction has ended" {
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

    var cursor: lmdb.Cursor = undefined;
    {
        var txn = try env.beginReadOnly();
        defer txn.abort();
        const db = try txn.openDatabase(null, .{});
        cursor = try txn.openCursor(db);
        try std.testing.expectEqualStrings("alpha", (try cursor.first()).key);
        // The transaction is aborted here, and a read-only transaction never
        // frees its cursors: lmdb.h:1622-1624 leaves that to the caller.
    }

    // Closing after the transaction ended is the documented order, and the
    // cursor must not have been freed underneath us.
    cursor.close();
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

    // The transaction owns this one and frees it when it commits; the facade
    // must not have freed it twice on the way.
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
    // Nothing may be flushed through a handle that has not mapped anything.
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

    // Upstream rejects a table with no slots at all (mdb.c:1021-1027).
    try std.testing.expectError(error.InvalidArgument, env.setMaxReaders(0));

    const configured = 37;
    try env.setMaxReaders(configured);
    try env.open(box.path, .{}, 0o664);
    // Not "the setter was called": the lock table the environment was built
    // with is this size, which is why a read transaction can now be begun.
    try std.testing.expectEqual(@as(u32, configured), try env.maxReaders());

    var txn = try env.beginReadOnly();
    txn.abort();
}

test "named databases are addressed by name and the limit is enforced" {
    var box = try Sandbox.init();
    defer box.deinit();

    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 2 });
    defer env.close();

    // A database handle stays valid across transactions, so one opened and
    // committed in the first transaction is closed in the second block.
    var stored: lmdb.Database = undefined;

    {
        var txn = try env.beginWrite();
        defer txn.abort();

        // A name that is not there yet is only refused when MDB_CREATE is off.
        try std.testing.expectError(error.NotFound, txn.openDatabase("one", .{}));

        const one = try txn.openDatabase("one", .{ .create = true });
        const two = try txn.openDatabase("two", .{ .create = true });
        try txn.put(one, "alpha", "in one");
        try txn.put(two, "alpha", "in two");

        // The same name opens the same database, and the values are separate.
        const again = try txn.openDatabase("one", .{});
        try std.testing.expectEqualStrings("in one", try txn.get(again, "alpha"));

        // Two named databases is what was asked for; a third is not there to
        // be given (mdb.c:12310-12312).
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

    // Closing the handle is the one release that is not automatic, and the
    // header allows it only with no transaction live and no cursor still
    // pointing at the database (lmdb.h:1403-1418).
    env.closeDatabase(stored);
    env.closeDatabase(stored);

    {
        var txn = try env.beginReadOnly();
        defer txn.abort();
        // Releasing the slot did not destroy the database: the name is still
        // in the environment's catalog and resolves again.
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

    // An empty *value* is a different question, and is allowed.
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

    // A `data.mdb` full of 0xFF. `mdb_env_read_header` reads a whole meta
    // buffer (mdb.c:4729), finds the page flagged as a meta page, and then
    // compares `mm_magic` against `MDB_MAGIC` (mdb.c:4759-4762). So the
    // refusal below is decided by the core reading the file, not by anything
    // this facade checks before it calls.
    const data_path = try std.fmt.allocPrintSentinel(gpa, "{s}/data.mdb", .{box.path}, 0);
    defer gpa.free(data_path);
    const junk = [_]u8{0xff} ** 1024;
    // `createFileAbsolute` is a `std.Io.Dir` function that takes the absolute
    // path; `createFile` is the method on a handle, for a path below it.
    const not_an_env = try std.Io.Dir.createFileAbsolute(io, data_path, .{});
    try not_an_env.writeStreamingAll(io, &junk);
    // Closed before the open below: from there the file is LMDB's to take.
    not_an_env.close(io);

    var env = try lmdb.Environment.create();
    defer env.close();
    try std.testing.expectError(error.Invalid, env.open(box.path, .{}, 0o664));

    // The failed attempt spent the handle. Upstream's own guard is the
    // data-file descriptor, and the failure path closed that descriptor
    // without clearing it (mdb.c:6257, mdb.c:6508), so a second open cannot
    // work — and must not be reported as an invalid argument, which is what
    // the stale descriptor makes upstream return.
    try std.testing.expectError(error.OpenFailed, env.open(box.path, .{}, 0o664));
    // Nor is the handle usable for anything else: it never became an
    // environment, so there is nothing to begin a transaction on.
    try std.testing.expectError(error.EnvironmentClosed, env.beginWrite());

    // The way out is a new handle, and it meets the same file and the same
    // refusal, which is the answer the file itself gives.
    var second = try lmdb.Environment.create();
    defer second.close();
    try std.testing.expectError(error.Invalid, second.open(box.path, .{}, 0o664));

    // Once closed, the first handle is released rather than refusing: it is
    // gone, so there is nothing left for `open` to be wrong about.
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

        // Every record reads back through `get`, and the keys are distinct.
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

    // `max_dbs` is a precondition of the named open below; see the module
    // comment and lmdb.h:1326-1327.
    var env = try lmdb.Environment.init(.{ .path = box.path, .max_dbs = 1 });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase("reversed", .{ .reversekey = true, .create = true });

    // Reversed, these are "cba", "dba" and "cbx", so "abc" precedes "xbc"
    // precedes "abd" -- an order that the forward collation would not give.
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

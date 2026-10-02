//! An out-of-tree consumer of the LMDB facade.
//!
//! This program is the proof that the library's published module is enough on
//! its own: the only thing it knows about the library is
//! `@import("lmdb")`, which the package resolves through
//! `dep.module("lmdb")`. It names no include directory, links no system
//! library, and reaches for `lmdb.c` only where the raw ABI is genuinely
//! interesting — the version string the compiled core reports.
//!
//! It checks persistence rather than merely round-tripping inside one handle:
//! it writes one set of records and abandons another, releases the
//! environment, opens it again from scratch, and then requires the exact
//! bytes of the committed records and the exact absence of the abandoned
//! ones. The environment is built in a directory of its own under the
//! temporary root the process was started with — `TMPDIR`, and on Windows
//! `TEMP` then `TMP` — and that directory is removed before it exits.
//!
//! `zig build run` executes it; a disagreement exits non-zero.

const std = @import("std");
const lmdb = @import("lmdb");
const builtin = @import("builtin");

/// Committed and abandoned in the same environment, and in the same order, so
/// the only difference between them is which transaction was committed.
const committed = [_]Record{
    .{ .key = "alpha", .value = "one" },
    .{ .key = "beta", .value = "two" },
    .{ .key = "gamma", .value = "three" },
};

const abandoned = [_]Record{
    .{ .key = "alpha", .value = "clobbered" },
    .{ .key = "delta", .value = "four" },
};

const Record = struct { key: []const u8, value: []const u8 };

const Failure = error{
    /// An observation did not match what the library promises.
    Disagreed,
    /// A committed record came back with different bytes.
    WrongValue,
    /// A record that was never committed is in the database.
    UnexpectedRecord,
};

fn require(ok: bool, what: []const u8) Failure!void {
    if (!ok) {
        std.debug.print("consumer: disagreed: {s}\n", .{what});
        return error.Disagreed;
    }
}

/// The environment variables that name a temporary root, in the order they are
/// consulted: `TMPDIR` on every platform, the Windows spellings after it.
/// A variable that is unset or empty names no directory.
const temp_root_vars: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "TMPDIR", "TEMP", "TMP" }
else
    &.{"TMPDIR"};

/// The directory the scratch environment is created under, as an absolute
/// path: what the temporary root variable names — taken against the working
/// directory when it is relative, because `mdb_env_open` is handed an absolute
/// path — or `.zig-cache/tmp` under the working directory when the environment
/// names no temporary root at all, which keeps a consumer on a host that
/// configures none portable.
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

/// A directory under the temporary root holding one environment, removed on
/// the way out. `mdb_env_open` needs an absolute path and does not create the
/// directory: `mdb.c` contains no `mkdir`.
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

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    var scratch = try Scratch.init(io, gpa, init.environ);
    defer scratch.deinit(io, gpa);

    const version = lmdb.version();
    std.debug.print("consumer: linked LMDB {d}.{d}.{d}\n", .{
        version.major,
        version.minor,
        version.patch,
    });

    try writeThenAbandon(scratch.path);
    try readBackAfterReopen(scratch.path);

    std.debug.print("consumer: committed records persisted, abandoned ones did not\n", .{});
}

/// Write, commit, and then run a second transaction that overwrites one
/// committed record and adds another — and abandon it.
///
/// Only the unnamed database is opened, so the environment is asked for no
/// named-database slots: `mdb_env_set_maxdbs` would have to be repeated on
/// every later handle, and nothing here needs it.
fn writeThenAbandon(path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{ .path = path });

    var keeper = try env.beginWrite();
    defer keeper.abort();
    const keeper_db = try keeper.openDatabase(null, .{});
    for (committed) |record| try keeper.put(keeper_db, record.key, record.value);
    try keeper.commit();
    try env.sync(true);

    var loser = try env.beginWrite();
    defer loser.abort();
    const loser_db = try loser.openDatabase(null, .{});
    for (abandoned) |record| try loser.put(loser_db, record.key, record.value);
    try require(
        std.mem.eql(u8, "clobbered", try loser.get(loser_db, "alpha")),
        "the abandoned transaction sees its own write",
    );
    loser.abort();
}

/// Open the same directory again — a new handle, a new mapping, a new
/// transaction — and check the file holds exactly the committed state.
fn readBackAfterReopen(path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    for (committed) |record| {
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
    // transaction added must not be there at all.
    if (!std.mem.eql(u8, "one", try txn.get(db, "alpha"))) return error.UnexpectedRecord;
    try require(
        if (txn.get(db, "delta")) |_| false else |err| err == error.NotFound,
        "the record the abandoned transaction added is absent",
    );

    // Walking the whole database must find exactly the committed keys, which
    // also rules out a stray record the reopen did not think to ask for.
    var cursor = try txn.openCursor(db);
    defer cursor.close();

    var seen: usize = 0;
    var entry = try cursor.first();
    while (true) {
        if (seen >= committed.len) return error.UnexpectedRecord;
        if (!std.mem.eql(u8, committed[seen].key, entry.key)) return error.UnexpectedRecord;
        if (!std.mem.eql(u8, committed[seen].value, entry.value)) return error.WrongValue;
        seen += 1;
        const next = cursor.next();
        if (next) |following| {
            entry = following;
        } else |err| {
            try require(err == error.NotFound, "the walk ends with NotFound");
            break;
        }
    }
    try require(seen == committed.len, "the walk found every committed record and no more");
}

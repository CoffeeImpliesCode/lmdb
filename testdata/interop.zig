//! The reference interoperability check, and the run that decides it.
//!
//! The oracle is not this package. It is `mdb_dump`, upstream's own
//! command-line tool, built from the unmodified `libraries/liblmdb/mdb_dump.c`
//! in this repository and linked against the same C core and the same
//! `lmdb.h` the facade's translated header came from. `zig build interop`
//! builds both halves and runs this program with the path to that binary:
//!
//! ```
//! $ZIG build interop
//! ```
//!
//! This program writes `testdata/corpus.txt` into a fresh environment through
//! the facade, runs the reference tool over the same directory, and compares
//! what the two printed. What is compared is the *body* of `mdb_dump -p` — the
//! bytes between its `HEADER=END` and `DATA=END` marker lines
//! (mdb_dump.c:136, mdb_dump.c:154) — against the same body rendered from the
//! fixture. The header above those markers is deliberately left out: it
//! carries the memory-map address (mdb_dump.c:124-125), which is the kernel's
//! choice and differs between runs over the same bytes, so comparing it would
//! compare two addresses rather than two readers of one file. The body is
//! compared byte for byte, so neither half is its own witness.
//!
//! `mdb_dump -p` renders each key and value as `mdb_dump.c:65-84` renders it:
//! a leading space, then every byte; a printable byte other than `\` stands
//! for itself, and anything else becomes `\xx`. This corpus is restricted to
//! printable ASCII without a backslash, and the program checks that
//! restriction before it relies on it, so the simple rendering below *is* the
//! reference rendering for this input and no escaping rule is re-invented
//! here. A corpus that grew a non-printable byte would fail that check rather
//! than silently disagree with `mdb_dump`.
//!
//! The read-back walk this program performs through the facade is a
//! supplementary self-check and not the gate: it would pass if both halves of
//! the comparison were this same wrapper. What decides is upstream's output.
//!
//! ## Arguments
//!
//! `--dump=<path>` names the reference executable and is required.
//! `--dir=<path>` names an existing empty directory to build the environment
//! in; without it the program uses a scratch directory under the temporary
//! root the process was started with — `TMPDIR`, and on Windows `TEMP` then
//! `TMP` — and removes it on the way out, and a host that names no temporary
//! root gets `.zig-cache/tmp`. `mdb_env_open` needs an absolute path and
//! does not create the directory — there is no `mkdir` anywhere in `mdb.c` —
//! so `--dir` is a path that already exists.
//!
//! `zig build check` compiles this program for every target of the matrix and
//! never runs it there: a reference binary for a foreign target would have to
//! be a foreign binary, and running one is not what that step claims to do.

const std = @import("std");
const lmdb = @import("lmdb");
const builtin = @import("builtin");

/// The marker lines `mdb_dump` prints around its records, newline included,
/// so the body is cut from exactly what the tool printed (`mdb_dump.c:136`
/// and `mdb_dump.c:154`).
const header_end = "HEADER=END\n";
const data_end = "DATA=END\n";

const arg_dump_prefix = "--dump=";
const arg_dir_prefix = "--dir=";

const corpus_text = @embedFile("corpus.txt");

const Record = struct {
    key: []const u8,
    value: []const u8,
};

/// Every way this program stops without a verdict, named.
const Failure = error{
    /// `--dump=` was missing, or an argument was not one of the two.
    BadArguments,
    /// The corpus is not shaped the way the comparison needs it to be.
    MalformedCorpus,
    /// The two bodies are not the same bytes.
    Disagreement,
    /// The reference tool could not be run, or did not finish successfully.
    ReferenceFailed,
    /// The reference tool's output did not carry the markers the body is cut
    /// from, so there was no body to compare.
    MarkersMissing,
};

const Options = struct {
    /// The reference executable, as given on the command line.
    dump: []const u8,
    /// An existing directory to build the environment in, or null for the
    /// scratch one.
    dir: ?[:0]const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    const args = try init.minimal.args.toSlice(arena);
    const options = try parseArgs(arena, args);

    const corpus = try parseCorpus(arena, corpus_text);
    try checkRenderingIsUnambiguous(corpus.insert);
    try checkRenderingIsUnambiguous(corpus.expect);
    if (corpus.insert.len != corpus.expect.len) return error.MalformedCorpus;

    // What the reference tool has to print for this fixture, rendered here
    // rather than read from the tool, so the comparison has two sides.
    const expected = try renderBody(arena, corpus.expect);

    if (options.dir) |dir| {
        // A caller-supplied directory is left behind: the environment in it
        // is the artefact, and the reference tool has to read the same bytes.
        try write(corpus, dir);
        try verify(corpus, dir);
        try compare(out, io, arena, options, corpus, expected, dir);
    } else {
        var scratch = try Scratch.init(io, arena, init.minimal.environ);
        defer scratch.deinit(io);
        try write(corpus, scratch.path);
        try verify(corpus, scratch.path);
        try compare(out, io, arena, options, corpus, expected, scratch.path);
    }
    try out.flush();
}

/// Run the reference tool over `dir` and decide whether its body is the body
/// the fixture says it must be.
fn compare(
    out: anytype,
    io: std.Io,
    arena: std.mem.Allocator,
    options: Options,
    corpus: Corpus,
    expected: []const u8,
    dir: [:0]const u8,
) !void {
    const actual = try runReference(io, arena, options.dump, dir);

    try out.print("body mdb_dump -p printed:\n{s}", .{actual});
    if (!std.mem.eql(u8, expected, actual)) {
        var at: usize = 0;
        while (at < expected.len and at < actual.len and expected[at] == actual[at]) at += 1;
        try out.print("\nbody testdata/corpus.txt requires:\n{s}", .{expected});
        try out.print("\nthe two bodies first differ at byte {d} of {d}\n", .{ at, expected.len });
        try out.flush();
        return error.Disagreement;
    }
    try out.print(
        "{d} records match mdb_dump -p byte for byte\n",
        .{corpus.expect.len},
    );
}

/// Read the command line. `--dump` is required; `--dir` is not.
fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var dump: ?[]const u8 = null;
    var dir: ?[:0]const u8 = null;
    // `args[0]` is this program's own path.
    const tail = if (args.len == 0) args else args[1..];

    for (tail) |arg| {
        if (std.mem.startsWith(u8, arg, arg_dump_prefix)) {
            dump = arg[arg_dump_prefix.len..];
        } else if (std.mem.startsWith(u8, arg, arg_dir_prefix)) {
            dir = try std.fmt.allocPrintSentinel(arena, "{s}", .{arg[arg_dir_prefix.len..]}, 0);
        } else {
            std.debug.print("interop: unrecognised argument {s}\n{s}{s}\n", .{
                arg,
                arg_dump_prefix,
                arg_dir_prefix,
            });
            return error.BadArguments;
        }
    }

    const dump_path = dump orelse {
        std.debug.print("interop: {s}<path to mdb_dump> is required\n", .{arg_dump_prefix});
        return error.BadArguments;
    };
    return .{ .dump = dump_path, .dir = dir };
}

/// Render the body the reference tool must print for these records.
///
/// The body is the bytes *between* the two marker lines and nothing else,
/// which is the span `extractBody` cuts out of what the tool printed. The
/// markers belong to the tool: `mdb_dump` writes them to bound its own
/// output, and rendering them here as well would put `HEADER=END` in front
/// of the comparison and `DATA=END` behind it, so the two sides would
/// differ on their first byte and the comparison would decide nothing.
/// The header above the markers is excluded for the reason given at the
/// top of this file: it carries the memory-map address.
///
/// The rendering is `mdb_dump.c:65-84` for this input, and
/// `checkRenderingIsUnambiguous` is what makes that so: it refuses a corpus
/// carrying a byte that `mdb_dump` would escape.
fn renderBody(arena: std.mem.Allocator, records: []const Record) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(arena);

    for (records) |record| {
        try body.append(arena, ' ');
        try body.appendSlice(arena, record.key);
        try body.append(arena, '\n');
        try body.append(arena, ' ');
        try body.appendSlice(arena, record.value);
        try body.append(arena, '\n');
    }
    return body.items;
}

/// Run the reference tool over `dir` and return the body of its `-p` output.
///
/// `-p` is the printable rendering, which is the one this corpus is written
/// for, and a single positional argument is what `mdb_dump` expects after its
/// options (`mdb_dump.c:249-251, mdb_dump.c:261, mdb_dump.c:282`).
fn runReference(
    io: std.Io,
    arena: std.mem.Allocator,
    dump: []const u8,
    dir: [:0]const u8,
) ![]const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ dump, "-p", dir },
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("interop: {s} -p exited {d}\n{s}", .{ dump, code, result.stderr });
            return error.ReferenceFailed;
        },
        else => {
            std.debug.print("interop: {s} -p did not exit normally\n", .{dump});
            return error.ReferenceFailed;
        },
    }
    return extractBody(result.stdout);
}

/// The bytes between `HEADER=END\n` and `DATA=END\n`.
///
/// Both markers are required and there must be only one header: a body cut
/// from the wrong place in the output would compare the wrong thing and could
/// pass without either half having read the database.
fn extractBody(dump_output: []const u8) Failure![]const u8 {
    const header = std.mem.indexOf(u8, dump_output, header_end) orelse
        return error.MarkersMissing;
    if (std.mem.indexOfPos(u8, dump_output, header + header_end.len, header_end) != null)
        return error.MarkersMissing;

    const body = header + header_end.len;
    const stop = std.mem.indexOfPos(u8, dump_output, body, data_end) orelse
        return error.MarkersMissing;
    return dump_output[body..stop];
}

/// Store every record in the order the fixture records them and commit.
fn write(corpus: Corpus, path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{ .path = path });
    defer env.close();

    var txn = try env.beginWrite();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});
    for (corpus.insert) |record| try txn.put(db, record.key, record.value);
    try txn.commit();
    try env.sync(true);
}

/// Reopen the environment and require that a forward walk produces exactly the
/// recorded expectation — the same walk `mdb_dump` performs.
///
/// This is the supplementary half and shares code with the writer, so on its
/// own it would only show the facade agreeing with itself. It is here because a
/// disagreement here says which of the two bodies is wrong.
fn verify(corpus: Corpus, path: [:0]const u8) !void {
    var env = try lmdb.Environment.init(.{ .path = path, .flags = .{ .rdonly = true } });
    defer env.close();

    var txn = try env.beginReadOnly();
    defer txn.abort();
    const db = try txn.openDatabase(null, .{});

    for (corpus.expect) |record| {
        const found = try txn.get(db, record.key);
        if (!std.mem.eql(u8, record.value, found)) return error.Disagreement;
    }

    var cursor = try txn.openCursor(db);
    defer cursor.close();

    var entry = try cursor.first();
    for (corpus.expect, 0..) |record, index| {
        if (!std.mem.eql(u8, record.key, entry.key)) return error.Disagreement;
        if (!std.mem.eql(u8, record.value, entry.value)) return error.Disagreement;
        if (index + 1 < corpus.expect.len) entry = try cursor.next();
    }
    // The reference tool stops at MDB_NOTFOUND too; anything else walking off
    // the end is a disagreement.
    if (cursor.next()) |_| {
        return error.Disagreement;
    } else |err| {
        if (err != error.NotFound) return error.Disagreement;
    }
}

/// Refuse a corpus whose bytes would not survive the plain rendering above.
///
/// `mdb_dump -p` writes a byte as itself only when `isprint` and it is not a
/// backslash; anything else is escaped. Checking the restriction is what makes
/// the printed body comparable to the reference tool's without this program
/// implementing the escape rule.
fn checkRenderingIsUnambiguous(records: []const Record) Failure!void {
    for (records) |record| {
        for ([_][]const u8{ record.key, record.value }) |bytes| {
            for (bytes) |byte| {
                if (!std.ascii.isPrint(byte) or byte == '\\') return error.MalformedCorpus;
            }
        }
    }
}

const Corpus = struct {
    insert: []const Record,
    expect: []const Record,
};

/// Parse the fixture: `key<TAB>value`, `#` comments, blank lines ignored, and
/// two blocks introduced by `[insert]` and `[expect]`.
fn parseCorpus(arena: std.mem.Allocator, text: []const u8) !Corpus {
    var insert: std.ArrayList(Record) = .empty;
    var expect: std.ArrayList(Record) = .empty;
    var in_expect = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[insert]")) continue;
        if (std.mem.eql(u8, line, "[expect]")) {
            in_expect = true;
            continue;
        }
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse
            return error.MalformedCorpus;
        const record = Record{ .key = line[0..tab], .value = line[tab + 1 ..] };
        if (in_expect) {
            try expect.append(arena, record);
        } else {
            try insert.append(arena, record);
        }
    }

    if (insert.items.len == 0 or expect.items.len == 0) return error.MalformedCorpus;
    return .{
        .insert = try insert.toOwnedSlice(arena),
        .expect = try expect.toOwnedSlice(arena),
    };
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
/// names no temporary root at all, which is what `std.testing.tmpDir` uses and
/// what keeps a host that configures none portable.
fn scratchRootAlloc(io: std.Io, arena: std.mem.Allocator, environ: std.process.Environ) ![:0]u8 {
    for (temp_root_vars) |name| {
        const value = environ.getAlloc(arena, name) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // Not set, or not a name this platform can spell: try the next.
            error.EnvironmentVariableMissing, error.InvalidWtf8 => continue,
        };
        defer arena.free(value);
        if (value.len == 0) continue;
        if (std.fs.path.isAbsolute(value)) return try arena.dupeZ(u8, value);
        const cwd = try std.process.currentPathAlloc(io, arena);
        defer arena.free(cwd);
        return try std.fs.path.joinZ(arena, &.{ @as([]const u8, cwd), value });
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    defer arena.free(cwd);
    return try std.fs.path.joinZ(arena, &.{ @as([]const u8, cwd), ".zig-cache", "tmp" });
}

/// A scratch environment directory under the temporary root, removed on the
/// way out. `mdb_env_open` needs an absolute path and does not create the
/// directory: `mdb.c` contains no `mkdir`.
const Scratch = struct {
    parent: std.Io.Dir,
    sub_path: [sub_path_len]u8,
    path: [:0]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init(io: std.Io, arena: std.mem.Allocator, environ: std.process.Environ) !Scratch {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        // The arena owns `root` and `path` for the rest of the run, so nothing
        // here is freed; the directory is the thing to remove.
        const root = try scratchRootAlloc(io, arena, environ);

        // The root is made when it is not there yet. Only the random child
        // made below it belongs to this program, and only that one is removed.
        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
        errdefer parent.close(io);
        try parent.createDirPath(io, &sub_path);

        const path = std.fs.path.joinZ(arena, &.{ @as([]const u8, root), &sub_path }) catch |err| {
            // The child is there from here on, so a path that cannot be built
            // must not leave it behind.
            parent.deleteTree(io, &sub_path) catch {};
            return err;
        };

        return .{ .parent = parent, .sub_path = sub_path, .path = path };
    }

    fn deinit(self: *Scratch, io: std.Io) void {
        self.parent.deleteTree(io, &self.sub_path) catch {};
        self.parent.close(io);
    }
};

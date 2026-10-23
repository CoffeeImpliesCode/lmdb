//! Zig facade over the bundled LMDB C library.
//! Handles own native resources; map bytes are borrowed until the next update or transaction end.
//! Linked builds are default; `-Druntime=true` requires [`load`]. [`c`] exposes the translated C API.
const std = @import("std");
const builtin = @import("builtin");

/// The translated upstream API, or its generated runtime dispatch with the same declarations.
/// Use it for raw status codes or operations not wrapped below.
pub const c = @import("c");

const rt = @import("rt");

/// Whether native symbols are resolved at runtime instead of link time.
/// A comptime constant; runtime-loaded calls require [`load`] first.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// An explicit provider path or system-loader basename; no fallback is used.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned when loading a runtime provider.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the selected provider; failed attempts publish nothing and may be retried.
/// A different request after success returns `error.ProviderMismatch`; linked builds panic.
pub fn load(source: LoadSource) LoadError!void {
    if (comptime !runtime_loaded) {
        std.debug.panic(
            "lmdb: load was called on a linked build; this module is not " ++
                "runtime-loaded, so there is no library to load. Build with " ++
                "runtime loading configured, or do not call load.",
            .{},
        );
    }
    return c.load(source);
}

/// The retained request that loaded successfully, or `null` in a linked build.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

/// File creation permissions: target `mode_t`, or `int` on MSVC.
pub const Mode = c.mdb_mode_t;

/// Upstream's unsigned type for map sizes, counts and transaction IDs.
pub const Size = c.mdb_size_t;

/// LMDB, operating-system and facade errors; raw statuses remain available through [`c`].
pub const Error = error{
    /// Key or key/data pair already exists.
    KeyExists,
    /// Requested key, duplicate value or named database is absent.
    NotFound,
    /// A referenced page does not exist.
    PageNotFound,
    /// Environment structures disagree with the file.
    Corrupted,
    /// Fatal earlier error; close and reopen the environment.
    Panic,
    /// Library and environment use different on-disk formats.
    VersionMismatch,
    /// The environment file header is invalid.
    Invalid,
    /// The database reached its map size; see `Environment.setMapSize`.
    MapFull,
    /// The named-database slot limit is reached.
    DbsFull,
    /// The reader lock table is full.
    ReadersFull,
    /// The thread-local reader-slot table overflowed.
    TlsFull,
    /// The transaction has too many dirty pages.
    TxnFull,
    /// The transaction has too many open cursors.
    CursorFull,
    /// A page cannot hold the key or duplicate value.
    PageFull,
    /// Another process grew the map; use `Environment.setMapSize(0)` to adopt it.
    MapResized,
    /// Database flags differ from those used to create it.
    Incompatible,
    /// A reader lock slot was used incorrectly.
    BadRslot,
    /// The transaction is inconsistent.
    BadTxn,
    /// Key or duplicate value size is invalid; zero-length keys are rejected.
    BadValSize,
    /// Database handle is stale or was not opened.
    BadDbi,
    /// Internal invariant failed; LMDB considers itself broken.
    Problem,
    /// Page checksum failed, or the environment is not checksummed.
    BadChecksum,
    /// The encryption callback failed.
    CryptoFail,
    /// Encryption was requested on an unconfigured environment.
    EnvEncryption,
    /// Transaction is prepared for two-phase commit.
    TxnPending,
    /// No committed transaction can be rolled back.
    CantRollback,
    /// Database handles remain open.
    DbisBusy,
    /// A file write completed only in part.
    ShortWrite,
    /// Another handle is using the environment.
    EnvBusy,
    /// A write was refused by a read-only transaction or environment, not by file permissions.
    IsReadOnly,
    /// LMDB's requested fixed-map address is in use.
    AddrBusy,

    /// A required environment file could not be opened for writing.
    AccessDenied,
    /// Upstream rejected an argument or a setter called after open.
    InvalidArgument,
    /// The C library or memory mapping could not allocate.
    OutOfMemory,
    /// The filesystem is full.
    NoSpaceLeft,
    /// POSIX I/O failure; Windows code 5 maps to `AccessDenied`.
    InputOutput,
    /// A component of the environment path does not exist.
    NoSuchFileOrDirectory,
    /// A lock is held, or its robust-lock owner died; retry when safe.
    WouldBlock,
    /// The filesystem is read-only.
    ReadOnlyFileSystem,
    /// The process or system ran out of file descriptors.
    TooManyOpenFiles,
    /// Windows refused a file opened by another process without `MDB_NOLOCK`.
    SharingViolation,

    /// Unknown native status or unexpected null result; use `c` for raw status.
    UnexpectedStatus,

    /// Environment handle is closed, or an unopened handle was used.
    EnvironmentClosed,
    /// The environment handle is already open.
    EnvironmentAlreadyOpen,
    /// The first open failed and spent the handle; close it and create another.
    OpenFailed,
    /// Transaction handle was used after commit or abort.
    TransactionClosed,
    /// Transaction is reset; only `renew` or `abort` is valid.
    TransactionReset,
    /// Reset requires a non-nested read-only transaction not already reset.
    TransactionNotResettable,
    /// The transaction must be reset before renewal.
    TransactionNotReset,
    /// Cursor handle was used after close.
    CursorClosed,
    /// Empty keys are refused; oversized keys return `BadValSize`.
    EmptyKey,
};

/// Target errno constants used by POSIX status mapping; Windows uses GetLastError.
const Errno = std.c.E;

/// Win32 status values returned by upstream on Windows.
const Win32 = struct {
    const file_not_found = 2; // ERROR_FILE_NOT_FOUND
    const path_not_found = 3; // ERROR_PATH_NOT_FOUND
    const access_denied = 5; // ERROR_ACCESS_DENIED
    const not_enough_memory = 8; // ERROR_NOT_ENOUGH_MEMORY
    const write_protect = 19; // ERROR_WRITE_PROTECT
    const sharing_violation = 32; // ERROR_SHARING_VIOLATION
    const lock_violation = 33; // ERROR_LOCK_VIOLATION
    const invalid_parameter = 87; // ERROR_INVALID_PARAMETER
    const disk_full = 112; // ERROR_DISK_FULL
};

/// Translate LMDB status codes and target OS errors into `Error`.
fn check(rc: c_int) Error!void {
    if (rc == c.MDB_SUCCESS) return;
    return switch (rc) {
        c.MDB_KEYEXIST => error.KeyExists,
        c.MDB_NOTFOUND => error.NotFound,
        c.MDB_PAGE_NOTFOUND => error.PageNotFound,
        c.MDB_CORRUPTED => error.Corrupted,
        c.MDB_PANIC => error.Panic,
        c.MDB_VERSION_MISMATCH => error.VersionMismatch,
        c.MDB_INVALID => error.Invalid,
        c.MDB_MAP_FULL => error.MapFull,
        c.MDB_DBS_FULL => error.DbsFull,
        c.MDB_READERS_FULL => error.ReadersFull,
        c.MDB_TLS_FULL => error.TlsFull,
        c.MDB_TXN_FULL => error.TxnFull,
        c.MDB_CURSOR_FULL => error.CursorFull,
        c.MDB_PAGE_FULL => error.PageFull,
        c.MDB_MAP_RESIZED => error.MapResized,
        c.MDB_INCOMPATIBLE => error.Incompatible,
        c.MDB_BAD_RSLOT => error.BadRslot,
        c.MDB_BAD_TXN => error.BadTxn,
        c.MDB_BAD_VALSIZE => error.BadValSize,
        c.MDB_BAD_DBI => error.BadDbi,
        c.MDB_PROBLEM => error.Problem,
        c.MDB_BAD_CHECKSUM => error.BadChecksum,
        c.MDB_CRYPTO_FAIL => error.CryptoFail,
        c.MDB_ENV_ENCRYPTION => error.EnvEncryption,
        c.MDB_TXN_PENDING => error.TxnPending,
        c.MDB_CANT_ROLLBACK => error.CantRollback,
        c.MDB_DBIS_BUSY => error.DbisBusy,
        c.MDB_SHORT_WRITE => error.ShortWrite,
        c.MDB_ENV_BUSY => error.EnvBusy,
        c.MDB_IS_READONLY => error.IsReadOnly,
        c.MDB_ADDR_BUSY => error.AddrBusy,

        else => positiveStatus(rc),
    };
}

/// Map positive status codes using the target's errno or Windows error space.
fn positiveStatus(rc: c_int) Error {
    return switch (builtin.os.tag) {
        .windows => winStatus(rc),
        else => posixStatus(rc),
    };
}

/// Map POSIX status codes returned by upstream.
fn posixStatus(rc: c_int) Error {
    return switch (rc) {
        @intFromEnum(Errno.ACCES) => error.AccessDenied,
        @intFromEnum(Errno.PERM) => error.AccessDenied,
        @intFromEnum(Errno.INVAL) => error.InvalidArgument,
        @intFromEnum(Errno.NOMEM) => error.OutOfMemory,
        @intFromEnum(Errno.NOSPC) => error.NoSpaceLeft,
        @intFromEnum(Errno.IO) => error.InputOutput,
        @intFromEnum(Errno.NOENT) => error.NoSuchFileOrDirectory,
        @intFromEnum(Errno.AGAIN) => error.WouldBlock,
        @intFromEnum(Errno.DEADLK) => error.WouldBlock,
        @intFromEnum(Errno.MFILE) => error.TooManyOpenFiles,
        @intFromEnum(Errno.NFILE) => error.TooManyOpenFiles,
        @intFromEnum(Errno.ROFS) => error.ReadOnlyFileSystem,
        else => error.UnexpectedStatus,
    };
}

/// Map Win32 codes returned by upstream; CRT `EINVAL` is handled separately.
fn winStatus(rc: c_int) Error {
    return switch (rc) {
        22 => error.InvalidArgument,
        // CreateFileW/OpenMutexA (mdb.c:5414-5420; :6140-6143).
        Win32.file_not_found => error.NoSuchFileOrDirectory,
        Win32.path_not_found => error.NoSuchFileOrDirectory,
        Win32.access_denied => error.AccessDenied,
        // VirtualAlloc and the CreateMutex shim (mdb.c:2876-2877, :395).
        Win32.not_enough_memory => error.OutOfMemory,
        // MDB_ERRCODE_ROFS (mdb.c:5945, :5959).
        Win32.write_protect => error.ReadOnlyFileSystem,
        Win32.sharing_violation => error.SharingViolation,
        // LockFileEx, the Windows counterpart of POSIX fcntl locks.
        Win32.lock_violation => error.WouldBlock,
        Win32.invalid_parameter => error.InvalidArgument,
        // WriteFile and CreateFileW.
        Win32.disk_full => error.NoSpaceLeft,
        else => error.UnexpectedStatus,
    };
}

/// Check a C call that returns its result through an out-parameter.
fn checkOut(comptime T: type, rc: c_int, out: ?*T) Error!*T {
    try check(rc);
    return out orelse error.UnexpectedStatus;
}

/// A key/data pair; map-backed bytes are borrowed until the next update or transaction end.
/// `getBoth` variants return the caller's key slice; duplicate traversal may return an empty key.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// The C may write this pointer for `MDB_NOOVERWRITE`; the facade reports `KeyExists` without exposing that value.
fn keyValue(key: []const u8) Error!c.MDB_val {
    if (key.len == 0) return error.EmptyKey;
    const raw: *anyopaque = @ptrCast(@constCast(key.ptr));
    return .{ .mv_size = key.len, .mv_data = raw };
}

/// Empty data is allowed except in duplicate-sort databases.
fn dataValue(data: []const u8) c.MDB_val {
    const raw: *anyopaque = @ptrCast(@constCast(data.ptr));
    return .{ .mv_size = data.len, .mv_data = raw };
}

/// Borrow the bytes described by an `MDB_val`; nothing is copied.
fn borrowed(val: c.MDB_val) []const u8 {
    if (val.mv_size == 0) return "";
    const bytes: [*]const u8 = @ptrCast(val.mv_data.?);
    return bytes[0..val.mv_size];
}

/// Return a bounded borrowed view of a library-owned NUL-terminated string.
fn cString(ptr: [*c]u8, comptime limit: usize) []const u8 {
    var len: usize = 0;
    while (len < limit and ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

/// The library version returned by `mdb_version`.
pub const Version = struct {
    major: c_int,
    minor: c_int,
    patch: c_int,
};

/// The version reported by the linked library or loaded provider; this is not a compatibility check.
pub fn version() Version {
    var v: Version = undefined;
    _ = c.mdb_version(&v.major, &v.minor, &v.patch);
    return v;
}
pub fn versionString() []const u8 {
    return cString(c.mdb_version(null, null, null), 256);
}

/// The library's static message for a raw LMDB or platform status code.
pub fn strerror(rc: c_int) []const u8 {
    return cString(c.mdb_strerror(rc), 512);
}

/// Options for `mdb_env_open`; booleans map to upstream bits, not packed field positions.
pub const EnvFlags = struct {
    /// `MDB_FIXEDMAP`: use a fixed map address; set when creating the environment.
    fixedmap: bool = false,
    /// `MDB_NOSUBDIR`: treat the path as the data file, not an environment directory.
    nosubdir: bool = false,
    /// `MDB_RDONLY`: open read-only; the lock file is still written where supported.
    rdonly: bool = false,
    /// `MDB_WRITEMAP`: write through the map; incompatible with nested transactions.
    writemap: bool = false,
    /// `MDB_NOMETASYNC`: omit commit metadata flush; a crash may undo the last transaction.
    nometasync: bool = false,
    /// `MDB_NOSYNC`: do not flush on commit.
    nosync: bool = false,
    /// `MDB_MAPASYNC`: flush asynchronously with `writemap`.
    mapasync: bool = false,
    /// `MDB_NORDAHEAD`: disable OS readahead.
    nordahead: bool = false,
    /// `MDB_NOMEMINIT`: do not zero reused pages before writing them.
    nomeminit: bool = false,
    /// `MDB_NOTLS`: bind reader slots to transactions, allowing thread migration.
    notls: bool = false,
    /// `MDB_NOLOCK`: disable locking; the caller must serialize access.
    nolock: bool = false,
    /// `MDB_PREVSNAPSHOT`: open the snapshot before the latest transaction.
    prevsnapshot: bool = false,
    /// `MDB_REMAP_CHUNKS`: map the file in chunks.
    remap_chunks: bool = false,

    /// Build the `mdb_env_open` bitmask.
    pub fn bits(self: EnvFlags) c_uint {
        return flag(c.MDB_FIXEDMAP, self.fixedmap) |
            flag(c.MDB_NOSUBDIR, self.nosubdir) |
            flag(c.MDB_RDONLY, self.rdonly) |
            flag(c.MDB_WRITEMAP, self.writemap) |
            flag(c.MDB_NOMETASYNC, self.nometasync) |
            flag(c.MDB_NOSYNC, self.nosync) |
            flag(c.MDB_MAPASYNC, self.mapasync) |
            flag(c.MDB_NORDAHEAD, self.nordahead) |
            flag(c.MDB_NOMEMINIT, self.nomeminit) |
            flag(c.MDB_NOTLS, self.notls) |
            flag(c.MDB_NOLOCK, self.nolock) |
            flag(c.MDB_PREVSNAPSHOT, self.prevsnapshot) |
            flag(c.MDB_REMAP_CHUNKS, self.remap_chunks);
    }
};

/// One upstream flag bit, or zero when it is not set.
fn flag(bit_value: anytype, on: bool) c_uint {
    if (!on) return 0;
    return @intCast(bit_value);
}

/// Options for `mdb_dbi_open`; fields map to upstream flags.
pub const DbFlags = struct {
    /// `MDB_REVERSEKEY`: compare keys from their last byte backwards.
    reversekey: bool = false,
    /// `MDB_DUPSORT`: allow several data items per key, sorted.
    dupsort: bool = false,
    /// `MDB_INTEGERKEY`: compare fixed-size machine integers in native byte order.
    integerkey: bool = false,
    /// `MDB_DUPFIXED`: require equal-sized data items with `dupsort`.
    dupfixed: bool = false,
    /// `MDB_INTEGERDUP`: compare duplicate values as machine integers.
    integerdup: bool = false,
    /// `MDB_REVERSEDUP`: compare duplicate values as reversed strings.
    reversedup: bool = false,
    /// `MDB_CREATE`: create the named database if absent; invalid in read-only mode.
    create: bool = false,

    /// Build the `mdb_dbi_open` bitmask.
    pub fn bits(self: DbFlags) c_uint {
        return flag(c.MDB_REVERSEKEY, self.reversekey) |
            flag(c.MDB_DUPSORT, self.dupsort) |
            flag(c.MDB_INTEGERKEY, self.integerkey) |
            flag(c.MDB_DUPFIXED, self.dupfixed) |
            flag(c.MDB_INTEGERDUP, self.integerdup) |
            flag(c.MDB_REVERSEDUP, self.reversedup) |
            flag(c.MDB_CREATE, self.create);
    }
};

/// Cursor operations using the translated target enum width.
/// Page-at-a-time `MDB_DUPFIXED` operations stay in `c`; their results count items, not bytes.
pub const CursorOp = enum(c.MDB_cursor_op) {
    /// Position at the first key/data item.
    first = @intCast(c.MDB_FIRST),
    /// Position at the first data item of the current key. `DUPSORT` only.
    first_dup = @intCast(c.MDB_FIRST_DUP),
    /// Position at the given key/data pair. `DUPSORT` only.
    get_both = @intCast(c.MDB_GET_BOTH),
    /// Position at the given key and the nearest data item. `DUPSORT` only.
    get_both_range = @intCast(c.MDB_GET_BOTH_RANGE),
    /// Return the key/data at the current cursor position.
    get_current = @intCast(c.MDB_GET_CURRENT),
    /// Position at the last key/data item.
    last = @intCast(c.MDB_LAST),
    /// Position at the last data item of the current key. `DUPSORT` only.
    last_dup = @intCast(c.MDB_LAST_DUP),
    /// Position at the next data item.
    next = @intCast(c.MDB_NEXT),
    /// Position at the next data item of the current key. `DUPSORT` only.
    next_dup = @intCast(c.MDB_NEXT_DUP),
    /// Position at the first data item of the next key.
    next_nodup = @intCast(c.MDB_NEXT_NODUP),
    /// Position at the previous data item.
    prev = @intCast(c.MDB_PREV),
    /// Position at the previous data item of the current key. `DUPSORT` only.
    prev_dup = @intCast(c.MDB_PREV_DUP),
    /// Position at the last data item of the previous key.
    prev_nodup = @intCast(c.MDB_PREV_NODUP),
    /// Position at a key and return the stored key.
    set_key = @intCast(c.MDB_SET_KEY),
    /// Position at the first key at or after the given key.
    set_range = @intCast(c.MDB_SET_RANGE),
};

/// Page and tree statistics for one database, copied from `MDB_stat`.
pub const Statistics = struct {
    /// Page size in bytes.
    page_size: c_uint,
    /// Height of the B-tree.
    depth: c_uint,
    /// Internal, non-leaf pages.
    branch_pages: Size,
    /// Leaf pages.
    leaf_pages: Size,
    /// Pages holding items too large for a leaf.
    overflow_pages: Size,
    /// Data items stored in the database, duplicates counted separately.
    entries: Size,
};

/// Map address, size, page/transaction IDs and reader-table counts.
pub const EnvInfo = struct {
    /// Map base address owned by the environment; not a readable pointer.
    map_address: ?*anyopaque,
    /// Size of the data memory map, and so the ceiling on the database.
    map_size: Size,
    /// ID of the last page used.
    last_page: Size,
    /// ID of the last committed transaction. This is the value
    /// [`Environment.rollback`] takes.
    last_txn: Size,
    /// Reader lock-table slots this environment has.
    max_readers: c_uint,
    /// Slots currently in use.
    num_readers: c_uint,
};

/// Options for environment copy operations.
pub const CopyFlags = struct {
    /// `MDB_CP_COMPACT`. Omit free pages from the copy.
    compact: bool = false,

    /// Build the `mdb_env_copy2`/`mdb_env_copyfd2` bitmask.
    pub fn bits(self: CopyFlags) c_uint {
        return flag(c.MDB_CP_COMPACT, self.compact);
    }
};

/// Target file-handle type (`int` on POSIX, opaque pointer on Windows); zero means absent.
pub const FileHandle = c.mdb_filehandle_t;

/// Upstream key and duplicate comparator type.
/// Install the same function before data access in every program that opens the database.
pub const KeyComparator = c.MDB_cmp_func;

/// Upstream fixed-map relocation callback; recorded but not called in this release.
pub const RelocationCallback = c.MDB_rel_func;

/// Callback used by `Environment.setAssertCallback`.
pub const AssertCallback = c.MDB_assert_func;

/// Reader-table callback; a negative return stops the listing.
pub const MessageCallback = c.MDB_msg_func;

/// Options for `Environment.init`; null settings retain LMDB defaults.
pub const OpenOptions = struct {
    /// Existing directory or `nosubdir` data file; borrowed for the call and copied by LMDB.
    path: [:0]const u8,
    /// Flags for the open.
    flags: EnvFlags = .{},
    /// File permissions, default `0664` subject to umask; ignored on Windows.
    mode: Mode = 0o664,
    /// Memory-map size and database limit; null retains the upstream default.
    map_size: ?Size = null,
    /// Named-database capacity; set again for every environment open.
    /// LMDB reserves two internal slots; the default permits no named database.
    max_dbs: ?u32 = null,
    /// Reader lock-table slots. `null` leaves upstream's default.
    max_readers: ?u32 = null,
};

/// Environment directory/file, lock table and map; the native handle has one owner.
/// Keep it at a stable address while transactions borrow it; close after all children.
pub const Environment = struct {
    /// C-owned handle, or null after close.
    handle: ?*c.MDB_env,
    /// Whether opening succeeded; a failed first attempt also spends the handle.
    opened: bool,
    /// Set when `mdb_env_open` is entered; even a failed attempt spends this handle (mdb.c:6257, :6508).
    open_attempted: bool,

    /// Create an unopened environment with a C-owned allocation.
    /// Configure it before `open`; use `init` when no intermediate setup is needed.
    pub fn create() Error!Environment {
        var out: ?*c.MDB_env = null;
        const handle = try checkOut(c.MDB_env, c.mdb_env_create(&out), out);
        return .{ .handle = handle, .opened = false, .open_attempted = false };
    }

    /// Create, configure and open; limits are set before opening and failures close the handle.
    pub fn init(options: OpenOptions) Error!Environment {
        var env = try create();
        errdefer env.close();
        if (options.max_dbs) |count| try env.setMaxDbs(count);
        if (options.max_readers) |count| try env.setMaxReaders(count);
        if (options.map_size) |bytes| try env.setMapSize(bytes);
        try env.open(options.path, options.flags, options.mode);
        return env;
    }

    /// Open a created environment; `directory` is sentinel-terminated and borrowed for the call.
    /// A handle can be opened once; even failure spends it, so close and recreate it (`OpenFailed`).
    pub fn open(self: *Environment, directory: [:0]const u8, options: EnvFlags, mode: Mode) Error!void {
        if (self.opened) return error.EnvironmentAlreadyOpen;
        if (self.open_attempted) return error.OpenFailed;
        const handle = try self.pending();
        // Mark before C: a failed open spends the handle too.
        self.open_attempted = true;
        try check(c.mdb_env_open(handle, directory.ptr, options.bits(), mode));
        self.opened = true;
    }

    /// Close the environment after all transactions, databases and cursors are released.
    /// Idempotent; also frees a handle whose first open failed.
    pub fn close(self: *Environment) void {
        const handle = self.handle orelse return;
        self.handle = null;
        self.opened = false;
        self.open_attempted = false;
        c.mdb_env_close(handle);
    }

    /// Set the map limit; zero adopts a size another process persisted (`MapResized`).
    /// No transaction may be live: a read-only transaction can be missed and its borrowed bytes unmapped.
    pub fn setMapSize(self: *Environment, bytes: Size) Error!void {
        try check(c.mdb_env_set_mapsize(try self.pending(), bytes));
    }

    /// Set named-database capacity before open; LMDB reserves two internal slots.
    pub fn setMaxDbs(self: *Environment, count: u32) Error!void {
        try check(c.mdb_env_set_maxdbs(try self.pending(), @intCast(count)));
    }

    /// Set reader slots before open; zero is invalid.
    pub fn setMaxReaders(self: *Environment, count: u32) Error!void {
        try check(c.mdb_env_set_maxreaders(try self.pending(), @intCast(count)));
    }

    /// Return the environment's configured reader-slot count.
    pub fn maxReaders(self: *Environment) Error!u32 {
        var readers: c_uint = 0;
        try check(c.mdb_env_get_maxreaders(try self.pending(), &readers));
        return @intCast(readers);
    }

    /// Return the maximum key size in bytes; requires an open environment.
    /// Larger keys return `error.BadValSize`.
    pub fn maxKeySize(self: *Environment) Error!u32 {
        return @intCast(c.mdb_env_get_maxkeysize(try self.openHandle()));
    }

    /// Set a supported power-of-two page size before open; invalid values return `error.InvalidArgument`.
    pub fn setPageSize(self: *Environment, bytes: c_int) Error!void {
        try check(c.mdb_env_set_pagesize(try self.pending(), bytes));
    }

    /// Return the flags currently set on this environment.
    pub fn flags(self: *Environment) Error!c_uint {
        var bits: c_uint = 0;
        try check(c.mdb_env_get_flags(try self.openHandle(), &bits));
        return bits;
    }

    /// Set or clear mask bits; upstream decides which flags may change after open.
    /// Not mutex-protected; callers must serialize concurrent changes.
    pub fn setFlags(self: *Environment, mask: c_uint, on: bool) Error!void {
        try check(c.mdb_env_set_flags(try self.openHandle(), mask, if (on) 1 else 0));
    }

    /// Borrow the path stored by LMDB; it lasts until the environment closes.
    pub fn path(self: *Environment) Error![:0]const u8 {
        var text: ?[*:0]const u8 = null;
        try check(c.mdb_env_get_path(try self.openHandle(), &text));
        return text orelse error.UnexpectedStatus;
    }

    /// Return the environment-owned data-file handle (`int` on POSIX, opaque pointer on Windows).
    pub fn fileHandle(self: *Environment) Error!FileHandle {
        var handle: FileHandle = 0;
        try check(c.mdb_env_get_fd(try self.openHandle(), &handle));
        return handle;
    }

    /// Statistics for the main database; use `Transaction.statistics` for named databases.
    pub fn statistics(self: *Environment) Error!Statistics {
        var raw: c.MDB_stat = undefined;
        try check(c.mdb_env_stat(try self.openHandle(), &raw));
        return .{
            .page_size = raw.ms_psize,
            .depth = raw.ms_depth,
            .branch_pages = raw.ms_branch_pages,
            .leaf_pages = raw.ms_leaf_pages,
            .overflow_pages = raw.ms_overflow_pages,
            .entries = raw.ms_entries,
        };
    }

    /// Return map, page, transaction and reader-table information.
    pub fn info(self: *Environment) Error!EnvInfo {
        var raw: c.MDB_envinfo = undefined;
        try check(c.mdb_env_info(try self.openHandle(), &raw));
        return .{
            .map_address = raw.me_mapaddr,
            .map_size = raw.me_mapsize,
            .last_page = raw.me_last_pgno,
            .last_txn = raw.me_last_txnid,
            .max_readers = raw.me_maxreaders,
            .num_readers = raw.me_numreaders,
        };
    }

    /// Copy to an existing, writable, empty directory; long-lived readers may make the copy grow.
    pub fn copy(self: *Environment, destination: [:0]const u8) Error!void {
        try check(c.mdb_env_copy(try self.openHandle(), destination.ptr));
    }

    /// Copy the environment into `path` with options.
    pub fn copyWithOptions(self: *Environment, destination: [:0]const u8, options: CopyFlags) Error!void {
        try check(c.mdb_env_copy2(try self.openHandle(), destination.ptr, options.bits()));
    }

    /// Copy to a caller-opened writable handle; LMDB writes no lock file unless needed.
    pub fn copyToFileHandle(
        self: *Environment,
        handle: FileHandle,
        options: CopyFlags,
    ) Error!void {
        try check(c.mdb_env_copyfd2(try self.openHandle(), handle, options.bits()));
    }

    /// Dump commits after `txn` to a new file that must not already exist.
    pub fn dumpSince(self: *Environment, destination: [:0]const u8, txn: Size) Error!void {
        try check(c.mdb_env_incr_dump(try self.openHandle(), destination.ptr, txn));
    }

    /// Dump commits after `txn` to a caller-opened writable handle.
    pub fn dumpSinceToFileHandle(self: *Environment, handle: FileHandle, txn: Size) Error!void {
        try check(c.mdb_env_incr_dumpfd(try self.openHandle(), handle, txn));
    }

    /// Load a dump into an environment opened with `writemap`; no other task may access it during the call.
    pub fn loadSinceFromFileHandle(self: *Environment, handle: FileHandle) Error!void {
        try check(c.mdb_env_incr_loadfd(try self.openHandle(), handle));
    }

    /// Roll back the newest committed transaction; no other process may write between commit and rollback.
    /// Older or unknown IDs return `error.CantRollback`.
    pub fn rollback(self: *Environment, txn: Size) Error!void {
        try check(c.mdb_env_rollback(try self.openHandle(), txn));
    }

    /// Store a caller-owned context pointer; it is not copied or freed.
    pub fn setUserContext(self: *Environment, context: ?*anyopaque) Error!void {
        try check(c.mdb_env_set_userctx(try self.pending(), context));
    }

    /// Return the context pointer previously stored.
    pub fn userContext(self: *Environment) Error!?*anyopaque {
        return c.mdb_env_get_userctx(try self.pending());
    }

    /// Set or clear the assertion callback, called before upstream aborts on an assertion failure.
    /// The callback is compiled out when the provider is built with `NDEBUG`.
    pub fn setAssertCallback(self: *Environment, callback: ?AssertCallback) Error!void {
        try check(c.mdb_env_set_assert(try self.pending(), callback));
    }

    /// List readers; the context is borrowed and callback results are returned unchanged.
    /// A negative callback result stops the listing; errors only report an unopened environment.
    pub fn listReaders(self: *Environment, callback: MessageCallback, context: ?*anyopaque) Error!c_int {
        const status = c.mdb_reader_list(try self.openHandle(), callback, context);
        return status;
    }

    /// Return the number of stale reader slots reclaimed; zero is normal.
    pub fn clearStaleReaders(self: *Environment) Error!c_int {
        var dead: c_int = 0;
        try check(c.mdb_reader_check(try self.openHandle(), &dead));
        return dead;
    }

    /// Flush data buffers; `force` flushes even when sync flags defer commit writes.
    pub fn sync(self: *Environment, force: bool) Error!void {
        try check(c.mdb_env_sync(try self.openHandle(), if (force) 1 else 0));
    }

    /// Return a database slot; no thread, transaction or cursor may still use the handle.
    /// No implicit close occurs; closing only makes the slot reusable.
    pub fn closeDatabase(self: *Environment, db: Database) void {
        const handle = self.handle orelse return;
        c.mdb_dbi_close(handle, db.dbi);
    }

    /// Begin a snapshot transaction; it borrows this environment wrapper until commit or abort.
    pub fn beginReadOnly(self: *Environment) Error!Transaction {
        return self.begin(true);
    }

    /// Begin a write transaction; it borrows this wrapper and waits for the single writer slot.
    pub fn beginWrite(self: *Environment) Error!Transaction {
        return self.begin(false);
    }

    fn begin(self: *Environment, read_only: bool) Error!Transaction {
        const handle = try self.openHandle();
        var out: ?*c.MDB_txn = null;
        const txn_flags: c_uint = if (read_only) @intCast(c.MDB_RDONLY) else 0;
        const txn = try checkOut(c.MDB_txn, c.mdb_txn_begin(handle, null, txn_flags, &out), out);
        return .{
            .handle = txn,
            .env = self,
            .read_only = read_only,
            .nested = false,
            .suspended = false,
            .prepared = false,
        };
    }

    /// Return the existing C handle, whether or not it is open.
    fn pending(self: *Environment) Error!*c.MDB_env {
        return self.handle orelse error.EnvironmentClosed;
    }

    /// Return the C handle only after a successful open.
    fn openHandle(self: *Environment) Error!*c.MDB_env {
        const handle = try self.pending();
        if (!self.opened) return error.EnvironmentClosed;
        return handle;
    }
};

/// Page encryption/checksum calls when declared by the selected header; configure them before open.
/// Encryption requires `MDB_REMAP_CHUNKS`.
pub const Encryption = if (@hasDecl(c, "mdb_env_set_encrypt")) struct {
    /// Page-encryption callback; input is map-backed and the destination is callback-owned during the call.
    pub const Callback = c.MDB_enc_func;

    /// Page-checksum callback; it writes `size` bytes into library-owned storage.
    pub const ChecksumCallback = c.MDB_sum_func;

    /// Configure page encryption; the caller's callback must remain valid for the environment's lifetime.
    /// `key` and `auth_data_size` are passed to the callback; `MDB_ENCRYPT` is set by LMDB.
    pub fn set(env: *Environment, callback: Callback, key: []const u8, auth_data_size: c_uint) Error!void {
        var key_value = dataValue(key);
        try check(c.mdb_env_set_encrypt(try env.pending(), callback, &key_value, auth_data_size));
    }

    /// Configure a plain checksum; keep the caller-owned callback valid for the environment's lifetime.
    pub fn setChecksum(env: *Environment, callback: ChecksumCallback, size: c_uint) Error!void {
        try check(c.mdb_env_set_checksum(try env.pending(), callback, size));
    }
} else void;

/// A transaction snapshot; the wrapper owns one native handle and borrows its environment.
/// Close read cursors before commit, abort or reset; borrowed map bytes expire with updates or transaction end.
pub const Transaction = struct {
    /// C-owned transaction handle; null after commit or abort.
    handle: ?*c.MDB_txn,
    /// Borrowed environment wrapper; keep it alive at this address until this transaction ends.
    env: *Environment,
    /// Read-only state, also used to select cursor ownership.
    read_only: bool,
    /// Nested state; committed child writes merge into the parent.
    nested: bool,
    /// True between reset and renew, when data operations are invalid.
    suspended: bool,
    /// True after prepare; only commit or abort is valid and native cursors are closed.
    prepared: bool,

    /// Begin a child transaction; the parent may only commit or abort while it is live.
    /// Child writes merge on commit and are discarded on abort.
    pub fn beginNested(self: *Transaction) Error!Transaction {
        const parent = try self.active();
        const env_handle = try self.env.pending();
        var out: ?*c.MDB_txn = null;
        const txn = try checkOut(c.MDB_txn, c.mdb_txn_begin(env_handle, parent, 0, &out), out);
        return .{
            .handle = txn,
            .env = self.env,
            .read_only = false,
            .nested = true,
            .suspended = false,
            .prepared = false,
        };
    }

    /// Open a database; named opens require `max_dbs` before environment open.
    /// The handle remains private until commit, and database opens must not overlap across transactions.
    pub fn openDatabase(self: *Transaction, name: ?[:0]const u8, options: DbFlags) Error!Database {
        const handle = try self.active();
        var dbi: c.MDB_dbi = 0;
        const name_ptr: [*c]const u8 = if (name) |n| n.ptr else null;
        try check(c.mdb_dbi_open(handle, name_ptr, options.bits(), &dbi));
        return .{ .dbi = dbi };
    }

    /// Store bytes under `key`; inputs are copied, while `DUPSORT` adds a duplicate.
    /// A failed replacement may remove the old item and fail the transaction; abort rather than treat it as a no-op.
    pub fn put(self: *Transaction, db: Database, key: []const u8, value: []const u8) Error!void {
        return self.store(db, key, value, 0);
    }

    /// Store only when `key` is absent, including in `DUPSORT`; otherwise returns `error.KeyExists`.
    /// The facade does not expose the stored-value pointer upstream writes to its local `MDB_val`.
    pub fn putNoOverwrite(self: *Transaction, db: Database, key: []const u8, value: []const u8) Error!void {
        return self.store(db, key, value, c.MDB_NOOVERWRITE);
    }

    /// Store a duplicate only when the key/data pair is absent; requires `DUPSORT`.
    pub fn putNoDupData(self: *Transaction, db: Database, key: []const u8, value: []const u8) Error!void {
        return self.store(db, key, value, c.MDB_NODUPDATA);
    }

    fn store(
        self: *Transaction,
        db: Database,
        key: []const u8,
        value: []const u8,
        mdb_flags: c_int,
    ) Error!void {
        const handle = try self.active();
        var k = try keyValue(key);
        var v = dataValue(value);
        try check(c.mdb_put(handle, db.dbi, &k, &v, @intCast(mdb_flags)));
    }

    /// Return the first value for `key`; the result borrows map bytes until the next update or transaction end.
    pub fn get(self: *Transaction, db: Database, key: []const u8) Error![]const u8 {
        const handle = try self.active();
        var k = try keyValue(key);
        var v: c.MDB_val = undefined;
        try check(c.mdb_get(handle, db.dbi, &k, &v));
        return borrowed(v);
    }

    /// Delete `key` and all its duplicates; returns `error.NotFound` when absent.
    pub fn delete(self: *Transaction, db: Database, key: []const u8) Error!void {
        const handle = try self.active();
        var k = try keyValue(key);
        try check(c.mdb_del(handle, db.dbi, &k, null));
    }

    /// Delete one duplicate; returns `error.NotFound` when absent.
    /// Without `DUPSORT`, upstream deletes the key as for `delete`.
    pub fn deleteValue(
        self: *Transaction,
        db: Database,
        key: []const u8,
        value: []const u8,
    ) Error!void {
        const handle = try self.active();
        var k = try keyValue(key);
        var v = dataValue(value);
        try check(c.mdb_del(handle, db.dbi, &k, &v));
    }

    /// Open a cursor borrowing this wrapper's stable address; close read cursors before ending or resetting the transaction.
    /// A write cursor's native allocation belongs to the transaction.
    pub fn openCursor(self: *Transaction, db: Database) Error!Cursor {
        const handle = try self.active();
        var out: ?*c.MDB_cursor = null;
        const cursor = try checkOut(c.MDB_cursor, c.mdb_cursor_open(handle, db.dbi, &out), out);
        return .{ .handle = cursor, .owner = self, .read_only = self.read_only };
    }

    /// Commit and release the transaction; close read cursors first.
    /// The handle is spent on success or failure; a deferred abort is safe.
    pub fn commit(self: *Transaction) Error!void {
        try check(c.mdb_txn_commit(try self.take()));
    }

    /// Discard uncommitted writes and release the handle; idempotent after commit or abort.
    /// Close read cursors first; commit/abort invalidate borrowed bytes.
    pub fn abort(self: *Transaction) void {
        const handle = self.handle orelse return;
        self.handle = null;
        self.suspended = false;
        self.prepared = false;
        c.mdb_txn_abort(handle);
    }

    /// Write data pages without the metapage; only `commit` or `abort` remains valid and cursors close.
    /// Nested prepare behaves as commit; another prepare returns `error.TxnPending`.
    pub fn prepare(self: *Transaction) Error!void {
        const handle = try self.active();
        try check(c.mdb_txn_prepare(handle));
        if (self.nested) {
            self.handle = null;
            self.suspended = false;
            return;
        }
        self.prepared = true;
    }

    /// Reset a non-nested read-only transaction; it releases the snapshot and invalidates borrowed bytes.
    /// Close read cursors first; other transaction kinds return `error.TransactionNotResettable`.
    pub fn reset(self: *Transaction) Error!void {
        const handle = self.handle orelse return error.TransactionClosed;
        if (self.suspended) return error.TransactionNotResettable;
        if (!self.read_only or self.nested) return error.TransactionNotResettable;
        c.mdb_txn_reset(handle);
        self.suspended = true;
    }

    /// Renew a reset handle with the newest committed snapshot.
    pub fn renew(self: *Transaction) Error!void {
        const handle = self.handle orelse return error.TransactionClosed;
        if (!self.suspended) return error.TransactionNotReset;
        try check(c.mdb_txn_renew(handle));
        self.suspended = false;
    }

    /// Return the active transaction ID used by rollback and incremental dumps.
    pub fn id(self: *Transaction) Error!Size {
        const handle = try self.active();
        return c.mdb_txn_id(handle);
    }

    /// Return the flags this transaction was begun with.
    pub fn flags(self: *Transaction) Error!c_uint {
        var bits: c_uint = 0;
        try check(c.mdb_txn_flags(try self.active(), &bits));
        return bits;
    }

/// Return the C-reported environment handle borrowed by this transaction.
    pub fn environment(self: *Transaction) Error!*c.MDB_env {
        const handle = try self.active();
        return c.mdb_txn_env(handle) orelse error.UnexpectedStatus;
    }

/// Return page and tree statistics for a named database.
    pub fn statistics(self: *Transaction, db: Database) Error!Statistics {
        var raw: c.MDB_stat = undefined;
        try check(c.mdb_stat(try self.active(), db.dbi, &raw));
        return .{
            .page_size = raw.ms_psize,
            .depth = raw.ms_depth,
            .branch_pages = raw.ms_branch_pages,
            .leaf_pages = raw.ms_leaf_pages,
            .overflow_pages = raw.ms_overflow_pages,
            .entries = raw.ms_entries,
        };
    }

/// Return the flags this database was created with.
    pub fn databaseFlags(self: *Transaction, db: Database) Error!c_uint {
        var bits: c_uint = 0;
        try check(c.mdb_dbi_flags(try self.active(), db.dbi, &bits));
        return bits;
    }

/// Empty a database or delete a named database and close its handle; the main database can only be emptied.
/// Read-only returns `IsReadOnly`; do not close a handle deleted by this call.
    pub fn drop(self: *Transaction, db: Database, delete_database: bool) Error!void {
        try check(c.mdb_drop(try self.active(), db.dbi, if (delete_database) 1 else 0));
    }

/// Install the key comparator before data access and use it in every program that opens this database.
/// The callback must not re-enter the environment or retain its map-backed arguments.
    pub fn setKeyComparator(self: *Transaction, db: Database, comparator: KeyComparator) Error!void {
        try check(c.mdb_set_compare(try self.active(), db.dbi, comparator));
    }

/// Install the duplicate-value comparator before data access; all programs must use the same function.
/// It is stored for any database but affects normal operations only with `DUPSORT`.
    pub fn setValueComparator(self: *Transaction, db: Database, comparator: KeyComparator) Error!void {
        try check(c.mdb_set_dupsort(try self.active(), db.dbi, comparator));
    }

/// Record a fixed-map relocation callback; upstream marks this feature unimplemented.
    pub fn setRelocation(self: *Transaction, db: Database, relocation: RelocationCallback) Error!void {
        try check(c.mdb_set_relfunc(try self.active(), db.dbi, relocation));
    }

/// Store a caller-owned relocation context pointer; it is neither copied nor freed.
    pub fn setRelocationContext(
        self: *Transaction,
        db: Database,
        context: ?*anyopaque,
    ) Error!void {
        try check(c.mdb_set_relctx(try self.active(), db.dbi, context));
    }

/// Compare keys with the database comparator; return ordering, not a status.
    pub fn compareKeys(self: *Transaction, db: Database, a: []const u8, b: []const u8) Error!c_int {
        const handle = try self.active();
        const left = dataValue(a);
        const right = dataValue(b);
        return c.mdb_cmp(handle, db.dbi, &left, &right);
    }

/// Compare duplicate values with the database comparator; return ordering, not a status.
/// Requires `DUPSORT`; without it upstream calls a null comparator.
    pub fn compareValues(self: *Transaction, db: Database, a: []const u8, b: []const u8) Error!c_int {
        const handle = try self.active();
        const left = dataValue(a);
        const right = dataValue(b);
        return c.mdb_dcmp(handle, db.dbi, &left, &right);
    }

/// Return a usable native handle or the closed, reset or prepared error.
    fn active(self: *Transaction) Error!*c.MDB_txn {
        const handle = self.handle orelse return error.TransactionClosed;
        if (self.suspended) return error.TransactionReset;
        if (self.prepared) return error.TxnPending;
        return handle;
    }

/// Take the handle before a C call frees it; prepared transactions remain spendable.
    fn take(self: *Transaction) Error!*c.MDB_txn {
        const handle = self.handle orelse return error.TransactionClosed;
        if (self.suspended) return error.TransactionReset;
        self.handle = null;
        return handle;
    }
};

/// A copyable slot index, not an owner; obtain it through `openDatabase`.
/// A new slot is private until commit; close a published slot before environment shutdown.
pub const Database = struct {
    dbi: c.MDB_dbi,
};

/// A cursor borrows its transaction wrapper; close read cursors before transaction end or reset.
/// Returned map bytes are borrowed; cursors from a completed nested transaction are unusable.
pub const Cursor = struct {
    /// Native pointer while open; close spends the wrapper, and ownership depends on `read_only`.
    handle: ?*c.MDB_cursor,
    /// Borrowed transaction wrapper; keep it alive at this address until the cursor closes.
    owner: *Transaction,
    /// Ownership kind captured by `openCursor`; do not modify it.
    read_only: bool,

    /// Close read cursors while their transaction is live and not reset; the transaction frees write cursors.
    /// Idempotent; later traversal returns `error.CursorClosed`.
    pub fn close(self: *Cursor) void {
        const handle = self.handle orelse return;
        self.handle = null;
        if (self.read_only) c.mdb_cursor_close(handle);
    }

    /// Position at the first key/data item.
    pub fn first(self: *Cursor) Error!Entry {
        return self.seek(.first, null, null);
    }

    /// Position at the final key/value pair.
    pub fn last(self: *Cursor) Error!Entry {
        return self.seek(.last, null, null);
    }

    /// Advance to the next item, crossing keys after their duplicate values.
    /// Before positioning, returns the first item.
    pub fn next(self: *Cursor) Error!Entry {
        return self.seek(.next, null, null);
    }

    /// Move to the previous item; before positioning, returns the last item.
    pub fn prev(self: *Cursor) Error!Entry {
        return self.seek(.prev, null, null);
    }

    /// Move to the first item under the next key, skipping remaining duplicates.
    pub fn nextNoDup(self: *Cursor) Error!Entry {
        return self.seek(.next_nodup, null, null);
    }

    /// Move to the last item under the previous key.
    pub fn prevNoDup(self: *Cursor) Error!Entry {
        return self.seek(.prev_nodup, null, null);
    }

    /// Return the current item without moving; unpositioned cursors return `error.InvalidArgument`.
    pub fn current(self: *Cursor) Error!Entry {
        return self.seek(.get_current, null, null);
    }

    /// Position at an exact key and return its stored key and first value.
    /// Returns `error.NotFound` when absent.
    pub fn set(self: *Cursor, key: []const u8) Error!Entry {
        return self.seek(.set_key, key, null);
    }

    /// Position at the first key greater than or equal to `key`; returns `error.NotFound` past the end.
    pub fn setRange(self: *Cursor, key: []const u8) Error!Entry {
        return self.seek(.set_range, key, null);
    }

    /// Move to the first duplicate; requires a positioned cursor and `DUPSORT`.
    /// For duplicate values the returned key is empty; use `current` for the key.
    pub fn firstDup(self: *Cursor) Error!Entry {
        return self.seek(.first_dup, null, null);
    }

    /// Move to the last duplicate; same positioning, `DUPSORT`, and key rules as `firstDup`.
    pub fn lastDup(self: *Cursor) Error!Entry {
        return self.seek(.last_dup, null, null);
    }

    /// Move to the next duplicate; requires `DUPSORT` and returns `error.NotFound` at the key's end.
    pub fn nextDup(self: *Cursor) Error!Entry {
        return self.seek(.next_dup, null, null);
    }

    /// Move to the previous duplicate; requires `DUPSORT`.
    pub fn prevDup(self: *Cursor) Error!Entry {
        return self.seek(.prev_dup, null, null);
    }

    /// Position at an exact key/value pair; requires `DUPSORT`.
    /// `Entry.key` borrows the caller's input slice, not the map.
    pub fn getBoth(self: *Cursor, key: []const u8, value: []const u8) Error!Entry {
        return self.seek(.get_both, key, value);
    }

    /// Position at the least value at or after `value`; requires `DUPSORT`, and `Entry.key` borrows `key`.
    pub fn getBothRange(self: *Cursor, key: []const u8, value: []const u8) Error!Entry {
        return self.seek(.get_both_range, key, value);
    }

    /// Replace the current value; the supplied key must match and `DUPSORT` values must keep their sort position.
    /// A size change may delete before insert; abort the transaction if insertion fails.
    pub fn putCurrent(self: *Cursor, key: []const u8, value: []const u8) Error!void {
        const handle = try self.live();
        var k = try keyValue(key);
        var v = dataValue(value);
        try check(c.mdb_cursor_put(handle, &k, &v, @intCast(c.MDB_CURRENT)));
    }

    /// Delete the current pair; the cursor must be positioned and remains usable afterward.
    /// After end-of-walk it still addresses the last item.
    pub fn deleteCurrent(self: *Cursor) Error!void {
        try check(c.mdb_cursor_del(try self.live(), 0));
    }

    /// Delete all duplicates of the current key; requires `DUPSORT`.
    pub fn deleteAllDuplicates(self: *Cursor) Error!void {
        try check(c.mdb_cursor_del(try self.live(), @intCast(c.MDB_NODUPDATA)));
    }

    /// Count values for the current key; requires a positioned cursor and `DUPSORT`.
    /// Returns `error.Incompatible` without `DUPSORT`, `error.InvalidArgument` before positioning, or `error.NotFound` at end.
    pub fn count(self: *Cursor) Error!Size {
        var n: c.mdb_size_t = 0;
        try check(c.mdb_cursor_count(try self.live(), &n));
        return n;
    }

    /// Rebind and unposition the cursor; borrowed bytes from the old transaction expire.
    /// The old cursor must remain valid: read transactions may end first, but write transactions free their cursors.
    pub fn renew(self: *Cursor, txn: *Transaction) Error!void {
        const handle = self.handle orelse return error.CursorClosed;
        try check(c.mdb_cursor_renew(try txn.active(), handle));
        self.owner = txn;
        self.read_only = txn.read_only;
    }

    /// Return the native transaction handle borrowed by this cursor.
    pub fn transaction(self: *Cursor) Error!*c.MDB_txn {
        return c.mdb_cursor_txn(try self.live()) orelse error.UnexpectedStatus;
    }

    /// Return the database handle this cursor was opened on.
    pub fn database(self: *Cursor) Error!c.MDB_dbi {
        return c.mdb_cursor_dbi(try self.live());
    }

    /// True when the current main-database record names a database; false if unpositioned.
    /// After exhaustion it still describes the last record; use traversal errors to detect the end.
    pub fn onNamedDatabase(self: *Cursor) Error!bool {
        return c.mdb_cursor_is_db(try self.live()) != 0;
    }

    /// Run one cursor operation; search inputs are consumed and returned map bytes are borrowed.
    fn seek(
        self: *Cursor,
        op: CursorOp,
        key_in: ?[]const u8,
        value_in: ?[]const u8,
    ) Error!Entry {
        const handle = try self.live();
        var key: c.MDB_val = if (key_in) |k| try keyValue(k) else .{
            .mv_size = 0,
            .mv_data = undefined,
        };
        var value: c.MDB_val = if (value_in) |v| dataValue(v) else .{
            .mv_size = 0,
            .mv_data = undefined,
        };
        try check(c.mdb_cursor_get(handle, &key, &value, @intFromEnum(op)));
        return .{ .key = borrowed(key), .value = borrowed(value) };
    }

    /// Return a cursor handle only while both it and its owning transaction are usable.
    fn live(self: *Cursor) Error!*c.MDB_cursor {
        const handle = self.handle orelse return error.CursorClosed;
        _ = try self.owner.active();
        return handle;
    }
};

//! Zig facade over LMDB, the Lightning Memory-Mapped Database.
//!
//! The database is not reimplemented here. Every byte that reaches the file,
//! every key comparison and every lock comes out of the canonical C in
//! `libraries/liblmdb/mdb.c`, reached through `pub const c`, the module
//! produced by `b.addTranslateC` over `translate.h`. What this module adds is
//! the part a C header cannot express: an ownership model for the four opaque
//! handles, a Zig error set standing in for upstream's single `int` status
//! code, and slices that carry the borrowing rules the header states in prose.
//!
//! ## The four handles and who frees them
//!
//! Upstream's contract, read out of `lmdb.h` and `mdb.c` rather than assumed:
//!
//!   * `MDB_env` is created by `mdb_env_create` and released by
//!     `mdb_env_close` (lmdb.h:589-600, :892-900). It is the only handle with
//!     no parent.
//!   * `MDB_txn` is created by `mdb_txn_begin` and released by **either**
//!     `mdb_txn_commit` or `mdb_txn_abort` (lmdb.h:1121-1163, :1190-1206,
//!     :1257-1265). `commit` releases it whether it succeeds or fails:
//!     `_mdb_txn_commit` leaves through `mdb_txn_end(txn, …|MDB_END_FREE)` on
//!     success and through `_mdb_txn_abort` on every failure branch
//!     (mdb.c:4629-4637).
//!   * `MDB_dbi` is a `unsigned int` index into the environment's slot table,
//!     not a pointer (lmdb.h:280-281). It needs no release; `mdb_dbi_close`
//!     only returns the slot (lmdb.h:1403-1419) and is deliberately awkward.
//!   * `MDB_cursor` is created by `mdb_cursor_open` and released by
//!     `mdb_cursor_close` (lmdb.h:1614-1644) — but a cursor belonging to a
//!     **write** transaction is freed by the transaction itself, and may not
//!     outlive it. A cursor belonging to a read-only transaction is never
//!     freed by the transaction and must be closed explicitly, before or
//!     after the transaction ends (lmdb.h:1620-1626).
//!
//! These are not stylistic choices, and the facade enforces each of them:
//!
//!   * [`Transaction.commit`] and [`Transaction.abort`] both clear the
//!     handle before calling the C, so a `defer txn.abort()` that runs after a
//!     successful commit is a no-op instead of a double free. A second
//!     `commit` or `abort` is likewise a no-op; any *other* call on a spent
//!     transaction returns `error.TransactionClosed`.
//!   * [`Cursor.close`] calls `mdb_cursor_close` for a read-only cursor and
//!     does **not** call it for a write cursor, because the owning transaction
//!     already freed that pointer and freeing it again is a double free. This
//!     holds whichever order the caller releases them in.
//!   * [`Database`] is a value; nothing in this module closes a database
//!     handle behind the caller's back. [`Environment.closeDatabase`] is the
//!     only release, and it carries upstream's restriction verbatim.
//!
//! ## Errors
//!
//! `mdb.c` returns one `int` for two families of code: its own negative
//! constants (`MDB_NOTFOUND`, `MDB_KEYEXIST`, …) and whatever the operating
//! system reported for a file, lock or memory failure. Both are mapped by
//! name into [`Error`]; nothing is collapsed into a generic failure.
//!
//! Which numbers the second family carries depends on the target, because
//! `mdb.c` decides that itself: `ErrCode()` is `errno` away from Windows
//! (mdb.c:501) and `GetLastError()` on it (mdb.c:409). A Windows build
//! therefore mixes two numeric spaces — it returns explicit C `errno`
//! constants from a few places *and* `GetLastError()` values from the Win32
//! calls — and those spaces overlap, so the two are mapped by two separate
//! tables in `check`, one per family, and a code neither names stays
//! `error.UnexpectedStatus`. The raw `c` escape hatch is the way to see it.
//!
//! ## Borrowed bytes
//!
//! `mdb_get` and `mdb_cursor_get` return pointers into the memory map, and
//! the header says exactly how long they live: "Values returned from the
//! database are valid only until a subsequent update operation, or the end of
//! the transaction" (lmdb.h:1521-1526). [`Transaction.get`] and every
//! [`Cursor`] traversal return `[]const u8` borrowed from the map, never a
//! copy. Writing through those bytes is undefined; in a read-only transaction
//! it faults.
//!
//! ## Allocation
//!
//! This module never asks Zig for memory. Every allocation behind an
//! `MDB_env`, `MDB_txn` or `MDB_cursor` belongs to the C and is released by
//! the matching C call, and every path and database name is passed to the C
//! as the sentinel-terminated slice the caller already holds.

const std = @import("std");
const builtin = @import("builtin");

/// The unmodified upstream ABI, translated from `libraries/liblmdb/lmdb.h`.
///
/// Prefer the typed wrappers above it. Reach for this when you need a call
/// this facade does not wrap — `mdb_stat`, `mdb_env_copy`, `mdb_drop`,
/// `mdb_env_set_flags` — or when you want the raw status code rather than
/// [`Error`].
pub const c = @import("c");

/// UNIX permissions for the files LMDB creates: `mode_t` on the platforms
/// that have it, `int` where upstream declares it that way (lmdb.h:180-185).
pub const Mode = c.mdb_mode_t;

/// The unsigned type upstream uses for mapsize, entry counts and page and
/// transaction IDs. It is `size_t` unless the library is built with
/// `MDB_VL32` (lmdb.h:197-204).
pub const Size = c.mdb_size_t;

/// Every failure this facade can report.
///
/// The negative codes are upstream's own, named as `lmdb.h:473-544` names
/// them. The rest are the `errno` values `mdb.c` returns unchanged, and are
/// spelled with this module's vocabulary rather than the platform's.
pub const Error = error{
    /// `MDB_KEYEXIST`. The key was already present (with `noOverwrite`), or
    /// the key/data pair was (with `putNoDupData`).
    KeyExists,
    /// `MDB_NOTFOUND`. No such key, no such duplicate value, or no such
    /// named database.
    NotFound,
    /// `MDB_PAGE_NOTFOUND`. The page a structure pointed at does not exist.
    PageNotFound,
    /// `MDB_CORRUPTED`. The environment's structures disagree with its file.
    Corrupted,
    /// `MDB_PANIC`. A fatal error occurred earlier; the environment must be
    /// closed and reopened before it can be used again.
    Panic,
    /// `MDB_VERSION_MISMATCH`. The library and the environment disagree about
    /// the on-disk format.
    VersionMismatch,
    /// `MDB_INVALID`. The environment file header is not a valid header.
    Invalid,
    /// `MDB_MAP_FULL`. The database reached the size of the memory map; see
    /// [`Environment.setMapSize`].
    MapFull,
    /// `MDB_DBS_FULL`. More named databases were opened than
    /// [`Environment.setMaxDbs`] allows.
    DbsFull,
    /// `MDB_READERS_FULL`. The reader lock table reported by
    /// [`Environment.maxReaders`] is full.
    ReadersFull,
    /// `MDB_TLS_FULL`. The thread-local reader-slot table overflowed.
    TlsFull,
    /// `MDB_TXN_FULL`. The transaction has too many dirty pages.
    TxnFull,
    /// `MDB_CURSOR_FULL`. The transaction has too many open cursors.
    CursorFull,
    /// `MDB_PAGE_FULL`. A page cannot hold the item; this is the signature of
    /// a key or duplicate value above `mdb_env_get_maxkeysize()`.
    PageFull,
    /// `MDB_MAP_RESIZED`. Another process grew the map past this handle's
    /// map size; call [`Environment.setMapSize`] with zero to adopt it.
    MapResized,
    /// `MDB_INCOMPATIBLE`. The database's flags differ from the ones it was
    /// created with.
    Incompatible,
    /// `MDB_BAD_RSLOT`. A reader lock slot was used incorrectly.
    BadRslot,
    /// `MDB_BAD_TXN`. The transaction is inconsistent.
    BadTxn,
    /// `MDB_BAD_VALSIZE`. A key (or a duplicate value) has a size the database
    /// cannot store — zero-length keys land here.
    BadValSize,
    /// `MDB_BAD_DBI`. The database handle is stale or was never opened.
    BadDbi,
    /// `MDB_PROBLEM`. An internal invariant failed. The library considers
    /// itself broken at this point.
    Problem,
    /// `MDB_BAD_CHECKSUM`. A page failed its checksum, or the environment is
    /// not checksummed.
    BadChecksum,
    /// `MDB_CRYPTO_FAIL`. The encryption callback failed.
    CryptoFail,
    /// `MDB_ENV_ENCRYPTION`. Encryption was requested of an environment that
    /// is not configured for it.
    EnvEncryption,
    /// `MDB_TXN_PENDING`. The transaction was already prepared for a
    /// two-phase commit.
    TxnPending,
    /// `MDB_CANT_ROLLBACK`. There is no committed transaction to roll back to.
    CantRollback,
    /// `MDB_DBIS_BUSY`. Database handles are still open.
    DbisBusy,
    /// `MDB_SHORT_WRITE`. A write reached the file only in part.
    ShortWrite,
    /// `MDB_ENV_BUSY`. The environment is in use by another handle.
    EnvBusy,
    /// `MDB_IS_READONLY`. The environment is read-only.
    IsReadOnly,
    /// `MDB_ADDR_BUSY`. The address LMDB wanted for a fixed map is taken.
    AddrBusy,

    /// `EACCES`, and `EPERM` on a POSIX build. A write was attempted in a
    /// read-only transaction or environment, or a file could not be opened
    /// for writing.
    AccessDenied,
    /// `EINVAL`, and `ERROR_INVALID_PARAMETER` on a Windows build. A
    /// parameter upstream rejects — including `setMaxReaders(0)`, and any
    /// setter called after the environment is open where upstream forbids
    /// it.
    InvalidArgument,
    /// `ENOMEM`, and `ERROR_NOT_ENOUGH_MEMORY` on a Windows build. The C
    /// library, or the memory-mapping call behind it, could not allocate.
    OutOfMemory,
    /// `ENOSPC`, and `ERROR_DISK_FULL` on a Windows build. The filesystem is
    /// full.
    NoSpaceLeft,
    /// `EIO`. A low-level write failed. A POSIX build only: on Windows the
    /// number `EIO` would carry is `ERROR_ACCESS_DENIED`, and saying "an I/O
    /// error" there would hide a permission failure, so a Windows build maps
    /// 5 to [`error.AccessDenied`] instead.
    InputOutput,
    /// `ENOENT`, and `ERROR_FILE_NOT_FOUND` / `ERROR_PATH_NOT_FOUND` on a
    /// Windows build. A part of the environment's path does not exist.
    NoSuchFileOrDirectory,
    /// `EAGAIN` or `EDEADLK` on a POSIX build, and `ERROR_LOCK_VIOLATION` on a
    /// Windows build. The environment is locked by another process, or its
    /// robust lock's owner died and the core has not made the lock consistent
    /// yet. Either way the caller can take the lock and try again.
    WouldBlock,
    /// `EROFS`, and `ERROR_WRITE_PROTECT` on a Windows build. The filesystem
    /// the environment lives on cannot be written. Upstream special-cases
    /// this for the lock file under `MDB_RDONLY` (mdb.c:5947, :5959-5961) and
    /// returns it unchanged for the data file.
    ReadOnlyFileSystem,
    /// `EMFILE` or `ENFILE`. The process or the system ran out of file
    /// descriptors while `mdb_env_open` was opening the environment's files —
    /// the data file through `open(2)` (mdb.c:5416-5420), or the named
    /// semaphore behind the lock on the backend that uses one
    /// (mdb.c:6146-6149). Distinct from [`error.OutOfMemory`] because
    /// freeing memory does not help.
    TooManyOpenFiles,
    /// `ERROR_SHARING_VIOLATION` (32) on a Windows build: `CreateFileW`
    /// refused the environment's data file because another process has it
    /// open without `MDB_NOLOCK` (mdb.c:5387-5389, :5414-5420). POSIX has no
    /// equivalent status — there the second writer blocks on the lock
    /// instead — so no POSIX build can report it.
    SharingViolation,

    /// The core returned a positive status that neither of the two tables in
    /// `check` names. The code is real and diagnosable through
    /// `pub const c`; it is reported distinctly rather than folded into a
    /// generic failure, and it is deliberately not reinterpreted, because the
    /// two numeric spaces a Windows build of `mdb.c` returns overlap and a
    /// guess would name the wrong condition.
    UnexpectedStatus,

    /// A method was called on an [`Environment`] whose handle has been
    /// released, or on one that was never opened where an open one is
    /// required.
    EnvironmentClosed,
    /// `Environment.open` was called on an environment that is already open.
    EnvironmentAlreadyOpen,
    /// `Environment.open` was called on a handle whose first attempt failed.
    /// Upstream guards a second open on the data-file descriptor rather than
    /// on a flag (mdb.c:6257), and `mdb_env_close_active` closes that
    /// descriptor on the failure path without clearing it (mdb.c:6508), so
    /// the handle is spent whether or not the open succeeded. Release it
    /// with [`Environment.close`] and create another; there is no retry on
    /// the same handle.
    OpenFailed,
    /// A method was called on a [`Transaction`] after `commit` or `abort`.
    TransactionClosed,
    /// A method was called on a [`Transaction`] between `reset` and `renew`.
    /// The C has released the reader lock; only `renew` and `abort` are
    /// defined until it is taken again.
    TransactionReset,
    /// `Transaction.reset` on a transaction that is not a non-nested read-only
    /// transaction, or on one that has already been reset. For the first,
    /// upstream's `mdb_txn_reset` returns silently (mdb.c:3816-3826); the
    /// facade names the mistake instead.
    TransactionNotResettable,
    /// `Transaction.renew` on a transaction that has not been reset.
    TransactionNotReset,
    /// A method was called on a [`Cursor`] after `Cursor.close`.
    CursorClosed,
    /// A key of zero length was passed. Upstream requires key sizes to be
    /// between 1 and `mdb_env_get_maxkeysize()` (lmdb.h:288-292), and reaches
    /// `MDB_BAD_VALSIZE` for one through `key->mv_size-1 >= ENV_MAXKEY(env)`
    /// (mdb.c:8605). The facade checks the condition it can name and reports
    /// it as itself; an oversized key still travels to the C and comes back
    /// as `error.BadValSize`.
    EmptyKey,
};

// ---------------------------------------------------------------- status map

/// The C library's `errno` for the target being built, taken from the target's
/// own `<errno.h>` through `std.c.E` rather than written out as numbers.
///
/// On Windows this is the CRT's POSIX-shaped table, which is *not* what
/// `mdb.c` returns there; see [`winStatus`].
const Errno = std.c.E;

/// One of the Win32 system error codes `mdb.c` can return on a Windows build.
///
/// They are written out because Zig's `std` carries no Windows error-code
/// table at this version, and translating `winerror.h` through
/// `translate.h` to obtain one constant would drag the whole SDK into every
/// build. The values are the SDK's, and have been unchanged since Windows NT.
///
/// Nothing here is named "because it looks like" an `errno`. The overlap is
/// the reason this table exists at all: `ERROR_ACCESS_DENIED` is 5 and the
/// CRT's `EIO` is also 5, so a build that read every positive code as POSIX
/// would report a permission failure as a disk error.
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

/// Translate one upstream status code into [`Error`].
///
/// `rc` is whatever `mdb.c` returned: zero for success, one of its own
/// negative constants, or a positive code from the operating system. The
/// negative constants are the same on every target; the positive ones are
/// handed to `positiveStatus`, because the numeric space they come from is
/// decided by `mdb.c` from the target rather than by this module.
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

/// Map the positive half of [`check`], which is two families rather than one.
///
/// `mdb.c`'s own `ErrCode()` is `errno` everywhere but Windows
/// (mdb.c:501) and `GetLastError()` on it (mdb.c:409), and on Windows it
/// also returns a few explicit `errno` constants of its own — `EINVAL` from
/// mdb.c:6257 and mdb.c:6275 above all. So the switch is on the target, not
/// on the code, and each arm names a value a call site in `mdb.c` can
/// actually produce. Every other positive code keeps
/// [`error.UnexpectedStatus`] rather than being reinterpreted.
fn positiveStatus(rc: c_int) Error {
    return switch (builtin.os.tag) {
        .windows => winStatus(rc),
        else => posixStatus(rc),
    };
}

/// The `errno` codes a POSIX build of `mdb.c` returns, through the target's
/// own `std.c.E` so the numbers come from its headers.
///
/// Each arm is reachable: `open(2)` at mdb.c:5416-5420 supplies the
/// permission, read-only-filesystem and not-found codes as well as the
/// descriptor-exhaustion ones; `sem_open` at mdb.c:6146-6149 on the backend
/// that uses a named semaphore adds its own; and the `fcntl` lock loops at
/// mdb.c:5791, mdb.c:5826 and mdb.c:5836 supply the busy and owner-died ones.
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

/// The Win32 codes a Windows build of `mdb.c` returns, each with the call
/// site that produces it.
///
/// `22` is the CRT's `EINVAL` and `mdb.c` returns it itself, on Windows as
/// everywhere else, when a second open hits a handle that already owns its
/// data file (mdb.c:6257) or a `MDB_FIXEDMAP` it cannot honour
/// (mdb.c:6275). It happens to share its number with `ERROR_SEEK_ON_DEVICE`,
/// which no Win32 call on the Windows path in `mdb.c` raises.
fn winStatus(rc: c_int) Error {
    return switch (rc) {
        22 => error.InvalidArgument,
        // CreateFileW in mdb_fopen (mdb.c:5414, :5419-5420) and OpenMutexA in
        // mdb_env_setup_locks (mdb.c:6140-6143).
        Win32.file_not_found => error.NoSuchFileOrDirectory,
        Win32.path_not_found => error.NoSuchFileOrDirectory,
        Win32.access_denied => error.AccessDenied,
        // VirtualAlloc behind the map (mdb.c:2876-2877) and the CreateMutex
        // shim (mdb.c:395).
        Win32.not_enough_memory => error.OutOfMemory,
        // MDB_ERRCODE_ROFS is ERROR_WRITE_PROTECT on Windows
        // (mdb.c:5945) and is compared at mdb.c:5959.
        Win32.write_protect => error.ReadOnlyFileSystem,
        Win32.sharing_violation => error.SharingViolation,
        // LockFileEx at mdb.c:5775-5776 and mdb.c:5813-5816, the Windows
        // counterpart of the fcntl loop at mdb.c:5826-5837.
        Win32.lock_violation => error.WouldBlock,
        Win32.invalid_parameter => error.InvalidArgument,
        // WriteFile (mdb.c:4232-4233) and CreateFileW.
        Win32.disk_full => error.NoSpaceLeft,
        else => error.UnexpectedStatus,
    };
}

/// `check`, for the C calls that return their result through an
/// out-parameter. A success status with nothing written is impossible for the
/// C as written, and is reported rather than assumed away.
fn checkOut(comptime T: type, rc: c_int, out: ?*T) Error!*T {
    try check(rc);
    return out orelse error.UnexpectedStatus;
}

// ------------------------------------------------------------------- values

/// One key and its data, both borrowed.
///
/// Where the bytes live depends on the call that produced the entry, and the
/// header says which:
///
///   * [`Transaction.get`], [`Cursor.first`], [`Cursor.last`],
///     [`Cursor.next`], [`Cursor.prev`], [`Cursor.nextNoDup`],
///     [`Cursor.prevNoDup`], [`Cursor.current`], [`Cursor.set`],
///     [`Cursor.setRange`], [`Cursor.nextDup`] and [`Cursor.prevDup`] return
///     both out of the memory map. They stay valid until the transaction's
///     next update operation, or until the transaction ends (lmdb.h:1521-1526,
///     :1683-1690), and must not be modified.
///   * [`Cursor.getBoth`] and [`Cursor.getBothRange`] return the value out of
///     the map but `key` is the caller's own slice handed back unchanged:
///     upstream rewrites the key only for `MDB_SET_RANGE` and `MDB_SET_KEY`
///     (mdb.c:8176-8180, :8225-8227).
///   * [`Cursor.firstDup`] and [`Cursor.lastDup`] return the value out of the
///     map. `key` is empty only when the current key carries duplicate data,
///     which is the one case where upstream writes the data and not the key
///     (mdb.c:8492); a key with a single value has upstream write the key too
///     (mdb.c:8482-8483). Read the key with [`Cursor.current`] rather than
///     inferring it from `key.len`.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Turn a caller's slice into the `MDB_val` upstream reads.
///
/// The pointer is passed through unchanged: nothing is copied and nothing is
/// allocated. `@constCast` is not a lie about the callee — upstream writes
/// through the *data* pointer when `MDB_NOOVERWRITE` finds the key already
/// present and hands back the stored item instead (lmdb.h:1559-1563), and the
/// facade exposes that as [`Transaction.putNoOverwrite`] returning
/// `error.KeyExists` with the buffer unread.
fn keyValue(key: []const u8) Error!c.MDB_val {
    if (key.len == 0) return error.EmptyKey;
    const raw: *anyopaque = @ptrCast(@constCast(key.ptr));
    return .{ .mv_size = key.len, .mv_data = raw };
}

/// Turn a caller's slice into the `MDB_val` upstream reads or writes.
///
/// Data, unlike a key, may be empty: lmdb.h:291-292 allows data items from 0
/// to `0xffffffff` bytes except where they are the duplicates of a
/// `MDB_DUPSORT` database.
fn dataValue(data: []const u8) c.MDB_val {
    const raw: *anyopaque = @ptrCast(@constCast(data.ptr));
    return .{ .mv_size = data.len, .mv_data = raw };
}

/// Borrow the bytes an `MDB_val` describes. Nothing is copied.
fn borrowed(val: c.MDB_val) []const u8 {
    if (val.mv_size == 0) return "";
    const bytes: [*]const u8 = @ptrCast(val.mv_data.?);
    return bytes[0..val.mv_size];
}

/// The upstream library version, as `mdb_version` reports it.
pub const Version = struct {
    major: c_int,
    minor: c_int,
    patch: c_int,
};

/// The version of the C this binary was linked against.
///
/// The returned C string belongs to the library and is static; this facade
/// does not expose it because rendering it needs a buffer the caller did not
/// ask for.
pub fn version() Version {
    var v: Version = undefined;
    _ = c.mdb_version(&v.major, &v.minor, &v.patch);
    return v;
}

// -------------------------------------------------------------------- flags

/// Options for `mdb_env_open`, one field per upstream flag.
///
/// Every field defaults to `false`, so `.{}` and any partial literal open an
/// environment with exactly the flags that are named. The bits themselves come
/// from `lmdb.h:348-374` through `bits`, never from a position written out by
/// hand: the constants are not contiguous, and a packed struct laid out in
/// declaration order would silently set the wrong ones.
pub const EnvFlags = struct {
    /// `MDB_FIXEDMAP`. Use a fixed address for the map. Highly experimental;
    /// must be set when the environment is created and is remembered in it.
    fixedmap: bool = false,
    /// `MDB_NOSUBDIR`. Treat the path as the data file itself instead of as a
    /// directory holding `data.mdb` and `lock.mdb`.
    nosubdir: bool = false,
    /// `MDB_RDONLY`. Open read-only. LMDB still writes the lock file, except
    /// on read-only filesystems where it does not lock at all.
    rdonly: bool = false,
    /// `MDB_WRITEMAP`. Write through the map instead of through `write(2)`.
    /// Faster while the database fits in RAM; incompatible with nested
    /// transactions.
    writemap: bool = false,
    /// `MDB_NOMETASYNC`. Flush data but not metadata on commit. Keeps
    /// atomicity and consistency; a crash may undo the last transaction.
    nometasync: bool = false,
    /// `MDB_NOSYNC`. Do not flush on commit at all.
    nosync: bool = false,
    /// `MDB_MAPASYNC`. With `writemap`, flush asynchronously.
    mapasync: bool = false,
    /// `MDB_NORDAHEAD`. Turn off OS readahead.
    nordahead: bool = false,
    /// `MDB_NOMEMINIT`. Do not zero pages taken from the heap before writing
    /// them to the file.
    nomeminit: bool = false,
    /// `MDB_NOTLS`. Tie reader slots to transactions instead of to threads,
    /// which lets a reader transaction span threads.
    notls: bool = false,
    /// `MDB_NOLOCK`. Take no locks at all; the caller serializes.
    nolock: bool = false,
    /// `MDB_PREVSNAPSHOT`. Open the snapshot before the last transaction.
    prevsnapshot: bool = false,
    /// `MDB_REMAP_CHUNKS`. Map the file a chunk at a time instead of whole.
    remap_chunks: bool = false,

    /// The `unsigned int` `mdb_env_open` takes.
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

/// Options for `mdb_dbi_open`, one field per upstream flag.
///
/// The bits come from `lmdb.h:381-395` through `bits`; see [`EnvFlags`] for
/// why they are not a packed struct.
pub const DbFlags = struct {
    /// `MDB_REVERSEKEY`. Compare keys from their last byte backwards.
    reversekey: bool = false,
    /// `MDB_DUPSORT`. A key may have several data items, kept in sorted
    /// order.
    dupsort: bool = false,
    /// `MDB_INTEGERKEY`. Keys are machine integers in native byte order and
    /// sort as such; they must all be the same size.
    integerkey: bool = false,
    /// `MDB_DUPFIXED`. With `dupsort`, every data item is the same size.
    dupfixed: bool = false,
    /// `MDB_INTEGERDUP`. Duplicate values are machine integers.
    integerdup: bool = false,
    /// `MDB_REVERSEDUP`. Duplicate values compare as reversed strings.
    reversedup: bool = false,
    /// `MDB_CREATE`. Create the named database if it is not there. Refused in
    /// a read-only transaction or environment.
    create: bool = false,

    /// The `unsigned int` `mdb_dbi_open` takes.
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

/// The `mdb_cursor_get` operations, named as `lmdb.h:436-465` names them.
///
/// Page-at-a-time operations for `MDB_DUPFIXED` databases (`MDB_GET_MULTIPLE`
/// and friends) are deliberately absent: they return a *count of items* in
/// the data value rather than bytes, which a `[]const u8` cannot represent
/// without lying. Use `pub const c` for those.
///
/// The tag type is the translated `MDB_cursor_op` itself rather than a width
/// written down here, because that type is a property of the target and not of
/// this header. `translate-c` gives a C enum the integer type the target's own
/// ABI gives it: `c_uint` where the target's C ABI gives every enum its full
/// width, and `u8` on hexagon, whose C ABI permits enums as narrow as their
/// enumerators need.
/// `lmdb.h:436-465` numbers nineteen of them 0..18 and promises nothing
/// about the width, so the tag type is read back out of the translation rather
/// than guessed at. Spelling `c_uint` typechecked on x86_64 and failed on
/// hexagon with "expected type 'u8', found 'c_uint'" at the `mdb_cursor_get`
/// call below, which is the facade asserting a width the header never
/// promised. The values below are this header's own enumerators, and `seek`
/// converts back at the C call.
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
    /// Position at the given key and return it out of the map. This is what
    /// [`Cursor.set`] uses: upstream's plain `MDB_SET` leaves the caller's key
    /// object untouched (lmdb.h:1686-1688), so the facade never asks for it.
    set_key = @intCast(c.MDB_SET_KEY),
    /// Position at the first key at or after the given key.
    set_range = @intCast(c.MDB_SET_RANGE),
};

// -------------------------------------------------------------- environment

/// Options for [`Environment.init`].
///
/// The `null` defaults mean "leave upstream's own default alone": the facade
/// never calls the corresponding setter, so the value the library chose for
/// itself survives. A non-null value is passed through unchanged.
pub const OpenOptions = struct {
    /// The directory the database lives in, or the data file itself when
    /// `flags.nosubdir` is set. Passed to the C as this exact sentinel-
    /// terminated slice; nothing is copied and nothing is allocated.
    path: [:0]const u8,
    /// Flags for the open.
    flags: EnvFlags = .{},
    /// Permissions for files LMDB creates. Upstream applies no default of its
    /// own — `mode` reaches `open(2)` as given (mdb.c:5416) — so the facade
    /// supplies the one upstream's own tools pass, `0664` (mdb_stat.c:138,
    /// mdb_dump.c:282, mdb_load.c:421, mdb_drop.c:120). Subject to the
    /// process umask.
    ///
    /// Ignored on Windows, as upstream ignores it (lmdb.h:716-717).
    mode: Mode = 0o664,
    /// Size of the memory map, and therefore the maximum size of the
    /// database. `null` leaves upstream's default.
    map_size: ?Size = null,
    /// Number of *named* databases. `mdb_env_set_maxdbs` adds the two
    /// upstream reserves internally, `env->me_maxdbs = dbs + CORE_DBS`
    /// (mdb.c:1053-1059). `null` leaves upstream's default, which is those
    /// two reserved databases and room for no name at all (mdb.c:5028).
    ///
    /// Upstream holds this in the handle rather than in the environment
    /// file, so every open of the same directory has to set it again: a
    /// reopen that does not refuses each named open with `MDB_DBS_FULL`.
    max_dbs: ?u32 = null,
    /// Reader lock-table slots. `null` leaves upstream's default.
    max_readers: ?u32 = null,
};

/// An LMDB environment: one directory or file, one lock table, one map.
///
/// The handle is not thread-safe to create or destroy; see lmdb.h:892-897.
/// Use one `Environment` per process, or per thread when they never share a
/// transaction.
pub const Environment = struct {
    handle: ?*c.MDB_env,
    /// Whether `mdb_env_open` has succeeded on this handle. Only a success
    /// makes the handle usable; see `open_attempted` for why that is not the
    /// whole story.
    opened: bool,
    /// Whether `mdb_env_open` has been entered on this handle, whatever it
    /// returned. Upstream's own guard against a second open is the data-file
    /// descriptor, not a flag (mdb.c:6257), and `mdb_env_close_active` closes
    /// that descriptor on the failure path without resetting it (mdb.c:6508);
    /// `me_fd` goes back to `INVALID_HANDLE_VALUE` in exactly one place,
    /// `mdb_env_create` at mdb.c:5029. So a failed open has spent the handle
    /// just as thoroughly as a successful one, and this records that
    /// conservatively instead of leaving the caller free to retry into
    /// upstream's `EINVAL`.
    open_attempted: bool,

    /// Create an unopened environment.
    ///
    /// Nothing but the handle exists yet; `open` is what maps the file. Use
    /// this when configuration must happen between the two, and `init` when
    /// it does not.
    ///
    /// The allocation is the C's (`calloc` in `mdb_env_create`), not Zig's.
    pub fn create() Error!Environment {
        var out: ?*c.MDB_env = null;
        const handle = try checkOut(c.MDB_env, c.mdb_env_create(&out), out);
        return .{ .handle = handle, .opened = false, .open_attempted = false };
    }

    /// Create, configure and open an environment in one call.
    ///
    /// The setters run in the order upstream's documentation pairs them:
    /// database and reader limits, which `mdb_env_open` freezes, then the map
    /// size, which may also be changed later. If the open fails the handle is
    /// released, as lmdb.h:602-604 requires.
    pub fn init(options: OpenOptions) Error!Environment {
        var env = try create();
        errdefer env.close();
        if (options.max_dbs) |count| try env.setMaxDbs(count);
        if (options.max_readers) |count| try env.setMaxReaders(count);
        if (options.map_size) |bytes| try env.setMapSize(bytes);
        try env.open(options.path, options.flags, options.mode);
        return env;
    }

    /// Open an environment created by `create`.
    ///
    /// `path` is the sentinel-terminated slice as given; it is not copied and
    /// not converted. On failure the handle is still valid and must be
    /// released with `close` (lmdb.h:602-604), and it cannot be opened again:
    /// see below.
    ///
    /// This handle may be opened once. Upstream refuses a second open with
    /// `EINVAL` because the handle already owns a file descriptor
    /// (mdb.c:6257), and a *failed* open has already given it one —
    /// `mdb_env_close_active` closes the data file on the failure path
    /// (mdb.c:6508) without returning `me_fd` to `INVALID_HANDLE_VALUE`,
    /// which only `mdb_env_create` does (mdb.c:5029). The facade therefore
    /// records the attempt, not the success: a second `open` on a handle
    /// whose first attempt succeeded is `error.EnvironmentAlreadyOpen`, and
    /// on one whose first attempt failed it is `error.OpenFailed`, so a
    /// caller learns which happened rather than being told its argument is
    /// invalid by the stale descriptor its own previous call left behind.
    /// Release the handle with `close` and create another.
    pub fn open(self: *Environment, path: [:0]const u8, flags: EnvFlags, mode: Mode) Error!void {
        if (self.opened) return error.EnvironmentAlreadyOpen;
        if (self.open_attempted) return error.OpenFailed;
        const handle = try self.pending();
        // Set before the call, not after: on the failure path this handle is
        // spent even though nothing below knows it yet.
        self.open_attempted = true;
        try check(c.mdb_env_open(handle, path.ptr, flags.bits(), mode));
        self.opened = true;
    }

    /// Release the environment and everything under it.
    ///
    /// Upstream requires that every transaction, database handle and cursor
    /// is already closed (lmdb.h:892-897). Idempotent: closing a released or
    /// never-opened environment does nothing, which is what makes an
    /// `errdefer env.close()` safe next to a successful open, and it is the
    /// way out of a handle whose `open` failed: the handle is freed, so the
    /// next environment is a new one rather than this one.
    pub fn close(self: *Environment) void {
        const handle = self.handle orelse return;
        self.handle = null;
        self.opened = false;
        self.open_attempted = false;
        c.mdb_env_close(handle);
    }

    /// Set the size of the memory map, and so the maximum size of the
    /// database.
    ///
    /// Zero adopts the size another process persisted, which is the
    /// documented answer to `error.MapResized` (lmdb.h:976-979). Must be
    /// called before `open`, or afterwards only when no write transaction is
    /// live in this process — a condition upstream does not check and this
    /// facade does not invent; the C reports `EINVAL` when it notices
    /// (mdb.c:5178-5185).
    pub fn setMapSize(self: *Environment, bytes: Size) Error!void {
        try check(c.mdb_env_set_mapsize(try self.pending(), bytes));
    }

    /// Set how many *named* databases may be opened. Upstream reserves two
    /// further slots internally (mdb.c:1053-1059). Refused once the
    /// environment is open.
    pub fn setMaxDbs(self: *Environment, count: u32) Error!void {
        try check(c.mdb_env_set_maxdbs(try self.pending(), @intCast(count)));
    }

    /// Set how many reader lock-table slots exist. Refused once the
    /// environment is open, and refused for zero (mdb.c:1021-1030).
    pub fn setMaxReaders(self: *Environment, count: u32) Error!void {
        try check(c.mdb_env_set_maxreaders(try self.pending(), @intCast(count)));
    }

    /// The number of reader lock-table slots this environment actually has.
    ///
    /// Reads the field the environment was built with, so it answers "did the
    /// setting take" rather than "was a setter called".
    pub fn maxReaders(self: *Environment) Error!u32 {
        var readers: c_uint = 0;
        try check(c.mdb_env_get_maxreaders(try self.pending(), &readers));
        return @intCast(readers);
    }

    /// Flush the data buffers to disk.
    ///
    /// `force` flushes even when no write transaction asked for it, which is
    /// what makes `MDB_NOSYNC` and `MDB_MAPASYNC` recoverable: the flags
    /// defer the flush, this call performs it.
    pub fn sync(self: *Environment, force: bool) Error!void {
        try check(c.mdb_env_sync(try self.openHandle(), if (force) 1 else 0));
    }

    /// Return a database handle's slot to the environment.
    ///
    /// Upstream's warning, verbatim in effect (lmdb.h:1403-1418): this is not
    /// mutex protected, no other thread may still reference the handle or any
    /// of its cursors, and a handle whose database an existing transaction has
    /// modified must not be closed at all. Closing is never required; it only
    /// lets `openDatabase` reuse the slot.
    ///
    /// Nothing in this module closes a database handle implicitly, so a
    /// `Database` stays valid for the life of the environment unless the
    /// caller asks for this.
    pub fn closeDatabase(self: *Environment, db: Database) void {
        const handle = self.handle orelse return;
        c.mdb_dbi_close(handle, db.dbi);
    }

    /// Begin a read-only transaction, which sees the last committed snapshot.
    ///
    /// Several read-only transactions may be live at once, but a read-only
    /// transaction holds the pages its snapshot needs; keeping one open for a
    /// long time makes the database grow (lmdb.h:1278-1281).
    pub fn beginReadOnly(self: *Environment) Error!Transaction {
        return self.begin(true);
    }

    /// Begin a read-write transaction. Only one may be live per environment.
    pub fn beginWrite(self: *Environment) Error!Transaction {
        return self.begin(false);
    }

    fn begin(self: *Environment, read_only: bool) Error!Transaction {
        const handle = try self.openHandle();
        var out: ?*c.MDB_txn = null;
        const flags: c_uint = if (read_only) @intCast(c.MDB_RDONLY) else 0;
        const txn = try checkOut(c.MDB_txn, c.mdb_txn_begin(handle, null, flags, &out), out);
        return .{
            .handle = txn,
            .env = self,
            .read_only = read_only,
            .nested = false,
            .suspended = false,
        };
    }

    /// The handle of an environment that exists but need not be open.
    fn pending(self: *Environment) Error!*c.MDB_env {
        return self.handle orelse error.EnvironmentClosed;
    }

    /// The handle of an environment that must be open, because the call about
    /// to be made dereferences the map.
    fn openHandle(self: *Environment) Error!*c.MDB_env {
        const handle = try self.pending();
        if (!self.opened) return error.EnvironmentClosed;
        return handle;
    }
};

// -------------------------------------------------------------- transaction

/// A transaction: the unit of isolation, and the lifetime that everything
/// borrowed from the database is bound to.
///
/// Owns its `MDB_txn`. `commit` and `abort` both release it, and both are
/// safe to reach more than once, so the ordinary
/// `defer txn.abort(); …; try txn.commit();` shape does not double free.
///
/// A transaction and its cursors belong to one thread (lmdb.h:1124-1127).
pub const Transaction = struct {
    handle: ?*c.MDB_txn,
    /// The environment this transaction was begun on. Borrowed: it must
    /// outlive the transaction, and closing it first is what upstream forbids
    /// at lmdb.h:892-897.
    env: *Environment,
    /// Whether this is a read-only transaction. Read from the request rather
    /// than from the handle, because it decides cursor ownership — see
    /// [`Cursor.close`] — and stays meaningful after the handle is released.
    read_only: bool,
    /// Whether this is a nested transaction. A nested transaction's cursors
    /// are merged into its parent, not freed away from it.
    nested: bool,
    /// Set between `reset` and `renew`, while the C has released the reader
    /// lock and no data operation is valid.
    suspended: bool,

    /// Begin a nested transaction inside this one.
    ///
    /// While a child is live the parent may do nothing but commit or abort it
    /// (lmdb.h:1129-1137). A child's writes become the parent's when the
    /// child commits, and vanish with it when the child aborts.
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
        };
    }

    /// Open a database in this transaction.
    ///
    /// `name` is `null` for the one unnamed database an environment always
    /// has, or a sentinel-terminated name, passed to the C unchanged. A named
    /// database needs `OpenOptions.max_dbs` to have been set before this
    /// environment was opened; until a slot is free upstream answers
    /// `MDB_DBS_FULL`, which arrives here as `error.DbsFull`
    /// (mdb.c:12316-12318, lmdb.h:1326-1327 and :1374-1375).
    ///
    /// The handle is private to this transaction until it commits; if the
    /// transaction aborts, upstream closes it automatically (lmdb.h:1315-1319).
    /// Upstream also forbids calling this from two concurrent transactions in
    /// one process: a transaction that opens a database must finish before
    /// another may (lmdb.h:1321-1324).
    pub fn openDatabase(self: *Transaction, name: ?[:0]const u8, flags: DbFlags) Error!Database {
        const handle = try self.active();
        var dbi: c.MDB_dbi = 0;
        const name_ptr: [*c]const u8 = if (name) |n| n.ptr else null;
        try check(c.mdb_dbi_open(handle, name_ptr, flags.bits(), &dbi));
        return .{ .dbi = dbi };
    }

    /// Store `value` under `key`, replacing whatever was there.
    ///
    /// The bytes are copied into the database during this call, so `key` and
    /// `value` need not outlive it. In a `DUPSORT` database this *adds* a
    /// duplicate rather than replacing one (lmdb.h:1541-1545).
    pub fn put(self: *Transaction, db: Database, key: []const u8, value: []const u8) Error!void {
        return self.store(db, key, value, 0);
    }

    /// Store under `key` only if the key is absent.
    ///
    /// Returns `error.KeyExists` when it is present, even in a `DUPSORT`
    /// database. Upstream then rewrites the caller's data value to point at
    /// the stored item (lmdb.h:1559-1563); the facade reports the error
    /// instead of exposing that pointer, because the buffer it would write to
    /// belongs to the caller and the bytes it would name are borrowed.
    pub fn putNoOverwrite(self: *Transaction, db: Database, key: []const u8, value: []const u8) Error!void {
        return self.store(db, key, value, c.MDB_NOOVERWRITE);
    }

    /// Store a duplicate only if the key/data pair is absent.
    ///
    /// Only valid on a `DUPSORT` database; upstream otherwise returns
    /// `EINVAL`. Returns `error.KeyExists` when the pair is already there.
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

    /// Read the value stored under `key`.
    ///
    /// The returned bytes are borrowed from the map, not copied. They stay
    /// valid until this transaction's next update operation or until it ends
    /// (lmdb.h:1521-1526). In a `DUPSORT` database this is the first data item
    /// for the key; the rest need a cursor (lmdb.h:1517-1519).
    pub fn get(self: *Transaction, db: Database, key: []const u8) Error![]const u8 {
        const handle = try self.active();
        var k = try keyValue(key);
        var v: c.MDB_val = undefined;
        try check(c.mdb_get(handle, db.dbi, &k, &v));
        return borrowed(v);
    }

    /// Delete `key` and, in a `DUPSORT` database, every duplicate under it.
    ///
    /// Returns `error.NotFound` when the key is absent (lmdb.h:1599-1600).
    pub fn delete(self: *Transaction, db: Database, key: []const u8) Error!void {
        const handle = try self.active();
        var k = try keyValue(key);
        try check(c.mdb_del(handle, db.dbi, &k, null));
    }

    /// Delete one duplicate value.
    ///
    /// Returns `error.NotFound` when the pair is absent. Use [`delete`] to
    /// remove the key and all of its duplicates. On a database opened without
    /// `DUPSORT` upstream forces the data argument to null and deletes the
    /// key (mdb.c:10622-10625), so this is the same operation as [`delete`]
    /// there.
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

    /// Open a cursor over `db` inside this transaction.
    ///
    /// The cursor borrows `self` and must not outlive it. How it is released
    /// depends on the kind of transaction; see [`Cursor.close`].
    pub fn openCursor(self: *Transaction, db: Database) Error!Cursor {
        const handle = try self.active();
        var out: ?*c.MDB_cursor = null;
        const cursor = try checkOut(c.MDB_cursor, c.mdb_cursor_open(handle, db.dbi, &out), out);
        return .{ .handle = cursor, .owner = self, .read_only = self.read_only };
    }

    /// Commit everything this transaction did, and release it.
    ///
    /// The handle is released whether this succeeds or fails: upstream frees
    /// it on the success path and aborts it on every failure path
    /// (mdb.c:4383-4637). The handle is cleared before the call, so a
    /// `defer`red [`abort`] that runs afterwards does nothing.
    ///
    /// In a `DUPSORT` database nothing here is atomic per pair — the whole
    /// transaction is.
    pub fn commit(self: *Transaction) Error!void {
        try check(c.mdb_txn_commit(try self.take()));
    }

    /// Abandon everything this transaction did, and release it.
    ///
    /// Nothing is written; a later reader sees the last committed state. Safe
    /// after `commit`, and safe twice: with no handle left there is nothing to
    /// abandon.
    pub fn abort(self: *Transaction) void {
        const handle = self.handle orelse return;
        self.handle = null;
        self.suspended = false;
        c.mdb_txn_abort(handle);
    }

    /// Release this read-only transaction's snapshot but keep the handle, so
    /// that [`renew`] can take a fresh one without another allocation.
    ///
    /// Only a non-nested read-only transaction can be reset; for anything
    /// else upstream's `mdb_txn_reset` returns silently (mdb.c:3816-3826) and
    /// this facade returns `error.TransactionNotResettable`. That error also
    /// covers a second reset of the same transaction. Between reset and renew
    /// no data operation is valid, and the facade says so rather than letting
    /// the C reach a finished transaction.
    ///
    /// Releasing the snapshot is the point: it lets writers reuse the pages
    /// this reader was pinning (lmdb.h:1278-1281).
    pub fn reset(self: *Transaction) Error!void {
        const handle = self.handle orelse return error.TransactionClosed;
        if (self.suspended) return error.TransactionNotResettable;
        if (!self.read_only or self.nested) return error.TransactionNotResettable;
        c.mdb_txn_reset(handle);
        self.suspended = true;
    }

    /// Take a new snapshot with a handle that [`reset`] released.
    ///
    /// The new snapshot is the newest committed state at this moment, not the
    /// one the transaction had before.
    pub fn renew(self: *Transaction) Error!void {
        const handle = self.handle orelse return error.TransactionClosed;
        if (!self.suspended) return error.TransactionNotReset;
        try check(c.mdb_txn_renew(handle));
        self.suspended = false;
    }

    /// A live `MDB_txn` for a data operation, or the reason there is none.
    fn active(self: *Transaction) Error!*c.MDB_txn {
        const handle = self.handle orelse return error.TransactionClosed;
        if (self.suspended) return error.TransactionReset;
        return handle;
    }

    /// Take the handle away, so that whichever C call frees it cannot be
    /// reached twice through this transaction.
    fn take(self: *Transaction) Error!*c.MDB_txn {
        const handle = try self.active();
        self.handle = null;
        return handle;
    }
};

// ----------------------------------------------------------------- database

/// A handle for one database in an environment.
///
/// This is a value, an index into the environment's slot table, and stays
/// valid for the life of the environment. It is deliberately not a resource
/// with a `deinit`: upstream frees the slot only in
/// [`Environment.closeDatabase`], and only when no live transaction has
/// modified that database (lmdb.h:1403-1418).
pub const Database = struct {
    dbi: c.MDB_dbi,
};

// ------------------------------------------------------------------- cursor

/// A cursor over one database inside one transaction.
///
/// Owns its `MDB_cursor`. Which side releases it is decided by the kind of
/// transaction that made it, and the rule comes straight out of lmdb.h:
///
///   * A cursor in a **read-only** transaction is never freed by the
///     transaction, and "must be closed explicitly, before or after its
///     transaction ends" (lmdb.h:1622-1624). [`close`] does exactly that, and
///     is safe whichever order the cursor and the transaction are released
///     in.
///   * A cursor in a **write** transaction "can be closed before its
///     transaction ends, and will otherwise be closed when its transaction
///     ends" (lmdb.h:1620-1621). The C frees it on the commit path
///     (mdb.c:4557) and on the abort path (mdb.c:3737-3738), and a nested
///     transaction's cursors are merged into its parent instead
///     (mdb.c:4439). [`close`] therefore does not call `mdb_cursor_close` for
///     one: the transaction owns that pointer, and freeing it here would be a
///     double free.
///
/// The bytes every traversal returns are borrowed from the memory map and are
/// valid until the transaction's next update operation or the end of the
/// transaction (lmdb.h:1521-1526, :1683-1690). Nothing is copied.
///
/// One place this facade is deliberately stricter than upstream: a cursor
/// opened in a nested transaction is refused once that transaction ends, even
/// though the C hands it to the parent instead of freeing it
/// (mdb.c:4439-4444). Open a cursor in the transaction you intend to keep
/// using, or reopen it there.
pub const Cursor = struct {
    handle: ?*c.MDB_cursor,
    /// The transaction this cursor was opened in. Borrowed, and must not be
    /// moved or reassigned while the cursor is live: every traversal reads it
    /// to tell a live transaction from a spent one. A cursor may not span
    /// transactions (lmdb.h:1127).
    owner: *Transaction,
    /// Whether `owner` is a read-only transaction, captured when the cursor
    /// was opened.
    ///
    /// Recorded rather than re-read, because the header lets a read-only
    /// cursor outlive its transaction and be closed "before or after" it
    /// ends (lmdb.h:1622-1624): by then `owner` may itself be out of scope,
    /// and `close` must still be safe. It is the only field `close` consults.
    read_only: bool,

    /// Release this cursor.
    ///
    /// Read-only transaction: calls `mdb_cursor_close`, as the header
    /// requires, and does so safely even if the transaction already ended —
    /// a read-only transaction never frees its cursors, and `mdb_cursor_close`
    /// does not look inside one (mdb.c:9788-9792).
    ///
    /// Write transaction: leaves the pointer to the transaction, which frees
    /// it when it commits or aborts. Either way the cursor is spent
    /// afterwards.
    ///
    /// A second `close` does nothing; any traversal after it returns
    /// `error.CursorClosed`.
    pub fn close(self: *Cursor) void {
        const handle = self.handle orelse return;
        self.handle = null;
        if (self.read_only) c.mdb_cursor_close(handle);
    }

    /// Position at the first key/data item.
    pub fn first(self: *Cursor) Error!Entry {
        return self.seek(.first, null, null);
    }

    /// Position at the last key/data item. Since a `DUPSORT` database keeps
    /// duplicates sorted, this is the greatest key and its greatest value.
    pub fn last(self: *Cursor) Error!Entry {
        return self.seek(.last, null, null);
    }

    /// Position at the next data item, crossing into the next key when the
    /// current key has no more duplicates.
    ///
    /// On a cursor that has not been positioned yet this is the first item,
    /// not an error: upstream falls back to `mdb_cursor_first`
    /// (mdb.c:7873-7874).
    pub fn next(self: *Cursor) Error!Entry {
        return self.seek(.next, null, null);
    }

    /// Position at the previous data item.
    ///
    /// On a cursor that has not been positioned yet this is the *last* item,
    /// not an error: upstream falls back to `mdb_cursor_last` and then steps
    /// back onto it (mdb.c:7958-7963).
    pub fn prev(self: *Cursor) Error!Entry {
        return self.seek(.prev, null, null);
    }

    /// Position at the first data item of the next key, skipping the current
    /// key's remaining duplicates.
    pub fn nextNoDup(self: *Cursor) Error!Entry {
        return self.seek(.next_nodup, null, null);
    }

    /// Position at the last data item of the previous key.
    pub fn prevNoDup(self: *Cursor) Error!Entry {
        return self.seek(.prev_nodup, null, null);
    }

    /// Return the key/data pair the cursor is on, without moving it.
    ///
    /// A cursor that has not been positioned refuses this with `EINVAL`, which
    /// arrives as `error.InvalidArgument` — not `error.NotFound`
    /// (mdb.c:8341-8343). Once the cursor has run off the end it reports the
    /// last item it was on.
    pub fn current(self: *Cursor) Error!Entry {
        return self.seek(.get_current, null, null);
    }

    /// Position at `key` exactly, and return that key and its first value.
    ///
    /// `MDB_SET_KEY` rather than `MDB_SET`, so the key that comes back is the
    /// stored one; with `MDB_SET` upstream leaves the key argument untouched
    /// (lmdb.h:1686-1688) and a caller comparing bytes would be comparing its
    /// own copy.
    ///
    /// Returns `error.NotFound` when the key is absent.
    pub fn set(self: *Cursor, key: []const u8) Error!Entry {
        return self.seek(.set_key, key, null);
    }

    /// Position at the first key at or after `key`.
    ///
    /// The returned key is the stored one, which may differ from `key`.
    /// Returns `error.NotFound` when no key is that large.
    pub fn setRange(self: *Cursor, key: []const u8) Error!Entry {
        return self.seek(.set_range, key, null);
    }

    /// Position at the current key's first duplicate value. `DUPSORT` only.
    ///
    /// The cursor must already be on a key — on a cursor that has never been
    /// positioned this is `EINVAL`, and on a database without duplicates it is
    /// `MDB_INCOMPATIBLE` (mdb.c:8467-8474). `key` comes back empty when the
    /// key carries duplicate data, because upstream then writes the data and
    /// not the key (mdb.c:8492); for a key with a single value upstream writes
    /// the key as well (mdb.c:8482-8483). Read it with [`current`] in either
    /// case rather than relying on `key.len`.
    pub fn firstDup(self: *Cursor) Error!Entry {
        return self.seek(.first_dup, null, null);
    }

    /// Position at the current key's last duplicate value. `DUPSORT` only,
    /// with the same requirements and the same `key` provenance as
    /// [`firstDup`].
    pub fn lastDup(self: *Cursor) Error!Entry {
        return self.seek(.last_dup, null, null);
    }

    /// Position at the current key's next duplicate value.
    ///
    /// Returns `error.NotFound` at the end of the duplicate list, which is
    /// how a walk over one key's values terminates without touching the next
    /// key. `DUPSORT` only.
    pub fn nextDup(self: *Cursor) Error!Entry {
        return self.seek(.next_dup, null, null);
    }

    /// Position at the current key's previous duplicate value. `DUPSORT` only.
    pub fn prevDup(self: *Cursor) Error!Entry {
        return self.seek(.prev_dup, null, null);
    }

    /// Position at the exact `key`/`value` pair. `DUPSORT` only.
    ///
    /// `Entry.key` here is `key` itself handed back, not bytes out of the map:
    /// upstream rewrites the key only for `MDB_SET_RANGE` and `MDB_SET_KEY`
    /// (mdb.c:8176-8180 and :8225-8227). The bytes match either way; their
    /// lifetime is the caller's slice's.
    pub fn getBoth(self: *Cursor, key: []const u8, value: []const u8) Error!Entry {
        return self.seek(.get_both, key, value);
    }

    /// Position at `key` and the least value at or after `value`.
    /// `DUPSORT` only, with the same provenance for `Entry.key` as
    /// [`getBoth`].
    pub fn getBothRange(self: *Cursor, key: []const u8, value: []const u8) Error!Entry {
        return self.seek(.get_both_range, key, value);
    }

    /// Replace the value under the cursor's current key.
    ///
    /// The key must still be supplied and must match the one the cursor is
    /// on. In a `DUPSORT` database the new value must still sort into the
    /// same place, and upstream turns the operation into a delete and insert
    /// when the size changes (lmdb.h:1717-1722).
    pub fn putCurrent(self: *Cursor, key: []const u8, value: []const u8) Error!void {
        const handle = try self.live();
        var k = try keyValue(key);
        var v = dataValue(value);
        try check(c.mdb_cursor_put(handle, &k, &v, @intCast(c.MDB_CURRENT)));
    }

    /// Delete the pair the cursor is on.
    ///
    /// The cursor stays usable, and the next traversal continues from where
    /// it was rather than from the deleted item (lmdb.h:1767-1773). A cursor
    /// that has never been positioned refuses this with `EINVAL`
    /// (mdb.c:9123-9124); one that has run off the end is still on the item it
    /// reached, so this deletes that.
    pub fn deleteCurrent(self: *Cursor) Error!void {
        try check(c.mdb_cursor_del(try self.live(), 0));
    }

    /// Delete every duplicate of the cursor's current key. `DUPSORT` only.
    pub fn deleteAllDuplicates(self: *Cursor) Error!void {
        try check(c.mdb_cursor_del(try self.live(), @intCast(c.MDB_NODUPDATA)));
    }

    /// How many duplicate values the cursor's current key has.
    ///
    /// Requires a `DUPSORT` database — upstream allocates the duplicate
    /// sub-cursor only for one (mdb.c:9707-9708) and returns
    /// `MDB_INCOMPATIBLE` without it, which surfaces here as
    /// `error.Incompatible`. The cursor must also be on a key: an unpositioned
    /// cursor is `EINVAL`, and an exhausted one is `MDB_NOTFOUND`
    /// (mdb.c:9744-9766).
    pub fn count(self: *Cursor) Error!Size {
        var n: c.mdb_size_t = 0;
        try check(c.mdb_cursor_count(try self.live(), &n));
        return n;
    }

    /// Run one `mdb_cursor_get`, with the two optional inputs a cursor
    /// operation may need.
    ///
    /// `key_in` is the search key for the operations that take one, and is
    /// consumed as input; `value_in` only for `MDB_GET_BOTH` and
    /// `MDB_GET_BOTH_RANGE`. Both outputs are written by the C into the two
    /// stack `MDB_val`s, and borrowed from there.
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

    /// A live `MDB_cursor` whose transaction can still be used.
    fn live(self: *Cursor) Error!*c.MDB_cursor {
        _ = try self.owner.active();
        return self.handle orelse error.CursorClosed;
    }
};

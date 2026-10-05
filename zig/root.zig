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
//! ## Two configurations, one API
//!
//! This module is built in one of two shapes, and [`runtime_loaded`] says
//! which at comptime.
//!
//! *Linked* is the default. liblmdb is linked, `c` is the translated header
//! itself, and every call below reaches the C directly. Nothing here costs a
//! branch, a table lookup or a load check.
//!
//! *Runtime-loaded* is the `-Druntime=true` configuration. `c` is a dispatch
//! generated from that same translation, so every type and constant is the
//! translated one and no call needs a cast; what changes is how a name reaches
//! the library. A call becomes a call through a table that [`load`] fills, and
//! a call before that fill stops the program with a message naming the
//! function — in every optimization mode, because reaching an unfilled table
//! is a programming error and not a condition to recover from.
//!
//! In a linked build [`load`] is a panic that says so and
//! [`loadedSource`] answers `null`; in a runtime-loaded build the module is
//! unusable until [`load`] succeeds. Everything else in this file — the four
//! handles, the error set, the borrowed slices, the flag words — is identical
//! in both, and neither configuration has an API view, an owning library object
//! or an unload.
//!
//! ## The external ABI family a provider has to belong to
//!
//! The complete record is `runtime/library.zig`, next to the table it
//! describes; the parts that decide whether a caller may swap one liblmdb for
//! another are these.
//!
//!   * The calling convention and the scalar widths. Every status is an `int`;
//!     `MDB_dbi` is `unsigned int`; [`Size`] is `size_t` because `MDB_VL32` is
//!     not defined (lmdb.h:197-203); [`Mode`] is `mode_t` on the targets this
//!     package compiles and `int` under MSVC (lmdb.h:180-184).
//!   * The complete layouts that cross the boundary: `MDB_val`
//!     (`{ size_t; void * }`, lmdb.h:293-296) for every key and datum,
//!     `MDB_stat` (lmdb.h:548-556), `MDB_envinfo` (lmdb.h:559-566) and
//!     `MDB_crypto_funcs` (lmdb.h:1873-1880). `MDB_env`, `MDB_txn` and
//!     `MDB_cursor` are opaque (lmdb.h:267, :274, :280), so their internal
//!     layout is *not* part of the boundary — only the pointers are.
//!   * The C enum width of `MDB_cursor_op` (lmdb.h:436-465), which is the
//!     target ABI's choice rather than the header's, and which
//!     [`CursorOp`] reads back out of the translation instead of guessing.
//!   * The per-target configuration macros in the build graph —
//!     `MDB_USE_POSIX_MUTEX` and `MDB_USE_ROBUST` on Linux,
//!     `MDB_USE_POSIX_SEM` on macOS, nothing forced on Windows or the BSDs,
//!     and nothing for `MDB_VL32`, `MDB_RPAGE_CACHE` or `MDB_ENCRYPT`. They
//!     choose between lock implementations and between sets of exported entry
//!     points; they do not change a prototype.
//!   * The allocator. Every allocation behind the three opaque handles is the
//!     provider's, from `calloc` in `mdb_env_create` (mdb.c:5028) to the free
//!     in `mdb_env_close`, and this module never mixes it with Zig's. The one
//!     place caller memory crosses into C is the other direction: a
//!     comparator, checksum, encryption, relocation, assert or message callback
//!     is the caller's own function and the `void *` context is whatever the
//!     caller put there.
//!
//! There are no variadic entry points in this header. Every prototype in
//! `lmdb.h` is fixed-arity, so every call through a provider uses an ordinary
//! typed call and none needs a tuple.
//!
//! ## The four handles and who frees them
//!
//! Upstream's contract, read out of `lmdb.h` and `mdb.c` rather than assumed:
//!
//!   * `MDB_env` is created by `mdb_env_create` and released by
//!     `mdb_env_close` (lmdb.h:589-600, :892-900). It is the only handle with
//!     no parent.
//!   * `MDB_txn` is created by `mdb_txn_begin` and spent by **either**
//!     `mdb_txn_commit` or `mdb_txn_abort` (lmdb.h:1121-1163, :1190-1206,
//!     :1257-1265). Commit spends it on success and failure alike. The core
//!     may recycle a top-level write allocation; that does not keep the
//!     caller's transaction usable (mdb.c:3758, :4629-4635).
//!   * `MDB_dbi` is a `unsigned int` index into the environment's slot table,
//!     not a pointer (lmdb.h:276-277). It needs no release; `mdb_dbi_close`
//!     only returns the slot (lmdb.h:1403-1419) and is deliberately awkward.
//!   * `MDB_cursor` is created by `mdb_cursor_open` and released by
//!     `mdb_cursor_close` (lmdb.h:1614-1644) — but a cursor belonging to a
//!     **write** transaction is freed by the transaction itself, and may not
//!     outlive it. A read-only cursor must be closed explicitly **before**
//!     its transaction commits, aborts or resets. Although lmdb.h:1622-1624
//!     permits later closure, this bundled core reads the transaction during
//!     cursor cleanup (mdb.c:9786). The facade requires the stricter order.
//!
//! The facade checks spent-handle state; parent lifetime and cleanup order
//! remain caller obligations:
//!
//!   * `Transaction.commit` and `Transaction.abort` clear the handle before
//!     calling C. A deferred abort after commit is a no-op, as is a second
//!     abort. A second commit returns `error.TransactionClosed`.
//!   * `Cursor.close` calls `mdb_cursor_close` for a read-only cursor while
//!     its transaction is live. For a write cursor it spends the Zig wrapper
//!     without freeing the transaction-owned pointer. Repeated close on the
//!     same wrapper does nothing; independent handle copies are not tracked.
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
//!
//! ## What the typed surface covers, and what stays behind `c`
//!
//! Wrapped: the whole environment lifecycle and configuration (flags, page
//! size, map size, database and reader limits, path, descriptor, statistics,
//! environment info, user context, copy, incremental dump and load, and
//! rollback), the whole transaction lifecycle (begin, nested begin, identifier,
//! flags, prepare, commit, abort, reset, renew), every database operation
//! upstream has (open, close, flags, statistics, drop, both comparators, the
//! relocation function and its context, and both comparison queries), every
//! cursor operation except the page-at-a-time ones, and the four callback
//! families — key and value comparators, the assert callback and the reader
//! message callback. [`Encryption`] adds the page encryptor and the page
//! checksummer where the header declares them.
//!
//! Left raw, on purpose:
//!
//!   * the `MDB_DUPFIXED` page-at-a-time cursor operations `MDB_GET_MULTIPLE`
//!     and its relatives, which put a *count of items* in the data value
//!     rather than bytes, so a `[]const u8` would have to lie about it (see
//!     [`CursorOp`]);
//!   * `mdb_modload`, `mdb_modunload` and `mdb_modsetup`, the three entry
//!     points LMDB's own command-line tools use to load an out-of-tree crypto
//!     module. Their payload is `MDB_crypto_funcs` — a struct of three callback
//!     pointers and three integers (lmdb.h:1873-1880) — and wrapping it here
//!     would mean restating that layout and each callback's signature in Zig,
//!     where the translation already has them exactly. A caller that needs them
//!     reads them out of `c`;
//!   * the raw status code behind every call, through `c` directly.
//!
//! Neither list removes anything from the library: every one of these names is
//! in the complete raw surface either way, and in a runtime-loading build every
//! one of them is resolved through the same table as the wrapped ones.
//!
//! ## Consumer sequence
//!
//! Zig 0.16.0. Import `dep.module("lmdb")` from a `b.dependency` with the
//! consumer's target and optimize mode. The facade links the bundled archive,
//! or the matching selected system library with `-fsys=lmdb`.
//! `dep.module("c")` is not registered; the raw route is `pub const c` on this
//! module, which carries this facade's own linkage with it.
//! The bundled `dep.artifact("lmdb")` is the C archive and installs `lmdb.h`;
//! no bundled artifact is produced in system mode.
//!
//! In a `-Druntime=true` build the module links nothing, and nothing works
//! until [`load`] has been given a provider: `--provider <path>` on a program's
//! own command line, or `LMDB_TEST_PROVIDER` in the environment, resolved by
//! whoever runs it. There is no default location, no search, no fallback to a
//! bundled copy and no automatic retry. See [`load`] for the rest of the
//! contract.
//!
//! `path` must name an existing database directory, and LMDB does not create
//! it: there is no `mkdir` anywhere in `mdb.c`. Each `try` propagates failure
//! while deferred cleanup runs in cursor, transaction, environment order:
//!
//! ```zig
//! const std = @import("std");
//! const lmdb = @import("lmdb");
//!
//! fn readFirst(path: [:0]const u8) !void {
//!     var env = try lmdb.Environment.init(.{ .path = path });
//!     defer env.close();
//!     var txn = try env.beginReadOnly();
//!     defer txn.abort();
//!     const db = try txn.openDatabase(null, .{});
//!     var cursor = try txn.openCursor(db);
//!     defer cursor.close();
//!     const entry = try cursor.first();
//!     std.debug.print("{s}={s}\n", .{ entry.key, entry.value });
//! }
//! ```
//!
//! Environment open/sync, writer acquisition and commit may block in the native
//! library. They have no Zig `std.Io` cancellation channel.

const std = @import("std");
const builtin = @import("builtin");

/// The unmodified upstream ABI, translated from `libraries/liblmdb/lmdb.h`.
///
/// Prefer the typed wrappers below it. Reach for this when you need a raw
/// status code rather than [`Error`], when you want a page-at-a-time
/// `MDB_DUPFIXED` operation that this facade deliberately does not wrap
/// ([`CursorOp`]), or when you want the C string `mdb_strerror` builds.
///
/// In a runtime-loading build this module is a generated dispatch rather than
/// the translation step's own output. It publishes the same namespace — every
/// type and constant is re-exported from the translated header, not restated —
/// so `c.MDB_val` here and the declaration behind the table are one nominal
/// type and nothing needs a cast. What differs is how a name reaches the
/// library: directly in a linked build, through the table [`load`] fills in a
/// runtime-loaded one. [`runtime_loaded`] says which, at comptime.
pub const c = @import("c");

/// The loader core, which is where a linked build's two public types come
/// from.
///
/// Imported only by the linked configuration. In a runtime-loading build the
/// dispatch carries its own copy of the same declarations, this module is
/// never referenced, and the import is never resolved. Either way there is
/// exactly one `LoadSource` and one `LoadError` in a build, which is what keeps
/// them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where liblmdb is linked and `c` is the
/// translated header itself. True when the build generated a dispatch that
/// resolves the same entry points through the platform loader, in which case
/// [`load`] is the call that makes the library usable and every entry point
/// before it stops the program.
///
/// A comptime constant, so a consumer can write two different code paths and
/// have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library [`load`] should open.
///
/// `.path` is an explicit file path and `.system` is an explicit basename
/// handed unchanged to the platform loader. There is no path-to-system
/// fallback in either direction and no implicit source of any kind: a request
/// that cannot be honoured is an error, not a different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way [`load`] can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside
/// the loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `error.ProviderMismatch`, and the library already in use stays in
/// use. A failed attempt publishes nothing and can be retried explicitly by
/// calling this again: there is no automatic retry, and no implicit second
/// source.
///
/// It keeps the process handle and its own copy of the request to the end of
/// the process. There is no unload and no reset, because the table is
/// process-global state that other code may already have called through — which
/// is also why a second liblmdb cannot replace the first one, and why no
/// `MDB_env`, `MDB_txn` or `MDB_cursor` may be carried across a provider
/// change: there is no provider change.
///
/// Safe to call from any thread. A thread that arrives while an attempt for
/// the same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports
/// both configurations can tell the two apart at comptime instead of meeting
/// this at run time.
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

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

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
    /// `MDB_IS_READONLY`. A write was refused because the transaction or the
    /// environment is read-only, and that refusal is the whole of the code:
    /// a write transaction in an `MDB_RDONLY` environment —
    /// [`Environment.beginWrite`] (mdb.c:3494-3495) — [`Environment.sync`]
    /// on such an environment (mdb.c:3114-3115), [`Transaction.put`] and its
    /// `NOOVERWRITE` and `NODUPDATA` variants through `mdb_put`
    /// (mdb.c:11120-11121, :8602-8603), [`Cursor.putCurrent`]
    /// (mdb.c:8602-8603), [`Transaction.delete`] and
    /// [`Transaction.deleteValue`] (mdb.c:10618-10619),
    /// [`Cursor.deleteCurrent`] and [`Cursor.deleteAllDuplicates`]
    /// (mdb.c:9120-9121), [`Transaction.openDatabase`] with
    /// [`DbFlags.create`] (mdb.c:12339-12340), and [`Transaction.drop`]
    /// (mdb.c:12540-12541). Not a permissions problem: see
    /// [`error.AccessDenied`].
    IsReadOnly,
    /// `MDB_ADDR_BUSY`. The address LMDB wanted for a fixed map is taken.
    AddrBusy,

    /// `EACCES`, and `EPERM` on a POSIX build. A file the environment needs
    /// could not be opened for writing — `open(2)` in `mdb_fopen`
    /// (mdb.c:5416-5420) — so this is the permissions on the directory or
    /// the file, and nothing else. A write refused because the transaction
    /// or the environment is read-only is [`error.IsReadOnly`].
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

    /// An unmapped native status, or success with an unexpectedly null result
    /// pointer. Neither case supplies its raw code through this error tag;
    /// call `c` directly when that detail is required. Windows status spaces
    /// overlap, so an unknown number is not guessed into another error.
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

/// Borrow a NUL-terminated C string the library owns.
///
/// `lmdb.h` declares `mdb_version` and `mdb_strerror` as returning `char *`
/// (lmdb.h:575, :587) — not `const char *` — so the C translator may give them
/// the plain pointer form, and `std.mem.span` does not apply to it. The
/// parameter accepts either rendering, because a sentinel-qualified pointer
/// coerces to a plain one, so this works whichever the translation produced.
/// The bound is a backstop rather than the rule: every string `mdb.c` builds
/// is far shorter, and a provider that failed to terminate one would be a
/// fault in the provider rather than something a caller can defend against.
fn cString(ptr: [*c]u8, comptime limit: usize) []const u8 {
    var len: usize = 0;
    while (len < limit and ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

/// The upstream library version, as `mdb_version` reports it.
pub const Version = struct {
    major: c_int,
    minor: c_int,
    patch: c_int,
};

/// The version of the liblmdb this build reaches.
///
/// Read out of the library rather than compiled in, so in a runtime-loading
/// build it names the provider that was loaded and in a linked build the
/// archive that was linked. It is not a compatibility verdict: see the external
/// ABI family at the top of this file and the complete record in
/// `runtime/library.zig` for what actually has to match.
pub fn version() Version {
    var v: Version = undefined;
    _ = c.mdb_version(&v.major, &v.minor, &v.patch);
    return v;
}

/// The whole version string the library builds for itself.
///
/// `mdb_version` returns LMDB's own static string, which the header spells
/// `MDB_VERSTR(MDB_VERSION_MAJOR, MDB_VERSION_MINOR, MDB_VERSION_PATCH,
/// MDB_VERSION_DATE)` (lmdb.h:251-259) — `"LMDB 1.0.1: (Aug 6, 2026)"` for
/// this tree's release. Borrowed, never copied, and valid for the life of the
/// process because the string is static storage inside the library.
pub fn versionString() []const u8 {
    return cString(c.mdb_version(null, null, null), 256);
}

/// Upstream's description of one status code, as `mdb_strerror` builds it.
///
/// The two families the returned text covers are the ones [`check`] separates:
/// a negative code is one of LMDB's own constants and this is the library's
/// text for it; a non-negative one is handed to the platform's `strerror(3)`
/// (lmdb.h:577-585), so the wording for a Windows code and for an `errno` is
/// the platform's rather than this library's. Borrowed and static, like
/// [`versionString`]. `rc` is the raw value, not an [`Error`].
pub fn strerror(rc: c_int) []const u8 {
    return cString(c.mdb_strerror(rc), 512);
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

/// Page and tree statistics for one database, read out of `MDB_stat`
/// (lmdb.h:548-556).
///
/// A copy of what the C reported, with the C's own field names changed to
/// snake_case. The C struct stays reachable through [`c`] for anything this
/// does not name; it is one of the two complete layouts that cross the
/// boundary, and it is a boundary because the caller reads the result rather
/// than passing its own.
pub const Statistics = struct {
    /// Size of a database page in bytes. Currently the same for every database
    /// in the environment.
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

/// What the environment knows about itself, read out of `MDB_envinfo`
/// (lmdb.h:559-566).
pub const EnvInfo = struct {
    /// Where the memory map starts. Borrowed from the mapping: it belongs to
    /// the environment and goes away with it, so it names an address and is
    /// not a pointer to anything the caller may read through.
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

/// Options for [`Environment.copyWithOptions`] and
/// [`Environment.copyToFileHandle`], one field per upstream flag
/// (lmdb.h:422-429).
pub const CopyFlags = struct {
    /// `MDB_CP_COMPACT`. Omit free pages from the copy.
    compact: bool = false,

    /// The `unsigned int` `mdb_env_copy2` and `mdb_env_copyfd2` take.
    pub fn bits(self: CopyFlags) c_uint {
        return flag(c.MDB_CP_COMPACT, self.compact);
    }
};

/// A file handle in whatever shape this target gives one: `int` on POSIX and
/// `void *` on Windows (lmdb.h:221-225). Returned by [`Environment.fileHandle`]
/// and accepted by the descriptor-flavoured calls; the C's own zero is the
/// absence of a handle, so compare against `@as(c.mdb_filehandle_t, 0)`.
pub const FileHandle = c.mdb_filehandle_t;

/// Upstream's key comparator, `MDB_cmp_func` (lmdb.h:299), and the comparator
/// for duplicate data as well (lmdb.h:1453-1474 uses the same typedef for
/// `mdb_set_dupsort`).
///
/// The translated type itself rather than a Zig spelling of it, so the
/// contract is upstream's `MDB_cmp_func` verbatim: a caller declares a
/// function of that type and hands it over directly. `&` is not that
/// spelling, because taking a function's address produces a pointer to it and
/// a pointer is not the type upstream's prototype declares. What matters here
/// is upstream's own rule, not this module's: the same comparison function
/// must be used by *every* program that opens the database, every time, and it
/// must be installed before any data operation (lmdb.h:1438-1441,
/// :1461-1464).
pub const KeyComparator = c.MDB_cmp_func;

/// Upstream's relocation callback for a `MDB_FIXEDMAP` database,
/// `MDB_rel_func` (lmdb.h:301-315). Feature currently unimplemented upstream
/// (lmdb.h:313), so a provider records the function and never calls it.
pub const RelocationCallback = c.MDB_rel_func;

/// Upstream's assertion callback, `MDB_assert_func` (lmdb.h:1079-1085).
/// Installed with [`Environment.setAssertCallback`].
pub const AssertCallback = c.MDB_assert_func;

/// Upstream's reader-table message callback, `MDB_msg_func` (lmdb.h:1828-1834),
/// used by [`Environment.listReaders`]. Returning a negative number aborts the
/// listing; zero or more continues it.
pub const MessageCallback = c.MDB_msg_func;

// -------------------------------------------------------------- environment

/// Options for [`Environment.init`].
///
/// The `null` defaults mean "leave upstream's own default alone": the facade
/// never calls the corresponding setter, so the value the library chose for
/// itself survives. A non-null value is passed through unchanged.
pub const OpenOptions = struct {
    /// Existing database directory, or data file when `flags.nosubdir` is set.
    /// Borrowed until `init` returns, with no interior NUL. The facade passes
    /// its pointer unchanged; the native environment stores a copy.
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
/// Construct with `create` or `init`; preserve all state fields. This is a
/// single owner: copying duplicates the native handle, not ownership. Close
/// only that owner after its transactions and cursors have finished.
/// Keep the wrapper alive at one address while transactions borrow it.
/// Native environment destruction must not race any use (lmdb.h:892-897).
pub const Environment = struct {
    /// Owned native handle, or `null` after close. Not an independent owner;
    /// do not replace or free it behind the facade.
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
    /// `path` is borrowed for this call, with no interior NUL; the native core
    /// stores its own copy (mdb.c:6338). On failure the handle must be
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
    pub fn open(self: *Environment, directory: [:0]const u8, options: EnvFlags, mode: Mode) Error!void {
        if (self.opened) return error.EnvironmentAlreadyOpen;
        if (self.open_attempted) return error.OpenFailed;
        const handle = try self.pending();
        // Set before the call, not after: on the failure path this handle is
        // spent even though nothing below knows it yet.
        self.open_attempted = true;
        try check(c.mdb_env_open(handle, directory.ptr, options.bits(), mode));
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
    /// documented answer to `error.MapResized` (lmdb.h:976-979).
    ///
    /// Call it before `open`, or afterwards only when no transaction of
    /// *either* kind is live in this process. That precondition is the
    /// caller's, and upstream enforces only half of it: lmdb.h:967-969
    /// states it in prose, and the C checks the write half alone —
    /// `env->me_txn` (mdb.c:5184-5185), which is assigned only on the write
    /// path of `mdb_txn_renew0` (mdb.c:3402) and cleared when that
    /// transaction ends (mdb.c:3757).
    ///
    /// So a live *write* transaction is refused: `EINVAL` arrives here as
    /// `error.InvalidArgument`, and the map is left as it was. A live
    /// *read-only* transaction is not detected, and in the configuration
    /// this package builds — `MDB_RPAGE_CACHE` is 1 without
    /// `MDB_REMAP_CHUNKS` (lmdb.h:192-195), so `MDB_REMAPPING` is false
    /// (mdb.c:2333-2337) — the C goes on to `munmap` the old mapping and map
    /// the new one (mdb.c:5200-5205). Every `[]const u8` borrowed through
    /// [`Transaction.get`] or a [`Cursor`] traversal points into unmapped
    /// memory from that moment, and the next dereference of one faults.
    /// This facade neither refuses the call nor repairs the borrow.
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

    /// The largest key this environment will accept, in bytes.
    ///
    /// Depends on the page size, and only an open environment has one:
    /// `mdb_env_open2` is where upstream computes `me_maxkey`
    /// (mdb.c:5657-5659) and `mdb_env_get_maxkeysize` reads that field back
    /// (mdb.c:12678-12682), which is what lmdb.h:1055-1057 means by "Can
    /// only be used after #mdb_env_open()". A key is 1..this inclusive
    /// (lmdb.h:288-292); a longer one travels to the C and comes back as
    /// `error.BadValSize` (mdb.c:8605-8606).
    ///
    /// This is the one call in the surface whose return value is an answer
    /// rather than a status — lmdb.h:1061 documents its return as "The
    /// maximum size of a key we can write" — so it is the one return value
    /// here that does not go through `check`. Every real answer is well above
    /// zero, so `check` turned all of them into `positiveStatus`.
    pub fn maxKeySize(self: *Environment) Error!u32 {
        return @intCast(c.mdb_env_get_maxkeysize(try self.openHandle()));
    }

    /// Set the page size in bytes, before the open (lmdb.h:995-1002).
    ///
    /// Only a power of two between the minimum and maximum the operating
    /// system supports is accepted; what those are is the platform's, and a
    /// refusal comes back as `error.InvalidArgument`.
    pub fn setPageSize(self: *Environment, bytes: c_int) Error!void {
        try check(c.mdb_env_set_pagesize(try self.pending(), bytes));
    }

    /// The flags this environment is actually carrying.
    ///
    /// Read out of the handle, so it answers what the environment is using
    /// rather than what a caller once asked for — which is the whole point,
    /// because several flags may be changed after the open (lmdb.h:902-928).
    pub fn flags(self: *Environment) Error!c_uint {
        var bits: c_uint = 0;
        try check(c.mdb_env_get_flags(try self.openHandle(), &bits));
        return bits;
    }

    /// Set or clear environment flags on an open environment.
    ///
    /// `on` sets every bit in `mask` and clears them when false. Upstream lists
    /// which flags may change after the open and which may not
    /// (lmdb.h:613-726), and this passes the mask through rather than deciding
    /// that for the caller. Not mutex protected: if several threads change
    /// flags at once the result is undefined (lmdb.h:903-904).
    pub fn setFlags(self: *Environment, mask: c_uint, on: bool) Error!void {
        try check(c.mdb_env_set_flags(try self.openHandle(), mask, if (on) 1 else 0));
    }

    /// The path this environment was opened with, as upstream stored it.
    ///
    /// Not a copy: the header says the string belongs to the environment, must
    /// not be altered, and is what `mdb_env_open` was given (lmdb.h:930-942).
    /// Relative exactly as the caller wrote it, and gone with the environment.
    pub fn path(self: *Environment) Error![:0]const u8 {
        var text: ?[*:0]const u8 = null;
        try check(c.mdb_env_get_path(try self.openHandle(), &text));
        return text orelse error.UnexpectedStatus;
    }

    /// The descriptor the environment's data file is open on.
    ///
    /// `int` on POSIX and an opaque pointer on Windows (lmdb.h:221-225), which
    /// is what [`FileHandle`] is. Zero is the absence of a descriptor. The
    /// handle belongs to the environment and is closed by `close`; nothing
    /// here duplicates or takes ownership of it.
    pub fn fileHandle(self: *Environment) Error!FileHandle {
        var handle: FileHandle = 0;
        try check(c.mdb_env_get_fd(try self.openHandle(), &handle));
        return handle;
    }

    /// Page and tree statistics for the environment as a whole, which for LMDB
    /// is its main database.
    ///
    /// For one named database, ask inside a transaction with
    /// [`Transaction.statistics`].
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

    /// What the environment knows about itself: where its map is, how large it
    /// is, the last page and transaction identifiers, and how full the reader
    /// table is.
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

    /// Copy the environment into the directory `path`, with no options.
    ///
    /// `path` must already exist, be writable and otherwise be empty
    /// (lmdb.h:731-745). The copy is taken through a read-only transaction of
    /// its own, so a long-lived reader elsewhere can make it grow
    /// (lmdb.h:737).
    pub fn copy(self: *Environment, destination: [:0]const u8) Error!void {
        try check(c.mdb_env_copy(try self.openHandle(), destination.ptr));
    }

    /// Copy the environment into `path` with options.
    pub fn copyWithOptions(self: *Environment, destination: [:0]const u8, options: CopyFlags) Error!void {
        try check(c.mdb_env_copy2(try self.openHandle(), destination.ptr, options.bits()));
    }

    /// Copy the environment onto a descriptor the caller has already opened for
    /// writing (lmdb.h:787-804). No lock file is written; the copy gets one at
    /// need.
    pub fn copyToFileHandle(
        self: *Environment,
        handle: FileHandle,
        options: CopyFlags,
    ) Error!void {
        try check(c.mdb_env_copyfd2(try self.openHandle(), handle, options.bits()));
    }

    /// Write everything committed after transaction `txn` into the new file
    /// `path`, which must not already exist (lmdb.h:824-840).
    pub fn dumpSince(self: *Environment, destination: [:0]const u8, txn: Size) Error!void {
        try check(c.mdb_env_incr_dump(try self.openHandle(), destination.ptr, txn));
    }

    /// The same incremental dump, onto a descriptor the caller has opened for
    /// writing (lmdb.h:806-822).
    pub fn dumpSinceToFileHandle(self: *Environment, handle: FileHandle, txn: Size) Error!void {
        try check(c.mdb_env_incr_dumpfd(try self.openHandle(), handle, txn));
    }

    /// Load an incremental dump back into the environment from `handle`.
    ///
    /// The environment must have been opened with `writemap` set
    /// (lmdb.h:842-853), and no other task may touch the environment while this
    /// runs (lmdb.h:847-848). Both are caller obligations upstream does not
    /// check.
    pub fn loadSinceFromFileHandle(self: *Environment, handle: FileHandle) Error!void {
        try check(c.mdb_env_incr_loadfd(try self.openHandle(), handle));
    }

    /// Roll the environment back to the commit `txn` names.
    ///
    /// `txn` is the identifier [`Transaction.id`] reported for the transaction
    /// to undo, and it has to be the *newest* committed one: upstream compares
    /// it against the newest metapage and answers `error.CantRollback` for
    /// anything else, including an older transaction and zero (mdb.c:4662-4665).
    /// Nothing else may have committed since — the header requires that no
    /// other process wrote to the environment between the commit and this call
    /// (lmdb.h:1231-1241), and nothing in this module can check it.
    ///
    /// Upstream writes the previous metapage and moves the reader table's
    /// transaction identifier with it (mdb.c:4676-4679), so readers begin from
    /// the state before the transaction being undone.
    pub fn rollback(self: *Environment, txn: Size) Error!void {
        try check(c.mdb_env_rollback(try self.openHandle(), txn));
    }

    /// Store a pointer for the application to find again later.
    ///
    /// Stored, not copied and not owned (lmdb.h:1064-1070): whatever the
    /// pointer names stays the caller's responsibility and nothing in this
    /// module frees it.
    pub fn setUserContext(self: *Environment, context: ?*anyopaque) Error!void {
        try check(c.mdb_env_set_userctx(try self.pending(), context));
    }

    /// The pointer given to [`setUserContext`], unchanged (lmdb.h:1072-1077).
    pub fn userContext(self: *Environment) Error!?*anyopaque {
        return c.mdb_env_get_userctx(try self.pending());
    }

    /// Set or clear the assertion callback.
    ///
    /// Upstream calls it with the environment and the assertion message before
    /// printing its own message and aborting (lmdb.h:1079-1094). The whole
    /// mechanism is compiled out when liblmdb is built with `NDEBUG`; this
    /// package passes no such define (`build.zig`, `c_flags` is only
    /// `-std=gnu17`), so the callback is live in a provider built the same way.
    /// Passing `null` removes it.
    pub fn setAssertCallback(self: *Environment, callback: ?AssertCallback) Error!void {
        try check(c.mdb_env_set_assert(try self.pending(), callback));
    }

    /// Print the reader lock table through `callback`.
    ///
    /// `context` is handed back to the callback untouched; it is neither copied
    /// nor freed by anything here. A callback that returns a negative number
    /// stops the listing (lmdb.h:1828-1834), and that number is what this
    /// returns, so a caller can tell "the table ran out" from "the callback
    /// refused". Callback results, negative or nonnegative, are not LMDB error
    /// statuses and are returned unchanged. The error union only reports an
    /// environment that is closed or has not been opened.
    pub fn listReaders(self: *Environment, callback: MessageCallback, context: ?*anyopaque) Error!c_int {
        const status = c.mdb_reader_list(try self.openHandle(), callback, context);
        return status;
    }

    /// Reclaim reader lock-table slots whose owning thread has gone, answering
    /// how many were reclaimed (lmdb.h:1845-1851).
    ///
    /// Zero is the ordinary answer and is not an error; a table that is full
    /// because nothing has died is full, and freeing memory does not help.
    pub fn clearStaleReaders(self: *Environment) Error!c_int {
        var dead: c_int = 0;
        try check(c.mdb_reader_check(try self.openHandle(), &dead));
        return dead;
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
    /// Several readers can coexist when the native thread/`notls` rules permit
    /// them. A reader holds its snapshot's pages; a long-lived one can make the
    /// database grow (lmdb.h:1278-1281). The result borrows this wrapper's stable
    /// address until commit or abort.
    pub fn beginReadOnly(self: *Environment) Error!Transaction {
        return self.begin(true);
    }

    /// Begin a read-write transaction, borrowing this wrapper's stable address.
    /// Waits for the single writer slot; no cancellation channel is provided.
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

/// Page encryption and plain checksums, where the header declares them.
///
/// `mdb_env_set_encrypt` and `mdb_env_set_checksum` sit inside
/// `#if MDB_RPAGE_CACHE` (lmdb.h:317-342, :1096-1119) together with the
/// callback typedefs they take. `lmdb.h:192-195` defines that macro to 1
/// unless `MDB_VL32` is defined, and this package defines neither, so both are
/// in this build's translation and both are in the provider's table. A header
/// without them — an older installed `lmdb.h` under `-fsys=lmdb`, say — leaves
/// this as `void`, and `c` carries no declaration to call either, so a program
/// written against them cannot be built against one without them. That is a
/// property of the header, stated here rather than papered over.
///
/// Both setters must be called before [`Environment.open`] (lmdb.h:1099-1102,
/// :1111-1113) and encryption implies `MDB_REMAP_CHUNKS` (lmdb.h:1100-1102).
pub const Encryption = if (@hasDecl(c, "mdb_env_set_encrypt")) struct {
    /// Upstream's page encryption callback, `MDB_enc_func` (lmdb.h:318-330).
    /// The library calls it for every page it reads and every page it writes;
    /// the source and the key come out of the map and the destination is
    /// storage the callback owns for the duration of the call.
    pub const Callback = c.MDB_enc_func;

    /// Upstream's page checksum callback, `MDB_sum_func` (lmdb.h:332-341). It
    /// writes the checksum into `dst`; the bytes there belong to the library
    /// for the length the setter below was given.
    pub const ChecksumCallback = c.MDB_sum_func;

    /// Encrypt this environment's pages with `callback`.
    ///
    /// `key` is the encryption key as one `MDB_val`, and `auth_data_size` is the
    /// number of bytes of authentication data the callback expects alongside it
    /// (lmdb.h:1104-1107). The callback is the caller's own function: the
    /// library calls back into it during page access and retains nothing of
    /// it, so it must stay valid and reachable for the life of the
    /// environment. `MDB_ENCRYPT` is set by the library rather than by the
    /// caller, so it is not in [`EnvFlags`].
    pub fn set(env: *Environment, callback: Callback, key: []const u8, auth_data_size: c_uint) Error!void {
        var key_value = dataValue(key);
        try check(c.mdb_env_set_encrypt(try env.pending(), callback, &key_value, auth_data_size));
    }

    /// Checksum this environment's pages with `callback`, `size` bytes wide.
    ///
    /// A plain checksum rather than authenticated encryption: the callback
    /// receives the page and writes `size` bytes into the page's checksum
    /// field (lmdb.h:1110-1118). The same ownership rule as [`set`] applies —
    /// the callback stays the caller's for the life of the environment.
    pub fn setChecksum(env: *Environment, callback: ChecksumCallback, size: c_uint) Error!void {
        try check(c.mdb_env_set_checksum(try env.pending(), callback, size));
    }
} else void;

// -------------------------------------------------------------- transaction

/// A transaction: the unit of isolation, and the lifetime that everything
/// borrowed from the database is bound to.
///
/// Construct through an environment or `beginNested`, and preserve the fields.
/// One owner spends its handle with commit or abort; do not independently clean
/// up copies. Abort is idempotent on the same wrapper. A repeated commit returns
/// `error.TransactionClosed`, so `defer txn.abort(); try txn.commit();` is safe.
///
/// Close every read cursor before commit, abort or reset. Those operations
/// invalidate borrowed bytes. The cleanup order is a caller precondition, not
/// a tracked property. Keep this wrapper at one address while cursors borrow it.
/// Transactions and cursors obey the native thread/`notls` rules
/// (lmdb.h:1124-1127); a copied wrapper does not grant concurrent use.
pub const Transaction = struct {
    /// Owned native transaction, or `null` after commit/abort. Do not alter it.
    handle: ?*c.MDB_txn,
    /// Borrowed environment wrapper. It must remain alive, open and at the same
    /// address until this transaction ends; `beginNested` dereferences it.
    env: *Environment,
    /// Whether this is a read-only transaction. Read from the request rather
    /// than from the handle, because it decides cursor ownership — see
    /// [`Cursor.close`] — and stays meaningful after the handle is released.
    read_only: bool,
    /// Whether this is a nested transaction. Its cursors transfer to the
    /// parent on commit; on abort the native transaction releases them.
    nested: bool,
    /// Set between `reset` and `renew`, while the C has released the reader
    /// lock and no data operation is valid.
    suspended: bool,
    /// Set after `prepare`, once the data pages are on disk and only the
    /// metapage update is left (lmdb.h:1208-1229). A prepared transaction has
    /// no valid data operation; only `commit` and `abort` are, and the C has
    /// already closed every cursor that belonged to it.
    prepared: bool,

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
            .prepared = false,
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
    pub fn openDatabase(self: *Transaction, name: ?[:0]const u8, options: DbFlags) Error!Database {
        const handle = try self.active();
        var dbi: c.MDB_dbi = 0;
        const name_ptr: [*c]const u8 = if (name) |n| n.ptr else null;
        try check(c.mdb_dbi_open(handle, name_ptr, options.bits(), &dbi));
        return .{ .dbi = dbi };
    }

    /// Store `value` under `key`, replacing whatever was there.
    ///
    /// The bytes are copied into the database during this call, so `key` and
    /// `value` need not outlive it. In a `DUPSORT` database this *adds* a
    /// duplicate rather than replacing one (lmdb.h:1541-1545).
    ///
    /// ## What a failed overwrite leaves behind
    ///
    /// An error from this call is not proof that nothing changed. When
    /// `key` is already there and the new value cannot be written over the
    /// stored one in place, upstream deletes the stored node and inserts
    /// afterwards: a plain database whose value size differs takes the
    /// `mdb_node_del` at mdb.c:8968, one whose stored value sits in an
    /// overflow page frees that page first and falls through to the same
    /// place (mdb.c:8892-8952), and a `DUPSORT` database whose sub-page has
    /// to grow deletes the key's node at mdb.c:8884. The insert is the part
    /// that fails (mdb.c:8973-8984): `MDB_MAP_FULL` (mdb.c:2862-2864),
    /// `MDB_TXN_FULL` (mdb.c:2964-2965), `MDB_PAGE_FULL`
    /// (mdb.c:9443-9449) or `ENOMEM` (mdb.c:3063-3066).
    ///
    /// By then this transaction no longer has the old value:
    /// [`Transaction.get`] answers `error.NotFound` and a [`Cursor`] over
    /// the database no longer sees the key. Each of those paths also marks
    /// the transaction failed (`MDB_TXN_ERROR`, mdb.c:2924, :3106, :9448,
    /// :11100), so [`Transaction.commit`] cannot make that gap permanent —
    /// it is refused with `MDB_BAD_TXN` (mdb.c:4411-4417), which arrives as
    /// `error.BadTxn`, and the C aborts the transaction on the way out
    /// (mdb.c:4633-4635). Aborting leaves the stored value intact. Read
    /// the error as the end of this transaction, not as a failed no-op.
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
    /// The cursor borrows this wrapper's stable address. Close a read cursor
    /// before committing, aborting or resetting the transaction. A write cursor's
    /// native allocation belongs to the transaction; see `Cursor.close`.
    pub fn openCursor(self: *Transaction, db: Database) Error!Cursor {
        const handle = try self.active();
        var out: ?*c.MDB_cursor = null;
        const cursor = try checkOut(c.MDB_cursor, c.mdb_cursor_open(handle, db.dbi, &out), out);
        return .{ .handle = cursor, .owner = self, .read_only = self.read_only };
    }

    /// Commit everything this transaction did, and release it.
    ///
    /// Close all read cursors first. The transaction is spent whether this
    /// succeeds or fails (mdb.c:4629-4635); its allocation may be recycled.
    /// The handle is cleared before C, so a deferred `abort` does nothing.
    /// A later commit returns `error.TransactionClosed`.
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
    /// Close all read cursors first; this also invalidates all borrowed bytes.
    pub fn abort(self: *Transaction) void {
        const handle = self.handle orelse return;
        self.handle = null;
        self.suspended = false;
        self.prepared = false;
        c.mdb_txn_abort(handle);
    }

    /// Write this transaction's data pages but not the metapage, leaving it
    /// prepared for the second half of a two-phase commit.
    ///
    /// On success the handle stays alive — that is the whole point — and every
    /// cursor on the transaction has been closed by the C (mdb.c:4557,
    /// lmdb.h:1212-1213). Afterwards only [`commit`] and [`abort`] are
    /// defined, and the facade says so: every other method here, and every
    /// traversal on a cursor that borrowed this transaction, answers
    /// `error.TxnPending` rather than reaching a transaction the C considers
    /// half-finished. [`commit`] writes the metapage and frees the handle
    /// (mdb.c:4615-4631); [`abort`] throws the data pages away.
    ///
    /// A *nested* transaction has no metapage of its own, so upstream treats
    /// this as a commit: the child's pages are merged into the parent and the
    /// child is freed (mdb.c:4419-4548), and the parent's `mt_flags` is
    /// overwritten with the child's, which does not carry the prepare bit
    /// (mdb.c:4436). Nothing is left prepared, so this wrapper is spent
    /// exactly as [`commit`] would have spent it and a later commit is
    /// `error.TransactionClosed`.
    ///
    /// A second `prepare` on the same transaction is `error.TxnPending`,
    /// which is also upstream's own answer (mdb.c:4649-4650).
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
    ///
    /// Close this transaction's read cursors before reset. The snapshot's
    /// borrowed bytes become invalid; renewed use needs newly opened cursors.
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

    /// This transaction's identifier (lmdb.h:1171-1180).
    ///
    /// Assigned by the library and meaningful only while the transaction is
    /// active. It is the value [`Environment.rollback`] names, and it is also
    /// the value [`Environment.dumpSince`] asks an incremental dump to start
    /// from. Not a byte count and not ordered between environments.
    pub fn id(self: *Transaction) Error!Size {
        const handle = try self.active();
        return c.mdb_txn_id(handle);
    }

    /// The flags this transaction was begun with (lmdb.h:1182-1188).
    ///
    /// Read out of the C rather than echoed from what this wrapper recorded at
    /// `begin`, so it is the library's own answer.
    pub fn flags(self: *Transaction) Error!c_uint {
        var bits: c_uint = 0;
        try check(c.mdb_txn_flags(try self.active(), &bits));
        return bits;
    }

    /// The environment handle the C says this transaction belongs to
    /// (lmdb.h:1165-1169).
    ///
    /// Borrowed, and the same handle this wrapper's [`Transaction.env`] points
    /// at; it is here for the callback and logging paths that want the C's own
    /// answer rather than the wrapper's copy.

    /// Upstream answers `NULL` only for a null transaction (mdb.c:3643), and
    /// `active` has already refused one, so a null from a transaction that is
    /// live is `error.UnexpectedStatus` rather than a handle to pass on.
    pub fn environment(self: *Transaction) Error!*c.MDB_env {
        const handle = try self.active();
        return c.mdb_txn_env(handle) orelse error.UnexpectedStatus;
    }

    /// Page and tree statistics for one database in this environment
    /// (lmdb.h:1380-1392).
    ///
    /// The same shape [`Environment.statistics`] returns; this one is scoped to
    /// the `MDB_dbi` the caller names rather than to the main database.
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

    /// The flags `db` was created with (lmdb.h:1394-1401).
    pub fn databaseFlags(self: *Transaction, db: Database) Error!c_uint {
        var bits: c_uint = 0;
        try check(c.mdb_dbi_flags(try self.active(), db.dbi, &bits));
        return bits;
    }

    /// Empty `db`, or delete it from the environment and close its handle
    /// (lmdb.h:1421-1430).
    ///
    /// `delete` false removes every entry and leaves the database in place;
    /// true removes a *named* database as well. The two are not the same for
    /// the main database, which cannot be deleted at all: there `true` only
    /// empties it (mdb.c:12616-12617).
    ///
    /// A named database whose handle this call closes is spent — its slot goes
    /// stale and back to the environment (mdb.c:12620-12621) — so
    /// [`Environment.closeDatabase`] must not be called on it afterwards. A
    /// database that was only emptied, and the main database under either
    /// setting, keeps its handle and is still released that way.
    ///
    /// Each refusal is upstream's own: a read-only transaction is
    /// `error.IsReadOnly` (mdb.c:12540-12541), a handle this transaction has
    /// itself changed is `error.BadDbi` (mdb.c:12543-12544), and dropping the
    /// main database while another database handle is open is
    /// `error.DbisBusy` (mdb.c:12562-12565).
    pub fn drop(self: *Transaction, db: Database, delete_database: bool) Error!void {
        try check(c.mdb_drop(try self.active(), db.dbi, if (delete_database) 1 else 0));
    }

    /// Install a custom key comparator for `db` (lmdb.h:1432-1451).
    ///
    /// Upstream's warning is a rule, not advice: the comparator must be in
    /// place before *any* data access on the database, and every program that
    /// opens this database must use this same comparator, every time, or the
    /// tree they read is not the tree the others wrote (lmdb.h:1438-1441). This
    /// module cannot check either, so the obligation stays with the caller.
    ///
    /// The function is called by the library during page access, on the
    /// library's own stack, with two `MDB_val` items out of the map. It must
    /// not call back into the environment that owns `db`, and it must not
    /// retain either pointer.
    pub fn setKeyComparator(self: *Transaction, db: Database, comparator: KeyComparator) Error!void {
        try check(c.mdb_set_compare(try self.active(), db.dbi, comparator));
    }

    /// Install a custom comparator for a `DUPSORT` database's duplicate data
    /// (lmdb.h:1453-1474, mdb.c:12651-12658).
    ///
    /// Same two obligations as [`setKeyComparator`]: install before any data
    /// access, and use the same comparator in every program that opens the
    /// database, every time (lmdb.h:1462-1464). A handle that is not a valid
    /// user database is `error.InvalidArgument` (mdb.c:12653-12654).
    ///
    /// Upstream stores the function whatever `db` was opened with — the call
    /// tests only that the handle exists (mdb.c:12651-12658) and never looks
    /// at `MDB_DUPSORT`, so there is no `MDB_INCOMPATIBLE` here — and
    /// lmdb.h:1457-1458 says what the store is for: the function "only takes
    /// effect if the database was opened with the #MDB_DUPSORT flag". Inside
    /// the library that is literally true: `md_dcmp` is read only from the
    /// `MDB_DUPSORT` branches (mdb.c:8206-8209, :8768-8771). The one other
    /// reader is [`compareValues`], which calls it whatever the flags are —
    /// which is how a database without duplicates gets an ordering at all.
    pub fn setValueComparator(self: *Transaction, db: Database, comparator: KeyComparator) Error!void {
        try check(c.mdb_set_dupsort(try self.active(), db.dbi, comparator));
    }

    /// Install a relocation function for a `MDB_FIXEDMAP` database
    /// (lmdb.h:1476-1494).
    ///
    /// Upstream records the function and its context; the feature itself is
    /// marked unimplemented in this release (lmdb.h:313), so nothing calls it.
    /// It is wrapped because the surface is part of the header and a caller may
    /// be written against a provider where it is not.
    pub fn setRelocation(self: *Transaction, db: Database, relocation: RelocationCallback) Error!void {
        try check(c.mdb_set_relfunc(try self.active(), db.dbi, relocation));
    }

    /// The pointer a [`setRelocation`] function receives as its `relctx`
    /// (lmdb.h:1496-1510).
    ///
    /// Stored, not copied and not owned. Nothing here frees it and the library
    /// never does either.
    pub fn setRelocationContext(
        self: *Transaction,
        db: Database,
        context: ?*anyopaque,
    ) Error!void {
        try check(c.mdb_set_relctx(try self.active(), db.dbi, context));
    }

    /// Compare two keys exactly as `db` orders them (lmdb.h:1804-1814).
    ///
    /// Negative, zero or positive as `a` sorts before, with, or after `b`.
    /// Neither argument is copied and neither is retained; the library reads
    /// both and answers, and the comparator it uses is whatever `db` was opened
    /// with — a custom one installed by [`setKeyComparator`] included.
    pub fn compareKeys(self: *Transaction, db: Database, a: []const u8, b: []const u8) Error!c_int {
        const handle = try self.active();
        const left = dataValue(a);
        const right = dataValue(b);
        return c.mdb_cmp(handle, db.dbi, &left, &right);
    }

    /// Compare two data items as `db` orders its duplicate values
    /// (lmdb.h:1816-1826, mdb.c:2219-2226).
    ///
    /// Negative, zero or positive as `a` sorts before, with, or after `b`.
    /// This is a comparison and not a status — a negative result is an
    /// ordering, never an error.
    ///
    /// `db` must have been opened with `dupsort`: that is the precondition
    /// lmdb.h:1821 states, and it is not a formality. A database opened
    /// without the flag is given a *null* `md_dcmp` (mdb.c:12258-12259) and
    /// `mdb_dcmp` calls that pointer with no check at all (mdb.c:2222-2225),
    /// so the call cannot answer: it jumps to address zero, and what happens
    /// there is the machine's business rather than a status upstream reports.
    /// There is no return code to refuse it with — the flag is the whole of the
    /// protection, and this module does not invent one it was not asked for.
    ///
    /// Given the flag, the answer is the database's own duplicate comparator:
    /// the one installed by [`setValueComparator`] where there is one, and
    /// otherwise the default `mdb_cmp_memn` — byte-lexicographic with the
    /// shorter item first (mdb.c:6659-6675) — or the integer or reversed
    /// variant the `dupsort` flags asked for (mdb.c:12258-12262).
    pub fn compareValues(self: *Transaction, db: Database, a: []const u8, b: []const u8) Error!c_int {
        const handle = try self.active();
        const left = dataValue(a);
        const right = dataValue(b);
        return c.mdb_dcmp(handle, db.dbi, &left, &right);
    }

    /// A live `MDB_txn` for a data operation, or the reason there is none.
    fn active(self: *Transaction) Error!*c.MDB_txn {
        const handle = self.handle orelse return error.TransactionClosed;
        if (self.suspended) return error.TransactionReset;
        if (self.prepared) return error.TxnPending;
        return handle;
    }

    /// Take the handle away, so that whichever C call frees it cannot be
    /// reached twice through this transaction.
    ///
    /// Unlike [`active`], this accepts a prepared transaction: `commit` is the
    /// second half of what `prepare` started and `abort` is the way out of it,
    /// so a prepared transaction is exactly the one that must still be spendable.
    /// A *reset* transaction is refused here as well, because the C has already
    /// finished it.
    fn take(self: *Transaction) Error!*c.MDB_txn {
        const handle = self.handle orelse return error.TransactionClosed;
        if (self.suspended) return error.TransactionReset;
        self.handle = null;
        return handle;
    }
};

// ----------------------------------------------------------------- database

/// A handle for one database in an environment.
///
/// An independently copyable slot index, not an owner with a `deinit`. Obtain
/// it through `Transaction.openDatabase`; do not substitute an arbitrary index.
/// A newly opened slot is private to that transaction until commit and may be
/// invalidated by abort. Once published it lives until environment close or
/// `Environment.closeDatabase` (lmdb.h:1315-1324, :1403-1418).
pub const Database = struct {
    dbi: c.MDB_dbi,
};

// ------------------------------------------------------------------- cursor

/// A cursor over one database inside one transaction.
///
/// Construct with `Transaction.openCursor`; preserve the returned fields.
/// A copy duplicates the native pointer and may not be independently closed.
///
/// A read cursor owns its native allocation: close it while its transaction
/// is live, before commit, abort or reset. The header permits later closure
/// (lmdb.h:1622-1624), but this core's page-cache cleanup dereferences the
/// transaction (mdb.c:9786). No allocation registry enforces the order.
///
/// A write cursor's allocation belongs to its transaction. `close` only spends
/// the Zig wrapper; native commit/abort frees the allocation, or a nested
/// commit transfers it to the parent (mdb.c:3737-3738, :4439, :4557).
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
    /// Native pointer while the wrapper is live, or `null` after close.
    /// Do not free or replace it; its native owner depends on `read_only`.
    handle: ?*c.MDB_cursor,
    /// Borrowed transaction wrapper. Keep it alive at this address while this
    /// cursor is open and used. A closed cursor no longer dereferences it;
    /// traversal then returns `error.CursorClosed`. Cursors do not span transactions.
    owner: *Transaction,
    /// Native ownership kind captured by `openCursor`. Do not change it:
    /// read cursors need explicit native release, write cursors do not.
    read_only: bool,

    /// Release this cursor.
    ///
    /// For a read cursor, the transaction must still be live and not reset.
    /// This caller precondition is unchecked; C cleanup reads the transaction.
    ///
    /// For a write cursor, leave the native pointer to its transaction, which
    /// frees it on commit/abort. The Zig wrapper may be closed afterwards
    /// without dereferencing the transaction.
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
    /// when the size changes (lmdb.h:1717-1722). The delete comes first, so
    /// a failure in the insert leaves this transaction without the item —
    /// the same gap [`Transaction.put`] describes.
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

    /// Point this cursor at `txn`, which may be a different transaction from
    /// the one it was opened in (lmdb.h:1646-1662, mdb.c:9726-9740).
    ///
    /// The header presents this as the way a cursor outlives its transaction
    /// (lmdb.h:1192-1194, :1259-1262); what that is worth depends on the kind
    /// of transaction the cursor came from, and the section below says which.
    /// The wrapper's ownership follows the native one: `owner` and the
    /// read/write kind are re-read from `txn`, because which call releases a
    /// cursor is decided by the kind of transaction it is in (see [`close`]).
    ///
    /// Every byte the cursor had borrowed went with the old transaction, and
    /// the cursor is unpositioned afterwards, so the next traversal is a seek
    /// again.
    ///
    /// Upstream's refusals: a cursor the environment does not track, or a new
    /// transaction that already has cursors of its own, is
    /// `error.InvalidArgument` (mdb.c:9732-9733); a transaction with a live
    /// child is `error.BadTxn` (mdb.c:9735-9736); a database handle the new
    /// transaction cannot see is `error.InvalidArgument` (mdb.c:9729-9730).
    ///
    /// ## What this core does with the old transaction
    ///
    /// The header says a cursor may be renewed after its transaction has ended
    /// (lmdb.h:1192-1194, :1259-1262), and for a *read-only* transaction that
    /// holds: ending one leaves a read cursor's allocation alone and frees the
    /// reader's slot. It does not hold for a write cursor. Committing or
    /// aborting one calls `mdb_cursors_close(txn, 0)` (mdb.c:4557), which frees
    /// every tracked cursor on the transaction (mdb.c:3202-3227), so a write
    /// cursor's pointer is dangling from the moment its transaction ends and
    /// renewing it reads freed memory.
    ///
    /// So renew a cursor whose old transaction was read-only, or one whose old
    /// transaction is still live. This facade does not refuse the other case:
    /// it cannot know what the C did to the allocation, and turning away a call
    /// upstream performs would be worse than stating the boundary.
    pub fn renew(self: *Cursor, txn: *Transaction) Error!void {
        const handle = self.handle orelse return error.CursorClosed;
        try check(c.mdb_cursor_renew(try txn.active(), handle));
        self.owner = txn;
        self.read_only = txn.read_only;
    }

    /// The transaction handle the C says this cursor belongs to
    /// (lmdb.h:1664-1668).

    /// Upstream answers `NULL` only for a null cursor (mdb.c:9806), and
    /// `live` has already refused one, so a null from a live cursor is
    /// `error.UnexpectedStatus` rather than a handle to pass on.
    pub fn transaction(self: *Cursor) Error!*c.MDB_txn {
        return c.mdb_cursor_txn(try self.live()) orelse error.UnexpectedStatus;
    }

    /// The database handle this cursor was opened on (lmdb.h:1670-1674).
    pub fn database(self: *Cursor) Error!c.MDB_dbi {
        return c.mdb_cursor_dbi(try self.live());
    }

    /// Whether the record the cursor is on is a named database's entry in the
    /// main database's catalogue rather than a user record (lmdb.h:1676-1681,
    /// mdb.c:9816-9826).
    ///
    /// This is how a walk of the main database distinguishes the records that
    /// name sub-databases from the records the application stored: those keys
    /// are the database names with their terminator, and those values are the
    /// sub-databases' `MDB_db` records in opaque bytes.
    ///
    /// Upstream reports the answer in the return value rather than in a status
    /// code: 1 for yes, 0 for no. A cursor that has never been positioned
    /// answers `false` rather than refusing, because `mdb_cursor_init` leaves
    /// `mc_snum` at zero and clears `C_INITIALIZED` (mdb.c:9673-9678), and
    /// `mdb_cursor_is_db` asks about that flag and `mc_snum` (mdb.c:9820).
    ///
    /// A cursor that has *run off the end* is a different case and does not
    /// answer `false`: running past the last record sets `C_EOF` and returns
    /// `MDB_NOTFOUND` while leaving `C_INITIALIZED` and the record index alone
    /// (mdb.c:7912-7917), so the cursor is still on the record it last reached
    /// and this still reports about it. `MDB_NOTFOUND` from the walk is what
    /// says the walk is over; this cannot be asked to say it.
    pub fn onNamedDatabase(self: *Cursor) Error!bool {
        return c.mdb_cursor_is_db(try self.live()) != 0;
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
        const handle = self.handle orelse return error.CursorClosed;
        _ = try self.owner.active();
        return handle;
    }
};

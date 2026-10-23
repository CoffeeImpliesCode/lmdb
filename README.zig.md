# Zig facade API

Facade calls return `Error!T` unless noted. `c` exposes the translated upstream API and raw status codes.

## Top-level

| Name | Contract |
|---|---|
| `runtime_loaded` | Compile-time flag; runtime-loaded calls require `load` first. |
| `LoadSource`, `LoadError` | Provider request and loader errors for the selected build mode. |
| `load(source)` | Runtime mode only; selects an explicit path or system name. Failed loads publish nothing and may be retried; a different request after success returns `ProviderMismatch`. A linked build panics if called. |
| `loadedSource()` | Returns the successful request, or `null` for linked builds. |
| `version()`, `strerror(rc)` | Return the library version and a message for a raw status. |
| `Mode`, `Size` | Upstream file-mode and unsigned size types. |

## Ownership and borrowed data

- `Environment` owns the native environment. Keep its wrapper at a stable address while transactions borrow it; close it after all children are released.
- `Transaction` owns its native handle and borrows the environment wrapper. `commit` spends the handle on success or failure; `abort` is idempotent.
- `Cursor` borrows its transaction wrapper. Close read cursors before commit, abort, reset, or environment close. The transaction frees write cursors.
- `Database` is a copyable slot index, not an owner. A newly opened slot is private until commit; `Environment.closeDatabase` releases a published slot for reuse.
- `Entry.key` and `Entry.value` usually borrow mapped bytes. They expire at the next update or transaction end; cursor results also expire when the cursor closes. `getBoth` and `getBothRange` return the caller's key slice.
- The facade does not copy returned data. Keep owner wrappers alive at stable addresses for the lifetime of their borrowed children.

## Environment

`OpenOptions` fields: `path: [:0]const u8`, `flags`, `mode` (default `0o664`), optional `map_size`, `max_dbs`, and `max_readers`. LMDB copies the path during open. Set limits before opening; set `max_dbs` again for each environment open.

- `Environment.create()` creates an unopened handle; configure it, then call `open(path, flags, mode)`. Open is one-shot, including failure; close a failed handle and create another.
- `Environment.init(options)` creates, configures, and opens; it closes the handle if setup fails. `close()` is idempotent.
- Configuration: `setMapSize`, `setMaxDbs`, `setMaxReaders`, `setPageSize`, `setUserContext`, `userContext`, `setAssertCallback`.
- Inspection: `maxReaders`, `maxKeySize`, `flags`, `setFlags`, `path`, `fileHandle`, `statistics`, `info`.
- Data and maintenance: `copy`, `copyWithOptions`, `copyToFileHandle`, `dumpSince`, `dumpSinceToFileHandle`, `loadSinceFromFileHandle`, `rollback`, `listReaders`, `clearStaleReaders`, `sync`.
- `beginReadOnly()` opens a snapshot; `beginWrite()` acquires LMDB's single writer slot. `closeDatabase(db)` returns a published slot for reuse.

## Transactions

- `beginNested()` creates a child; while it is live the parent may only commit or abort it. Child writes merge on commit and are discarded on abort.
- Database and record operations: `openDatabase(name, flags)`, `put`, `putNoOverwrite`, `putNoDupData`, `get`, `delete`, `deleteValue`, `openCursor`.
- Handle operations: `commit`, `abort`, `prepare`, `reset`, `renew`, `id`, `flags`, `environment`.
- Database operations: `statistics`, `databaseFlags`, `drop`, `setKeyComparator`, `setValueComparator`, `setRelocation`, `setRelocationContext`, `compareKeys`, `compareValues`.
- Named databases require `max_dbs` before environment open. Empty keys return `EmptyKey`; keys above LMDB's maximum return `BadValSize`.
- `reset()` accepts only non-nested read-only transactions and invalidates borrowed bytes. Only `renew()` or `abort()` is valid while reset; `renew()` takes the newest committed snapshot.

## Cursors

`first`, `last`, `next`, `prev`, `nextNoDup`, `prevNoDup`, `current`, `set`, `setRange`, `firstDup`, `lastDup`, `nextDup`, `prevDup`, `getBoth`, `getBothRange`, `putCurrent`, `deleteCurrent`, `deleteAllDuplicates`, `count`, `renew`, `transaction`, `database`, and `onNamedDatabase` are available. Duplicate-specific operations require a `DUPSORT` database. `close()` is idempotent; traversal after close returns `CursorClosed`.

`CursorOp` names the 15 wrapped C operations: `first`, `first_dup`, `get_both`, `get_both_range`, `get_current`, `last`, `last_dup`, `next`, `next_dup`, `next_nodup`, `prev`, `prev_dup`, `prev_nodup`, `set_key`, `set_range`. Page-at-a-time duplicate operations remain available through `c` because they return item counts, not byte slices.

## Flags and data types

- `EnvFlags`: `fixedmap`, `nosubdir`, `rdonly`, `writemap`, `nometasync`, `nosync`, `mapasync`, `nordahead`, `nomeminit`, `notls`, `nolock`, `prevsnapshot`, `remap_chunks`. Fields default to `false`; `bits()` maps each field to its named LMDB constant. `nolock` disables locking and requires caller-side serialization.
- `DbFlags`: `reversekey`, `dupsort`, `integerkey`, `dupfixed`, `integerdup`, `reversedup`, `create`; `bits()` maps them to LMDB constants.
- `CopyFlags.compact` omits free pages from a copy. `CursorOp` uses the translated C enum width.
- `Entry`, `Version`, `Statistics`, and `EnvInfo` provide facade-shaped results. `FileHandle` is `int` on POSIX and an opaque pointer on Windows.
- Callback aliases: `KeyComparator`, `RelocationCallback`, `AssertCallback`, and `MessageCallback`. `Encryption` is available when the selected header declares encryption APIs; otherwise it is `void`.

## Errors

`Error` combines LMDB statuses, target OS errors, and facade handle-state errors. It includes `KeyExists`, `NotFound`, `PageNotFound`, `Corrupted`, `Panic`, `VersionMismatch`, `Invalid`, `MapFull`, `DbsFull`, `ReadersFull`, `TlsFull`, `TxnFull`, `CursorFull`, `PageFull`, `MapResized`, `Incompatible`, `BadRslot`, `BadTxn`, `BadValSize`, `BadDbi`, `Problem`, `BadChecksum`, `CryptoFail`, `EnvEncryption`, `TxnPending`, `CantRollback`, `DbisBusy`, `ShortWrite`, `EnvBusy`, `IsReadOnly`, `AddrBusy`, `AccessDenied`, `InvalidArgument`, `OutOfMemory`, `NoSpaceLeft`, `InputOutput`, `NoSuchFileOrDirectory`, `WouldBlock`, `ReadOnlyFileSystem`, `TooManyOpenFiles`, `SharingViolation`, `UnexpectedStatus`, `EnvironmentClosed`, `EnvironmentAlreadyOpen`, `OpenFailed`, `TransactionClosed`, `TransactionReset`, `TransactionNotResettable`, `TransactionNotReset`, `CursorClosed`, and `EmptyKey`.

Unknown native statuses map to `UnexpectedStatus`; use `c` when the raw status value is needed.

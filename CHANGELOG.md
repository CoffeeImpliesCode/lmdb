# Changelog

Fork-only changes relative to LMDB 1.0.1 (`LMDB_1.0.1`, commit `6f0a32496a5aadee15a5e5103c479bd3355ae273`); upstream history remains in `libraries/liblmdb/CHANGES`.

- 2026-10-04 — `listReaders` returns `mdb_reader_list` callback values unchanged; callback results are not LMDB status codes.
- 2026-10-04 — `flake.lock` pins the `flake.nix` nixpkgs revision and ships with the source package.
- 2026-10-04 — `devenv` tasks run from the SDK root and keep Zig caches, scratch data, and install outputs outside the source tree.
- 2026-10-03 — Read cursors must close before transaction commit, abort, or reset; write cursors remain transaction-owned; closed cursor operations are rejected.
- 2026-10-03 — Commit spends its transaction handle before calling C; later commit returns `TransactionClosed`, abort is a no-op, and invalid reset returns `TransactionNotResettable`.
- 2026-10-03 — Facade wrappers keep stable addresses, cursor copies preserve aliasing, and successful null-result statuses are retained.
- Added a fork-scoped OLDAP-2.8 grant for fork-authored files; legal records distinguish upstream terms and third-party exceptions by path.
- Nix provides static and shared outputs with generated `lmdb.pc`, upstream tools and man pages, and legal notices; `devenv` provides a pinned development shell.
- `.paths` ships all 42 files under `libraries/liblmdb`; `UPSTREAM.sha256` covers them and the independent corpus.
- `OpenOptions.max_dbs` is passed on every environment-open path, including read-only reopen.
- Cursor keys mirror C outputs: `getBoth`/`getBothRange` return the search key, `set` returns the stored key, and `firstDup`/`lastDup` can return an empty key.
- Empty keys fail early with `EmptyKey`; oversized keys use upstream `BadValSize`; empty values remain valid.
- `Environment.open` is one-shot: reopening after success returns `EnvironmentAlreadyOpen`; failed native opens return `OpenFailed`. Typed errors also cover read-only filesystems, too many open files, and Windows sharing violations.
- POSIX and Windows status values use separate mappings; unknown native values remain `UnexpectedStatus`.
- `Database` wraps an `MDB_dbi` value; release it with `Environment.closeDatabase`, not `deinit`.
- Lock implementation is selected by OS; targets without a compatible shared-lock backend, including `wasm32-wasi`, are refused.
- `-fsys=lmdb` selects the installed header and library through forced pkg-config resolution.
- The archive includes upstream's `mdb.c`, `midl.c`, and `module.c`; Linux links `dl`, Windows links `kernel32`, and macOS needs no additional loader library.
- Added the Zig 0.16 package for LMDB 1.0.1 with a typed facade, smoke, interoperability, and external-consumer programs.

# lmdb — the Lightning Memory-Mapped Database, built and wrapped in Zig

This package compiles LMDB **1.0.1** — upstream's own C, byte for byte, from the
`libraries/liblmdb` tree in this repository — and publishes a Zig facade over the
translated `libraries/liblmdb/lmdb.h`. The whole library is three translation
units, the three `liblmdb.a` is made of upstream: `mdb.c`, `midl.c` and
`module.c` (`liblmdb/Makefile:87-88`). `zig build interop` additionally builds
upstream's own `mdb_dump` from this tree and compares what it prints against
what this package wrote, so the fixture is a reference reader rather than the
facade agreeing with itself.

`mdb_dump` is the **only** upstream tool unit this build compiles, and it links
**this package's own archive** — not a second copy of any core unit beside the
tool. Upstream's other four tools (`mdb_stat`, `mdb_copy`, `mdb_load`,
`mdb_drop`), its test programs, its man pages, its `Makefile`, `Doxyfile` and
release notes and its two legal files are carried and **shipped**: `.paths`
names the whole `libraries/liblmdb` directory, so a dependent receives
upstream's complete source rather than only the part this build compiles. See
[Integrity](#integrity).

No database engine is reimplemented. No table is regenerated, no upstream source
is patched, no upstream Makefile is run, and nothing is downloaded at build
time. `pub const c` keeps the whole translated C surface — `mdb_stat`,
`mdb_env_copy`, `mdb_drop`, `mdb_env_set_flags`, the encryption entry points —
reachable for anything the facade does not name.

## Requirements

Zig **0.16.0**, the real compiler. This package calls
`b.systemIntegrationOption`, `b.addTranslateC` and the `std.Io` interfaces of
that release; nothing here compiles on an earlier one. In the workspace that
grew this package a bare `zig` on `PATH` is a version dispatcher, so the pinned
binary is named explicitly on gate command lines.

A **C library** is required, and a **shared-lock backend**:

* `mdb.c` offers four shared-lock implementations (`mdb.c:175-231`): the native
  Win32 mutex, a process-shared POSIX mutex, a POSIX named semaphore and a SysV
  semaphore. This build names one per operating system and refuses every other.
* Linux uses the robust POSIX mutex, macOS the named semaphore, Windows the
  Win32 mutex. The choice is not cosmetic: it changes `MDB_LOCK_TYPE`
  (`mdb.c:965-981`), which is recorded in the lock file, so an environment
  opened under one backend cannot be opened by a build that chose another.
* **`wasm32-wasi` is refused, not built**, and the reason is measured rather than
  assumed. Its libc supplies none of the four backends, and a probe compiled
  against the **real** WASI SDK 34 sysroot — `_WASI_EMULATED_MMAN` defined,
  linked against `libwasi-emulated-mman.a`, executed on Wasmtime 46.0.3 — prints
  `pshared=0 robust=28 second_snapshot=31 persisted=31`. So the header and the
  function are both **present**: `mmap` is emulated as a `malloc`/`pread`
  snapshot, and the `0x52` written through a `MAP_SHARED` mapping is neither
  visible to a second mapping of the same file (`0x31`) nor still in the file
  after `munmap` (`0x31`); `msync` is not in that archive and an attempted call
  to it failed to link; and `PTHREAD_PROCESS_SHARED` is **accepted** while
  `PTHREAD_MUTEX_ROBUST` is rejected with `EINVAL`. There is therefore no shared
  mapping, no write-back and no independent-process robust lock — the three
  things LMDB is — and that is the refusal. `MDB_NOLOCK` is not a substitute: it
  is a runtime flag that drops the reader liveness table and the cross-process
  write lock, so building against it would produce a smaller and weaker library
  with different behaviour after a crash. `zig build check -Dtarget=wasm32-wasi`
  fails at **configure time** with the reason printed; it is not a warning and
  not a skipped target. The refusal is this package's own guard and surfaces as
  `error.UnsupportedTarget` (`build.zig:376`, reached from `build.zig:857`): the
  C compiler is never reached, so nothing upstream was compiled for WASI and
  **no result is claimed for one**. The probe above is a foreign program linked
  against the SDK's own emulated mman, not upstream's `mdb.c`
  (`local://foundation-portability-wasi-lmdb-sdk34-corrected-proof.json`). The
  refusal itself is unchanged; only its printed reason was corrected to say what
  was measured, and that corrected wording is `PENDING-VERIFICATION` — the last
  observed run printed the earlier text. The one string CI asserts,
  `there is no shared-lock backend`, is in both wordings.

The package has no Zig dependency and fetches nothing. That is a claim about
the **build**: a dependent's `zig fetch` of this package is packaging, not a
build-time dependency, and it has gates of its own in
[Verification status](#verification-status).

## The six commands

| # | Command | What it decides |
|---|---|---|
| 1 | `zig build` | Compiles the three-unit core and translates `translate.h` for the requested target, installs `zig-out/lib/liblmdb.a` and `zig-out/include/lmdb.h`, and compiles `smoke.zig`. It does **not** run the smoke program |
| 2 | `zig build test` | Builds **and runs** the 25 behavioural tests in `tests.zig`, in the requested `-Doptimize` mode |
| 3 | `zig build test -Doptimize=ReleaseSafe` | The same 25 in the mode a shipped consumer is most likely to use. Debug is where the C core is built with checks on; a binding that passes in one and fails in the other has a defect the other mode hides |
| 4 | `zig build smoke` | Builds and runs the deterministic smoke program. It fails non-zero, naming the disagreeing observation on stderr, so this is a check and not a demo that always succeeds |
| 5 | `zig build check` | Compiles the C core, the facade, `tests.zig`, `smoke.zig` **and** `testdata/interop.zig` for every supported target, **without running any of them**, and re-derives at configure time that `wasm32-wasi` is the refused row |
| 6 | `zig build check -Dtarget=wasm32-wasi` | **Must fail**, and must fail with `there is no shared-lock backend` and the typed error `error.UnsupportedTarget`. A zero exit here fails the CI job as loudly as a wrong reason does, and so does a failure carrying a compiler diagnostic instead — that would mean the target stopped being refused |

`-Dtarget=` and `-Doptimize=` are the ordinary standard options, `-fsys=lmdb` is
the system-library mode below. The optimisation mode is threaded verbatim into
the C core, the facade, the test root, the smoke root, the interoperability
program, the cross matrix and the nested consumer build; there is no
Debug-to-Release mapping anywhere and no Zig 0.16 call-convention workaround is
applied (LMDB's widest public prototype takes five parameters, so the seven-or-
more boundary another fork in this workspace hit is outside this surface).

## The rest of the gate set

| Command | What it decides |
|---|---|
| `zig build interop` | The primary fixture. Builds `mdb_dump` from `libraries/liblmdb/mdb_dump.c` linked against **this package's archive**, runs `testdata/interop.zig` over it and compares the body of `mdb_dump -p` with `testdata/corpus.txt` byte for byte |
| `zig build consumer` | Runs the separate package in `consumer/` as its own `zig build`, against `dep.module("lmdb")` and nothing else |
| `cd consumer && zig build run` | The same proof from inside the consumer package |
| `zig build check -Dtarget=<triple>` | Row 5 for one named target, so a failure is attributable to a target rather than to the sweep |
| `zig build -fsys=lmdb` | Links and translates an **installed** liblmdb instead of compiling this repository's copy |
| `sha256sum -c UPSTREAM.sha256` | The integrity record: all 43 digests, and every file behind them ships. See [Integrity](#integrity) |

### Cross-target checks: six commands, no target skipped

```
zig build check -Dtarget=x86_64-linux-gnu     -j8 --summary all
zig build check -Dtarget=aarch64-linux-gnu    -j8 --summary all
zig build check -Dtarget=aarch64-macos-none   -j8 --summary all
zig build check -Dtarget=x86_64-windows-gnu   -j8 --summary all
zig build check -Dtarget=riscv64-linux-gnu    -j8 --summary all
zig build check -Dtarget=wasm32-wasi          -j8 --summary all   # must fail, with the reason
```

The first five compile; the sixth is a refusal. `check` never executes a foreign
binary, so every result is compile evidence for that target and not a claim that
a cross-built program ran.

**Observed, twice.** On the earlier tree all five compiled with
`Build Summary: 7/7 steps succeeded` each — the C core, the facade, `tests.zig`,
`smoke.zig` and `testdata/interop.zig` for that target, which is five of six rows
of the matrix. Re-run against the current tree after `CHANGELOG.md` §28, all five
report **`8/8 steps succeeded`** instead: the eighth step is the new
`preprocess lmdb.h` that now runs under `translate-c`, so the step count moved and
the compile evidence did not. The sixth refused both times, printed the reason and
stopped with `error.UnsupportedTarget` at `build.zig:376:5`. The receipts are in
[Verification status](#verification-status), and the guard it exercised is
described in [Requirements](#requirements).

### The full platform matrix, and what it will and will not say about this package

The cross gate for this package is the published 53-platform `cross-test`
matrix, driven through the settings-only profile at the package root:

```
cross-test                      # reads ./cross-test.profile.sh
cross-test --no-profile         # the same matrix, discovered by the harness
```

`cross-test.profile.sh` sets exactly one variable, `CROSS_BUILD_STEP=test`, so
each cell is `zig build test -Dtarget=<target>`. `test` is already real work in
this build graph — `build.zig:778` is an `addTest` over the facade and
`build.zig:788` is its `addRunArtifact` — so a cell compiles the C core, the
translated `lmdb.h`, the facade and the 25-case test binary, and then either
executes it on a detected runner or leaves the cell **build-only**. The profile
deliberately does not narrow the matrix, install an artifact hook, choose a
runner, add `-Doptimize` or name a host path, so runner policy stays with the
harness and a target with no detected runner is never counted as a pass. It is
listed in `build.zig.zon` `.paths` because it is Bash the harness sources, not
documentation.

**What the matrix does for this package, from the final run.** `lockBackend`
names a shared-lock backend for Linux, macOS and Windows, and `build()` refuses
every other operating system at configure time with the reason printed. Run
`20261002-061717-7494-31221` (`zig build test -Dtarget=<target>` per cell,
`--build-timeout 1800`, `--test-timeout 300s`, `bookkeeping_failure: false`,
`local://foundation-cross-test-final-lmdb.json`) distributed 53 cells as:

| Cells | What happened | Why |
|---|---|---|
| 1 `x86_64-linux` | build and run, **25/25 green** — `Build Summary: 7/7 steps succeeded; 25/25 tests passed` | the host cell, executed natively |
| 19 foreign Linux | build and run, and **all 25 tests fail on each**: `run test lmdb-tests 0 pass, 25 fail (25 total)`, `Build Summary: 5/7 steps succeeded (1 failed); 0/25 tests passed (25 failed)` | `lockBackend`'s `.linux` arm names `MDB_USE_POSIX_MUTEX` + `MDB_USE_ROBUST`; the harness runs each of the 19 under a QEMU user-mode runner. Every trace is the same one: `Environment.init` → `open` → `mdb_env_open` → `check` → `positiveStatus` → `posixStatus`, whose unmatched positive code becomes `error.UnexpectedStatus`. **Each of the 19 has since been run on its own** against one probe that asks its runner directly: the raw `SYS_get_robust_list` call and the robust process-shared mutex initialisation both return `ENOSYS` in all nineteen — `38` on fifteen of the cells and `89` on the four MIPS cells, where that is `ENOSYS`'s own number. See [the nineteen probed cells](#verification-status) |
| 2 macOS, 4 Windows | build; **no runner on this host**, so build-only | `lockBackend`'s `.macos` and `.windows` arms; the harness detects no Wine and no macOS runtime here, and that is reported as `run=unavailable`, exit 0, rather than as a pass |
| 6 FreeBSD, 9 NetBSD, 9 OpenBSD | build. **No runner on this host**, so build-only | `lockBackend` gives them an empty macro list and `mdb.c:175-231` chooses: FreeBSD's own arm (`:175-179`, POSIX mutex + robust) on `__FreeBSD_version=1400500`, SysV semaphores on NetBSD and OpenBSD, which predefine `BSD` (`:183-194`). Observed by `zig cc -target TARGET -E -dM libraries/liblmdb/mdb.c`, exit 0 for all four (`local://foundation-cross-test-lmdb-target-macros.json`) |
| 2 macCatalyst | build; no runner on this host, so build-only | joins the macOS arm: `maccatalyst` is a Darwin target and predefines `__APPLE__`, so `MDB_USE_POSIX_SEM` is the backend `mdb.c:184-186` selects, and `dl*` resolves out of libSystem as it does on macOS |
| 1 `wasm32-wasi` | **refused at configure**, `build=fail`, exit 1, `run=not_run`, reason printed | there is no shared-lock backend, and the SDK 34 probe shows why the emulated pieces do not supply one: `PTHREAD_PROCESS_SHARED` is accepted and the robust attribute is rejected with `EINVAL`, while `mmap` is a `malloc`/`pread` snapshot — a `MAP_SHARED` write reaches neither a second mapping nor the file after `munmap` — and `msync` is absent from that archive. The refusal text says so, and the build stops in `refuseTarget` with `error.UnsupportedTarget` (`build.zig:376:5`), before any C is compiled. **No LMDB C is compiled for WASI by the SDK**: that probe is a foreign program linked against the SDK's own emulated mman, not upstream's `mdb.c` |

So **52 of the 53 cells reach the compiler**, which is what this section
previously asserted from the source alone and what the run has now observed.
Thirty-two of those 52 are build-only, and build-only is not a pass.

**Those 26 cells were refused by this fork, not by upstream, and the refusal is
now gone — and gone in a run, not only on paper.** Before: `cross-test` run
`20261002-040728-7930-27044` over `x86_64-freebsd` — exit 1, `build=fail`,
`run=not_run`, `reason=build_failed`,
31.39 s, `local://foundation-cross-test-before-lmdb-bsd.log`, with no C
translation unit compiled because the refusal happened in `build.zig` at
configure. `mdb.c:175-231` does have arms for the BSDs and Apple, and every
system header the core can reach outside its `_WIN32`, `__sun`/`__ANDROID__`,
`__mips && __linux` and `USE_VALGRIND` guards is present in Zig's bundled
`generic-freebsd`, `generic-netbsd`, `generic-openbsd` and `any-darwin-any`
include sets. What could not be read out of Zig's own source was which macros
clang predefines, and that mattered: `mdb.c:187-189` adds `MDB_USE_SYSV_SEM`
whenever `BSD` is defined and `mdb.c:223-225` adds `MDB_USE_POSIX_MUTEX` whenever
no arm set a semaphore, so naming the wrong one fails the ambiguity check at
`mdb.c:228-231`. The predefines are now observed and the fix is to name
**nothing**: an empty macro list leaves `mdb.c` its own choice, and because
`MDB_LOCK_TYPE` (mdb.c:965-981) is written into the lock file and checked on
open (`:6119`, `:6132`), that is exactly the type a native LMDB built on the
platform with the same libc headers would record. The loader needed the same
answer and has the same primary documentation behind it — FreeBSD's `dlopen(3)`
needs no libdl, NetBSD's is automatic and not a library to link, OpenBSD's is
the runtime-linker interface. See `FORK-NOTES.md` decision 12.

**The translator needed three repairs before those cells would build, and all
three are recorded in `CHANGELOG.md` §28.** The BSD and macCatalyst build-only
cells in the final run are the result: real C-header preprocessing for the
NetBSD and `mips64`/`mips64el`-OpenBSD cells, `enum(c.MDB_cursor_op)` for
`hexagon-linux`, and the compiler-owned `__int128` bridge for `aarch64-netbsd`
and `aarch64_be-netbsd`. None of them changed an upstream byte, and none of
them changed a lock backend.

**Nothing under `libraries/liblmdb/` is affected by any of this.** The archive
is still `mdb.c`, `midl.c` and `module.c`, `module.c` included, because it is
upstream's (`liblmdb/Makefile:87-88`) and upstream's own `mdb_dump` links it
unconditionally. No WASI filesystem or thread stub was introduced anywhere, and
the WASI cell stays a refusal rather than a build.

**Every cell of this matrix has now been attempted, and none of them is a
blanket green.** 1 pass, 32 build-only — attempted and not executed — 19 foreign
Linux run-failures with all 25 tests failing on each, and 1 configure refusal.
The earlier receipts in
[Verification status](#verification-status) from `zig build test`,
`zig build check`, `zig build smoke`, `zig build interop` and `zig build
consumer` remain; `cross-test.profile.sh`'s own syntax and its `--list` with and
without the profile have been run too, and all three exit 0. **All nineteen of
the foreign Linux cells have now been observed separately**, which supersedes
the earlier reading of this paragraph rather than repeating it: nineteen cells
failing identically was one observation about a signature and one about a
cause, and it is now nineteen runs of the runners themselves. In every one of
them the raw `SYS_get_robust_list` call returns `-1` with `ENOSYS` and the
robust process-shared mutex fails to initialise with the same code: `38` on
fifteen of the cells and `89` on `mips-linux`, `mipsel-linux`, `mips64-linux`
and `mips64el-linux`, where `ENOSYS` is 89 — so `mdb_env_open` returns it
unchanged and every test on every one of those cells reports
`error.UnexpectedStatus`. The same probe built for `x86_64-linux` and run
natively on this host's own kernel reports `get_robust_list rc=0 errno=0
length=24`, `robust shared mutex init rc=0` and `lock after owner death rc=130
expected=130`. That control is the evidence for `x86_64-linux` on this host and
for that probe; it is not a claim about any other architecture's kernel, and the
19 failures are not evidence about theirs either. **What is missing is a
provider that preserves the semantics, not a runner and not a diagnosis:**
those 19 cells do run here — on this host's own `qemu-*` runners — and they
fail there. Running them against a kernel that owns the robust list needs a
guest kernel and root filesystem per architecture, or hardware to run them on,
and none of those is on this host: the installed full-system emulators are
`qemu-system-i386` and `qemu-system-x86_64` only, and no other hardware. Those
runners cannot stand in for that, because upstream QEMU linux-user answers
`ENOSYS` for both robust-list syscalls unconditionally — no option, flag
or environment variable changes it: there is no toggle to turn on. None of that
changes what the package ships: no `MDB_NOLOCK`, no `MDB_USE_ROBUST=0`, and no
stub that answers a capability probe it cannot honour.

## Using it

### As a dependency

`build.zig.zon` of the dependent:

```zig
.dependencies = .{
    .lmdb = .{ .url = "…/lmdb-1.0.1.tar.gz", .hash = "…" },
},
```

`build.zig` of the dependent — the module carries the compiled archive and the
translated `c` import already bound, so there is no include directory, no `-L`,
no system library and no second module:

```zig
const dep = b.dependency("lmdb", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("lmdb", dep.module("lmdb"));
```

`consumer/` in this repository is exactly that, against a relative path, and it
exists so the claim is checked by a package that did not write this one.

**The two placeholders above are still placeholders.** What has been observed is
the `.path` form: `consumer/` was built and run against **this** tree after the
§28 repairs (exit 0, `7/7 steps succeeded`), and it was also built and run against
a copy materialised out of `.paths` — though that second observation predates
those repairs, so the two copies are not the same bytes. What has **not** been
observed is the `.url` form: this package has not been published, no archive has
been fetched over the network, and no registry entry exists, so the `.hash` is
not known and is not guessed here.

### A complete example

```zig
const std = @import("std");
const lmdb = @import("lmdb");

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `mdb_env_open` is handed an absolute path and does NOT create the
    // directory: there is no mkdir anywhere in mdb.c.
    const root = try std.Io.Dir.cwd().createDirPathOpen(io, "/tmp/example", .{});
    defer root.close(io);
    const path = try std.Io.Dir.allocatePath(io, &root, gpa, "db");
    defer gpa.free(path);

    // `.max_dbs` is not on disk. Every open of this directory must ask for the
    // named slot again, including a read-only reopen.
    var env = try lmdb.Environment.init(.{ .path = path, .max_dbs = 2 });
    defer env.close();

    {
        var txn = try env.beginWrite();
        defer txn.abort();                 // a no-op after commit
        const named = try txn.openDatabase("sorted", .{ .dupsort = true, .create = true });
        try txn.put(named, "key", "alpha");
        try txn.commit();                 // releases the handle on every path
    }

    {
        var txn = try env.beginReadOnly();
        defer txn.abort();
        const db = try txn.openDatabase(null, .{});

        var cursor = try txn.openCursor(db);
        defer cursor.close();             // a read-only cursor: close it
        var entry = try cursor.first();   // borrowed from the map, not a copy
        std.debug.print("{s}={s}\n", .{ entry.key, entry.value });
    }
}
```

## The API

### Handles at a glance

| Handle | Zig type | Created by | Released by |
|---|---|---|---|
| `MDB_env` | `Environment` | `Environment.create` / `Environment.init` | `Environment.close` |
| `MDB_txn` | `Transaction` | `beginWrite` / `beginReadOnly` / `beginNested` | `Transaction.commit` **or** `Transaction.abort`, whichever comes first |
| `MDB_dbi` | `Database` | `Transaction.openDatabase` | `Environment.closeDatabase`, optionally |
| `MDB_cursor` | `Cursor` | `Transaction.openCursor` | a **read-only** transaction's cursor: `Cursor.close`; a **write** transaction's cursor: the transaction itself |

### Environment

| Name | What it is |
|---|---|
| `Environment.init(options)` | create, configure and open in one call. Setters run in the order the header pairs them: `max_dbs` and `max_readers`, which `mdb_env_open` freezes, then `map_size`. If the open fails the handle is released |
| `Environment.create()` | an unopened environment, for configuration that has to happen between create and open |
| `open(path, flags, mode)` | opens a `create`d handle. **Once per handle**: `error.EnvironmentAlreadyOpen` after a success, `error.OpenFailed` after a failure |
| `close()` | releases everything under it. Idempotent |
| `setMapSize(bytes)` | the map, and so the maximum database size. Zero adopts a size another process persisted — the documented answer to `error.MapResized` (`lmdb.h:976-979`) |
| `setMaxDbs(count)` / `setMaxReaders(count)` | refused once the environment is open — both check `env->me_map` (`mdb.c:5218-5219`, `:5228`); `setMaxReaders(0)` is refused at any time |
| `maxReaders()` | the slot count the environment actually has, read from the handle |
| `sync(force)` | flush the data buffers. `force` performs the flush that `MDB_NOSYNC` and `MDB_MAPASYNC` deferred |
| `closeDatabase(db)` | returns a slot. Not mutex protected; never required |
| `beginReadOnly()` / `beginWrite()` | a read-only transaction sees the last committed snapshot; only one write transaction may be live per environment |

### Transaction

| Name | What it is |
|---|---|
| `beginNested()` | a child transaction. While it is live the parent may do nothing but commit or abort it |
| `openDatabase(name, flags)` | `name == null` is the one unnamed database. A name needs `max_dbs`, on **every** open of the environment |
| `put` / `putNoOverwrite` / `putNoDupData` | store, store-if-absent, store-duplicate-if-absent |
| `get(db, key)` | the value, borrowed from the map. In a `DUPSORT` database this is the first value for the key |
| `delete` / `deleteValue` | delete a key with all its duplicates; delete one duplicate |
| `openCursor(db)` | a cursor that borrows this transaction |
| `commit()` | commits and **releases**, on success and on failure alike. The handle is cleared before the C call, so a `defer`red `abort` after it is a no-op |
| `abort()` | abandons and releases. Safe after `commit` and safe twice |
| `reset()` | releases a read-only transaction's snapshot but keeps the handle. **Read-only and non-nested only**, else `error.TransactionNotResettable` — upstream returns silently here (`mdb.c:3816-3826`) and the facade names the mistake |
| `renew()` | takes a fresh snapshot on a handle `reset` released. The new snapshot is the newest committed state, not the old one |
| `open_attempted`, `opened` | the two pieces of state that make `open` one-shot; see [Status and errors](#status-and-errors) |

### Cursor

| Name | What it is |
|---|---|
| `first` / `last` | first and last item in collation order |
| `next` / `prev` | step one item, crossing into the neighbouring key |
| `nextNoDup` / `prevNoDup` | step one **key**, skipping that key's remaining duplicates |
| `current` | the item the cursor is on, without moving. `EINVAL` on a cursor that was never positioned — `error.InvalidArgument`, not `NotFound` (`mdb.c:8341-8343`) |
| `set(key)` | `MDB_SET_KEY`, so the key that comes back is the stored one. `MDB_SET` leaves the caller's key object untouched (`lmdb.h:1686-1688`) |
| `setRange(key)` | the first key at or after `key` |
| `firstDup` / `lastDup` / `nextDup` / `prevDup` | `DUPSORT` only. `firstDup` on an unpositioned cursor is `EINVAL`; on a database without duplicates `MDB_INCOMPATIBLE` |
| `getBoth(key, value)` / `getBothRange(key, value)` | `DUPSORT` only. `Entry.key` here is **the caller's own slice handed back**, not bytes out of the map: upstream rewrites the key only for `MDB_SET_RANGE` and `MDB_SET_KEY` (`mdb.c:8176-8180`, `:8225-8227`) |
| `putCurrent(key, value)` / `deleteCurrent()` / `deleteAllDuplicates()` | write or delete at the cursor. The cursor stays usable after a delete |
| `count()` | duplicates of the current key. `DUPSORT` only — upstream allocates the sub-cursor only for one (`mdb.c:9707-9708`) |
| `close()` | see [Lifetimes](#lifetimes-and-ownership-in-one-place). Idempotent; any traversal afterwards is `error.CursorClosed` |

`CursorOp` names the fifteen `mdb_cursor_get` operations of `lmdb.h:436-465`.
`MDB_GET_MULTIPLE` and its relatives are deliberately **not** wrapped: they
return a *count of items* in the data value rather than bytes, which a
`[]const u8` cannot represent without lying. They are reachable through
`pub const c`.

### Database

`Database` is a value — an `unsigned int` index into the environment's slot
table (`lmdb.h:280-281`), not a pointer. It has no `deinit`. It stays valid for
the life of the environment, and releasing its slot with
`Environment.closeDatabase` is optional.

## Lifetimes and ownership, in one place

These are upstream's rules, read out of `lmdb.h` and `mdb.c`, and the facade
enforces each one:

| Rule | What it is | Where |
|---|---|---|
| The environment owns nothing above it | Every transaction, database handle and cursor must be closed before `close()` | `lmdb.h:892-897` |
| **A successful commit invalidates the transaction handle** | `mdb_txn_commit` releases it on success (`mdb_txn_end(… MDB_END_FREE)`) and aborts it on every failure branch, so a handle is spent either way | `mdb.c:4629-4637` |
| An aborted transaction handle is spent too | Which is why `commit` and `abort` clear the handle *before* calling the C | — |
| **A read-only transaction never frees its cursors** | They "must be closed explicitly, before or after its transaction ends" — so `Cursor.close` calls `mdb_cursor_close` and is safe in either order | `lmdb.h:1620-1626` |
| **A write transaction frees its own cursors** | On commit (`mdb.c:4557`) and on abort (`mdb.c:3737-3738`); a nested transaction's are merged into the parent (`mdb.c:4439`). `Cursor.close` therefore does **not** call `mdb_cursor_close` for one — that would be a double free | — |
| `reset`/`renew` suspend the transaction | Between them the C has released the reader lock; only `renew` and `abort` are defined | `lmdb.h:1278-1281` |
| Nothing in this module closes a database behind your back | `closeDatabase` is the only release | `lmdb.h:1403-1418` |

This module never asks Zig for memory. Every allocation behind an `MDB_env`,
`MDB_txn` or `MDB_cursor` belongs to the C and is released by the matching C
call, and every path and database name is passed as the sentinel-terminated
slice the caller already holds — nothing is copied and nothing is allocated.

## Borrowed bytes

`mdb_get` and `mdb_cursor_get` return pointers **into the memory map**. The
header says exactly how long they live: "Values returned from the database are
valid only until a subsequent update operation, or the end of the transaction"
(`lmdb.h:1521-1526`). `Transaction.get` and every `Cursor` traversal therefore
return `[]const u8` borrowed from the map, never a copy. Writing through them is
undefined; in a read-only transaction it faults.

Two consequences a caller must hold on to: a borrow taken from a write
transaction dies at the next write in that transaction, and a borrow taken from
a cursor dies with the cursor. `Entry.key` from `getBoth`/`getBothRange` is the
exception and is the caller's own bytes.

## Status and errors

`mdb.c` returns one `int` for **two** families of code: its own negative
constants, and whatever the operating system reported. The negative constants
are the same on every target. The positive ones are **not**: `ErrCode()` is
`errno` everywhere but Windows (`mdb.c:501`), where it is `GetLastError()`
(`mdb.c:409`) — and a Windows build returns a few explicit `errno` constants of
its own besides (`mdb.c:6257`, `:6275`). So the switch is on the target, not on
the code, and each arm names a value a call site in `mdb.c` can actually
produce.

| Code | Error | Where it comes from |
|---|---|---|
| `MDB_KEYEXIST` | `KeyExists` | `putNoOverwrite` on a stored key; `putNoDupData` on a stored pair |
| `MDB_NOTFOUND` | `NotFound` | no such key, no such duplicate, no such name |
| `MDB_IS_READONLY` | `IsReadOnly` | a write in a read-only transaction. `mdb.c:8602-8603` answers this, whatever the header's older prose says about `EACCES` |
| `MDB_MAP_FULL` / `MDB_DBS_FULL` / `MDB_MAP_RESIZED` | `MapFull` / `DbsFull` / `MapResized` | the map, the slot table, and another process's resize |
| `MDB_BAD_VALSIZE` | `BadValSize` | a key or duplicate value above `maxkeysize` — and **a zero-length key**, reached by upstream at `mdb.c:8605` |
| `MDB_PANIC` | `Panic` | a fatal error earlier; the environment must be closed and reopened |
| `EACCES`, `EPERM` | `AccessDenied` | POSIX; on Windows `ERROR_ACCESS_DENIED` (5) |
| `EINVAL` | `InvalidArgument` | POSIX; also the CRT's `EINVAL` (22) on Windows, which `mdb.c:6257` returns itself |
| `ENOMEM` | `OutOfMemory` | POSIX; Windows `ERROR_NOT_ENOUGH_MEMORY` (8), from `VirtualAlloc` (`mdb.c:2876-2877`) |
| `ENOSPC` | `NoSpaceLeft` | POSIX; Windows `ERROR_DISK_FULL` (112), from `WriteFile` (`mdb.c:4232-4233`) |
| `EIO` | `InputOutput` | POSIX **only** |
| `ENOENT` | `NoSuchFileOrDirectory` | POSIX; Windows `ERROR_FILE_NOT_FOUND` (2) / `ERROR_PATH_NOT_FOUND` (3), from `CreateFileW` (`mdb.c:5414`, `:5419-5420`) |
| `EAGAIN`, `EDEADLK` | `WouldBlock` | POSIX; Windows `ERROR_LOCK_VIOLATION` (33), from `LockFileEx` (`mdb.c:5775-5776`, `:5813-5816`) |
| `EROFS` | `ReadOnlyFileSystem` | POSIX; `MDB_ERRCODE_ROFS` is `ERROR_WRITE_PROTECT` (19) on Windows (`mdb.c:5945`, `:5959-5961`) |
| `EMFILE`, `ENFILE` | `TooManyOpenFiles` | `open(2)` at `mdb.c:5416-5420`, or the named semaphore at `mdb.c:6146-6149`. Distinct from `OutOfMemory`: freeing memory does not help |
| — | `SharingViolation` | Windows `ERROR_SHARING_VIOLATION` (32) only. POSIX has no equivalent status — there the second writer blocks on the lock — so **no POSIX build can report it** |
| a positive code no table names | `UnexpectedStatus` | real and diagnosable through `pub const c`; reported distinctly rather than folded into a generic failure |
| — | `EmptyKey` | checked by the facade before the core is called. An **oversized** key is not: it travels and comes back as `BadValSize` |
| — | `EnvironmentClosed`, `EnvironmentAlreadyOpen`, `OpenFailed` | see below |
| — | `TransactionClosed`, `TransactionReset`, `TransactionNotResettable`, `TransactionNotReset` | see the transaction table |
| — | `CursorClosed` | a traversal after `Cursor.close` |

**The one-shot `open`, and why a *failed* open spends the handle too.**
Upstream's own guard against a second `mdb_env_open` is the data-file
descriptor, not a flag (`mdb.c:6257`), and `mdb_env_close_active` closes that
descriptor on the failure path without returning `me_fd` to
`INVALID_HANDLE_VALUE` (`mdb.c:6508`) — which happens in exactly one place,
`mdb_env_create` (`mdb.c:5029`). So a handle whose open **failed** is spent as
thoroughly as one whose open succeeded. `Environment.open` records the
**attempt**, before the call, so a retry reports `error.OpenFailed` instead of
upstream's misleading `EINVAL`. There is no retry on the same handle: release it
with `close` and create another.

## Flags

`EnvFlags` and `DbFlags` are packed structs of booleans that default to `false`,
so `.{}` and any partial literal are valid. **The bits are not written out by
position**: the constants are not contiguous, and a struct laid out in
declaration order would silently set the wrong ones. Each `bits()` names its own
constant.

| Env flag | Meaning |
|---|---|
| `fixedmap` | `MDB_FIXEDMAP`. Experimental; must be set at create and is remembered in the environment |
| `nosubdir` | `MDB_NOSUBDIR`. The path is the data file itself, not a directory holding `data.mdb` and `lock.mdb` |
| `rdonly` | `MDB_RDONLY`. The lock file is still written, except on a read-only filesystem where it does not lock at all |
| `writemap` | `MDB_WRITEMAP`. Write through the map. Incompatible with nested transactions |
| `nometasync`, `nosync`, `mapasync` | `MDB_NOMETASYNC`, `MDB_NOSYNC`, `MDB_MAPASYNC`. `sync(true)` performs the flush these defer |
| `nordahead` | `MDB_NORDAHEAD` |
| `nomeminit` | `MDB_NOMEMINIT` |
| `notls` | `MDB_NOTLS`. Tie reader slots to transactions, so a reader can span threads |
| `nolock` | `MDB_NOLOCK`. The caller serialises. This is a runtime weakening, not a build configuration, and this package never builds against it |
| `prevsnapshot` | `MDB_PREVSNAPSHOT` |
| `remap_chunks` | `MDB_REMAP_CHUNKS` |

| Db flag | Meaning |
|---|---|
| `reversekey` | `MDB_REVERSEKEY`. Compare keys from their last byte backwards (`mdb.c:6676`) |
| `dupsort` | `MDB_DUPSORT`. A key may carry several values, kept in sorted order |
| `integerkey`, `dupfixed`, `integerdup`, `reversedup` | the four `DUPSORT`/key-shape modifiers |
| `create` | `MDB_CREATE`. Refused in a read-only transaction or environment |

The default collation is `mdb_cmp_memn` (`mdb.c:6659-6672`): `memcmp` over the
common prefix, **the shorter item first**. So `alpha` precedes `alphabet`,
`alpha` precedes `beta`, and `delta` precedes `gamma` — the shorter-prefix rule
first, then plain byte order.

## Bounds

| Bound | Where it comes from | What happens past it |
|---|---|---|
| key length 1 … `maxkeysize` | `lmdb.h:288`; `mdb_env_get_maxkeysize()` | `error.EmptyKey` at zero (checked here); `error.BadValSize` above the maximum (upstream's `MDB_BAD_VALSIZE`, `mdb.c:8605`) |
| value length 0 … | `lmdb.h:291-292`: "Other data items can in theory be from 0 to 0xffffffff bytes long" | an empty **value** is stored and read back as itself |
| `DUPSORT` duplicate size | also `maxkeysize` | `error.BadValSize` |
| map size | `OpenOptions.map_size`, `setMapSize` | `error.MapFull` |
| named databases | `OpenOptions.max_dbs`, plus the two upstream reserves (`mdb.c:5220`; `CORE_DBS` is 2 at `mdb.c:1352`, and `mdb_env_create` sizes the table to it at `mdb.c:5028`) | `error.DbsFull` (`mdb.c:12318`) |
| reader slots | `setMaxReaders`; zero is refused | `error.ReadersFull` |
| dirty pages, open cursors | upstream's own per-transaction ceilings | `error.TxnFull`, `error.CursorFull` |

**`max_dbs` is not on disk.** Upstream holds the slot table in the handle
(`me_maxdbs`), not in the environment file, so **every** open of the same
directory has to set it again — a reopen that does not, including a read-only
one, refuses each named open with `MDB_DBS_FULL` even though the name is right
there in the catalogue.

## The environment directory and the lock file

An LMDB "database" is a **directory** holding `data.mdb` and `lock.mdb` (unless
`MDB_NOSUBDIR`). Three things about it are not obvious and are all enforced
here:

1. **`mdb_env_open` does not create the directory.** There is no `mkdir`
   anywhere in `mdb.c`. The caller creates it and hands the C an **absolute**
   path. All four of this package's scratch-creating entry points do exactly
   that.
2. **The path must be sentinel-terminated.** `OpenOptions.path` is
   `[:0]const u8` and is passed to the C unchanged.
3. **The lock file is real and is not optional.** It carries the lock-backend
   type this build chose (`mdb.c:965-981`) and the reader liveness table. Two
   processes that disagree about the backend cannot open the same environment.
   On a read-only *filesystem* under `MDB_RDONLY` upstream does not lock at all
   (`mdb.c:5947`, `:5959-5961`), which is why `ReadOnlyFileSystem` is its own
   error rather than `AccessDenied`.

The default `mode` is `0o664`, subject to the process umask. Upstream applies no
default of its own — `mode` reaches `open(2)` as given (`mdb.c:5416`) — so the
facade supplies the one upstream's own tools pass (`mdb_stat.c:138`,
`mdb_dump.c:282`, `mdb_load.c:421`, `mdb_drop.c:120`). It is ignored on Windows,
as upstream ignores it (`lmdb.h:716`).

## Scratch directories

`tests.zig`, `smoke.zig`, `testdata/interop.zig` and `consumer/src/main.zig` all
build their environment under the temporary root **the process was actually
started with**, read at runtime: `TMPDIR` on every platform, and `TEMP` then
`TMP` on Windows. A value that is relative is joined against the working
directory, so `mdb_env_open` always gets an absolute path; a host that names no
temporary root at all falls back to `.zig-cache/tmp`, the convention
`std.testing.tmpDir` uses.

Under that root each program creates **one** directory named from 12 random
bytes in base64url, and removes **only that directory** — on the normal path and
on every failure path after it was created. The root itself, its siblings and
every other file in it are untouched. No fixed host path is baked into any of
these sources, and `std.testing.tmpDir` is not used.

## Interoperability: the deterministic dump body

`zig build interop` builds `libraries/liblmdb/mdb_dump.c` — upstream's own
reader — against **this package's archive** and runs `testdata/interop.zig`
over it. The program writes `testdata/corpus.txt` through the facade, runs
`mdb_dump -p` over the same directory and compares what the two printed.

**What is compared is the body**, the bytes between `mdb_dump`'s `HEADER=END`
and `DATA=END` marker lines (`mdb_dump.c:136`, `:154`) — six records, compared
byte for byte. The header above those markers is deliberately excluded: it
carries the **memory-map address** (`mdb_dump.c:124-125`), which is the
kernel's choice and differs between two runs over the same bytes, so comparing
it would compare two addresses rather than two readers of one file.

The comparison is not escaped-string equality dressed up. `mdb_dump -p` renders
each key and value as `mdb_dump.c:65-84` renders it — a leading space, then
every byte, a printable byte other than `\` standing for itself and anything
else becoming `\xx` — and the program **refuses any corpus byte that `mdb_dump`
would escape** before it relies on the plain rendering. A corpus that grew a
non-printable byte fails that check instead of silently disagreeing.

`interop` is deliberately not part of `test` or `smoke`: those run on every
commit and this one builds and runs two programs. `zig build check` compiles
`testdata/interop.zig` for every matrix target and never runs it there — a
reference binary for a foreign target would have to be a foreign binary.

## Build modes

| Mode | What it links | What it translates |
|---|---|---|
| default | this repository's three C units | this repository's `lmdb.h`, via `-I libraries/liblmdb` |
| `-fsys=lmdb` | an installed `liblmdb`, by pkg-config name `lmdb` with `.force` | the **installed** `<lmdb.h>`, with no in-tree include path at all |
| `zig build check` | always this repository's | always this repository's |

The system mode adds no in-tree include path on purpose: `translate.h` includes
`<lmdb.h>` with **angle brackets**, so a stray `lmdb.h` beside the package root
cannot win, and in system mode the header that resolves is the one next to the
library being linked. Translating this repository's header against a
differently-versioned installed library would bind an ABI the library does not
have.

`.force`, not `.yes`: on a failed pkg-config query `.yes` falls back to a bare
`-llmdb` — a library that may not exist — and a translation that silently finds
no `lmdb.h` is worse than a build that stops.

**No run of `-fsys=lmdb` has happened in this workspace**, so no result is
claimed for it; it needs an installed liblmdb with its own matching header.

## Examples

`smoke.zig`, run by `zig build smoke`, walks one environment's whole lifecycle
in order — create, configure, open, write, commit, sync, close, reopen
read-only, walk, release — and checks the whole thing in one process. Its
observed output is in the [verification table](#verification-status). It is
deterministic: no input, no clock, no random seed. The one number that varies
with the target is the width of the main database's catalogue record, which is
the width of the core's own private `MDB_db` — printed as an opaque byte count,
never asserted against a number this package invented.

`consumer/src/main.zig` does the persistence half from outside: it writes one
set of records, abandons another, releases the environment, opens it again from
scratch, and requires the committed bytes and the exact absence of the abandoned
ones — through `dep.module("lmdb")`, in a package that did not write this one.

`testdata/interop.zig` is the third: the same corpus, compared against upstream's
own reader.

## Testing approach

The oracle is **upstream's own reader**, not this package's own wrapper:

* `testdata/corpus.txt` is a hand-written known answer. Its `[expect]` block is
  the collation written down, not computed, so the C is compared against a
  recorded answer: `Zulu` (0x5A) before the lowercase keys, `alpha` before
  `alphabet` because it is a prefix of it, `beta` before `delta` before `gamma`.
  `delta` has an **empty value**, which is what makes the zero-length case
  observable: a key must be at least one byte, a value need not be.
* `zig build interop` writes that corpus through the facade and compares
  upstream's `mdb_dump -p` body with it byte for byte. Neither half of that
  comparison is this package's wrapper, which is what makes it a fixture and not
  another round trip.
* The read-back walk inside `interop.zig` is a **supplement** and is labelled as
  one: it shares code with the writer, so on its own it would only show the
  facade agreeing with itself.
* The 25 tests in `tests.zig` state upstream's own contracts and observe the
  compiled core: commit/abort persistence across a reopen, `NOOVERWRITE`,
  read-only refusal, snapshot `reset`/`renew`, `DUPSORT` order in both
  directions, the named-database slot, cursor `NotFound` at both ends, cursor
  deletion leaving the cursor in place, nested commit and abort, the one-shot
  transaction, the two cursor-ownership rules, `max_dbs`, the empty key, a file
  that is not an environment, `MDB_REVERSEKEY`, and the corpus round trip.

Three things are asserted **by omission**, because asserting them would have
been asserting the fork's own bookkeeping rather than a contract: there is no
test that the version string equals the pin, no test that a forwarded accessor
agrees with a raw member, no test that a call does not throw, and no test that a
copied pointer equals the original. Version pinning belongs to
`UPSTREAM.sha256`; the smoke program prints the version it linked against, which
is a reading rather than a pin.

Upstream's own test material (`mtest*.c`, `mplay.c`, the sample databases) is
carried **and shipped** — it is inside `libraries/liblmdb`, which `.paths`
names whole. Nothing here compiles it: the three core units and `mdb_dump` are
the only C units this build turns into objects.

## Verification status

Every gate below was **run by the driver and observed**, never predicted, and the
receipt that holds each output is named. The gates that have **not** run are
listed with the reason. This is the package's only gate table; the other four
records link here instead of repeating it.

Rows whose receipt is a `foundation-expansion-lmdb-…-NNN.log` are receipts from
the source state **before** `CHANGELOG.md` §28 and are kept as history. Where a
`native re-verification` or `baseline (re-run)` row below covers the same gate,
that row is the current evidence; where none does — `interop` and the installed-C
surface — the gate simply has not been re-run on the current tree.

**The portability wave after §28 changed this tree again, and no gate in this
table has been re-run over it.** What it changed here is the printed reason the
build gives for refusing `wasm32-wasi`: it now states what was measured on the
real SDK rather than that a header is missing, and that wording has not been
printed by a gate. The four provider probes near the bottom of the table are new
and observed; every other row describes the tree as it stood when its receipt
was taken. The last row names that whole round gate by gate, so no row above
reads as if this wave had been verified.

| Gate | Command | State | Receipt |
|---|---|---|---|
| smoke | `zig build smoke -j8 --summary all` | **observed green.** `all observations agreed`, `Build Summary: 6/6 steps succeeded`, `run exe lmdb-smoke success 23ms`. The walk prints `alpha=first beta=second gamma=third sorted\0=catalogued, 48 opaque bytes`, then the duplicate order, then the boundaries, then the borrowed-slice check | `local://foundation-expansion-lmdb-scratch-smoke-170.log` |
| test (Debug) | `zig build test -j8 --summary all` | **observed green, 25/25.** `Build Summary: 6/6 steps succeeded; 25/25 tests passed`, `run test lmdb-tests 25 pass (25 total)` | `local://foundation-expansion-lmdb-scratch-debug-172.log` |
| test (ReleaseSafe) | `zig build test -Doptimize=ReleaseSafe -j8 --summary all` | **observed green, 25/25** — `compile lib lmdb ReleaseSafe native success` and the same `25 pass (25 total)` | `local://foundation-expansion-lmdb-scratch-safe-173.log` |
| install | `zig build --prefix <scratch> -j8 --summary all` | **observed green.** `Build Summary: 6/6 steps succeeded`, `install lmdb success`, with `compile lib lmdb Debug native success 1s`, `translate-c success` and the smoke executable compiled beside it. The summary names the install step rather than listing what it wrote; the files it writes are the ones `build.zig:748-756` names, and a later gate compiled and ran a C program against that prefix's `include/` and `lib/` | `local://foundation-expansion-lmdb-installed-artifact-gruenau8-188.log` |
| interoperability | `zig build interop -j8 --summary all` | **observed green.** The program prints the body `mdb_dump -p` printed — twelve lines, six records in collation order — then `6 records match mdb_dump -p byte for byte`. `Build Summary: 7/7 steps succeeded`; `compile exe mdb_dump Debug native` is a real step, so the reference reader was built from this tree and linked against this package's archive | `local://foundation-expansion-lmdb-upstream-mdb-dump-interop-corrected-body-211.log` |
| consumer | `cd consumer && zig build run -j8 --summary all` | **observed green.** `consumer: linked LMDB 1.0.1`, `consumer: committed records persisted, abandoned ones did not` — a package that did not write this one, through `dep.module("lmdb")` | `local://foundation-expansion-lmdb-native-consumer-gruenau8-212.log` |
| installed C surface | `zig cc -std=gnu17 -pthread -ldl -I <prefix>/include <program>.c <prefix>/lib/liblmdb.a` | **observed green.** The program prints `module loader refused a module that is not there: …/lmdb-c-surface/absent.so: cannot open shared object file: No such file or directory` and then `installed lmdb.h and liblmdb.a interoperate`. A value committed in one transaction reads back byte for byte in a second, read-only one, and the loader's refusal is observed behaviour rather than a symbol name | `local://foundation-expansion-lmdb-installed-C-surface-corrected-226.log` |
| cross `x86_64-linux-gnu` | `zig build check -Dtarget=x86_64-linux-gnu -j8 --summary all` | **observed green**, `7/7 steps succeeded` | `local://foundation-expansion-lmdb-check-x86_64-linux-gnu-213.log` |
| cross `aarch64-linux-gnu` | `zig build check -Dtarget=aarch64-linux-gnu -j8 --summary all` | **observed green**, `7/7 steps succeeded` | `local://foundation-expansion-lmdb-check-aarch64-linux-gnu-214.log` |
| cross `aarch64-macos-none` | `zig build check -Dtarget=aarch64-macos-none -j8 --summary all` | **observed green**, `7/7 steps succeeded` | `local://foundation-expansion-lmdb-check-aarch64-macos-none-215.log` |
| cross `x86_64-windows-gnu` | `zig build check -Dtarget=x86_64-windows-gnu -j8 --summary all` | **observed green**, `7/7 steps succeeded` — the Win32 mutex backend, the Win32 status table and the `kernel32` loader all resolve for that target | `local://foundation-expansion-lmdb-check-x86_64-windows-gnu-216.log` |
| cross `riscv64-linux-gnu` | `zig build check -Dtarget=riscv64-linux-gnu -j8 --summary all` | **observed green**, `7/7 steps succeeded` | `local://foundation-expansion-lmdb-check-riscv64-linux-gnu-217.log` |
| six-target `check` baseline (re-run) | `zig build check -Dtarget=<triple> -Doptimize=Debug -j8 --summary all --color off`, five supported triples and `wasm32-wasi` | **observed against the current tree: 5 success, 1 refusal.** `x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`, `x86_64-windows-gnu` and `riscv64-linux-gnu` each report `Build Summary: 8/8 steps succeeded` in 3.042 / 3.542 / 3.472 / 4.547 / 4.091 s; `wasm32-wasi` is `refused`, exit 1, in 2.042 s, printing the reason and stopping at `error: UnsupportedTarget`. The eighth step is §28's `preprocess lmdb.h`, which is why the count moved from 7 to 8 | `local://foundation-cross-test-baseline-before-sdk-corrections.json` |
| native re-verification (Debug) | `zig build test smoke install -Doptimize=Debug -j8 --summary all --color off` | **observed green, 25/25, after the §28 repairs.** Exit 0, `Build Summary: 12/12 steps succeeded; 25/25 tests passed`, 3.369 s. One command covers test, smoke and install, so it supersedes the earlier separate smoke, test and install rows for the current source | `local://foundation-cross-test-stable-lmdb-native-Debug.log` |
| native re-verification (ReleaseSafe) | `zig build test smoke -Doptimize=ReleaseSafe -j8 --summary all --color off` | **observed green, 25/25.** Exit 0, `Build Summary: 10/10 steps succeeded; 25/25 tests passed`, 20.501 s. This mode runs no `install` step, so install stays the Debug row's evidence | `local://foundation-cross-test-stable-lmdb-native-ReleaseSafe.log` |
| native re-verification (consumer) | `zig build run -j8 --summary all --color off` in `consumer/` | **observed green.** Exit 0, `Build Summary: 7/7 steps succeeded`, 2.763 s, run against the same Debug prefix | `local://foundation-cross-test-stable-lmdb-native-consumer.log` |
| `wasm32-wasi` | `zig build check -Dtarget=wasm32-wasi -j8 --summary all` | **observed refused, which is the required result — twice.** Exit 1, the reason printed, and `error: UnsupportedTarget` in `refuseTarget`; that receipt names `build.zig:328:5`, which is where `refuseTarget` stood in that tree, and the current tree reports `build.zig:376:5`. The build stopped in `build.zig` — no C translation unit was compiled, so this is a refusal, **not** a WASI compile of upstream, and none is claimed. The printed reason has since been corrected to say what was measured on the real SDK (see [Requirements](#requirements)); that wording is `PENDING-VERIFICATION`, and the refusal itself, the typed error and the absence of any compiled C are unchanged by it | `local://foundation-expansion-lmdb-check-wasm32-wasi-218.log` |
| integrity | `sha256sum -c UPSTREAM.sha256` | **observed green, 43/43.** Every one of the 42 files under `libraries/liblmdb/` reports `OK`, and so does `testdata/corpus.txt`. Upstream's bytes and the one independent fixture are the bytes this record pins | `local://foundation-expansion-lmdb-immutable-source-fixture-integrity-219.log` |
| package fetch | `zig fetch --global-cache-dir <scratch> <this package path>`, from a build root outside the repository | **observed green, exit 0 — from the tree as it stood before `CHANGELOG.md` §28, and historical since the final-round row below.** The package materialised out of `.paths` and printed its identity `lmdb-1.0.1-tSeszYugEADun9Ij9Jq5V8rU2T4T5LmT2wgdti2-lPSV`. That is the identity of a fetch of a **local directory**, not of a published archive. An earlier fetch of an earlier tree printed `lmdb-1.0.1-tSeszSGBEAA4iYj2VgUVljPe8OfyeloZXM03YepgsSeU` (`local://foundation-expansion-lmdb-external-driver-package-fetch-323.log`) | `local://foundation-expansion-lmdb-delivery-settled-filtered-package-fetch-448.log` |
| materialised integrity | `sha256sum -c UPSTREAM.sha256`, run **inside** the fetched package | **observed green, 43/43 — same prior-tree caveat, and historical since the final-round row below.** Every line of the record has a file behind it in the filtered copy, including `libraries/liblmdb/LICENSE`, `COPYRIGHT`, `Makefile`, `Doxyfile` and `CHANGES`, so the record is checked where a dependent would read it, not only at the repository root | `local://foundation-expansion-lmdb-delivery-final-package-integrity-457.log` |
| materialised consumer | `cd <fetched package>/consumer && zig build run -j8 --cache-dir <scratch>` | **observed green, exit 0 — same prior-tree caveat, and historical since the final-round row below.** `consumer: linked LMDB 1.0.1`, `consumer: committed records persisted, abandoned ones did not`, `Build Summary: 6/6 steps succeeded`. The consumer's manifest resolves `.path = ".."`, so this row compiled the library out of the **filtered copy**, through `dep.module("lmdb")`, with no source-tree path available to it | `local://foundation-expansion-lmdb-delivery-final-package-consumer-458.log` |
| final filtered package round, after §28 | filtered fetch, source/fetched integrity and fetched consumer after SDK documents settle | **Observed, and this is the most recent packaging round on record.** The workspace's package-regression run of 2026-10-02T12:13:24Z–12:18:27Z finished `status: complete` with 8 of 8 packages passed, and its final contract reports `state: PASSED` at 12:23:25Z. For this package: `zig fetch` exit 0 printing `lmdb-1.0.1-tSeszSGFEQCKyjxN9BejhfjEWphAgfZqtC9Qbzh22EgG`; 16 `.paths` entries and 61 of 61 expected package files; `UPSTREAM.sha256` 43/43 in the source **and** 43/43 inside the fetched copy, the two manifests byte-identical (`70ca3843…`); `cross-test.profile.sh` identical in both; and the consumer, run inside the fetched copy against `.path = ".."`, exit 0 — `consumer: linked LMDB 1.0.1`, `Build Summary: 7/7 steps succeeded`. That round ran over the post-§28 tree and **predates this repair wave's `build.zig` change**, so it is the last packaging evidence on record and is not evidence for this wave's tree — which is why the pending row below is still open. The historical rows above predate the translator repairs; the 43 recorded native/fixture paths themselves did not change | `local://foundation-cross-test-package-regression.json`, `local://foundation-cross-test-final-receipt-contract.json` |
| `zig build -fsys=lmdb` | as above | **not run**, and no result is claimed. It needs an installed liblmdb with a matching header; no such installation was used, and the installed-artifact rows above are this package's **own** `zig-out/` contents, not a system library | — |
| `.github/workflows/verify.yml` | GitHub Actions | **never executed.** No runner, no `act`, no push. The workflow is `SOURCE-CONFIRMED` against the tree; every command it takes has a receipt outside a runner, and the one mode it does not run at all — `-fsys=lmdb` — is the one mode there is no receipt for | — |
| `cross-test`, full 53-platform matrix | `cross-test --jobs 2 --build-jobs 4 --build-timeout 1800` at the package root, through `cross-test.profile.sh` (`CROSS_BUILD_STEP=test`) | **observed, run `20261002-061717-7494-31221`, `bookkeeping_failure: false`.** Each cell is `zig build test -Dtarget=<target>`. **52 of 53 cells reach the compiler**: `x86_64-linux` passes with 25/25, **32 cells are build-only** (`run=unavailable`, exit 0, because this host detects no runner for them), **19 foreign Linux cells build, run, and fail all 25 tests each**, and `wasm32-wasi` is the configure refusal. The per-cell distribution is in [the matrix section](#the-full-platform-matrix-and-what-it-will-and-will-not-say-about-this-package) | `local://foundation-cross-test-final-lmdb.json` |
| the 19 foreign Linux run-failures | as above | **historical, and superseded on exactly one point: the "eighteen inferences" no longer describe the state of the record.** When this row was written only `aarch64-linux` had been probed separately. A diagnostic C program built with `-DMDB_USE_POSIX_MUTEX=1 -DMDB_USE_ROBUST=1` and run under `/bin/qemu-aarch64` (10.0.12) reports `mdb_env_open rc=38 Function not implemented` with `lock.mdb exists=1 data.mdb exists=0`, and `qemu-aarch64 -strace` puts `get_robust_list(0,…,1,3,0) = -1 errno=38 (Function not implemented)` immediately after the `lock.mdb` `mmap`. The same binary opens cleanly with `MDB_NOLOCK` (`lock.mdb exists=0 data.mdb exists=1`) and a `-DMDB_USE_ROBUST=0` build opens cleanly, while the `ROBUST=1` build opens on `x86_64-linux`. So the cause is this host's QEMU, **not** the backend: nothing in the shipped build was weakened to make the matrix green. Each of the other eighteen has since been run on its own; the rows below are that evidence, and they supersede this row's scope without invalidating a word of it | `local://foundation-cross-test-lmdb-open-diagnostics.json` |
| the 19 foreign Linux cells, each run on its own | one C probe compiled per cell with `zig cc -target <cell> -O2 -static -std=gnu17 -pthread`, then executed under that cell's installed `qemu-*` user-mode runner | **observed, all nineteen individually** (`state: CORE20TARGETS_SETTLED_SUPPLEMENTAL_NATIVE32_SPAWN_REFUSED`). Every probe compiled (exit 0) and every run then exited 1 at the mutex initialisation, printing `get_robust_list rc=-1 errno=38 length=0` and `robust shared mutex init rc=38` on fifteen of the cells, and `errno=89` with `robust shared mutex init rc=89` on `mips-linux`, `mipsel-linux`, `mips64-linux` and `mips64el-linux`, where `ENOSYS` is 89. The probe asks the runner's kernel directly, so what it reports is each runner's answer and not this package's lock backend; `mdb_env_open` returns that code unchanged, which is why all 25 tests on each cell report `error.UnexpectedStatus` | `local://foundation-portability-robust-initial-diagnostics.json` |
| the same probe, natively, on `x86_64-linux` | the same source with `-target x86_64-linux`, run directly | **observed green**: `get_robust_list rc=0 errno=0 length=24`, `robust shared mutex init rc=0`, `lock after owner death rc=130 expected=130`, exit 0. The child leaves by `_Exit` while owning the mutex, so only the kernel's robust list can mark owner death, and `pthread_mutex_consistent` and the relock that follow did not fail. The identical code path is what fails on all nineteen foreign runners. **The scope of this row is this host's own `x86_64-linux` kernel and this probe**; it is not evidence about any other architecture's kernel, and no other architecture's kernel has been exercised with it | `local://foundation-portability-robust-initial-diagnostics.json` |
| a native 32-bit `x86-linux` run of the same probe | the same source, run without a runner | **not available, and not a robust failure**: `UNAVAILABLE`, `Observed hostexecOSError8Execformaterror; not robust failure, native32unsupported`. The `x86-linux` cell is still covered, by its `qemu-i386` run in the row above | `local://foundation-portability-robust-initial-diagnostics.json` |
| WASI SDK 34 prerequisites for LMDB | a C probe with `_WASI_EMULATED_MMAN` built by `zig build-exe -target wasm32-wasi` against `wasi-sysroot-34.0` and linked with `libwasi-emulated-mman.a`, executed on Wasmtime 46.0.3 | **observed**: `actual WASI SDK 34: pshared=0 robust=28 second_snapshot=31 persisted=31`. `pthread_mutexattr_setpshared` is **accepted**, `pthread_mutexattr_setrobust` is rejected with `EINVAL`, the `0x52` written through a `MAP_SHARED` mapping reads back `0x31` in a second mapping of the same file and `0x31` from the file after `munmap`, and `msync` is not in that archive — an attempted call to it failed to link. `<sys/mman.h>` and `mmap` are present; the facility LMDB needs is not | `local://foundation-portability-wasi-lmdb-sdk34-corrected-proof.json` |
| this portability wave, over this tree | `zig build check -Dtarget=wasm32-wasi`; `zig build test`, `smoke` and `install` in Debug and ReleaseSafe; `consumer`; the six-target `check` baseline; the 53-cell `cross-test` matrix; `zig build interop`; the installed-C surface; `sha256sum -c UPSTREAM.sha256`; `zig fetch` with the 43-line record and the consumer inside the fetched copy | **PENDING-VERIFICATION — none of these has been re-run over this wave's tree.** The native, packaging and source-integrity rows above are the last observations, from earlier source states. This wave corrected one printed reason and added no upstream byte, so the 43 records are untouched by it, but no gate here has re-checked them. Real runtime evidence for the 19 foreign Linux cells is deliberately absent from this list, and it is not a gate this host could run: those cells do run and do fail on its own `qemu-*` runners, and evidence against a kernel that owns the robust list would need a guest kernel, a root filesystem or hardware per architecture, and it has none of those | — |
| the C library the 20 Linux cells use | — | **not asserted.** The published triples carry no ABI suffix and this compiler defaults them to musl (`musl`/`musleabi`/`musleabihf`/`muslabi64`), so a glibc `--libc-runtimes` directory must not be assumed to be what they link. The six-target `check` baseline is separate and explicit — it names `*-linux-gnu` | — |
| `cross-test.profile.sh` | `bash -n`, then `cross-test --list` and `cross-test --no-profile --list` | **observed, all three exit 0** — 0.0048 s / 1.496 s / 3.688 s. `bash -n` prints nothing at all, and both listings name the same **53** targets, so the settings-only profile demonstrably does not narrow the matrix | `local://foundation-cross-test-profile-verification.json` |
| re-run after the `.paths` change | `sha256sum -c UPSTREAM.sha256`, `zig build`, `zig fetch`, consumer inside the fetched copy | **The `.paths` round ran; the round over this wave's tree has not.** `cross-test.profile.sh` is fork-authored and outside the integrity record, so the 43-record rows are unaffected by it; the `.paths` count moved 15 → 16, and per `CHANGELOG.md` §26 a `.paths` change wants a fresh fetch and a fresh consumer inside it. That is what the 2026-10-02T12:14Z package-regression round did: it fetched this package with all 16 entries (61/61 files), checked all 43 records in the source and inside the fetched copy, and ran the consumer inside the fetched copy to exit 0. What is unrun is that same round over this wave's tree, which is the pending row above | — |

**`cross-test`'s statuses and `check`'s statuses are different questions, and
this table keeps them apart.** `zig build check` compiles and never executes, so
each of the five green cross rows above is **compile evidence only** — a green
Windows row says the core and every program compile for that target, not that
anything ran there. The 53-cell run produces three further kinds of answer that
`check` cannot produce at all: `pass` (one cell, executed natively), `build_only`
(32 cells, compiled and then not run because this host detects no runner — a
build-only cell is **not** a pass), and `fail` with a reason (19 runtime
failures, plus `wasm32-wasi`, which fails at configure and never reaches the
compiler). A `check` row cannot be promoted to any of the three without a runner
the harness has to find first.

**What the receipts do and do not establish.** The smoke receipt establishes that
the facade, the smoke program, the translated header and the archive agree, link
and run **on this host**: every published observation on stdout, ending `all
observations agreed`. The five `check` cross rows are **compile** evidence and
nothing more, for the reason the paragraph above gives. The `wasm32-wasi` row is
a refusal, not a build. The interop receipt is the one that
compares two implementations of a reader, and the installed-C receipt is the one
that exercises the archive and header as a C consumer sees them.

**What the three packaging rows establish.** They answer one question — does the
package a dependent receives actually contain this library — and they answer it
about a copy made **from `.paths` alone**: the fetched tree has no file in it that
`.paths` did not name, and the 43-line record checks out inside it. Upstream's
engine, its other tools, its headers, its build definitions, its man pages and
release notes, and its licence and copyright files are all in that copy, so
OLDAP-2.8's conditions travel with the bytes they govern. The workspace's
2026-10-02T12:14Z round asked the same question again on the post-§28 tree and
got the same answers — 61 of 61 files, 43/43 records in the source and in the
fetched copy, the consumer green inside the fetched copy — under a different
package identity; that is the round above, and it is a run over the tree before
this wave, not over this one. Nothing else is claimed by them:

* **This is not a registry or publication proof.** The fetch resolved a local
  directory on this machine; nothing was published, pushed, uploaded or resolved
  from a registry, and the identity it printed is the identity of *that*
  directory. A `.url` dependency (see [As a dependency](#as-a-dependency)) would
  carry a different hash, obtained by a different fetch, and it has not been
  taken here.
* **They do not touch any other row.** `wasm32-wasi` is still the configure-time
  `error.UnsupportedTarget` refusal it has always been, `-fsys=lmdb` is still not
  run, and no cross target was executed by them.
* **The bytes are the pinned upstream bytes.** That the shipped native tree is
  unchanged from upstream is a separate receipt —
  `git diff --exit-code 6f0a32496a5aadee15a5e5103c479bd3355ae273 -- libraries/liblmdb`,
  exit 0 and empty output
  (`local://foundation-expansion-lmdb-pinned-native-pristine-diff-266.log`) — not
  something the fetch observed.
* **No CI ran.** `.github/workflows/verify.yml` has still never been executed;
  each of these three rows was run by the driver, outside a runner, and each names
  its own receipt.

**The interop gate was red twice before it passed**, and both repairs are
fork-side; no upstream byte, no expected value and no fixture changed.
`CHANGELOG.md` records them with their receipts.

## Integrity

```
sha256sum -c UPSTREAM.sha256
```

**43 records, 689093 bytes**: the SHA-256 of all 42 upstream files under
`libraries/liblmdb/` — a complete copy of that one directory at the pinned
commit — plus `testdata/corpus.txt`, the independent known-answer corpus, because
a silent edit to it moves every published expectation in the package at once.

**The record and the package now agree, and that is observed rather than
argued.** `build.zig.zon` `.paths` ships the whole `libraries/liblmdb` directory,
and running this same command **inside a package materialised from `.paths`
alone** reports all 43 lines `OK`
(`local://foundation-expansion-lmdb-materialized-package-integrity-332.log`), so
the check is not merely a repository-root check. An
earlier state of this fork shipped eight of those 42 — the four C units, the two
headers and the two legal files — and carried the other 34 for re-sync only, in
which case a fetched package reported `No such file or directory` on those 34
lines. Shipping the full source means a dependent gets upstream's engine, its
tools, its headers, its build definitions and release notes, and its licence and
copyright files, so OLDAP-2.8's conditions travel with the bytes they govern
instead of resting on whoever re-syncs next remembering them. `.paths` is 16
entries: the build files, the `cross-test` profile, the facade and its two
programs, the fixture and the consumer package, the whole upstream directory,
and this repository's five records plus `UPSTREAM.sha256`.

The whole-tree archive receipt in `UPSTREAM.md` is a **different record** and
answers a different question; the two are not comparable and a difference
between them is not corruption.

Nothing this fork wrote is hashed, except the fixture. See `UPSTREAM.md` for how
the digests were produced and what they do and do not prove.

## Licence

Upstream's own code in this package is under **The OpenLDAP Public License,
Version 2.8**. The text ships verbatim as `libraries/liblmdb/LICENSE` and the
copyright notice as `libraries/liblmdb/COPYRIGHT`; both are in `.paths` and in
`UPSTREAM.sha256`, and 29 of the 42 files under `libraries/liblmdb/` — including
all six the build compiles or installs — restate the redistribution terms in their
own headers.

**OLDAP-2.8 is not the only term in the tree**, and saying it was is wrong. Three
further terms are retained there, two of them inside the compiled core:

| Term | Where | Compiled here |
|---|---|---|
| ISC-style, Martin Hedenfalk, "derived from btree.c" | `lmdb.h:151-166`, `mdb.c:19-33` | **yes** — both files are core |
| Public domain, Landon Curt Noll, FNV-1a | `mdb.c:5846-5872`, inside `#ifdef MDB_USE_HASH` at `mdb.c:5845` | **conditionally** — a third term, on top of the two core terms, for `aarch64-macos-none` and `x86_64-windows-gnu` only |
| Public domain, D. J. Bernstein | `chacha8.c:1-5` | no |

Read the FNV-1a row with the others, not on its own. The ISC-style grant is in
`mdb.c` and `lmdb.h`, so it is compiled into **every** supported target's archive —
a record naming only OLDAP-2.8 was wrong on all five supported targets, not
conditionally. FNV-1a is a third term layered on top, and it is the only one whose
reach varies: present on `aarch64-macos-none` and `x86_64-windows-gnu` because
`MDB_USE_HASH` is reached from `MDB_USE_POSIX_SEM` or `_WIN32`, absent from the
three Linux targets, which still carry both core terms. `wasm32-wasi` produces no
binary at all — it is in `refused_check_targets` and the build stops with
`error.UnsupportedTarget` — so no compiled terms apply there. That split is
`SOURCE-CONFIRMED` from the macro lists `build.zig` passes, except the Windows
row, which is inferred from the target's own `_WIN32`; `NOTICE.md` records which
is which and why.

Two more files need a narrow note rather than a licence. `chacha8.h` has no
notice, no grant and no attribution in its own bytes; the D. J. Bernstein
public-domain statement above is recorded for `chacha8.c` alone and is not extended
to the header, whose own author said nothing about it. And `crypto.c`/`cryptoc.c`
are OLDAP-2.8 whose
`#include <sodium.h>` names a dependency this package neither vendors, compiles
nor links — a mention, not a grant.

`NOTICE.md` records the licence scope, the 13 of the 42 upstream files that do not
restate the redistribution sentence and why — all 42 of which now travel —
upstream's own disagreement between two copyright year lines (`lmdb.h:141` says
2011-2026, `COPYRIGHT:1` says 2011-2021 — neither corrected here), the OLDAP-2.8
obligations this package meets and the one place where `zig build install` does not
carry the conditions text into `zig-out/`, the full per-path table of every term
in the tree, and every file this fork adds.

No sublicensing is invented and no new grant is created over upstream's bytes:
the terms above are upstream's own retentions, reproduced because
`libraries/liblmdb/` is byte-identical to the pin. This package claims no second
grant of its own for any upstream file and no licence over upstream's marks.

## See also

* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the three translation units, the header
  closure, the loader dependency, and what the integrity record establishes.
* [`UPSTREAM.sha256`](UPSTREAM.sha256) — the integrity record itself.
* [`NOTICE.md`](NOTICE.md) — the per-path legal record: OLDAP-2.8 and how it is
  met, every other term the tree retains with its lines, compiled core versus
  carried-but-uncompiled files, and every file this fork adds.
* [`CHANGELOG.md`](CHANGELOG.md) — numbered fork-only divergences, each with its
  receipt.
* [`FORK-NOTES.md`](FORK-NOTES.md) — the decisions and the lessons, in
  condition/symptom/fix/target-bound form.
# lmdb — LMDB 1.0.1, built from its own pinned C with Zig 0.16

LMDB is a memory-mapped key/value store: a B-tree in a single memory-mapped file,
with readers that do not block writers and writers that do not block readers. This
repository compiles **upstream's own C, byte for byte**, from
`libraries/liblmdb/`, and publishes a Zig facade over the translated `lmdb.h`.

| | |
|---|---|
| Upstream | <https://github.com/LMDB/lmdb.git>, tag `LMDB_1.0.1`, commit `6f0a32496a5aadee15a5e5103c479bd3355ae273` |
| Version compiled | `1.0.1`, read out of `libraries/liblmdb/lmdb.h:235-239` |
| Licence of upstream's code | **OLDAP-2.8**, plus three terms upstream itself retains — see [Licence](#licence) |
| Licence of this fork's own files | **OLDAP-2.8** (`SPDX-License-Identifier: OLDAP-2.8`), on the owner's authorization — see [`FORK-LICENSE.md`](FORK-LICENSE.md) |
| Toolchain | Zig **0.16.0**, the real compiler. Nothing here compiles on an earlier one |
| C library | three translation units: `mdb.c`, `midl.c`, `module.c` — exactly `liblmdb.a` at the pin (`liblmdb/Makefile:87-88`) |

The Zig interface — every method, handle lifetime, error, flag, bound and example
— is in [`README.zig.md`](README.zig.md). This file is the fork's own record:
what deviates from upstream, what the current build and test surface is, and how to
consume the thing.

---

## Current native-source deviations

**None.**

No file under `libraries/liblmdb/` is modified, added or removed. All 42 of them
are upstream's bytes at the pin, and `UPSTREAM.sha256` is the record that says so
from the bytes rather than from a promise:

```
sha256sum -c UPSTREAM.sha256
```

43 records — the 42 upstream files plus `testdata/corpus.txt`, the independent
known-answer fixture. `UPSTREAM.md` explains what that record does and does not
establish; in short it is a hash of this working tree, not a signature and not a
re-derivation of the commit id.

One upstream disagreement is recorded rather than corrected, because correcting it
would be an edit to upstream's bytes: `liblmdb/Makefile:36` says
`LMDB_VERSION = 1.0.0` for a 1.0.1 release. The header is the ABI the compiled code
answers to, so the header wins and the Makefile string travels unchanged.

**There is no `README.upstream.md` in this repository.** Upstream's tree has no
README at any depth, so there are no upstream README bytes to preserve separately;
`README.md` here is fork-authored from its first line. Upstream's prose — what it
does have — is `libraries/liblmdb/intro.doc` and `libraries/liblmdb/upgrading.doc`,
which stay at those original paths, unmodified, inside `.paths`, and are never
copied into this file.

---

## Current native-build deviations

Everything in this section is fork-side: build graph, packaging and documentation.
It is dated **2026-10-04**, and its full history is
[`CHANGELOG.md`](CHANGELOG.md) §31 and onward, with the numbered entries before it.

| # | Deviation | Why | Where |
|---|---|---|---|
| 1 | `-Dlinkage=static\|dynamic`, spelled with `std.builtin.LinkMode`, **default `static`** | the build hardcoded `linkage = .static`; the option adds the shared variant without changing what any existing command does | `build.zig` |
| 2 | The shared variant is `-fPIC`, and only the shared variant | upstream builds its shared objects from separately compiled `.lo` objects that carry `-fPIC` (`Makefile:132-139`) and its static `.o` objects that do not (`Makefile:144-145`) | `build.zig` |
| 3 | The shared library is `liblmdb.so.1.0.1`, with symlinks `liblmdb.so.1` and `liblmdb.so` | Zig names it for `version = 1.0.1`; upstream's is `liblmdb.so.1.0` (`VEREXT = 1.0`, `Makefile:33-37`). The **soname series is the same** — `liblmdb.so.1`, upstream's `SOVER` (`Makefile:56-57`) — but that equality is read out of Zig's naming rules, not yet out of a built artifact | `build.zig` |
| 4 | `lib/pkgconfig/lmdb.pc` is **generated and installed**, where before there was none | upstream writes one only through its own Makefile (`Makefile:147-158`) and this fork never ran that Makefile. A C consumer needs link metadata | `build.zig` |
| 5 | That `.pc` states `Version: 1.0.1` | upstream's template interpolates `LMDB_VERSION`, which its own Makefile leaves at `1.0.0` (`Makefile:36`). The generated file states the pin | `build.zig` |
| 6 | That `.pc` splits upstream's single `Libs: -llmdb -ldl -pthread` (`Makefile:158`) into `Libs: -llmdb` plus `Libs.private: -ldl -pthread` **for the static variant only** | in the shared variant those dependencies are already inside the shared object and re-adding them is wrong. `Libs.private` is emitted only under `pkg-config --static`, which is exactly who needs it | `build.zig` |
| 7 | That `.pc` is relocatable (`prefix=${pcfiledir}/../..`) | upstream writes a literal `prefix=$(prefix)` (`Makefile:148`), which a relocated copy carries to the wrong place | `build.zig` |
| 8 | All five upstream tools are compiled and installed, not only `mdb_dump` | `IPROGS = mdb_stat mdb_copy mdb_dump mdb_load mdb_drop` (`Makefile:52`) and upstream's `install:` installs them (`Makefile:65-70`). Only `mdb_dump` was compiled before, for the interop oracle | `build.zig` |
| 9 | The five man pages are installed | `IDOCS` (`Makefile:53`), installed by upstream at `Makefile:78`. Their roff comments tell a reader to see `COPYRIGHT` and `LICENSE`, so the output that carries them must carry those too | `build.zig` |
| 10 | Upstream's `LICENSE` and `COPYRIGHT` are installed at `share/lmdb/` | OLDAP-2.8's condition 3 requires a verbatim copy of the licence document to travel, and condition 2 requires the notices. `zig build install` used to copy neither | `build.zig` |
| 11 | Installed executables get `$ORIGIN/../lib` (ELF) or `@loader_path/../lib` (Darwin), and on ELF every rpath Zig added is stripped | Zig appends an rpath into its own build cache for anything linking a dynamic artifact; that cache does not exist once the binary is installed | `build.zig`, and `package.nix` re-asserts it for the Nix outputs |
| 12 | `package.nix`, `flake.nix`, `flake.lock`, `devenv.nix`, `devenv.yaml`, `.envrc` exist | the SDK is standalone: pinned nixpkgs, its recorded resolution, separate static and shared derivations, and devenv as the canonical shell. See [Consumption](#consumption) | this repository |
| 13 | The fork's own files are under **OLDAP-2.8** | before this migration wave they carried no licence statement at all. The owner authorized a per-project grant matching the primary upstream term | [`FORK-LICENSE.md`](FORK-LICENSE.md) |
| 14 | This fork's own eight records are installed at `share/lmdb/`, beside upstream's `LICENSE` and `COPYRIGHT` | the fork's files are under OLDAP-2.8 too, so condition 2's "applicable copyright statements and notices" now covers them as well. A package fetched through `.paths` carried them, but no install tree did | `build.zig` |
| 15 | `-Dcpu=<model>` exists, as a string folded into the target query through `std.Build.parseTargetQuery`'s `cpu_features` — the field the compiler's own `-mcpu` fills | the Nix derivation passes `-Dcpu=baseline` so an output does not depend on the builder's CPU. `baseline`, `native`, a model name and `+feature`/`-feature` all parse; matching is case-sensitive, as `-mcpu` is | `build.zig` |

Two things that look like deviations and are not:

* **`-Dcpu` is not pushed onto the cross matrix.** Each `check` row names a triple,
  and a named triple already resolves to its own architecture's baseline model
  (`lib/std/Target/Query.zig:490-506`). Pushing a model name meant for another
  architecture onto a foreign target would be the wrong instruction, so `-Dcpu`
  applies to the target this build was asked for.
* **The `-pthread` flag is not repeated on Zig's link line.** Upstream puts it on
  every line (`Makefile:24`, `:158`); Zig's libc carries the POSIX threads entry
  points inside libc on every target this build supports, so asking the linker for
  a separate `libpthread` would turn a complete library into a search for a file
  that exists only on the machine running the build.


* **`-fsys=lmdb` still means what it meant.** An installed liblmdb by pkg-config
  name `lmdb`, with `.force` and no in-tree include path, so the header that
  resolves is the one next to the library being linked. **The force is on both
  hops, not only the translation.** The `translate-c` step calls
  `translate_c.linkSystemLibrary(pkg_config_name, .{ .use_pkg_config = .force })`
  (`build.zig:702`), and the published module calls
  `module.linkSystemLibrary(pkg_config_name, .{ .use_pkg_config = .force,
  .preferred_link_mode = options.system_linkage })` (`build.zig:768-771`), so a
  dependent that imports `dep.module("lmdb")` and never names `-llmdb` of its own
  gets the same forced query and the same selected installed linkage. One
  metadata source answers both, and the first named link entry wins. What is
  still unrun is `-fsys=lmdb` itself.

---

## Current build / run / test matrix

The gate table with every receipt is [`README.zig.md` §Verification
status](README.zig.md#verification-status); that is where results live, and nothing
here repeats one. What this section states is the **current surface** — which
commands exist, what each decides, and whether an observation exists for it.

### The commands

| Command | What it decides | State |
|---|---|---|
| `zig build` | compiles the three-unit core, translates `translate.h`, installs `lib/liblmdb.a`, `include/lmdb.h`, `lib/pkgconfig/lmdb.pc`, the five tools, the five man pages, `share/lmdb/LICENSE`, `share/lmdb/COPYRIGHT`, and compiles the smoke program without running it | observed on an earlier tree; **this wave's install layout is `PENDING-VERIFICATION`** |
| `zig build -Dlinkage=dynamic` | the same install layout with the shared library and `Libs.private` emptied | **new in this wave — `PENDING-VERIFICATION`** |
| `zig build test` | runs the behavioural tests, in the requested `-Doptimize` | observed on an earlier tree: 25/25 in Debug and in ReleaseSafe |
| `zig build test -Doptimize=ReleaseSafe` | the same tests in the mode a shipped consumer is most likely to use | as above |
| `zig build smoke` | runs the deterministic smoke program; non-zero on any disagreeing observation | observed on an earlier tree |
| `zig build check` | compiles core, facade, tests, smoke and interop for every supported target **without running any of them**, and re-derives at configure time that `wasm32-wasi` is the refused row | observed on an earlier tree: five targets `8/8 steps succeeded` |
| `zig build check -Dtarget=wasm32-wasi` | **must fail**, with `there is no shared-lock backend` and `error.UnsupportedTarget` | observed on an earlier tree |
| `zig build interop` | builds upstream's `mdb_dump` from this tree, linked against this package's own archive, and compares its `-p` body with the fixture byte for byte | observed on an earlier tree |
| `zig build consumer -Dscratch=<dir>` | runs the separate package in `consumer/` through `dep.module("lmdb")`, against either delivery form and in the runtime-loaded shape. `-Dscratch` is **required**, or export `LMDB_TEST_SCRATCH`; see [`README.zig.md` §The consumer package](README.zig.md#the-consumer-package) | **observed on this tree**, in nine cases from a cross-SDK nested-route driver: eight route cases, each exit 0 with `Build Summary: 7/7 steps succeeded` and the consumer program's own `committed records persisted, abandoned ones did not, both routes agreed`, and one `-Druntime=true` case with no provider that exited 1 with `error: NoProviderConfigured`, the required refusal. The earlier receipt is kept below, and it is evidence about the tree it was taken on, whose consumer took its scratch location implicitly |
| `sha256sum -c UPSTREAM.sha256` | all 43 digests, and every file behind them ships | observed on an earlier tree: 43/43 |
| `zig build -fsys=lmdb` | links and translates an **installed** liblmdb instead of compiling this repository's copy | **never run**; needs an installed liblmdb with a matching header |
| `devenv tasks run lmdb:<gate>` | the same commands inside the canonical development shell, as namespaced tasks | spelling corrected 2026-10-04: the pinned devenv declares `tasks` with `run` beneath it and no singular alias, and its acceptance driver invokes `devenv tasks run`; **no task body has run green yet** — `PENDING-VERIFICATION` |
| `devenv build outputs.static`, `outputs.shared` | the two Nix outputs, built from the same `package.nix` the flake calls | **new in this wave — `PENDING-VERIFICATION`** |

### Targets

| Target | `check` | Compiled terms in the archive |
|---|---|---|
| `x86_64-linux-gnu` | compiles | OLDAP-2.8 + the Martin Hedenfalk grant |
| `aarch64-linux-gnu` | compiles | as above |
| `riscv64-linux-gnu` | compiles | as above |
| `aarch64-macos-none` | compiles | OLDAP-2.8 + Hedenfalk + the Landon Curt Noll FNV-1a public-domain notice |
| `x86_64-windows-gnu` | compiles | as above — the Windows row of that table is inferred from the target's own `_WIN32`, not from an observed preprocessor run |
| `wasm32-wasi` | **refused at configure time**, `error.UnsupportedTarget` | none: no binary is produced, so no compiled terms apply |

The refusal is measured, not assumed: WASI SDK 34 *does* provide an emulated
`<sys/mman.h>` and `mmap`, and what it lacks is the shared mapping, the write-back
and the independent-process robust lock that LMDB is made of.
`MDB_NOLOCK` is not used as a substitute — it is a runtime flag that drops the
reader liveness table and the cross-process write lock, so building against it
would produce a smaller and weaker library. `README.zig.md` §Requirements has the
probe output.

The full published 53-platform `cross-test` matrix, and what `build_only` means in
it, are in [`README.zig.md`](README.zig.md#the-full-platform-matrix-and-what-it-will-and-will-not-say-about-this-package).

### What this wave has and has not been checked against

Everything in the third column above that says **new in this wave** or
**`PENDING-VERIFICATION`** is a declared contract until a run says otherwise, and
some of them now have one. The rows that cite an older observation describe the
tree as it stood when that receipt was taken, and `README.zig.md`'s gate table says
which tree that was. Nothing in this file upgrades a historical result to a
current one.

### The four source-bound runs of 2026-10-04 and 2026-10-05

Each of these ran over this tree, and each holds one source stamp for its whole
run.

| Run | What it covers | Result |
|---|---|---|
| six-target `check` — baseline run `20261005T014547Z-797a73f2`, label `baseline-lmdb-check` | `zig build check` over the declared compile targets | **exit 0**, `Build Summary: 36/36 steps succeeded`, no failing step, five targets seen. `wasm32-wasi` is not among them, because this graph refuses it at configure time — the `Targets` row above |
| 53-platform matrix — run `20261004T221720228710Z-45046`, receipt `lmdb-53-target-8.json`, source stamp `208a5547821d…` identical before and after | `cross-test --jobs 8 --build-jobs 8` | **exit 1**: **1 pass, 32 build-only, 1 build failure, 19 run failures** of 53, 20 cells executed at 38 tests each. `x86_64-linux` is the one cell that passes |
| native final wave — `native-final-evidence/20261004T233628757747Z-69351` | `zig build test smoke install -Druntime=false`, both linkages × four modes | **8 of 8 `exit 0`**, each `46/46 steps succeeded` and `38/38 tests passed` |
| own-loaded wave — `loaded-final-evidence/20261004T232823091897Z-23133` | the same steps under `-Druntime=true` | **8 of 8 `pass`**, each `48/48 steps succeeded` and `38/38 tests passed` |

The 19 run failures are one family and one frame. Every one fails all 38 tests at
`zig/root.zig:622` in `posixStatus`, reached from `positiveStatus` (`:607`) ←
`check` (`:560`) ← `open` (`:1169`) ← `init` (`:1139`), which is the first call of
the environment lifecycle: `mdb_env_open` returned an errno the switch does not
map, and the unmapped `else` arm at `:635` is `error.UnexpectedStatus`. The cells
are every foreign Linux target the harness executed, `aarch64-linux` through
`x86-linux`, and `x86_64-linux` alone passes at 38 of 38.

**The cause, and where its evidence is.** These matrix logs carry no `ENOSYS`
string, so they establish the frame and the unmapped arm and nothing more. The
cause was closed by a separate probe: each of the nineteen runners was asked
directly about `get_robust_list` and about initialising the robust process-shared
mutex, and all nineteen answer `ENOSYS` — fifteen reporting `errno=38`, and four
(`mips-linux`, `mipsel-linux`, `mips64-linux`, `mips64el-linux`) reporting `89`,
which is that number. `FORK-NOTES.md` § "What the parent still owns" carries that
probe and its numbers. What is still open is the layer above it: real execution
against a kernel that owns the robust list, which needs a guest kernel, a root
filesystem or hardware per architecture. That is a provider boundary, not a gap
in this file.

The one build failure is `wasm32-wasi`, and it is this graph's own documented
refusal: `refuseTarget`, with `LMDB has no buildable configuration for this
target: there is no shared-lock backend`. It is a refusal rather than a defect,
and it is the `Targets` row above arriving at its own conclusion.

Three boundaries belong here rather than in a footnote, because each one is a place
where a reader would otherwise assume more than exists:

* **`.github/workflows/verify.yml` now defines gates for both linkages** —
  installed-closure assertions for the archive, `readelf -d` assertions on the
  shared object's soname and its `libdl` entry, the same C program linked against
  the `.so` with `-pthread` and `-ldl` deliberately absent, the installed tools run
  out of `bin/`, and `zig build check -Dlinkage=dynamic` across the supported
  matrix. Its `consumer` job runs `zig build run` with `LMDB_TEST_SCRATCH`
  exported to a directory it creates first under the runner's own temp —
  never `/tmp`, never the checkout — because the program refuses to invent a
  location and exits non-zero without it. **It has never run here.** It is
  `SOURCE-CONFIRMED` against the tree, and every gate in it is outstanding with
  the rest.
* **The recorded `install` row is historical.** Its `6/6 steps` receipt was taken
  when the default step compiled three things. The default step now also compiles
  five executables and installs the library, the header, a generated pkg-config
  file, the five tools, the five man pages and the two legal files. The receipt is
  evidence about the tree it was taken on and about nothing else.
* **The consumer package proves both delivery forms and the runtime-loaded
  shape, and it needs two values named.** `consumer/build.zig` declares
  `-Dlinkage` and `-Druntime` and passes both into `b.dependency("lmdb", …)`,
  and `build.zig` forwards both into that nested build **unconditionally**, so
  `zig build consumer -Dlinkage=dynamic` and `zig build consumer -Druntime=true`
  really do build the shape they name. The program itself refuses to invent its
  database location and, under `-Druntime`, its provider: `-Dscratch=<dir>` or
  `LMDB_TEST_SCRATCH` is **required**, `-Dprovider=<path>` or
  `LMDB_TEST_PROVIDER` is required under `-Druntime`, and a provider that
  cannot be loaded fails the run rather than falling back to a linked copy.
  [`README.zig.md` §The consumer package](README.zig.md#the-consumer-package)
  has the exact commands. An earlier claim that the shared shape was
  unavailable was wrong: the option was already declared and forwarded.

* **The five tools are outside `check`.** `zig build check` compiles the C core,
  the facade, `tests.zig`, `smoke.zig` and `testdata/interop.zig` per target — not
  the tools. A green five-target `check` therefore says nothing about whether
  `mdb_stat`, `mdb_copy`, `mdb_dump`, `mdb_load` and `mdb_drop` build for those
  targets, nor anything about their shared variant. They are compiled for the
  requested target by the install step alone.

---

## Consumption

### As a Zig dependency

```console
zig fetch --save=<name> https://github.com/<owner>/<this repository>
```

then, in `build.zig.zon`:

```nix
.dependencies = .{
    .lmdb = .{
        .url = "https://github.com/<owner>/<this repository>";
        .hash = "<the hash your fetch printed>";
    },
};
```

and in `build.zig`:

```zig
const lmdb = b.dependency("lmdb", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("lmdb", lmdb.module("lmdb"));
```

`dep.module("lmdb")` exposes the typed facade and `pub const c`, the whole
translated C surface, for anything the facade does not name. `consumer/` in this
repository is exactly this, as a separate package that depends on this one by
relative path, and its program is runnable in all three shapes of this library:

```console
zig build consumer -Dscratch=<dir>                              # static, default
zig build consumer -Dlinkage=dynamic -Dscratch=<dir>            # shared
zig build consumer -Druntime=true -Dprovider=<abs .so path> -Dscratch=<dir>
```

`-Dscratch` is **required** (`LMDB_TEST_SCRATCH` is the same value by another
route), and `-Dprovider` is required under `-Druntime`
(`LMDB_TEST_PROVIDER`). The program refuses to invent either, and a provider it
cannot load is a failure — never a fallback to a linked copy.
[`README.zig.md` §The consumer package](README.zig.md#the-consumer-package) has
the details and the full command set.

**What the nested build inherits.** `zig build consumer` runs `consumer/` as a
separate `zig build`, and `runConsumer` hands it what this graph resolved: the
target query, the CPU that query names (`-Dcpu`), optimization, linkage, runtime
and the system-library choice (`-fsys=lmdb` or `-fno-sys=lmdb`), the executor
switches, `-j8` and `--summary all`, this build's local cache under a `consumer`
subdirectory, its global cache whole, and its install prefix when the caller
named one. `hostCanExecute` chooses `run` or `install` from the same
`std.zig.system.getExternalExecutor` call `std.Build.Step.Run` makes. Arguments
after `--` reach the nested build, which hands its own `b.args` to the program.

This package **fetches no dependency and needs none**: it has no Zig dependency,
compiles only the sources in its own tree, and downloads nothing at build time.

### As a C library, from the Nix output

```console
nix build .#static      # the default, and upstream's archive form
nix build .#shared
```

Each variant installs the same closure, written by `build.zig` alone:

```
lib/liblmdb.a                      # static
lib/liblmdb.so.1.0.1               # shared, plus liblmdb.so.1 and liblmdb.so
include/lmdb.h
lib/pkgconfig/lmdb.pc
bin/mdb_stat  bin/mdb_copy  bin/mdb_dump  bin/mdb_load  bin/mdb_drop
bin/lmdb-smoke
share/man/man1/mdb_stat.1  mdb_copy.1  mdb_dump.1  mdb_load.1  mdb_drop.1
share/lmdb/LICENSE  share/lmdb/COPYRIGHT          # upstream's own terms
share/lmdb/NOTICE.md  FORK-LICENSE.md  UPSTREAM.md  UPSTREAM.sha256
           README.md  README.zig.md  CHANGELOG.md  FORK-NOTES.md
```

`package.nix` installs nothing beyond running that build once against `$out`, so
there is one writer per path. `UPSTREAM.sha256` installs as the record it is: its
paths are relative to the package root, so it is **not** runnable from a prefix and
the output does not claim otherwise.

`cc $(pkg-config --cflags lmdb) prog.c $(pkg-config --libs lmdb)` for the shared
variant. **For the static variant add `--static`**, because the loader dependency
that `module.c` introduces is recorded in `Libs.private` and only surfaces there:

```console
cc $(pkg-config --cflags --static lmdb) prog.c $(pkg-config --libs --static lmdb)
```

That is not a formality. `module.c` is unit 3 of the archive and it calls
`dlopen`/`dlsym`/`dlerror`/`dlclose` (`module.c:51-66`, `:77-78`), so a static
consumer that omits `-ldl` has an unresolved link; on Windows the same unit
resolves `LoadLibrary`/`GetProcAddress`/`FreeLibrary` from `kernel32`, and on
Darwin there is nothing to add because libSystem already exports those symbols.

The tools carry `$ORIGIN/../lib` (or `@loader_path/../lib`) so they find the
installed library from their own prefix. `package.nix` additionally strips the
build-cache rpath Zig leaves in each installed binary, on ELF only:
`patchelf` does not read Mach-O, and on Darwin the correct entry is already
present, so one dead search-path entry survives there.

### As a C library, from `zig build install`

```console
zig build --prefix "$PWD/out"
```

writes the same layout under `$PWD/out`. This path carries upstream's `LICENSE` and
`COPYRIGHT` **and** this fork's own eight records at `share/lmdb/`, so both
copyright statements that apply reach a binary recipient, as OLDAP-2.8's condition 2
requires.

### Development


```console
devenv shell                                 # tools only; builds nothing
devenv tasks run lmdb:build                  # and the rest of the gates
devenv tasks run lmdb:check-refused-target   # must fail, with the reason
devenv build outputs.static                  # or outputs.shared
```

Tasks: `lmdb:build`, `lmdb:build-dynamic`, `lmdb:test`, `lmdb:test-release-safe`,
`lmdb:smoke`, `lmdb:check`, `lmdb:check-refused-target`, `lmdb:interop`,
`lmdb:consumer`, `lmdb:integrity`. `outputs.static` and `outputs.shared` are the
same `package.nix` the flake calls, left lazy so entering the shell builds
nothing.

Every task body changes into this SDK's own directory before it runs anything.
That directory is named in `devenv.nix` as `builtins.toString ./.` and
shell-quoted, not taken from `$DEVENV_ROOT`, because `devenv tasks run`
materialises a task as a generated script that inherits the directory the
caller was standing in — and the way this shell is driven is `devenv --from
path:<this SDK> …`, from a scratch project holding no `build.zig`, no
`UPSTREAM.sha256` and no `consumer/`. A `cd` that fails ends the task instead
of letting it build where it was.

Every task's `zig build` carries the same three flags, spelled once in
`devenv.nix` so no body can differ: `--cache-dir "$lmdb_build_cache" -j8
--summary all`. The cache directory is `$ZIG_LOCAL_CACHE_DIR/lmdb/build`, named
explicitly on every task because Zig's own default would be `.zig-cache` in the
working directory — this checkout. It is printed on stderr as it is chosen.

`lmdb:build` and `lmdb:build-dynamic` install, and a bare `zig build` installs
into `zig-out` inside this checkout unless it is told otherwise, so both name
`--prefix` under the local cache they already resolved: `lmdb/static` and
`lmdb/dynamic` beneath `$ZIG_LOCAL_CACHE_DIR`, one per linkage, printed on
stderr as they go. The other seven `zig build` steps install nothing — `test`,
`test-release-safe`, `smoke`, `check`, `check-refused-target`, `interop` and
`consumer` — and carry no prefix.

`lmdb:consumer` names the scratch location itself, because the consumer program
refuses to invent one. An exported `LMDB_TEST_SCRATCH` is used as-is; otherwise
the task makes a fresh `mktemp -d` inside the `TMPDIR` you exported and prints
where. It never falls back to `/tmp` or to the checkout, and it sweeps nothing —
the consumer removes the one random child it created and the task adds no
cleanup of its own. With neither `LMDB_TEST_SCRATCH` nor `TMPDIR` exported it
exits non-zero and says which one it wanted.

`devenv` is the canonical environment; `.envrc` is one `use devenv` line for
direnv. This repository publishes **no `devShells` output**, so `nix develop` does
not work here and that is a decision rather than an oversight: a dev shell that
has to build the SDK to be entered is not a fast loop. `devenv` is pinned by
`devenv.yaml`; `flake.nix` is pinned by its own `nixpkgs` input. **`flake.lock`
is in the tree** and records the very commit `flake.nix` names, with its
`narHash`, so `nix build` resolves that pin rather than a branch, and it is
listed in `build.zig.zon`'s `.paths` so a package fetched through `.paths`
receives the resolution along with the flake. `devenv.lock` is not in the tree
and is not listed, and this repository does not invent one: that lock is the
driver's to create from `devenv.yaml`'s input.

`devenv.nix` supplies defaults for `ZIG_GLOBAL_CACHE_DIR` and
`ZIG_LOCAL_CACHE_DIR` only when they are unset; an exported value is never
overwritten or unset. Exporting both before `devenv shell` points them at
approved scratch instead. When one is unset, the default directory is
`$XDG_CACHE_HOME`, or `$TMPDIR` where no cache directory is set, and the only two
directories this shell creates are the ones it chose itself — never the checkout.
With neither a cache directory nor `TMPDIR` set, it prints on stderr that it
chose no location and leaves both variables unset.

The same two variable names, in the same order and under the same two directory
names, are applied inside every task body, because a task is reached without
that hook having run: an exported `ZIG_GLOBAL_CACHE_DIR` or
`ZIG_LOCAL_CACHE_DIR` is left exactly as it is, and with neither a cache
directory nor `$TMPDIR` exported a task names the two it wanted on stderr and
exits non-zero rather than choosing a location.

---

## Licence

Upstream's own code is under **The OpenLDAP Public License, Version 2.8**
(`SPDX-License-Identifier: OLDAP-2.8`). The text ships verbatim as
`libraries/liblmdb/LICENSE` and the copyright notice as
`libraries/liblmdb/COPYRIGHT`; both are in `.paths`, in `UPSTREAM.sha256`, and in
every installed output at `share/lmdb/`.

**OLDAP-2.8 is not the only term in this tree.** A record that names it and stops
there is **wrong outright about two of upstream's 42 files**, **incomplete about
two more**, and silent about five that carry a notice of a different kind:

| Term | Where | Compiled into the library |
|---|---|---|
| OLDAP-2.8, Howard Chu / Symas Corp. | 29 of 42 files restate it; `LICENSE` and `COPYRIGHT` carry the text and the notice | yes |
| ISC-style, Martin Hedenfalk, "derived from btree.c" | `lmdb.h:151-166`, `mdb.c:19-33` | **yes** — both files are core |
| Public domain, Landon Curt Noll, FNV-1a | `mdb.c:5846-5872`, **inside** `#ifdef MDB_USE_HASH` at `mdb.c:5845` | **conditionally** — a third term, on top of the two core ones, and only for `aarch64-macos-none` and `x86_64-windows-gnu` |
| Public domain, D. J. Bernstein | `chacha8.c:1-5` | no |
| **No notice of any kind** | `chacha8.h` — seven lines, no copyright, no grant, no attribution | no |

The Hedenfalk grant is in `mdb.c` and `lmdb.h` — the two files a record naming only
OLDAP-2.8 is **incomplete** about — so it is compiled into **every** supported
target's archive: that record was wrong on all five supported targets, not on some
of them. The two files it is **wrong outright** about are `chacha8.c`, which is
public-domain D. J. Bernstein code and not upstream's work at all, and `chacha8.h`,
which is recorded as carrying nothing rather than being given its companion file's
dedication, because inferring one file's terms for another is an interpretation, not
a reading.

The five it is **silent** about are the man pages. Each carries a copyright line
and `Copying restrictions apply.  See COPYRIGHT/LICENSE.` inside a roff comment
(`mdb_*.1:2-3`) — in the file's bytes and travelling with it, but not the
redistribution sentence and not rendered by `man`. Counting them as "unlicensed"
is as wrong as calling them OLDAP text.

`NOTICE.md` carries the **complete per-file inventory of all 42** — term, the line
range in that file, what the build does with it, and whether an output installs it,
in 35 rows covering 42 files — plus `module.c`'s loader dependency as link metadata,
upstream's five tools and their man pages under their own terms, and every file
this fork adds.

**This fork's own files are also OLDAP-2.8**, on the owner's explicit authorization
for this migration wave, matching the project's primary upstream term rather than
inventing a second one. A generic MIT was considered and rejected and is asserted
nowhere in this tree. [`FORK-LICENSE.md`](FORK-LICENSE.md) records the
authorization, the full file list, what the grant does not reach, and the two
clauses of the OLDAP-2.8 text that constrain how the names in it may be used — one
of which is the paragraph that names the OpenLDAP Foundation, who is **not** an
author of a single file this fork wrote.

`UPSTREAM.md` is the provenance record. `CHANGELOG.md` is the numbered
divergence history. `FORK-NOTES.md` is the decisions and their lessons, in
condition/symptom/fix/target-bound form.
# FORK-NOTES — what was decided, and what it cost

This file records the decisions taken while building this Zig package over LMDB
1.0.1, and the lessons that came out of them. It is the reasoning behind
[`CHANGELOG.md`](CHANGELOG.md); where the two disagree, the changelog records
what changed and this one records why.

Everything here is in **condition / symptom / fix / target-bound** form, so a
observed** says so. That is a real distinction in this package: several of its
most expensive items were found by reading `mdb.c` and the workflow file rather
than by a gate, and the gates have since been run on both. The WASI refusal is
an observation now, and the closure step those readings produced has been deleted
in favour of a digest that fails on a moved byte.

Every gate in this workspace has been **run** at least once, except two, and both
are named in ["What the parent still owns"](#what-the-parent-still-owns) with the
reason: the system-library mode, which needs an installed liblmdb, and the CI
workflow itself, which has never met a runner. **The portability wave after §28
re-ran none of them over its own tree**: what it added is four observed probes,
and the gates that would re-check that tree are listed by name in the same
section. The single table of what was observed, with a receipt for every row, is
in [`README.zig.md`](README.zig.md); this file does not repeat it. What it
repeats is the reasoning — and the history of the gates that were red before they
were green, which is in `CHANGELOG.md` entries 21, 22 and 23.

## Decisions

### 1. The archive is three objects, and `module.c` is one of them

**Decision.** `core_sources` names `mdb.c`, `midl.c` and `module.c`, by name and
not by glob (`build.zig:76-80`).

**Why not drop `module.c`.** Two independent reasons, both from upstream. It is
in `liblmdb.a` (`Makefile:87-88`) and in the shared library built from the same
three (`:90-92`); and `mdb_dump.c` names `mdb_modload`, `mdb_modsetup` and
`mdb_modunload` unconditionally (`mdb_dump.c:270`, `:275`, `:364`), so upstream's
own reference tool does not link against a two-object archive.

An earlier state of this fork did drop it, and compiled a second copy beside
`mdb_dump` instead. That was wrong twice: the archive was no longer the library
the pin names, and the tool had a unit the installed archive does not have.

**Why it stays even though nothing calls it.** The generalisation is the point:

> **What the shipped archive contains is a property of the upstream library, not
> of which facade methods happen to exist.**

A wrapper's API surface is a choice. A library's object list is upstream's. When
the two disagree, upstream wins and the wrapper documents the gap.

**Cost, honestly.** Someone has to notice if a future release adds or drops an
object. That is step 3 of the re-sync procedure in `UPSTREAM.md`, and the CI
closure step is what makes a mistake loud.

### 2. The names are written out, and the licence job is a digest

**Decision.** `core_sources` and `tool_sources` are literals, and the licence job
runs `sha256sum -c UPSTREAM.sha256` — all 43 records — and nothing else.

**Why not a glob in the build.** A glob lets an upstream release add a translation
unit with no decision recorded anywhere. A wrapper's API surface is a choice; a
library's object list is upstream's.

**Why the derived closure step went.** It asked four questions of the files
themselves: does every `.paths` entry exist; is the shipped C set exactly the set
`build.zig` compiles; is every quoted `#include` transitively shipped; does every
file in that closure still carry its notice. That was the right instrument while
`.paths` named individual files. It stopped being one when `.paths` began naming
the whole directory: three of its four questions were then about a manifest that
asserted nothing file-by-file, and the fourth — does the notice travel — is
answered more strongly by a digest of the file that carries the notice than by a
regex over its first lines.

**The generalisation, and it is the reason the step could go.**

> A check is worth its maintenance only while it is checking something that is
> asserted somewhere else. When the assertion it policed is deleted, the check
> has not become safer — it has become theatre, and it costs a reader more than
> it saves them.

**What was lost, said plainly.** Those four questions are still worth asking at a
re-sync, and they are now asked by a person reading `build.zig` and the manifest
rather than by a gate. `sha256sum -c` covers the fourth and the first, because a
moved upstream byte is a moved byte whatever the manifest says; the second and
third are covered by reading two short lists. That is thinner than a gate and it
is the honest trade.

**Cost, honestly.** Neither the deleted step nor the digest job that replaced it
has run on a runner — no `act`, no runner, no push. The digest itself **has**
been run here, outside one: 43 of 43 `OK`.

### 3. The platform loader is declared once, on the module that owns the unit

**Decision.** `loaderSystemLibraries(os_tag)` is added to the `core` module
(`build.zig:453-455`), not once per program.

**Why there.** Zig copies a static library's own link objects onto the link line
of everything that links it (`lib/std/Build/Step/Compile.zig:1064-1088`). One
declaration therefore reaches the facade, the tests, the smoke program, the
interoperability program, upstream's `mdb_dump` and the external consumer
package. Per-program declarations would be six chances to forget one.

**Why the `else` arm panics.** A new operating system added to `lockBackend`
without a decision here would otherwise get a build that links an archive calling
`dlopen` with nothing to resolve it. A log line and a panic make that a build
failure instead of a runtime one.

**`-pthread`, deliberately not repeated.** Upstream puts it on every line
(`Makefile:24`, `:158`). Zig's libc carries the POSIX threads entry points inside
libc on every target this build supports, so asking the linker for a separate
`libpthread` would turn a library that is already complete into a search for a
file that exists only on the machine running the build. The CI gate's plain C
consumer *does* repeat it, because that link line is `zig cc`'s.

**Cost, honestly.** `-ldl` on the non-native Linux targets rests on upstream's own
`LDL` (`Makefile:31`, `:92`, `:158`) plus the fact that `module.c` calls
`dlopen`. Zig 0.16 embeds the glibc link stubs in the compiler binary rather than
in `lib/`, so they could not be read out of the shipped tree for
`aarch64-linux-gnu` or `riscv64-linux-gnu`. The cross matrix is what confirms
them, and it has now been run: both compile, `7/7 steps succeeded` each. The
Windows target compiles too, with `module.c` resolving through `kernel32`. So the
loader dependency is observed for every target this build names a backend for —
observed as a **link**, since `check` executes nothing.

### 4. The lock backend is a table with a refusal, not a default

**Decision.** `lockBackend` names one backend per OS; `refusalFor` stops the
build for anything else; `checkMatrixPartition` re-derives the supported and
refused sets on **every** invocation, not only on `check`.

**Why this is not a preference.** The choice changes `MDB_LOCK_TYPE`
(`mdb.c:965-981`), which is **recorded in the lock file**. Two processes that
disagree cannot open the same environment. Letting an unverified arm of `mdb.c`'s
ladder pick that format on a machine nobody looked at is how a database becomes
unopenable.

**Why the macros are defined rather than left to the ladder.** Defining a macro
with an identical replacement list is well defined (C11 6.10.3p2), so these are
not overrides: they state the selection where it can be read, and they keep
`mdb.c:228-231` — `#error "Ambiguous shared-lock implementation"` — armed
against a second arm appearing silently.

**Why `wasm32-wasi` is refused rather than built with `MDB_NOLOCK`.** `MDB_NOLOCK`
is a runtime flag for `mdb_env_set_flags` that drops the reader liveness table
and the cross-process write lock. Building against it would produce a smaller and
weaker library than the pinned one, with different failure behaviour after a
crash. A refusal with a printed reason is a result; a stub is not.

**Why CI asserts the refusal.** No `continue-on-error`, no `|| true`. A zero exit
fails the job, and so does a failure carrying the wrong reason or a missing
header instead of the refusal. A refusal hidden in a matrix is
indistinguishable from a flaky runner.

**Cost, honestly.** The refusal row has now been run here, and the result is
narrower than a green row and worth stating in exactly these terms: the build
printed the reason and stopped with `error: UnsupportedTarget` inside
`build.zig`, having never invoked the C compiler. No upstream C was compiled for
`wasm32-wasi`, and no result is claimed for one. The **reason** has since been
rewritten against a measurement instead of a reading: it used to say that WASI
has "no `<sys/mman.h>` either", which is not true — the SDK 34 sysroot ships an
optional emulated mman archive, and `<sys/mman.h>` compiles against it — and it
now says what that emulation is and is not (L20). Nothing about the decision
changed: the refusal, `refusalFor`, `lockBackend`, the backend macros and every
gate are untouched. The new wording is `PENDING-VERIFICATION`, because no gate
has printed it yet, and the one string CI asserts,
`there is no shared-lock backend`, is in the old text and the new one alike.

### 5. The error taxonomy is cut at what this code actually checked

**Decision.** `Error` has one member per code a call site can produce, split by
target, and one honest `UnexpectedStatus` for everything else.

**Why two tables.** `ErrCode()` is `errno` except on Windows (`mdb.c:501`), where
it is `GetLastError()` (`mdb.c:409`) — and a Windows build returns a few explicit
`errno` constants of its own besides (`mdb.c:6257`, `:6275`). The two numeric
spaces **overlap**: `ERROR_ACCESS_DENIED` is 5 and the CRT's `EIO` is also 5. A
single table reading every positive code as POSIX would report a permission
failure as a disk error, and no test on a Linux host would ever see it.

**Why the Win32 values are literals.** Zig 0.16's `std` carries no Windows
error-code table, and translating `winerror.h` through `translate.h` to obtain one
constant would drag the whole SDK into every build. The POSIX arm uses the
target's own `std.c.E`, so its numbers come from its headers; the Win32 arm is
written out, each value tied to the `mdb.c` call site that produces it.

**Why `UnexpectedStatus` exists rather than a catch-all.** The two numeric spaces
overlap, so a guess would name the wrong condition. Reporting it distinctly and
leaving `pub const c` reachable is more honest than collapsing it.

**Why `posixStatus` gained `EPERM`, `EROFS`, `EMFILE`, `ENFILE` and `EDEADLK`.**
Each is reachable from a call site in `mdb.c`: `open(2)` at `mdb.c:5416-5420`
supplies the permission, read-only-filesystem, not-found and descriptor-
exhaustion codes; `sem_open` at `mdb.c:6146-6149` on the semaphore backend adds
its own; the `fcntl` lock loops supply the busy and owner-died ones.

**Why `SharingViolation` exists on Windows and nowhere else.** POSIX has no
equivalent status — there the second writer blocks on the lock instead — so no
POSIX build can report it, and the error member says so.

**Cost, honestly.** The Windows table is `SOURCE-CONFIRMED` against `mdb.c` and
Zig's own `lib/libc` headers. **No Windows build has been run in this
workspace.** It is the least-proved part of the package.

### 6. `open` records the attempt, not the success

**Decision.** A private `open_attempted` flag is set **before** `mdb_env_open` is
entered, and a second `open` is `error.EnvironmentAlreadyOpen` after a success
and `error.OpenFailed` after a failure.

**Why.** Upstream's guard against a second open is the data-file descriptor
(`mdb.c:6257`), and `mdb_env_close_active` closes that descriptor on the failure
path without returning `me_fd` to `INVALID_HANDLE_VALUE` (`mdb.c:6508`) — which
happens in exactly one place, `mdb_env_create` (`mdb.c:5029`). A handle whose
open **failed** is therefore spent as thoroughly as one whose open succeeded, and
upstream reports the retry as `EINVAL`.

**The generalisation.**

> A handle is spent by the library's **cleanup path**, not by its success path.
> Any "already done" guard that survives an error is a guard that will fire on
> the retry, and it will blame the caller's argument. Record the attempt.

**Why `close` clears the flag.** After a close the handle is gone; there is
nothing left for `open` to be wrong about, and the way out of a failed open is a
new handle.

### 7. `max_dbs` is a per-open setting, and the docs say so

**Decision.** `OpenOptions.max_dbs` is documented as belonging to the handle, and
every environment-creating entry point in this package sets it — including the
read-only reopen.

**Why it is not on disk.** `mdb_env_create` sizes the slot table to the two
databases upstream keeps for itself (`mdb.c:5028`; `CORE_DBS` is 2 at
`mdb.c:1352`) and only `mdb_env_set_maxdbs` grows it (`mdb.c:5220`).
`mdb_dbi_open` refuses a name once the table is full (`mdb.c:12318`) — including
on a reopen, where the name is sitting in the catalogue and the slot table is
empty. `lmdb.h:1326-1327` makes the setter a precondition of the call.

**The generalisation.** A limit held in a **handle** is not a limit held in a
**file**. Re-opening a resource does not re-acquire it, and a read-only open
needs the same permission a writing open does.

**Cost, honestly.** Every caller must remember it. The facade cannot infer it,
and guessing a default would be inventing a bound the core owns.

### 8. The fixture is upstream's reader, built from this tree

**Decision.** `zig build interop` builds `libraries/liblmdb/mdb_dump.c` against
**this package's archive**, and compares the **body** of `mdb_dump -p` with
`testdata/corpus.txt` byte for byte.

**Why the tool is built here.** An `mdb_dump` found on the machine running the
build is some other version of the reader. Agreeing with it would say nothing
about the pin this package names.

**Why only the body.** The header above `HEADER=END` carries the **memory-map
address** (`mdb_dump.c:124-125`), which is the kernel's choice and differs
between two runs over the same bytes. Comparing it compares two addresses, not
two readers of one file. The deterministic part is the body: the bytes between
`HEADER=END` and `DATA=END` (`mdb_dump.c:136`, `:154`).

**Why the escape rule is not re-implemented.** `mdb_dump -p` writes a printable
byte other than `\` as itself and escapes the rest (`mdb_dump.c:65-84`). Rather
than reimplement that, `interop.zig` **refuses any corpus byte that `mdb_dump`
would escape**, so the plain rendering it uses *is* upstream's rendering for this
input. A corpus that grew a non-printable byte fails that check loudly instead of
silently disagreeing.

**Cost, honestly.** It builds and runs two programs instead of one, so it is
deliberately not part of `test` or `smoke`, which run on every commit. And it was
red twice before it was green: first an undeclared flag in the parser, then a
renderer that emitted the very marker lines `extractBody` removes. Both defects
were in the *harness*, and in both cases the tempting repair was to relax the
expectation until the comparison passed. Neither was taken — the renderer changed,
the expectation did not. `CHANGELOG.md` entries 21 and 22 carry the receipts.

### 9. Scratch goes where the process was started

**Decision.** All four scratch-creating programs read the temporary root at
runtime — `TMPDIR`, and on Windows `TEMP` then `TMP` — create **one** directory
named from 12 random bytes in base64url under it, and delete **only that
directory**.

**Why `std.testing.tmpDir` is not used.** It puts its directory under the
**working directory** whatever the environment says. A host policy that keeps
scratch off the filesystem — and never in a repository checkout — is not honoured
by it. `tests.zig` reads `std.testing.environ`, the environment the test runner
itself was started with.

**Why the path is made absolute.** A relative `TMPDIR` is joined against the
working directory, because `mdb_env_open` is handed a path and needs an absolute
one, and because LMDB does not create the directory — there is no `mkdir`
anywhere in `mdb.c` — so the sandbox has to.

**Why `Environ.getAlloc` and not `getPosix`.** `Block` is `GlobalBlock` on
Windows and `createMap` reads the PEB there; `getPosix` would not compile for the
matrix.

**Why only the child is removed.** The root is shared; another process may be
using it. `deleteTree` on the random child and nothing else, on the normal path
and on the one failure point after the child was created. No creation error is
swallowed: `NotDir`, `AccessDenied`, `ReadOnlyFileSystem` and the rest
propagate.

**Cost, honestly.** `.zig-cache/tmp` remains the fallback when the environment
names no root. That is `std.testing.tmpDir`'s convention and it keeps a host that
configures none portable — it is a fallback, not a claim that writing to the
checkout is fine.

### 10. No SDK source bakes in a host path

There is no fixed temporary path anywhere in `zig/root.zig`, `tests.zig`,
`smoke.zig`, `testdata/interop.zig` or `consumer/src/main.zig`. The storage
policy that keeps scratch on an approved mount is the **parent's** compulsory
environment (`host-scratch.sh`), not a constant in a library a downstream would
inherit. That separation is the point: a package that hardcodes one host's
scratch mount cannot be used on a host without one.

### 11. The licence record is per path, and it had to be re-derived

**Decision.** `NOTICE.md` now states every term present in `libraries/liblmdb/`
with the path and line range where it is written, and distinguishes the files the
build compiles from the files it only carries. It does not stop at the licence the
project is named for.

**Why this was a correction and not a clarification.** The document previously
said, in two places, that "the grant on the C is OLDAP-2.8 and nothing else", and
one table row sent `chacha8.c`/`chacha8.h` to a section that never said what their
terms were. Reading the headers refuted that:

* `lmdb.h:151-166` and `mdb.c:19-33` carry an ISC-style grant from **Martin
  Hedenfalk** for code "derived from btree.c", with the condition that the notice
  appear in all copies. Both files are the compiled core and the installed
  header.
* `mdb.c:5846-5872` carries Landon Curt Noll's **public-domain** FNV-1a notice,
  inside `#ifdef MDB_USE_HASH` at `mdb.c:5845`.
* `chacha8.c:1-5` is **public domain, D. J. Bernstein** — third-party code, not
  upstream's OLDAP work at all.
* `chacha8.h` carries no notice, no grant and no attribution in its own bytes,
  and the DJB statement is recorded for `chacha8.c` alone.
* `crypto.c`/`cryptoc.c` are OLDAP-2.8 and `#include <sodium.h>`, which is a
  dependency on a library this package does not vendor, compile or link.

**Cost, honestly, and a first draft that made it worse.** The material finding is
the Hedenfalk grant, because it is in `mdb.c` and `lmdb.h` — the engine and the
installed header — and is therefore compiled into **every** supported target's
archive. The old "OLDAP-2.8 and nothing else" record was wrong on all five
supported targets, not on some of them. The FNV-1a public-domain notice is a
**third** term layered on top of those two: `MDB_USE_HASH` is defined at
`mdb.c:211` (under `MDB_USE_POSIX_SEM`, which `build.zig:193-195` sets for macOS)
and at `mdb.c:378-379` (under `_WIN32`), so it is compiled only for
`aarch64-macos-none` and `x86_64-windows-gnu`. The three Linux cores still carry
both core terms. `wasm32-wasi` produces no binary — it is in
`refused_check_targets` (`build.zig:145-147`) and the build stops with
`error.UnsupportedTarget` — so no compiled terms apply there at all.

The first draft of this record got that backwards: it claimed the old record
would have been "wrong on the macOS and Windows binaries and right on the Linux
and wasm ones". That was wrong in both halves. The Linux cores are not covered by
OLDAP-2.8 alone — they carry the Hedenfalk grant too — and there is no wasm binary
to be right or wrong about. Corrected in all five files. The generalisable part
survives: a term inside a build conditional has to be stated per target, and a
refused target is not a target whose terms you get to describe.

**What did not change.** No byte under `libraries/liblmdb/` was touched. The
correction is entirely in five documentation files, none of which is hashed by
`UPSTREAM.sha256`, so the record and its validity are untouched — re-checked after
the edit, still 43 of 43 `OK`.

### 12. The cross gate is the published matrix, and this package states only what it owns

**Decision.** The cross gate for this package is
`~/.local/bin/cross-test` over the published Zig 0.16.0 Tier 1/2 table, driven
through a settings-only `cross-test.profile.sh` whose one assignment is
`CROSS_BUILD_STEP=test`. `check` stays as the fast compile-only six-target
matrix it already was, and neither one narrows the other.

**Why the profile is nearly empty.** A profile is trusted Bash the harness
sources, so writing one is choosing how the package is measured, and the ways to
get that wrong are all quiet: a `TARGETS` line that drops the platforms this
build refuses, a `cross_artifact` hook that turns an unavailable runner into an
apparent pass, a `CROSS_BUILD_ARGS` `-Doptimize` that quietly replaces the Debug
gate, and a scratch path that only exists on the machine that wrote it. The
package owns exactly one of those choices — which build step is the gate — and
everything else stays with the harness. Runner detection, resource limits and
scratch placement are `cross-test`'s and its own host policy's, and the profile
says so in a comment rather than leaving the omission to be read as an accident.

**Why the choice is recorded rather than assumed.** `lockBackend`
names a shared-lock decision for Linux, Apple, the three BSDs and Windows.
Anything outside that set is refused at configure time by `refuseTarget`
(`build.zig:322-329`), with the reason printed, and that is a *decision the
build makes about the on-disk
format*: `MDB_LOCK_TYPE` (mdb.c:965-981) is `8` for SysV semaphores and
`10 + LOG2_MOD(ALIGNOF2(pthread_mutex_t), 5) + sizeof(pthread_mutex_t)/4 % 22 *
5` for POSIX mutexes, and it is written into the lock file. An environment
opened by one backend cannot be opened by a build that chose another, so naming
a backend for a platform nobody compiled is how a database becomes unopenable.

**The BSD question, answered by observation rather than by inference.** Before
this wave reached them, the 24 BSD and macCatalyst cells were refused by **this
fork's** decision table, not by upstream's reach: `cross-test` run
`20261002-040728-7930-27044` over `x86_64-freebsd` is exit 1, `build=fail`,
`run=not_run`, `reason=build_failed`, 31.39 s,
`local://foundation-cross-test-before-lmdb-bsd.log`, with no C translation unit
compiled at all because the refusal happened in `build.zig` at configure.
`mdb.c:175-231` does have arms for the BSDs, and every system header the core
can reach outside its `_WIN32`, `__sun`/`__ANDROID__`, `__mips && __linux` and
`USE_VALGRIND` guards is present in Zig's bundled `generic-freebsd`,
`generic-netbsd`, `generic-openbsd` and `any-darwin-any` include sets. What was
*not* readable out of Zig's own source was which macros clang predefines — the
distinction was not academic, because `mdb.c:223-225` defines
`MDB_USE_POSIX_MUTEX` whenever no ladder arm set a semaphore and
`mdb.c:187-189` adds `MDB_USE_SYSV_SEM` whenever `BSD` is defined, so a guessed
`-D` either fails the ambiguity check at `mdb.c:228-231` or, worse, silently
changes a format that is written to disk.

The predefines are now observed. `zig cc -target TARGET -E -dM
libraries/liblmdb/mdb.c` on the pinned Zig 0.16.0 exits 0 for all four targets
(`local://foundation-cross-test-lmdb-target-macros.json`): FreeBSD
`BSD=199506`, `__FreeBSD__=14`, `__FreeBSD_version=1400500`; NetBSD
`BSD=199506`, `__NetBSD__=1`; OpenBSD `BSD=199306`, `__OpenBSD__=1`;
macCatalyst `BSD=199506`, `__APPLE__=1`. The arms landed accordingly:
**macCatalyst joins the existing macOS arms**, and **the three BSDs take an
empty macro list**, which is the answer the observation points at — `mdb.c`
already reaches a decision on its own for all three, and that decision is the
one whose `MDB_LOCK_TYPE` (mdb.c:965-981, checked on open at `:6119` and
`:6132`) matches what a native LMDB built on the platform records. The loader
answer is the same empty list, on each platform's own documentation: FreeBSD's
`dlopen(3)` records `LIBRARY: Standard C Library (libc, -lc)` and needs no
libdl, NetBSD's says the interface is automatically included in every
dynamically linked program and is not a library to link, OpenBSD's is the
runtime-linker interface. **No native source was touched.**

**The six-target baseline was deliberately not widened.**
`supported_check_targets` and `refused_check_targets` are unchanged — five
supported and `wasm32-wasi` refused — because a target is selected by
`-Dtarget=` and the fast compile-only baseline is not the matrix.

**Cost.** Four files, none of them C: the profile, the `.paths` entry, the
`NOTICE.md`/`UPSTREAM.sha256` records that name it as this fork's own file with
no licence asserted, and two switch arms in `build.zig`. `test` was already real
work — `build.zig:788` is `b.addRunArtifact(test_artifact)` over an `addTest` at
`:778` — so no step, target or flag was added, and the six-target `check` still
compiles exactly what it compiled.

**Target bound.** Any package whose cross gate is a harness that discovers a
root profile, and any vendored library whose backend selection is recorded in
its own on-disk format. In the second case the portable move is the platform's
own selection path, not a macro imported from another platform.

### 13. The matrix ran, and the failures it found were the translator's, not the lock backend's

**Decision.** When the 53-cell run finally executed, thirteen cells failed at
build time. One was the designed WASI refusal. The other twelve were this
package's own `translate-c` failing to read a header the C core compiles without
difficulty, and each family got the repair its own failure asked for rather than
a general one — preprocessed headers for the BSD header bugs, the translated
enum's own tag type for `hexagon`, and a `__int128` bridge for the two AArch64
NetBSD cells. `CHANGELOG.md` §28 has each with its receipts; what is decided here
is the order and the boundary.

**Why the header goes through the compiler first.** Aro is not the preprocessor
this repository's C is compiled by. Two of its input assumptions are wrong on
real targets: NetBSD's `__END_DECLS` is `__END_PUBLIC_DECLS`, whose
`_Pragma` Aro leaves in the token stream, and OpenBSD's `mips64/endian.h` will
not define `BYTE_ORDER` without a `__MIPSEL__`/`__MIPSEB__` predefine Aro's MIPS
table does not carry. Both could have been "fixed" by passing `-D__MIPSEL__` or a
replacement pragma, and both fakes would describe a target that does not exist:
those macros decide what the C library headers mean. The compiler that compiles
the C core for these same targets already reads both correctly, so `preprocessedHeader`
lets it expand `translate.h` and hands `translate-c` the result. `-dD` keeps the
`#define` lines, so a macro a C caller reads as a macro still reaches Zig as a
constant — without it `c.MDB_REVERSEKEY`, `c.MDB_CURRENT` and `c.MDB_NODUPDATA`
are expanded away and stop existing.

**Why the enum's tag type is read back rather than written down.** `CursorOp`
spelled `enum(c_uint)` typechecked on x86_64 and failed on `hexagon` with
`expected type 'u8', found 'c_uint'`. `lmdb.h:436-465` numbers nineteen
operations `0..18` and promises nothing about the width, and `translate-c` gives
a C enum the integer type the **target's** ABI gives it — full width where the
ABI always widens, `u8` where it permits narrowing. A hard-coded width is the
facade asserting something the header never said, so the tag type is now the
translated `MDB_cursor_op` and the facade reads the answer back.

**Why the `__int128` bridge is narrow.** NetBSD's `__ALIGNBYTES` macros name
`__int128_t` without the implicit declaration Clang's own preprocessor emits
beside them, so once the header was preprocessed the translator saw a name with
no declaration. The bridge restates only Clang's builtin integer types, under the
compiler's own `__SIZEOF_INT128__` capability macro, ahead of the real header.
It copies no LMDB declaration and changes no ABI; the header a dependent
compiles against is still upstream's byte for byte. It is the same convention the
PCRE2 package in this workspace already uses, and it is the last of the three —
the first repair surfaced it, it could not have been seen before.

**What the run says about the backend, which is the part worth not
over-claiming.** Nineteen foreign Linux cells build, run and fail **all 25**
tests each. That is not a lock-backend defect in this package: `aarch64-linux`
was probed directly and `get_robust_list` returns `ENOSYS` under this host's QEMU
10.0.12, so `mdb_env_open` returns 38 and the facade reports
`error.UnexpectedStatus`. `MDB_NOLOCK` and `MDB_USE_ROBUST=0` both open cleanly
there — and the `NOLOCK` open leaves no `lock.mdb` at all, which is exactly the
weakening this package refuses to ship. Neither configuration was shipped;
`lockBackend`'s `.linux` arm is exactly what it was. **The other eighteen cells
were not probed** when this was written, and the paragraph says so in those words
because that was the state of the record. They have since each been run on their
own, so the sentence is **superseded on that point, not vindicated**: under all
nineteen runners the raw `SYS_get_robust_list` call returns `-1` with
`ENOSYS`, and the robust process-shared mutex then fails to initialise with the
same number: `38` on fifteen of the cells, and `89` on `mips-linux`,
`mipsel-linux`, `mips64-linux` and `mips64el-linux`, where `ENOSYS` is 89.
`mdb_env_open` returns that number unchanged. The same source built for
`x86_64-linux` and run natively **on this host's own kernel** reports
`get_robust_list rc=0 errno=0 length=24`, `robust shared mutex init rc=0` and
`lock after owner death rc=130 expected=130`; that control is scoped to
`x86_64-linux` here and to that probe, and is not a claim about any other
architecture's kernel. What is missing is a **provider that preserves the
semantics**, not a runner and not a diagnosis: those 19 cells do run, on this
host's own `qemu-*` runners, and they fail there. Running them against a kernel
that owns the robust list needs a guest kernel and root filesystem per
architecture, or hardware to run them on, and none of those is on this host —
the installed full-system emulators are `qemu-system-i386` and
`qemu-system-x86_64` only, and there is no other hardware. Upstream QEMU
linux-user cannot stand in for that provider: it answers `ENOSYS` for both
robust-list syscalls unconditionally, and no option, flag or environment
variable changes that.
Nineteen identical failures remain one observation about a signature; what they
now also are is nineteen observations of nineteen runners, which is a different
claim — L18 and L19.

**Cost.** Three fork-side files, none of them C: `build.zig`'s
`preprocessedHeader`, `zig/root.zig`'s `CursorOp` tag type, and the two guarded
typedefs in `translate.h`. Nothing under `libraries/liblmdb/` moved and no digest
was rewritten. The step count of every successful build moved from 7 to 8,
because the preprocessing step is a real step.

**Target bound.** Any fork that translates a vendored C header with a toolchain
other than the one that compiles it. The translator's inputs are the headers, and
the headers were written against a different preprocessor's predefines and pragma
handling.

### 14. The two steps that must execute now ask the executor `Run` asks, not `Query.isNative()`

**Decision.** `interop` and `consumer` share one predicate, `hostCanExecute`
(`build.zig:883-918`), and that predicate is
`std.zig.system.getExternalExecutor` — the same call `std.Build.Step.Run` makes
about the artifact it is about to spawn (`lib/std/Build/Step/Run.zig:1268-1271`).
The two options `Run` derives from the artifact are filled here from this
package's own facts: `.link_libc = true`, because every executable this build
runs links libc, and `.qemu_fixes_dl = candidate.isGnuLibC() and
b.libc_runtimes_dir != null`, because QEMU reaches a foreign dynamic linker only
when a libc-runtimes directory was supplied. The four executor switches
`std.Build` exposes from the build runner (`b.enable_darling`, `.qemu`,
`.wasmtime`, `.wine`) are passed through, because each names a separate program
whose presence on `PATH` a build script cannot know. The result is mapped once:
`.native, .rosetta => true` (`build.zig:895`),
`.qemu => !candidate.isGnuLibC() or b.libc_runtimes_dir != null` (`:910`),
`.wine, .wasmtime, .darling => true` (`:913`),
`.bad_dl, .bad_os_or_cpu => false` (`:916`). The call sites are `build.zig:748`,
where `addInterop` returns before wiring the comparison, and `build.zig:828`,
where `runConsumer` passes `run` or `install` to the nested build.

**Why the old predicate could not answer the question.** `Target.Query.isNative()`
describes **how the target was written**, not what the host can execute:
`isNative()` is `isNativeTriple() and ofmt == null`
(`lib/std/Target/Query.zig:396-398`) over `isNativeCpu() and isNativeOs() and
isNativeAbi()` (`:392-394`), and `isNativeAbi()` is `os_tag == null and abi ==
null` (`:388-390`) — so naming the operating system at all makes it false.
`getExternalExecutor` computes something else entirely, from different facts:
`os_match` is `host.os.tag == candidate.os.tag` and `cpu_ok` is an architecture
comparison with two arch-family allowances (`lib/std/zig/system.zig:48-51`,
`:49-67`), and it then reaches `.native` (`:71-81`). **The consequence was that
the more explicit the target was, the more certainly the gate skipped** — and it
skipped on `-Dtarget=x86_64-linux-gnu`, the one triple that names the target this
host can plainly execute. Nothing about any foreign target was wrong; the native
one, which is the one that carries the fixture, was.

**Why `.qemu` needed a second gate rather than the option above it.**
`qemu_fixes_dl` describes the executor `Run` *will* build; it does not describe
the one `getExternalExecutor` *returns*. The QEMU arm is entered for a foreign
CPU on `!cpu_ok` alone (`lib/std/zig/system.zig:95`), whatever that option says,
so the returned `.qemu` is exactly the case the option has stopped describing.
What settles it is what `Run` then does (`lib/std/Build/Step/Run.zig:1290-1314`):
it appends `-L <runtime triple>` for a cross libc target and, with
`b.libc_runtimes_dir` unset, calls `failForeign` on `--libc-runtimes` (`:1310`)
instead of skipping. On that target a missing directory is a **failure**, so the
honest answer is no, and `.qemu => !candidate.isGnuLibC() or
b.libc_runtimes_dir != null` is that answer. `isGnuLibC()` is the whole of
`Run`'s `need_cross_libc` in this package (`Run.zig:1264-1266`): the musl half of
that disjunction also demands `exe.linkage == .dynamic`, and both executables
here are made with `b.addExecutable` and given no `linkage`, so it never holds
here and the two predicates now test the same fact rather than two that look
similar.

**Observed in both directions, in the driver's session, with no `local://`
receipt file for either.** Before: `zig build consumer interop
-Dtarget=x86_64-linux-gnu` printed `Build Summary: 9/9 steps succeeded`,
`+- consumer package success 9s` and `+- compile exe lmdb-interop` /
`+- compile exe mdb_dump`, with **no** `mdb_dump interoperability` line and no
consumer program output — a successful build of a gate that executed nothing.
After the identical command: `consumer: linked LMDB 1.0.1`, `consumer: committed
records persisted, abandoned ones did not`, `6 records match mdb_dump -p byte
for byte`, `+- mdb_dump interoperability success 24ms`,
`Build Summary: 10/10 steps succeeded`, exit 0. Both argv lines are written out in
`CHANGELOG.md` §30 so either can be repeated.

**What this change deliberately did not touch.** `check` still selects its
matrix by `target.query.isNative()` (`build.zig:1012`), and that is the right
question there: `check` compiles and never runs, so "did the caller name a
target?" is exactly what it needs to know. `test` and `smoke` never asked
anything — `b.addRunArtifact` (`build.zig:989`, `:996-998`) hands the decision to
`Run`, which asks `getExternalExecutor` about the artifact at run time — which is
why this cannot move one cell of the 53-cell matrix. The nineteen foreign Linux
cells are musl targets, their published triples carry no ABI suffix, and they are
exactly the cells this predicate already answered *no* for; their 25-failures-each
result is an observation from an earlier tree (§29), and over **this** tree every
cell of that matrix is `PENDING-VERIFICATION` like the rest. `lockBackend`'s
`.linux` arm, the robust lock, `posixStatus`, `refusalFor` and `refuseTarget` are
not what this change altered;
the WASI refusal is upstream of this in the build graph, since `build.zig:940`
stops a refused target before `interop` (`:1032`) or `consumer` (`:1042`) is
wired, so no executor decision is ever reached for `wasm32-wasi`.

**Cost.** One file and one function: `build.zig`. No C source, no macro, no
backend table, nothing under `libraries/liblmdb/`, and no digest rewritten.
`UPSTREAM.sha256` covers `libraries/liblmdb/` and `testdata/corpus.txt`, neither
of which moved.

**Still unexercised.** The `.qemu` second gate has never been run: no build has
asked `hostCanExecute` about a foreign GNU-libc target with `-fqemu` and no
`--libc-runtimes`. The argument for it is `SOURCE-CONFIRMED` against the pinned
compiler's own `lib/std`, cited above, and the behaviour is
`PENDING-VERIFICATION`. The 53-cell matrix, the six-target `check` baseline, the
native Debug/ReleaseSafe/consumer gates, `zig build interop` on the default
native selection, the installed-C surface, `sha256sum -c UPSTREAM.sha256` and
the package round all remain the parent's, over this tree.

**Target bound.** Zig 0.16.0's `lib/std` as this package pins it, for any fork
whose gate decides between *running* and *installing* — or between comparing and
not — with a predicate of its own. The general form is L21.

## Lessons

Each is condition / symptom / fix / target bound, in the shape the workspace's
learning mandate asks for, and stated so a later wave can apply it without
re-deriving it. Several restate a changelog entry on purpose: a rule that appears
only in a changelog is a rule nobody applies.

### L1 — Reproducing a C library means reproducing its object list

**Condition.** A fork builds a C library from source and publishes a wrapper over
part of it.

**Symptom.** The wrapper exposes none of one unit's API, so the unit is dropped
from the archive — and the upstream tool that names it stops linking, or, worse,
gets a second copy compiled beside it. Neither is observed by the wrapper's own
tests.

**Fix.** Take the object list from the upstream build's own rule
(`liblmdb.a: mdb.o midl.o module.o`, `Makefile:87-88`), ship exactly what it
names, and make the CI closure fail if the shipped set and the compiled set
disagree.

**Target bound.** Any fork of a C library whose upstream build names its objects.

### L2 — A status code's number is not its meaning across targets

**Condition.** A C library returns `int`, and the numeric space of the positive
half is chosen by the library's own `#ifdef`, not by yours.

**Symptom.** One table reads every positive code as POSIX and reports
`ERROR_ACCESS_DENIED` (5) as `EIO` (also 5). No test on a POSIX host can see it.

**Fix.** Switch on the **target**, not on the code. Write out the platform table
with each value tied to the call site that produces it. Keep one honest
`UnexpectedStatus` for the codes neither table names, and leave the raw C
reachable.

**Target bound.** Windows targets; Zig 0.16.0, whose `std` has no Win32 error
table — a later `std` that grows one should replace the literals.

### L3 — Never re-implement a reference tool's escaping; refuse the inputs where
your simple rendering is equivalent

**Condition.** A comparison needs a text rendering of binary records.

**Symptom.** You re-implement the tool's escape rule, it drifts by one case, and
the comparison becomes a comparison of two *of your* renderings — which is
exactly the property the fixture existed to avoid.

**Fix.** Check the corpus against the rule before relying on it, and refuse any
input where the tool would escape something. Then your plain rendering *is* the
reference rendering for that input, and the check is what makes it so.

**Target bound.** Any comparison against a reference CLI that renders bytes.

### L4 — A forward walk of a database with named databases open walks the catalogue

**Condition.** Named databases are open, so the main database carries a catalogue
record for each.

**Symptom.** A walk expects `NotFound` right after the last written key and gets
a record; or it expects the name and gets the name **with its terminator**; or it
expects the writer's insertion order and gets the comparator's.

**Fix.** Write the expectation from the C's comparator — `mdb_cmp_memn`
(`mdb.c:6659-6672`): `memcmp` over the common prefix, the shorter item first,
then plain byte order — and **require** the catalogue entries rather than
stepping over them. A walk that hid them would be walking over less than the
database contains.

**Target bound.** Any LMDB main-database walk; any B-tree whose stack keeps
metadata in the same keyspace as data.

### L5 — The width of a private struct is not a contract

**Condition.** An internal struct leaks into a public API's byte streams — as
here, `mdb_dbi_open` stores a catalogue record of `sizeof(MDB_db)` width
(`mdb.c:12302`, `:12327-12328`, `:12349`).

**Symptom.** A test asserting `sizeof(MDB_db) == 48` passes on a 64-bit target
and is meaningless: `MDB_db` (`mdb.c:1330-1339`) is upstream's private layout, it
follows the word size, and it is free to move.

**Fix.** **Print** the byte count as an opaque number; never assert it. The
deterministic smoke output then still shows something changed, without pinning
something that was never promised.

**Target bound.** Any binding over a C library with `MDB_VL32`-style conditional
widths; 64-bit and 32-bit targets alike.

### L6 — A round trip through your own wrapper is not a fixture

**Condition.** A primary oracle is required for a binding.

**Symptom.** The "oracle" is the package under test, and the only thing proven is
that it agrees with itself.

**Fix.** Build the **reference implementation from the same sources at the same
pin** — here `mdb_dump.c` out of `libraries/liblmdb/`, linked against this
package's own archive — and compare against something recorded independently.

**Target bound.** Any binding whose upstream ships a CLI reader, dumper or
formatter.

### L7 — Compare the deterministic part of a reference tool's output

**Condition.** The tool's output carries a runtime-dependent value.

**Symptom.** Comparing a memory-map address, a PID, a timestamp or an inode makes
a correct implementation fail intermittently, and the failure looks like a
disagreement about data.

**Fix.** Cut the body out between the tool's own marker lines and compare that,
byte for byte, and say in the harness *why* the header is excluded.

**Target bound.** Any comparison against a reference CLI; here
`mdb_dump.c:124-125` versus `:136`, `:154`.

### L8 — Compiling is not proving

**Condition.** A public function nobody calls, and a static archive nobody
links.

**Symptom.** Zig analyses a function body only when something calls it, so a
public entry point that no test exercises is unproven; and a C archive that is
"on the link line" without an executable linking it resolves nothing.

**Fix.** Have the tests call every public entry point, compile the tests, the
smoke program and the interop program for **every** target of the matrix, and
make the reference tool link the archive so `module.o` is actually pulled out of
it.

**The refinement, learned by getting it wrong first.** This gate originally named
the loader's three symbols through a `void *volatile` array, reasoning that a
comparison against `NULL` may be folded away and a reference the optimizer
deletes is a reference the linker never sees. The reasoning is sound and the
method is weaker than it looks: it proves the symbol resolved, and nothing else.
The gate now **calls** `mdb_modload` for a module that is not there and requires
the loader to refuse it with a reason. That pulls `module.o` out of the archive
the same way, resolves its `dl*` calls against `-ldl`, cannot be deleted by any
optimizer, and decides something besides:

> A reference that produces an observable the gate checks beats a reference that
> merely exists — and the second kind is the kind that rots silently.

**Target bound.** Zig 0.16.0's lazy analysis; any static archive.

### L9 — Do not assert the fork's own bookkeeping

**Condition.** A change is tempting to "prove" with a test that reads the fork's
own state.

**Symptom.** The test passes when the code is wrong in the same way the test is,
and fails when a legitimate refactor lands. Four were found and deleted here: an
assertion comparing a string literal with itself; a version-**major** smoke gate;
`sizeof(MDB_db)`; and a smoke assertion comparing a **key** against
`entry.value`.

**Fix.** Delete them. Keep the ones that state an upstream contract and observe
the compiled core: a behavioural boundary, an ownership transition, an error
path, an independent known answer, an interoperability result. Print the version
rather than pinning it; version pinning belongs to the integrity record.

**Target bound.** Every fork in this workspace; the policy is in `AGENTS.md` §7.

### L10 — `std.testing.tmpDir` ignores the temporary root, and LMDB will not
create the directory either

**Condition.** A suite or example needs scratch space, and the host keeps scratch
on an approved mount rather than beside the sources.

**Symptom.** Every environment lands under the working directory; or, after
fixing that, `mdb_env_open` fails because nothing created the directory and the
relative path it was given resolves somewhere the process did not intend.

**Fix.** Read the temporary root at runtime (`TMPDIR`, then `TEMP`/`TMP` on
Windows), join a relative value against the working directory so the C gets an
**absolute** path, create the root and exactly one random child, and delete only
that child on every exit path.

**Target bound.** Zig 0.16.0's `std.testing.tmpDir`; any library that requires
its directory to pre-exist (`mdb.c` contains no `mkdir`).

### L11 — A CLI-visible refusal belongs in CI, asserted, with its reason

**Condition.** A target cannot be built, and that is the correct answer.

**Symptom.** The target is either dropped from the matrix silently, or put in the
matrix in a way that a flaky runner and a real refusal look the same.

**Fix.** Put it in its own job, assert a **non-zero** exit, assert the exact
reason string appears, assert the typed error name appears, and assert a
compiler-level failure ("no such file or directory") does *not*. Re-derive the
supported/refused partition on every build so a new backend cannot leave the
refusal list stale.

**Observed — and narrower than a green row, which is the point.** The WASI gate
stops inside `build.zig`: the reason is printed and the build returns
`error.UnsupportedTarget` from `refuseTarget`, so the C compiler is never
invoked. That is the strongest form of the refusal, because it is decided from
the source of `mdb.c` and from what the target's libc has, not from whatever a
compiler happens to emit for that target — and it is exactly why the result has
to be stated narrowly. **No upstream C was compiled for `wasm32-wasi` and none is
claimed.** The reason printed when it was last observed said, in its own words,
that WASI's libc supplies none of the four shared-lock backends — no
`<semaphore.h>`, no `sem_open`, no `<sys/sem.h>` — and "no `<sys/mman.h>` either,
so there is no `mmap`". **That last clause was wrong, and it is withdrawn**: the
WASI SDK 34 sysroot carries an optional emulated mman archive, `<sys/mman.h>`
compiles against it and `mmap` links. The reason now says what was measured
instead — no POSIX named-semaphore or SysV-semaphore backend, and
`pthread_mutexattr_setrobust` rejects robust locking; the emulated mman **does**
provide `<sys/mman.h>` and `mmap`, but implements a `malloc`/`pread` snapshot,
not shared file mappings or write-back, and `msync` is unavailable; WASI threads
share one module's memory, not independent processes; so neither facility
supplies LMDB's shared locking and persistence. The refusal is unchanged, and so
is `MDB_NOLOCK` being refused as a substitute, because it is a runtime flag that
drops the reader liveness table and the cross-process write lock, not a build
configuration. **The corrected wording is `PENDING-VERIFICATION`** — no gate has
printed it — and it is quoted from `build.zig`, not from a run. The lesson is
unchanged by any of this: the reason a refusal prints is part of the result, so
it has to be as true as the refusal, and a gate that asserts only *that* a target
is refused will never notice a reason that has quietly become false.

**Target bound.** Any build system with a target that is genuinely unsupported
rather than merely unbuilt; here `wasm32-wasi`.

### L12 — A `.paths` entry is a path, not a name

**Condition.** A package manifest lists the files a dependent receives.

**Symptom.** `"LICENSE"` is on the list and the file is at
`libraries/liblmdb/LICENSE`. Nothing compiles it, so the build passes, the tests
pass and a dependent receives a manifest that names a file it does not have.

**Fix.** Name the real path, and add a gate that asserts every `.paths` entry
exists in the tree. Nothing else catches this class of mistake.

**Target bound.** Any package manifest with a path list; Zig 0.16.0's
`build.zig.zon`.

### L13 — Two receipts of different scopes must never be compared

**Condition.** A provenance record and an archive digest both describe "the
sources".

**Symptom.** A re-sync asserts the two numbers are equal. They never will be: one
is a per-file hash of **42 of the repository's files**, the other is a digest of
the **whole upstream tree as a stream**.

**Fix.** Say, in both files, which set each covers, which one is replayable
without a network, and that a difference between them is not corruption. Hash
only what upstream wrote; never hash a fork file, or every fork edit invalidates
the record.

**Target bound.** Any fork with both a per-file record and an upstream archive
receipt.

### L14 — Line numbers from a dump are off by one; `grep -n` is the authority

**Condition.** Doc comments cite `file.c:line` as the evidence for a claim.

**Symptom.** A number taken from counting lines in a `sed -n 'A,Bp'` dump lands
one line off, and a later re-sync reads the wrong line. This package's own
records were re-checked while these notes were written: `mdb_dump.c:136` and
`:154`, `mdb.c:5028`, `:5029`, `:12327-12328` and `:12349` are all correct, but
two line numbers cited elsewhere in the package — `mdb.c:1021-1030` and
`mdb.c:1053-1059`, both in `zig/root.zig` — point at a page-layout comment
rather than at the setter they describe. The actual sites are `mdb.c:5228`
(`mdb_env_set_maxreaders`, zero refused) and `mdb.c:5220`
(`env->me_maxdbs = dbs + CORE_DBS`).

**Fix.** Take every cited line from `grep -n` for the exact token, not from a
printed range. When a cited range is wrong, fix the comment: a wrong line number
is a claim about the upstream source, and it is the claim a re-sync trusts.

**Target bound.** Every documentation set in this workspace. The two line
numbers above are outside this record's ownership (`zig/root.zig` is the
facade's file) and are named here so whoever owns that file can correct them.

### L15 — "One licence, named after the project" is a claim to refute, not a premise

**Condition.** A fork's `NOTICE.md` names the licence of the upstream project and
counts how many carried files restate it.

**Symptom.** The count is right, the files are right, and the record is still
wrong, because the count answers "which files restate *this* sentence" and not
"what terms are in this tree". In LMDB the 29-of-42 count and the 13-file
remainder were both accurate on every re-check, and the document still asserted
that the grant was "OLDAP-2.8 and nothing else" while `lmdb.h` and `mdb.c` carried
a second grant in the compiled core and `chacha8.c` was public-domain code that is
not upstream's at all. The tell is a sentence of the form *X and nothing else*:
that is a universal claim, and no file-count check can establish one.

**Fix.** Build the inventory per path from the sources, not from the project's
name: grep every carried file for `copyright`, `permission is hereby granted`,
`public domain`, `derived from` and the project's own licence sentence, and record
what each file says with its line range. Then separate three questions the count
conflates — which term applies, **whether this build compiles that file**, and
whether the file is only carried. A dependency is a fourth thing again: an
`#include` of an external library is not a grant and no licence text is owed for
it, but it is also not nothing, so it gets its own row rather than being folded
into the default.

The part worth generalising is the conditional one, and it cuts against a mistake
I made while writing this very lesson up. `mdb.c` carries the public-domain FNV-1a
notice inside `#ifdef MDB_USE_HASH`, reached only when the lock backend selects it,
so the same source file is under a **third** term for `aarch64-macos-none` and
`x86_64-windows-gnu` and under the two core terms for the three Linux targets. The
first draft of this entry said the record "would have been wrong on the macOS and
Windows binaries and right on the Linux and wasm ones" — wrong twice: the Linux
cores also carry the Hedenfalk grant, and `wasm32-wasi` is refused outright
(`build.zig:145-147`, `error.UnsupportedTarget`), so there is no wasm binary to be
right about. **A licence claim that is conditional on a build macro has to be
stated per target or it is not a claim at all**, and **a refused target has no
compiled terms to describe at all** — do not extend a target matrix over a target
the build does not produce. The per-target split is `SOURCE-CONFIRMED` from the
macro lists `build.zig` passes, except the Windows row, which is inferred from the
target's own `_WIN32`; `NOTICE.md` separates the read from the inference.

The companion error is the mirror image, and it is the one to guard against on the
way to a per-path record: having found that `chacha8.c` is public-domain D. J.
Bernstein, it is tempting to say the same of `chacha8.h` because the source
includes the header. **Do not assign one file's terms to another by association.**
`chacha8.h` has no notice, no grant and no attribution in its own bytes, and
recording a term there is this fork writing a grant its author never wrote —
a legal interpretation dressed as a reading, and therefore not a `SOURCE-CONFIRMED`
claim at all. State what each file says about itself and stop there.

**Target bound.** Any fork that carries a whole upstream directory rather than
the four files it compiles, and any upstream that retains third-party code in its
own files — which is most of them. Re-derive on every re-sync: this very release
carries `CHANGES:9`, ITS#10540 "cleanup outdated license notices", so the set of
retained notices is something upstream is actively editing.

### L16 — A settings-only harness profile is the honest default, not an empty one

* **Condition.** A harness discovers `./cross-test.profile.sh` at the project
  root and sources it as trusted Bash before it reads any matrix or runner
  name.
* **Symptom.** **Not a failure.** The package cannot say how it wanted to be
  measured, and a package that *does* ship a profile has a new way to be wrong:
  a `TARGETS` line that quietly drops the platforms the build refuses, an
  artifact hook that turns an unavailable runner into an apparent pass, an added
  `-Doptimize`, or a scratch path that exists only on the writing machine.
* **Fix.** Write the one decision the package owns — `CROSS_BUILD_STEP=test` —
  and put every non-decision in a comment saying why it is absent. Ship it in
  `.paths` and record it in `NOTICE.md` with no licence asserted, because it is
  executed code, not documentation.
* **Target bound.** Any package measured by a harness that discovers a root
  profile. Runner policy stays with the harness, and that is what keeps a
  runner-less target at build-only.

### L17 — "Which backend does it use?" is a question about clang, not about the vendored source

* **Condition.** A vendored C library selects a lock backend in an `#if`
  ladder keyed on compiler predefines — LMDB's `mdb.c:175-231`, keyed on
  `__APPLE__`, `BSD`, `__FreeBSD__`, `__FreeBSD_version`, `__FreeBSD_kernel__`,
  `__ANDROID__`, `__HAIKU__`.
* **Symptom.** **Reads like source and is not source.** The ladder is perfectly
  legible; the *inputs* are not. Nothing in Zig's `lib/std` or `lib/libc` says
  whether clang predefines `BSD` for a NetBSD target — that lives in clang's
  `InitPreprocessor.cpp`, which is not in the distribution. Two of the four
  candidate answers are safe and two are not: `mdb.c:223-225` defines
  `MDB_USE_POSIX_MUTEX` whenever no arm set a semaphore, and `mdb.c:187-189`
  adds `MDB_USE_SYSV_SEM` whenever `BSD` is defined, so `-DMDB_USE_POSIX_MUTEX`
  is right exactly when `BSD` is absent and fails the ambiguity check at
  `mdb.c:228-231` when it is present.
* **Fix.** Read what *is* in the toolchain — Zig's include-path assembly
  (`lib/std/zig/LibCDirs.zig`) and the actual header directories — and treat the
  macro set as an observation the parent must take, not as an inference to
  publish. Where a platform's own selection path is well defined under every
  reachable input, letting it choose is both safer and more format-compatible
  than naming a backend imported from another platform.
* **Target bound.** Any vendored library whose backend, allocator or wire format
  is chosen in a preprocessor ladder. The same rule applies to anything keyed on
  `__GLIBC__`, `__MACH__` or `_MSC_VER`.
* **Why it matters more than it looks.** The backend is recorded in the on-disk
  format — `MDB_LOCK_TYPE` at `mdb.c:965-981` is `8` for SysV semaphores and a
  `pthread_mutex_t`-derived value for POSIX mutexes, written into the lock file
  and checked on open at `mdb.c:6119`/`:6132`. A wrong guess does not fail a
  build; it produces a library that silently writes a database the platform's own
  LMDB cannot open.

### L18 — Nineteen identical failures are one diagnosis, not nineteen

* **Condition.** A cross-run returns many cells failing the same way: here
  nineteen foreign Linux cells, each reporting `0 pass, 25 fail (25 total)` and
  each trace ending `mdb_env_open` → `error.UnexpectedStatus`.
* **Symptom.** The temptation is to write "the same defect causes 19 failures"
  and call the row verified. That converts one observation into nineteen.
* **Fix.** Probe **one** cell with something outside the harness — a diagnostic
  program, a `-D` variant, a `-strace` — and record what the probe proved. Here
  that was `qemu-aarch64 -strace` putting `get_robust_list = -1 ENOSYS` right
  after the `lock.mdb` `mmap`, which is a cause. The other eighteen share a
  *signature*; say so in those words. Nineteen cells that fail identically is one
  observation about the signature and one about the cause.
* **Target bound.** Any gate that returns a table of per-target results. Also
  applies to `build_only`, which is a **third** answer and not a near-pass: it
  means the compile worked and nothing was executed, so it says nothing about
  runtime at all.
* **Why it matters more than it looks.** A wrong shared cause sends the next
  wave to edit the library instead of the harness, and the two configurations
  that would have made these nineteen cells green — `MDB_NOLOCK` and
  `MDB_USE_ROBUST=0` — are exactly the two that weaken or drop the lock. A
  premature "same defect, same fix" conclusion has a working-looking green
  matrix on one side of it and a library that no longer locks on the other.

* **Superseded example, kept as the rule's own history.** When this was written,
  one cell of the nineteen had been probed and eighteen had not. All nineteen
  have since been run individually and every runner answered `ENOSYS`, so the
  example is no longer a caution about leaving cells unprobed. **The rule is not
  weakened by that**, because it was never about how cheap a probe is — it is
  about which claim a receipt supports. Nineteen identical signatures are still
  one observation about a signature; the nineteen runs are nineteen observations
  of nineteen runners. "All nineteen runners answered `ENOSYS` under their own
  probe" is a stronger row and now a true one; written a day earlier it would
  have been exactly the over-claim this lesson warns against.

### L19 — User-mode emulation has no robust list: measure the runner, never stub the probe

* **Condition.** A library needs a kernel facility that its libc exposes as a
  **capability probe** before it will use it, and the only way to execute foreign
  cells on this host is a user-mode emulator. Here: a robust process-shared
  mutex, where musl calls `SYS_get_robust_list` first
  (`pthread_mutexattr_setrobust.c`, `if (r) return r;`) and declines the
  attribute when that call fails.
* **Symptom.** Every foreign Linux cell compiles, runs, and fails all 25 tests
  with one identical trace ending `error.UnexpectedStatus`, while the native cell
  is green. The honest one-line cause ("this runner answers `ENOSYS`") and the
  tempting wrong one ("the lock backend is wrong") look identical in test output
  alone.
* **Fix.** Ask the runner, not the suite. One small program, compiled per target
  with the real compiler and run under that cell's own `qemu-*`, that calls the
  raw syscall itself (`syscall(SYS_get_robust_list, 0, &head, &len)`), then
  initialises the process-shared robust mutex, forks, and lets a child leave by
  `_Exit` while owning it — so that only the **kernel's** list can mark owner
  death — and run the *same* source natively as the control. That is
`local://foundation-portability-robust-initial-diagnostics.json`: `ENOSYS` in
all nineteen foreign runners (`errno=38` on fifteen of them, `89` on the four
MIPS cells, where `ENOSYS` is 89) and, natively on this host's own
`x86_64-linux` kernel, `get_robust_list rc=0 errno=0 length=24`,
`robust shared mutex init rc=0`, `lock after owner death rc=130 expected=130`,
exit 0 — which means `pthread_mutex_consistent` and the relock passed too.
Read `errno`'s **name** per architecture, never its number: `38` and `89` are
the same answer.
* **Targets bound.** QEMU linux-user ≥10.0.12 on a Linux host; any foreign Linux
  target whose guest libc is musl; any library whose shared lock uses
  `PTHREAD_MUTEX_ROBUST`. That upstream returns `ENOSYS` unconditionally for both
  robust-list syscalls, in 10.0.0 and in master, with no knob and no environment
  variable, is `SOURCE-CONFIRMED` from upstream's own `linux-user/syscall.c` as
  cited in `local://foundation-portability-qemu-provider-report.txt` — it was not
  observed here, and the observation above is the installed runners' behaviour
  rather than that source reading. What is lost is precisely **process death by
  signal**: musl's userspace walk still recovers ordinary thread death, and only
  the kernel list recovers a process killed outright.
* **Targets not bound, and not negotiable.** No `MDB_NOLOCK`, no
  `MDB_USE_ROBUST=0`, and no `get_robust_list` shim that answers success. All
  three buy a working-looking green matrix over a library that no longer
  recovers owner death; the third additionally lies to a probe that user-mode
  emulation cannot make true. What those 19 cells need is a **provider that
  preserves the semantics** — a guest kernel and rootfs per architecture, real
  hardware, or a runner that actually delivers the kernel-side robust-list walk
  — and no such provider is on this host: `/usr/bin` lists only
  `qemu-system-i386` and `qemu-system-x86_64`, there is no foreign kernel or
  rootfs, and there is no other hardware. Bringing a provider of our own was
  never the obstacle: what is out of bounds is changing the shared tool
  installation, not standing one up beside it, and nothing of the kind has been
  built, measured or owner-death-proved here. A runner that forwarded those two
  syscalls would be a change to a vendored emulator rather than a setting of the
  installed one, whose `ENOSYS` has no knob at all. The bounded 64-bit-LE
  pass-through sketched in the provider report is a source-grounded argument
  about five of the nineteen, labelled there as an unrun hypothesis; it is
  evidence for no cell and is not relied on here.

### L20 — A header and a symbol being present is not a facility

* **Condition.** A target is refused for lacking a facility, and the reason was
  written from reading its libc's headers: here `<sys/mman.h>` and `mmap` for
  LMDB, stated as though the header's absence settled it.
* **Symptom.** The claim is universal and false — WASI SDK 34 ships an optional
  `libwasi-emulated-mman.a`; `<sys/mman.h>` compiles with
  `_WASI_EMULATED_MMAN` and `mmap` links. The refusal is still *correct*, so the
  wrong reason survives every review and every gate that only checks that the
  target is refused.
* **Fix.** Measure the facility on the real provider and write the reason in
  those terms. The SDK 34 probe prints
  `pshared=0 robust=28 second_snapshot=31 persisted=31`: `PTHREAD_PROCESS_SHARED`
  is **accepted** (`0`), `PTHREAD_MUTEX_ROBUST` is rejected with `EINVAL` (`28`),
  and the `0x52` written through a `MAP_SHARED` mapping reads back `0x31` in a
  second mapping of the same file and `0x31` from the file after `munmap` — a
  `malloc`/`pread` snapshot, not a shared mapping and not write-back — while
  `msync` is not in the archive and an attempted call to it failed to link. The
  reason that survives is **no shared mapping, no write-back, no
  independent-process robust lock**, which is true whether or not the header is
  there. Write that, and keep the refusal.
* **Targets bound.** Any refusal written from a header set rather than from a
  run: sandboxed and WASI-like libcs, capability-restricted runtimes, and any SDK
  shipping an optional compatibility archive. It is also the reason a CI job
  should assert the *content* of a refusal message and re-derive it when the
  provider moves, not merely that the target is refused.

### L21 — A step that must execute has to ask `std`'s own executor question; "is this target native?" is a different one, and it is false on the host's own triple

* **Condition.** A build graph has a step whose value **is** the execution — a
  consumer package spawned as its own nested `zig build`, or an interoperability
  comparison between two programs the build just made — and that step has to
  decide, for the target it was handed, whether to run the thing or to build it
  and stop. Here: `build.zig:828`, `run.addArg(if (…) "run" else "install")`, and
  `build.zig:748`, `if (!hostCanExecute(b, target)) return;`. The natural
  predicate is `Target.Query.isNative()`, and it is the wrong one.
* **Symptom.** The gate reports success while executing nothing, and it does so
  *loudest exactly where it matters most*. `Query.isNative()` is
  `isNativeTriple() and ofmt == null` (`lib/std/Target/Query.zig:396-398`) over
  `isNativeCpu() and isNativeOs() and isNativeAbi()` (`:392-394`), and
  `isNativeAbi()` is `os_tag == null and abi == null` (`:388-390`) — so the
  act of naming the OS makes it false. Observed here: on an x86_64 Linux host,
  `zig build consumer interop -Dtarget=x86_64-linux-gnu` printed
  `Build Summary: 9/9 steps succeeded`, `+- consumer package success 9s` and two
  `compile exe` lines, with no `mdb_dump interoperability` step and no consumer
  output. Exit 0. Every foreign target was honestly skipped; the target the host
  can plainly execute was skipped too, and the fixture that gate exists to prove
  was never compared.
* **Fix.** Ask the question the spawn will actually be governed by:
  `std.zig.system.getExternalExecutor` (`lib/std/zig/system.zig:42`), which is
  what `std.Build.Step.Run` itself calls about the artifact it is about to spawn
  (`lib/std/Build/Step/Run.zig:1268-1271`). Fill its options from the artifact
  the way `Run` fills them — `.link_libc` from whether the program links libc,
  `.qemu_fixes_dl` from whether a libc-runtimes directory was supplied — plus the
  executor switches the build runner resolved, and map the returned executor
  once, in one function both call sites use. Then **check the option you passed
  against the executor you were handed**: `getExternalExecutor` enters its QEMU
  arm for a foreign CPU on `!cpu_ok` alone (`system.zig:95`), whatever
  `qemu_fixes_dl` says, and `Run` then turns a cross-libc target with no
  libc-runtimes directory into `failForeign` rather than a skip
  (`Run.zig:1290-1314`, `:1310`). A foreign **GNU**-libc target under QEMU with
  no directory is a failure, so the gate must answer *no*, which is a second test
  on the returned executor and not a reading of the option. Forward the executor
  switches to the nested build too (`build.zig:835-840`), or the nested build
  runs under a different executor than the one the decision was made with.
* **Targets bound.** Zig 0.16.0's `lib/std` as pinned, and any build script that
  decides between running and not. It is also the reason the honest default for
  such a step is to be *pessimistic in the direction that cannot hide a failure*:
  where the executor would hard-fail rather than skip, answer no, and let the
  step install — and say so, because install-only is compile evidence and a
  reader who is not told will read it as a pass. Two boundaries worth keeping in
  the same breath: a step that legitimately compiles and never runs (`check`
  here, still keyed on `Query.isNative()` at `build.zig:1012`, for the different
  and correct reason "did the caller name one target or walk the matrix?"), and a
  step that never asked at all (`test` and `smoke`, which hand the decision to
  `Run` through `addRunArtifact`) — so the repair's blast radius is the two
  steps that asked, and no matrix cell moves with it.

## What the parent still owns

These are the adjustments that are **not** in this record's ownership, stated
exactly, so nothing is lost between the documentation and the gates.

### Gates that have not run

| Gate | Why it is outstanding |
|---|---|
| `zig build -fsys=lmdb` | Never run; it needs an installed liblmdb with a matching header, and no such installation was used here. The installed-artifact receipts are this package's **own** `zig-out/` contents and the `zig cc` program run against them — not a system library, and not evidence for this row |
| `.github/workflows/verify.yml` | Never run; no `act`, no runner and no push. Its licence job is the digest, which **has** been run here, and every other step it takes is a command an observed receipt already names |
| execution of any `check` target | Impossible by construction: `zig build check` compiles and never runs. Five triples compiled and the sixth refused, in the original round and in the re-run; nothing in that six-target matrix has executed anywhere |
| the 32 build-only cells of the 53-cell run | Compiled, then reported `run=unavailable` because this host detects no runner for them — BSDs, macOS, macCatalyst and Windows. **Build-only is not a pass** and says nothing about runtime; see `CHANGELOG.md` §28 |
| a cause for 18 of the 19 foreign Linux run-failures | **Closed, and closed by observation rather than by argument.** Every one of the nineteen runners has since been asked directly, and all nineteen answer `ENOSYS`: `get_robust_list rc=-1 errno=38 length=0` and `robust shared mutex init rc=38` on fifteen of them, and `89` on `mips-linux`, `mipsel-linux`, `mips64-linux` and `mips64el-linux`, where that is `ENOSYS`'s number. What replaced this row is not a smaller gap but a different one, and it is the row below |
| real execution of the 19 foreign Linux cells **against a kernel that owns the robust list** | **Outstanding, and it is a provider boundary rather than a documentation gap or a runner problem.** The nineteen cells are not unrunnable and are not reported as unavailable: each one builds, runs on this host's own `qemu-*` runner and fails all 25 tests, which is the row above. What is missing is a provider that preserves the semantics — a guest kernel and root filesystem for each architecture, or hardware to run them on. None is here: `/usr/bin` lists only `qemu-system-i386` and `qemu-system-x86_64`, there is no foreign kernel or rootfs, and there is no other hardware, while the installed user-mode runners answer `ENOSYS` with no knob that changes it. Bringing in a private provider was never what blocks this row, and nothing of the kind has been built or measured. Nothing in this package can close this row, and nothing in it should be changed to pretend otherwise |
| this portability wave's own gates | Apart from the two explicit-target runs of decision 14 — `zig build consumer interop -Dtarget=x86_64-linux-gnu`, before and after the `hostCanExecute` change, observed in the driver's session with **no `local://` receipt file** — `zig build check -Dtarget=wasm32-wasi` for the corrected reason text, the native Debug/ReleaseSafe/consumer re-verification, the six-target `check` baseline, the 53-cell matrix, `zig build interop` on the default native selection, the installed-C surface, `sha256sum -c UPSTREAM.sha256`, and `zig fetch` with the 43-line record and the consumer inside the fetched copy: **none has been re-run over this wave's tree**, and each is `PENDING-VERIFICATION`. The wave changed a printed reason and no upstream byte, so the 43 records are untouched by it — but "unaffected" is an argument, and only a re-run is a receipt |
| `zig build interop` and the installed-C program on the current tree | **Split, and both halves are stated.** `zig build interop` has now been observed on this tree for one target selection — the explicit `-Dtarget=x86_64-linux-gnu`, where the harness ran and printed `6 records match mdb_dump -p byte for byte` with `Build Summary: 10/10 steps succeeded` (`CHANGELOG.md` §30). The **default native selection has no receipt over this tree**, so the `7/7` and `8/8` step counts of §28 and §29 were not re-measured, and **the installed-C program has not been re-run at all**. Both have receipts only from earlier trees |
| the foreign-GNU-under-QEMU branch of `hostCanExecute` | **Never exercised.** No build has asked `hostCanExecute` about a foreign GNU-libc target with `-fqemu` and no `--libc-runtimes`, so the arm that keeps such a target on `install` is `SOURCE-CONFIRMED` against the pinned compiler's `lib/std/zig/system.zig:95` and `lib/std/Build/Step/Run.zig:1290-1314`, and `PENDING-VERIFICATION` as behaviour |
| the final filtered package round | The last round on record is the workspace package-regression run of 2026-10-02T12:13–12:18Z, and it did run over a later tree than the historical `foundation-expansion-…` logs: `zig fetch` printed `lmdb-1.0.1-tSeszSGFEQCKyjxN9BejhfjEWphAgfZqtC9Qbzh22EgG` with 16 `.paths` entries and 61/61 files, the 43-line record checked 43/43 in the source **and** 43/43 inside the fetched copy with the two manifests byte-identical, and the consumer inside the fetched copy exited 0. That round ran over the post-§28 tree and predates **both** of this wave's `build.zig` changes (§29 and §30), so the round over **this** wave's tree has not run and nothing is claimed for it. `UPSTREAM.sha256` itself is unaffected by either — it covers `libraries/liblmdb/` and `testdata/corpus.txt`, and neither moved |

What **has** run since §28, and is recorded with a receipt in the single gate
table in `README.zig.md`: the full 53-cell matrix, `bash -n` over the profile and
both `cross-test --list` listings, the native Debug/ReleaseSafe/consumer
re-verification, and the six-target `check` baseline re-run. Since then the
portability wave has added four observed probes and nothing else: the nineteen
foreign Linux runners each asked about `get_robust_list` and about initialising
the robust process-shared mutex, that same probe run natively on `x86_64-linux`
— where this host's own kernel makes the owner-death,
`pthread_mutex_consistent` and relock path green, and which is evidence for
that cell here and for no other architecture —
the native 32-bit `x86-linux` run recorded `UNAVAILABLE` as an exec-format
refusal rather than a robust failure, and the WASI SDK 34 prerequisites.
**Decision 14 then added two more, and they are the only build-level runs this
wave has produced**: `zig build consumer interop -Dtarget=x86_64-linux-gnu` once
before the `hostCanExecute` change and once after it, both observed in the
driver's session with **no `local://` receipt file**, both written out with
their argv in `CHANGELOG.md` §30. Apart from that pair, **no build, test, `check`,
matrix, interop, packaging or integrity gate of this package has been re-run
since**, which is what the rows above say.

### `build.zig.zon` `.paths` — the open question, closed: ship the whole directory

**Decision.** `.paths` is 16 entries and names `libraries/liblmdb` as a
directory, not forty-two individual paths. Everything upstream wrote for `liblmdb`
travels — the three core units, the reference tool, both headers, the other four
tools, the man pages, the test programs and sample databases, the build
definitions and release notes, upstream's own `.gitignore`, and the two legal
files — and so do this repository's five records and `UPSTREAM.sha256`.

**What decided it.** Not "the documents are nice to have". The integrity record
covers 43 files, the manifest shipped eight of the 42 upstream ones, and three
documents had to explain why 34 lines of a check would fail anywhere outside this
repository. A record that describes a package nobody should build is worse than
no record: it teaches a reader that the package is expected to be incomplete.

**The second reason is the licence one.** OLDAP-2.8's conditions apply to the
whole of what upstream wrote, so the whole of it travels. That makes the
condition-3 verbatim `LICENSE` copy structural rather than remembered, and it
carries the twelve files that restate no notice along with it — a directory with
holes in it is a re-sync bug waiting to happen.

**What did not change.** Nothing about the build. `build.zig` still names its
three core units and its one tool unit by name (`build.zig:76-80`, `:97-99`), so
shipping more source cannot silently compile more of it, and the five targets
and one refusal are unchanged.

### `UPSTREAM.sha256` — nothing in this round invalidated it

The 43 records cover all 42 upstream-carried files and `testdata/corpus.txt`.
**No fork-written file is hashed**, so the repairs recorded in `CHANGELOG.md`
changed neither the record nor its validity: `testdata/interop.zig`, the CI
program and the manifest are not in it. Only a change to a file under
`libraries/liblmdb/`, or to `testdata/corpus.txt`, would require regeneration —
and this fork made neither. Entry 22 changed the renderer, not the expectation,
and the renderer is not covered.

The check itself has now been run at the repository root and reported **43 of 43
`OK`**. The header's two numbers — `43 records`, `689093 bytes` — are unchanged
and still match the tree.

The licence audit recorded in decision 11 and lesson L15 did not change that
either. It was a read of the carried headers and an edit to five documentation
files; `NOTICE.md`, `UPSTREAM.md`, `README.zig.md`, `CHANGELOG.md` and this file
are fork-written and none is in the record. The check was re-run after those edits
and still reports **43 of 43 `OK`**, which is what establishes that the licence
bytes the new per-path table describes are the bytes on disk.

### `.github/workflows/verify.yml` — the closure step is gone, and the C consumer calls the library

Two changes, both recorded as `CHANGELOG.md` entries 16 and 23:

* The licence job is `sha256sum -c UPSTREAM.sha256` and nothing else. The
  110-line derived-closure step and its licence-regex pass were deleted once
  `.paths` stopped naming individual files, because three of its four questions
  no longer described anything the manifest asserted.
* The installed-C program no longer declares the loader's symbols in a
  `void *volatile` array. It calls `mdb_modload` for a module that is not there
  and requires the loader to refuse it with a reason, which forces `module.o` out
  of the archive, resolves its `dl*` calls against `-ldl`, and cannot be deleted
  by an optimizer the way a comparison against `NULL` can. It also clears the
  transaction pointer immediately after `mdb_txn_commit` returns and before
  checking its status, because the commit consumes the pointer either way
  (`lmdb.h:1192`).

The job that asserts the WASI refusal is unchanged and is now backed by an
observation made outside a runner: the build printed the reason and stopped with
`error.UnsupportedTarget` before any C was compiled.

**Still true and still outstanding.** The workflow has never executed. No `act`,
no runner and no push have run it, and it remains `SOURCE-CONFIRMED` against the
tree and `PENDING-VERIFICATION` as a gate.

### Out of this record's scope entirely

* `FORKS.json` and the workspace `README.md` have no `lmdb` entry, so the pin is
  not yet registered with the knowledge role. Both are top-level files owned by
  the driver, and neither was touched.
* `libraries/liblmdb/` was not modified, added to or removed from. All 42 of its
  files are upstream's.
* No commit, push, remote or repository setting was touched by this record's
  work. The package is local and unpublished, and remains so until the user says
  otherwise.
* `.github/workflows/verify.yml` **used to** repeat the withdrawn claim in one
  **comment** above its WASI job — that WASI's libc provides no backend "and no
  mmap either" — while its **assertion** stayed correct throughout: the job
  greps for `there is no shared-lock backend` and for `UnsupportedTarget`, and
  both strings are in the corrected reason, so nothing in CI ever failed on the
  stale wording. **Resolved, by the parent rather than by this record**: the
  comment now names the optional `mmap` emulation, its private-snapshot
  semantics with no shared write-back, the absent `msync` and the absent
  independent-process robust lock. No assertion moved, no command changed, and
  the workflow is still `SOURCE-CONFIRMED` by reading and still **never
  executed** in a runner. This record did not edit that file and does not claim
  the correction as its own.

## See also

* [`UPSTREAM.md`](UPSTREAM.md) — the pin, what is compiled, and what the
  integrity record does and does not establish.
* [`UPSTREAM.sha256`](UPSTREAM.sha256) — the integrity record itself.
* [`NOTICE.md`](NOTICE.md) — the per-path legal record: the OLDAP-2.8 obligations,
  the three further terms the tree retains with their lines, compiled core versus
  carried-only files, upstream's two copyright lines, and every file this fork
  adds.
* [`README.zig.md`](README.zig.md) — how to build, import and call the package,
  with the full tables and the exact gate commands.
* [`CHANGELOG.md`](CHANGELOG.md) — the numbered divergences this file explains.
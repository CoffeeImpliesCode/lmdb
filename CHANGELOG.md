# CHANGELOG — fork-only divergences

Upstream's release history lives in its own repository
(`libraries/liblmdb/CHANGES`). This file records **only** what this fork
changed relative to LMDB `LMDB_1.0.1` (commit
`6f0a32496a5aadee15a5e5103c479bd3355ae273`), and nothing upstream did.

Each entry is in **condition / symptom / fix / target-bound** form, so a later
wave can apply it without re-deriving it. Where the symptom was **observed** by
a gate the receipt is named. Where it was found by reading, that is said: two of
the most expensive items in this package's history were found by reading `mdb.c`
and the CI file, not by a gate.

Status vocabulary is the workspace's: `OBSERVED` for a driver-observed run,
`SOURCE-CONFIRMED` for something read out of a file, `PENDING-VERIFICATION` for
a correction that has landed with no gate behind it yet.

## Verification this changelog is written against

The package's **single gate table** is the "Verification status" section of
[`README.zig.md`](README.zig.md): every gate, what was observed, and the receipt
that holds it. This file does not repeat that table. What belongs here instead
is the **history of the gates that were red before they were green**, because
entries 13, 21, 22 and 23 rest on those receipts:

| Receipt | What it recorded |
|---|---|
| `local://foundation-expansion-lmdb-primary-native-interop-174.log` | `zig build interop` **red**: `testdata/interop.zig:333:13: error: use of undeclared identifier 'in_expect'`. `compile exe mdb_dump Debug native success` in the same summary — the reference tool built and linked while the harness did not compile |
| `local://foundation-expansion-lmdb-upstream-mdb-dump-interop-corrected-184.log` | `zig build interop` **red again**, after entry 21: `error: Disagreement` at `interop.zig:149` |
| `local://foundation-expansion-lmdb-installed-C-surface-before-correction-197.log` | the installed-C program **red** under `zig cc`: two `assigning to 'int' from incompatible type 'void'` diagnostics and one `too few arguments to function call, expected 3, have 0` |
| `local://foundation-expansion-lmdb-upstream-mdb-dump-interop-corrected-body-211.log` | `zig build interop` **green**: the body `mdb_dump -p` printed, then `6 records match mdb_dump -p byte for byte`, `Build Summary: 7/7 steps succeeded` |
| `local://foundation-expansion-lmdb-installed-C-surface-corrected-226.log` | the installed-C program **green**: the loader's refusal, then `installed lmdb.h and liblmdb.a interoperate` |

Every entry below is marked with the evidence it actually has. Two gates have
never run at all and stay `PENDING-VERIFICATION`: `zig build -fsys=lmdb`, which
needs an installed liblmdb with a matching header, and
`.github/workflows/verify.yml`, which has never met a runner. Since entry 29
this package's own gates have also not been re-run over the portability wave's
tree; that list is in §29 and, gate by gate, in the gate table in
`README.zig.md`. **Entry 30 changes that in exactly one place**: the driver ran
`zig build consumer interop -Dtarget=x86_64-linux-gnu` over this tree, once
before the change and once after it, and **neither run has a `local://` receipt
file** — both were observed in the driver's own session. §30 records the argv
and the observed lines so either can be repeated, and names them as what they
are. Every other gate in §29's list is still `PENDING-VERIFICATION` over this
tree.

## 1. Added the Zig 0.16 package

**Condition.** LMDB has no Zig package and none is inherited.

**Change.** `build.zig`, `build.zig.zon`, `translate.h`, `zig/root.zig`,
`tests.zig`, `smoke.zig`, `testdata/corpus.txt`, `testdata/interop.zig`,
`consumer/` and `.github/workflows/verify.yml` are new files. The package
fingerprint was generated for this package.

`build.zig.zon` carries `.version = "1.0.1"`, taken from `lmdb.h:235-239` rather
than from the tag spelling, and `build.zig:724-730` refuses to configure when it
stops matching the pin.

## 2. The archive is upstream's three objects, `module.c` included

**Condition.** `module.c` is the dynamic crypto-module loader —
`mdb_modload`, `mdb_modsetup`, `mdb_modunload`, all three declared in the public
header (`lmdb.h:1899-1918`) — and this fork's Zig facade never calls any of
them. An earlier state of this fork dropped it from the shipped archive and
compiled a second copy of it beside `mdb_dump`.

**Symptom.** Found by reading, not by a gate. The archive stopped being the
library the pin names, and upstream's own reference tool was given a unit the
installed archive did not have.

**Fix.** `core_sources` names all three, by name and not by glob
(`build.zig:76-80`), and `mdb_dump` links **that same archive**
(`build.zig:612-617`). `liblmdb/Makefile:87-88` builds `liblmdb.a` from
`mdb.o midl.o module.o` and `:90-92` builds the shared library from the same
three; `mdb_dump.c:270`, `:275` and `:364` name the loader's entry points
unconditionally, so upstream's tool does not link against a two-object archive.
`.paths` ships `module.c` accordingly, and the CI licence job now fails if a
compiled unit is not shipped.

**Target bound.** Any fork that reproduces a C library from an upstream object
list. *What the shipped archive contains is a property of the upstream library,
not of which facade methods happen to exist.*

## 3. The loader's system library is declared once, on the module that owns `module.c`

**Condition.** A static archive resolves nothing, so `module.c`'s
`dlopen`/`dlsym`/`dlclose` (`module.c:50-67`, `:77-78`) have to be resolved by
whatever links the archive.

**Fix.** `loaderSystemLibraries(os_tag)` is added to the `core` module
(`build.zig:453-455`) — Linux `dl`, Windows `kernel32`, macOS nothing, and an
`else` arm that logs and panics rather than answering with an empty list, so a
new operating system cannot lose its loader silently. Zig carries a static
library's own link objects onto every dependent's link line
(`lib/std/Build/Step/Compile.zig:1064-1088`), so one declaration reaches the
facade, the tests, the smoke program, the interoperability program, upstream's
`mdb_dump` and the external consumer package.

**`-pthread` is deliberately not repeated.** Upstream puts it on every line
(`liblmdb/Makefile:24`, `:158`) and Zig's libc carries the POSIX threads entry
points inside libc on every target this build supports, so asking for a separate
`libpthread` would turn a complete library into a search for a file that exists
only on the machine running the build. The CI gate's plain C consumer *does*
repeat it, because that link line is `zig cc`'s and not this build graph's.

**Target bound.** Linux → `dl` (upstream's own `LDL`, `Makefile:31`); Windows →
`kernel32` (`module.c:14-15`, `:33-49`, `:74-76`; there is no libdl there for
upstream's `LDL` to name); macOS → nothing, because Darwin's `dl*` come from
`libSystem`, which `link_libc` already links. A new platform is a new row.

## 4. `-fsys=lmdb` is the opt-in, and the system mode never sees this repository's header

**Condition.** `b.systemIntegrationOption` is fed by `-fsys=`, not by a `-D`
option, so `-Dsystem=true` would be an unknown option rather than a mode.

**Fix.** `b.systemIntegrationOption("lmdb", .{})`, so the bundled, full, in-tree
library is what a plain `zig build` produces. `translate.h` is nothing but
`#include <lmdb.h>` — **angle brackets**, so a stray `lmdb.h` beside the package
root cannot win over the one `build.zig` put on the include path — and in system
mode no in-tree include path is added at all, so the header that resolves is the
one next to the library being linked. `.force`, not `.yes`: on a failed
pkg-config query `.yes` falls back to a bare `-llmdb`, which may not exist.

**Target bound.** Any C facade with a system-library mode. **No run of
`-fsys=lmdb` has happened in this workspace and no result is claimed for it.**

## 5. `sanitize_c = .off` on the C modules

**Condition.** Zig leaves `Module.sanitize_c` null unless a module says
otherwise, and null emits no flag at all (`lib/std/Build/Module.zig:558-562`),
so the compiler's own Debug default stands, and that default sanitises C
sources.

**Fix.** `.sanitize_c = .off` on the `core` module and on `mdb_dump`'s module.
`mdb.c` is written on unsigned wraparound in page, transaction and reader IDs and
on narrowing conversions ISO C leaves undefined — exactly the class of code that
turns into diagnostics. The optimisation mode is untouched; only the C sanitizer
is off.

**Target bound.** Zig 0.16.0's Debug default for C sources.

## 6. The lock backend is chosen per operating system, and anything else is refused

**Condition.** `mdb.c` offers four shared-lock implementations
(`mdb.c:175-231`) and the choice changes `MDB_LOCK_TYPE` (`mdb.c:965-981`),
which is **recorded in the lock file**. Two processes that disagree cannot open
the same environment.

**Fix.** `lockBackend(os_tag)` names one: robust POSIX mutex on Linux, POSIX
named semaphore on macOS (and `MDB_USE_ROBUST` must stay undefined there or
`mdb.c` falls through to SysV, which Apple has no `<sys/sem.h>` for), the Win32
mutex on Windows (the target is the selection; no macro is needed). The
macros are defined identically to the values `mdb.c`'s own ladder would pick,
which both states the selection where it can be read and keeps
`mdb.c:228-231` ("Ambiguous shared-lock implementation") armed against a second
arm being added silently.

`refusalFor` stops `zig build` and `zig build check -Dtarget=<refused>` at
configure time with the reason printed. `checkMatrixPartition` re-derives the
supported/refused partition on **every** invocation, so an edit that adds a
backend or a triple that stops resolving fails any build of this package.

**Target bound.** `wasm32-wasi` is the refused row, and **the reason for it was
corrected on 2026-10-02, after this entry was written** — see §29 for the
measurement. In its corrected form: no shared-lock backend, no independent-
process robust lock, and an `mmap` that is a `malloc`/`pread` snapshot rather
than a shared mapping with write-back. `MDB_NOLOCK` is not a substitute — it is
a runtime flag that drops the reader liveness table and the cross-process write
lock, so building against it would produce a weaker library with different
failure behaviour after a crash. The CI job asserts the refusal rather than
tolerating it: no `continue-on-error`, a zero exit fails it, and so does a
failure carrying the wrong reason. **Observed**: the build printed the reason
and stopped with `error: UnsupportedTarget` at `build.zig:328:5 in refuseTarget`,
having never reached the C compiler
(`local://foundation-expansion-lmdb-check-wasm32-wasi-218.log`). That is a
refusal, and it is **not** a claim that upstream's C compiles or runs for WASI —
the guard is this package's, and the refusal is the whole of the result. The
corrected wording has not been printed by a gate and is
`PENDING-VERIFICATION`; the string the job greps for,
`there is no shared-lock backend`, is in the old text and the new one alike.

## 7. The facade owns four handle lifetimes, because the header only states them in prose

**Condition.** `lmdb.h` states each rule in English and the C follows none of
them for you.

**Fix.** `zig/root.zig` enforces each:

| Upstream rule | What the facade does |
|---|---|
| `mdb_txn_commit` frees the handle on success (`mdb.c:4629-4637`) and aborts it on every failure | `commit` and `abort` both **clear the handle before calling the C**, so `defer txn.abort(); … try txn.commit();` is a no-op afterwards and a second `commit` is a no-op rather than a double free |
| A read-only transaction never frees its cursors; they must be closed "before or after" the transaction ends (`lmdb.h:1620-1626`) | `Cursor.close` calls `mdb_cursor_close`, and is safe in either order |
| A write transaction frees its own cursors — commit `mdb.c:4557`, abort `mdb.c:3737-3738`, nested merged into the parent `mdb.c:4439` | `Cursor.close` **does not** call `mdb_cursor_close` for a write cursor; the transaction owns that pointer |
| `MDB_dbi` is an index, not a pointer (`lmdb.h:280-281`) | `Database` is a value with no `deinit`; `Environment.closeDatabase` is the only release |
| `mdb_txn_reset` returns silently on the wrong kind of transaction (`mdb.c:3816-3826`) | `error.TransactionNotResettable` names the mistake instead |

**Target bound.** The `Cursor.read_only` field is **captured at open**, not
re-read at close, because a read-only cursor is allowed to outlive its
transaction and `close` must still be safe when `owner` is out of scope.

## 8. Two status tables, not one, because a Windows build of `mdb.c` returns two numeric spaces

**Condition.** `ErrCode()` is `errno` everywhere but Windows
(`mdb.c:501`), where it is `GetLastError()` (`mdb.c:409`) — and a Windows build
returns a few explicit `errno` constants of its own besides (`mdb.c:6257`,
`:6275`).

**Symptom.** Found by reading. A single table that read every positive code as
POSIX reported `ERROR_ACCESS_DENIED` (5) as `EIO` (also 5) — a permission
failure named as a disk error.

**Fix.** `check` dispatches on `builtin.os.tag`. `posixStatus` uses the target's
own `std.c.E`, so the numbers come from its headers; `winStatus` is a literal
Win32 table, each value tied to the `mdb.c` call site that produces it, because
Zig 0.16's `std` carries no Windows error-code table. A code neither names keeps
`error.UnexpectedStatus`, and the raw `c` escape hatch is how to see it.

**Target bound.** Windows builds only. **No Windows program has been *run*** in
this workspace: the target was compiled — `zig build check
-Dtarget=x86_64-windows-gnu`, `7/7 steps succeeded`
(`local://foundation-expansion-lmdb-check-x86_64-windows-gnu-216.log`) — and
`check` never executes a foreign binary, so the table remains
`SOURCE-CONFIRMED` against `mdb.c` and Zig's own `lib/libc` headers as far as
runtime behaviour goes.

## 9. Four new error members, and `open` became honestly one-shot

**Condition.** Upstream's guard against a second `mdb_env_open` is the
data-file descriptor, not a flag (`mdb.c:6257`), and `mdb_env_close_active`
closes that descriptor on the failure path without returning `me_fd` to
`INVALID_HANDLE_VALUE` (`mdb.c:6508`) — which happens in exactly one place,
`mdb_env_create` (`mdb.c:5029`).

**Symptom.** A retry after a failed open came back as `EINVAL`, so the caller
was told its argument was invalid by a stale descriptor its own previous call
left behind.

**Fix.** `Error` gained `ReadOnlyFileSystem`, `TooManyOpenFiles`,
`SharingViolation` (Windows only — POSIX has no equivalent status, so no POSIX
build can report it) and `OpenFailed`. A private `open_attempted` flag is set
**before** `mdb_env_open` is entered, so the facade records the attempt rather
than the success: `error.EnvironmentAlreadyOpen` after a success,
`error.OpenFailed` after a failure. `Environment.close` clears it.

**Target bound.** Any LMDB binding. The one-shot rule is upstream's, not this
fork's; the only choice here was to name which of the two happened.

## 10. An empty key is refused before it reaches the core

**Condition.** `lmdb.h:288-292` requires key sizes between 1 and
`mdb_env_get_maxkeysize()`, and upstream reaches `MDB_BAD_VALSIZE` for a
zero-length key through `key->mv_size-1 >= ENV_MAXKEY(env)` (`mdb.c:8605`).

**Fix.** `keyValue` reports `error.EmptyKey` for a zero-length key and is used
by `put`, `putNoOverwrite`, `putNoDupData`, `get`, `delete`, `deleteValue` and
every cursor seek. An **oversized** key is not checked here — the wrapper does
not re-derive a bound the core owns — and travels to the C and comes back as
`error.BadValSize`.

**Target bound.** The boundary is `1 … maxkeysize` on a key, and `0 …` on a
value: an empty *value* is stored and read back as itself, which
`tests.zig` and `smoke.zig` both observe.

## 11. Where a key's bytes come from, is stated per method

**Condition.** Upstream rewrites the caller's key object **only** for
`MDB_SET_RANGE` and `MDB_SET_KEY` (`mdb.c:8176-8180`, `:8225-8227`), and
`MDB_SET` leaves it untouched (`lmdb.h:1686-1688`).

**Fix.** `Entry.key` is bytes out of the map for eleven of the thirteen
traversals and is **the caller's own slice handed back** for `getBoth` and
`getBothRange`; `Cursor.set` uses `MDB_SET_KEY` so the key that comes back is
the stored one; and `firstDup`/`lastDup` return an empty `key` when the current
key carries duplicate data, because upstream then writes the data and not the
key (`mdb.c:8492`, against `:8482-8483`). `README.zig.md` states which is which
rather than leaving one shape for all of them.

**Target bound.** `MDB_DUPSORT` databases and any traversal that takes a key.

## 12. `max_dbs` is documented as not being on disk, and passed on every open

**Condition.** `mdb_env_create` sizes the slot table to the two databases
upstream keeps for itself (`mdb.c:5028`; `CORE_DBS` is 2 at `mdb.c:1352`), and
`mdb_dbi_open` refuses any name once that table is full (`mdb.c:12318`).
`mdb_env_set_maxdbs` adds the two reserves back (`mdb.c:5220`).

**Symptom.** A reopen of an environment that already held a named database
refused the name with `error.DbsFull` even though the name was in the catalogue.
The limit lives in the handle (`me_maxdbs`), not in the environment file.

**Fix.** `OpenOptions.max_dbs` is documented as a per-open setting, and all four
of this package's environment-creating entry points set it — **including the
read-only reopen**, which needs the slot just as much to find the name.
`tests.zig` "a named open needs a slot the environment must be asked for" proves
all three cases: no slot, slot on the creating open, slot on a read-only reopen.

**Deleted with it.** A test asserting `sizeof(MDB_db)`. `MDB_db` is upstream's
**private** struct (`mdb.c:1330-1339`), reached only because `mdb_dbi_open`
stores a catalogue record of that width (`mdb.c:12302`, `:12327-12328`,
`:12349`). The smoke program still *prints* the catalogue value's length —
it is 48 bytes on a 64-bit target — but as an opaque byte count, because the
width of an internal struct is not a contract this package can pin.

## 13. `zig build interop`: the oracle is upstream's own reader, built from this tree

**Condition.** A same-code round trip is not a fixture. The primary oracle has
to be an implementation that did not come from this package.

**Fix.** `zig build interop` builds `libraries/liblmdb/mdb_dump.c` against
**this package's archive** — not an `mdb_dump` found on the machine running the
build, which would be some other version of the reader — and runs
`testdata/interop.zig` over it with `--dump=<path>`.

**What is compared, and what deliberately is not.** The **body** of
`mdb_dump -p`: the bytes between its `HEADER=END` and `DATA=END` marker lines
(`mdb_dump.c:136`, `:154`). The header above those markers carries the
**memory-map address** (`mdb_dump.c:124-125`), which is the kernel's choice and
differs between two runs over the same bytes; comparing it would compare two
addresses rather than two readers of one file. The body is compared byte for
byte, so neither half of the comparison is this package's own wrapper.

**No escape rule is re-invented.** `mdb_dump -p` renders a printable byte other
than `\` as itself and escapes the rest (`mdb_dump.c:65-84`); the program
**refuses any corpus byte that `mdb_dump` would escape** before relying on the
plain rendering, so a corpus that grew a non-printable byte fails that check
rather than silently disagreeing.

**Status.** **OBSERVED green.** `zig build interop -j8 --summary all` compiled
`mdb_dump` from this repository's sources against this package's archive, ran the
program over a fresh environment, printed the body the tool printed and then
`6 records match mdb_dump -p byte for byte`, with `Build Summary: 7/7 steps
succeeded` (`local://foundation-expansion-lmdb-upstream-mdb-dump-interop-corrected-body-211.log`).
The gate was red twice on the way there; entries 21 and 22 record both repairs.
Both were fork-side changes to the harness, and **no upstream byte, no expected
value and no fixture was touched to make the comparison pass.**

## 14. Scratch environments go where the process was started, not in the checkout

**Condition.** `std.testing.tmpDir` puts its directory under the **working
directory** whatever the environment says, and this workspace's policy puts
scratch on an approved mount rather than in a repository. LMDB also does not
create the environment directory — there is no `mkdir` anywhere in `mdb.c` — so
something has to, and `mdb_env_open` needs an **absolute** path.

**Symptom.** Every environment in every program landed in `.zig-cache/tmp` under
the checkout, ignoring the temporary root the process had been given.

**Fix.** All four scratch-creating entry points — `tests.zig`, `smoke.zig`,
`testdata/interop.zig`, `consumer/src/main.zig` — read the temporary root at
runtime: `TMPDIR` on every platform, `TEMP` then `TMP` on Windows. A relative
value is joined against the working directory so the C always gets an absolute
path; a host that names no root falls back to `.zig-cache/tmp`, which is what
`std.testing.tmpDir` uses. Under the root each program creates **one** directory
named from 12 random bytes in base64url (96 bits) and removes **only that
directory**, on the normal path and on the one failure point after it was
created.

**Target bound.** `std.process.Environ.getAlloc` is used rather than
`getPosix` because `Block` is `GlobalBlock` on Windows and `createMap` reads the
PEB there. `std.testing.tmpDir` is used nowhere in the four files. No fixed
host path is baked into any SDK source. The `.zig-cache/tmp` fallback remains a
fallback and is not a claim that a host may write to its checkout.

## 15. Two smoke expectations were wrong about the C's own collation

**Condition.** The smoke program walks the main database forward and expects an
order, and separately walks one key's `DUPSORT` values.

**Symptom.** Found by reading `mdb_cmp_memn` (`mdb.c:6659-6672`) — `memcmp` over
the common prefix, **the shorter item first**, then plain byte order.

1. The duplicate walk expected `gamma` before `delta`. Lexically it is
   `alpha, beta, delta, gamma`. **Fixed.**
2. A named database is catalogued in the main database, so a forward walk of the
   main database **meets that record** rather than stopping after the last
   written one. The catalogue key is the name **with its terminator** —
   `mdb_dbi_open` measures `strlen(name)+1` (`mdb.c:12302`) and stores that many
   bytes of the name (`mdb.c:12327-12328`) — so the key is `"sorted\0"`, not
   `"sorted"`, and it collates last because `s` (0x73) sorts after `g` (0x67).
   **The walk now requires that entry and then requires `NotFound` after it**,
   because a walk that hid it would be walking over less than the database
   contains.

A third defect in the same function — an assertion comparing a **key** against
`entry.value` — is in entry 17.

**Target bound.** Any forward walk of an LMDB main database that has a named
database open.

## 16. CI's licence job is the digest, and the C consumer calls the library

**Condition.** A hand-written list of file names cannot detect a translation unit
added to the core or a header the core starts including; and a consumer that only
*names* the loader's symbols proves nothing about whether the linker pulled them
out of the archive.

**Fix, first form.** The two hand-written file lists were replaced by one derived
step asking four questions of the files themselves: does every `.paths` entry
exist; is the set of C sources the manifest ships exactly the set `build.zig`
compiles, once each; is every `#include "..."` those sources reach, transitively,
shipped; and does every file in that closure still carry its OpenLDAP
redistribution notice. Upstream records the same dependency set in its own rules
(`liblmdb/Makefile:126-144`).

**Superseded.** That step — 110 lines of embedded Python plus a licence-regex
pass — was **deleted**. `.paths` no longer names individual files under
`libraries/liblmdb/` (entry 24), so the closure it computed no longer described
anything the manifest asserted, and the digest already in the repository is the
stronger check: it fails on a changed byte, not only on a changed name. The
licence job is now `sha256sum -c UPSTREAM.sha256` and nothing else, and that check
is `OBSERVED` green, 43/43.

**The C consumer now calls the library instead of naming it.** It no longer
declares `mdb_modload`/`mdb_modsetup`/`mdb_modunload` in a `void *volatile` array.
It calls `mdb_modload` for a module that is not there and requires the loader to
refuse it with a reason (`module.c:51-66`), which is what forces `module.o` out
of the archive and resolves its `dl*` calls against `-ldl`. A reference the
optimizer deletes is a reference the linker never sees; a call whose result is
checked cannot be deleted, and it decides something — a module that cannot be
opened must come back as no handle and a reason.

**Target bound.** The equivalent program was compiled, linked and run outside a
runner against an installed `liblmdb.a` and the installed `lmdb.h`, and is
`OBSERVED` green (`local://foundation-expansion-lmdb-installed-C-surface-corrected-226.log`;
its first form was red, entry 23). **The workflow itself has never been
executed** — no `act`, no runner, no push. It is `SOURCE-CONFIRMED` against the
tree and `PENDING-VERIFICATION` as a gate.

## 17. Removed tests that asserted the fork's own bookkeeping

Deleted, each for a stated reason rather than taste:

* an assertion that compared a string literal with itself for `MDB_GET_BOTH` —
  it proved nothing, and the policy forbids replacing it with a pointer-copy
  test;
* the smoke version-**major** gate (the version is still printed, which is a
  reading rather than a pin; version pinning belongs to `UPSTREAM.sha256`);
* `sizeof(MDB_db)`, in entry 12.

No permanent test here checks a version string, a default constant, `@hasDecl`,
export presence, a forwarding accessor against a raw member, a copy, a
forward, a non-zero length, or that a call does not throw.

## 18. `.paths` named the two legal files at the paths they are actually at

**Symptom.** Found by reading. `.paths` carried bare `"LICENSE"` and
`"COPYRIGHT"`, which name nothing at the package root; the files are at
`libraries/liblmdb/LICENSE` and `libraries/liblmdb/COPYRIGHT`. A dependent would
have fetched a package whose manifest named two files it does not have.

**Fix.** Both entries carried their real path, and a CI step asserted that every
`.paths` entry existed. Entry 24 then replaced the file list with the directory
itself, which makes this class of mistake impossible over the upstream tree
rather than merely checked.

**Target bound.** The record is in the manifest. The step that caught it went with
the rest of the closure step (entry 16); the digest covers the same ground more
directly.

## 19. The integrity record is 43 numbers for files, and not the archive digest

**Condition.** Two different receipts answer two different questions and must not
be compared.

**Fix.** `UPSTREAM.sha256` holds the SHA-256 of all 42 upstream files under
`libraries/liblmdb/` plus `testdata/corpus.txt` — **43 records, 689093 bytes** —
hashed as a raw byte read on 2026-10-01. It was deliberately **broader** than
`.paths`, which shipped eight of those 42, so a re-sync could diff upstream's
whole `liblmdb` directory; and the record said plainly what that cost — the check
was a **repository-root** check, and 34 lines reporting `No such file or
directory` in a package materialised out of `.paths` alone was the expected
result, not drift.

Entry 24 closed that gap from the manifest side. `.paths` ships the whole
directory, the record and the package cover the same set, and every line passes
wherever the package is materialised. Observed at the repository root: 43 of 43
`OK` (`local://foundation-expansion-lmdb-immutable-source-fixture-integrity-219.log`).
Observed **inside a package materialised from `.paths` alone**, later and by a
different route: 43 of 43 `OK`
(`local://foundation-expansion-lmdb-materialized-package-integrity-332.log`), which
is what the sentence above had only argued from the manifest. Entry 26 records
that run.

The whole-tree archive receipt `7c23a9c5…` in `UPSTREAM.md` is the driver's
`git archive` of the **full repository tree** at the pinned commit, read out of
the workspace delivery record `local://foundation-expansion-source-archives.json`.
It covers a different set of bytes and is replayable only by re-fetching. A
difference between the two numbers is not corruption and is not evidence of
drift.

Nothing this fork wrote is hashed, and no mutable fork file is.

## 20. Recorded, not corrected: upstream's own two version strings disagree

`libraries/liblmdb/Makefile:36` still reads `LMDB_VERSION = 1.0.0`, and
`Makefile:156` writes that string into the generated `lmdb.pc`. The header says
`1.0.1` (`lmdb.h:235-239`) and is the ABI the compiled code answers to —
`mdb_version()` returns `MDB_VERSION_FULL` — so the header is the record and the
Makefile string is a stale packaging detail upstream did not update at this tag.
It is **not** corrected by this fork: `libraries/liblmdb/` is upstream's, byte
for byte.

**Target bound.** Any re-sync; `UPSTREAM.md` step 1 says to record the
disagreement again rather than fix upstream's file.

## 21. `parseCorpus` declared the flag it assigned

**Condition.** `testdata/interop.zig` marks the `[expect]` block with a boolean
while parsing the fixture.

**Symptom.** `OBSERVED` red: `testdata/interop.zig:333:13: error: use of
undeclared identifier 'in_expect'`. The same summary line carries `compile exe
mdb_dump Debug native success` — the reference tool built and linked, the harness
did not compile — so the defect was in this package's own program and not in
anything upstream. The same file is on the `check` compile line for every matrix
target, so it blocked the cross matrix as well as the gate
(`local://foundation-expansion-lmdb-primary-native-interop-174.log`).

**Fix.** One declaration in `parseCorpus`.

**Target bound.** None; a compile error with one cause and one repair. It is
recorded because the file that carried it is the package's primary fixture, and
because afterwards the repair is invisible.

## 22. `renderBody` rendered the markers that `extractBody` removes

**Condition.** The comparison is the **body** of `mdb_dump -p`: the bytes between
its `HEADER=END` and `DATA=END` marker lines (`mdb_dump.c:136`, `:154`).

**Symptom.** `OBSERVED` red, after entry 21: `error: Disagreement` at
`interop.zig:149`. The renderer appended the two marker lines to the expected
body while `extractBody` cut them out of the tool's output, so the two sides
differed on their first byte and all six records compared unequal — a failure
that looks like a data disagreement and is not one
(`local://foundation-expansion-lmdb-upstream-mdb-dump-interop-corrected-184.log`).

**Fix.** `renderBody` renders records only, and its doc comment says why: the
markers belong to the tool, so rendering them here would put `HEADER=END` in
front of the comparison and `DATA=END` behind it and the two sides would differ
where neither has data.

**Target bound.** What was **not** changed is the point. Neither the expected
order nor one byte of `testdata/corpus.txt` nor any upstream file was edited to
make the comparison pass — a fixture repaired by rewriting its expectation is
not a fixture. The gate is now `OBSERVED` green: six records, in collation
order, `6 records match mdb_dump -p byte for byte`, `Build Summary: 7/7 steps
succeeded` (`local://foundation-expansion-lmdb-upstream-mdb-dump-interop-corrected-body-211.log`).

## 23. The installed-C gate compared `void` returns and called a three-argument function with none

**Condition.** The installed-C gate includes the installed `lmdb.h`, links the
installed `liblmdb.a` with `zig cc -std=gnu17 -pthread -ldl`, and decides three
things by behaviour: a value committed in one transaction read back byte for byte
in a second, read-only one; a module that is not there refused with a reason; and
every handle released.

**Symptom.** `OBSERVED` red: `error: assigning to 'int' from incompatible type
'void'` twice, for `mdb_txn_abort` (`lmdb.h:1265`) and `mdb_env_close`
(`lmdb.h:900`), and `error: too few arguments to function call, expected 3, have
0` for `mdb_version`, which takes three out-parameters (`lmdb.h:575`)
(`local://foundation-expansion-lmdb-installed-C-surface-before-correction-197.log`).

**Fix.** The two calls are made for their effect and are not assigned to. The
`mdb_version` call is removed rather than corrected: a version assertion is the
fork's own bookkeeping and not an upstream contract, and the gate already proves
the installed header and the installed archive agree by using them together. The
`void *volatile` symbol sink went with entry 16. The transaction pointer is
cleared **immediately after** `mdb_txn_commit` returns and before its status is
examined, because the commit consumes the pointer on success and on failure
alike (`lmdb.h:1192`): a stale `txn` in the exit path would abort a handle that
no longer exists, which is the bug this ordering removes.

**Target bound.** `OBSERVED` green:
`module loader refused a module that is not there: …/lmdb-c-surface/absent.so:
cannot open shared object file: No such file or directory`, then `installed
lmdb.h and liblmdb.a interoperate`
(`local://foundation-expansion-lmdb-installed-C-surface-corrected-226.log`). The
scratch environment is the program's own child inside the base it was handed,
because `mdb_env_open` creates nothing — there is no `mkdir` anywhere in `mdb.c`
— and the module path names a file inside that child which the program never
creates, so the loader can only refuse it.

## 24. `.paths` ships the whole upstream directory

**Condition.** `.paths` named sixteen entries and shipped eight of upstream's 42
files: the four C units, the two headers and the two legal files. The other 34
stayed in this repository for re-sync only, and a dependent received neither
upstream's other tools, nor its test material and sample databases, nor its
build definitions, man pages and release notes.

**Symptom.** Found by reading the manifest against the integrity record, and then
confirmed by running it: a package materialised out of `.paths` would have
reported `No such file or directory` on 34 of the 43 lines. Three documents
described that as expected, which is a record describing a package nobody should
build.

**Fix.** `.paths` names `libraries/liblmdb` — the directory — and is 15 entries:
the build files, the aggregate translation header, the facade and its two
programs, the fixture and the consumer package, the whole upstream directory, and
this repository's five records plus `UPSTREAM.sha256`. A dependent now receives
upstream's complete source at the pin, and OLDAP-2.8's conditions travel with the
bytes they govern instead of resting on whoever re-syncs next.

**Target bound.** Any re-sync: the directory is replaced wholesale and the digest
regenerated over it, with the count and byte total in the record's header moved
with it. Nothing else in the package depends on which files upstream wrote —
`build.zig` still names its three core units and its one tool unit by name
(`build.zig:76-80`, `:97-99`), so a new upstream file cannot silently join the
archive.

## 25. The licence record claimed "OLDAP-2.8 and nothing else", and the tree says otherwise

**Condition.** Five documents describe the terms of `libraries/liblmdb/`. Two of
them asserted a universal claim about them: `NOTICE.md` said "The grant on the C is
OLDAP-2.8 and nothing else", and `README.zig.md` said "the C is OLDAP-2.8 and
nothing else". A table row in `NOTICE.md` sent `chacha8.c` and `chacha8.h` to a
section that never stated what their terms were.

**Symptom.** `SOURCE-CONFIRMED` by reading the carried headers, not by any gate.
Grepping every one of the 42 files for `copyright`, `permission is hereby granted`,
`public domain` and `derived from` found terms the documents did not mention:

| Term | Files | Lines |
|---|---|---|
| ISC-style, **Martin Hedenfalk**, "derived from btree.c" | `libraries/liblmdb/lmdb.h`, `libraries/liblmdb/mdb.c` | `lmdb.h:151-166` (closing `*/` at `:167`), `mdb.c:19-33` (closing `*/` at `:34`) |
| Public domain, **Landon Curt Noll**, FNV-1a | `libraries/liblmdb/mdb.c`, conditional | `mdb.c:5846-5872`, inside `#ifdef MDB_USE_HASH` at `mdb.c:5845` |
| Public domain, **D. J. Bernstein** | `libraries/liblmdb/chacha8.c` | `chacha8.c:1-5` |
| No notice, no grant, no attribution in its own bytes | `libraries/liblmdb/chacha8.h` | whole file, 7 lines. The DJB statement above is recorded for `chacha8.c` only and is **not** extended to this file |

Two of those are in `mdb.c` and `lmdb.h` — the engine and the public header, both
in `liblmdb.a` and both installed. The claim was therefore wrong about the material
this package compiles, and wrong about it on **every** target that produces a
binary, not on some of them.

**The conditional one, and a first draft that got the scope wrong.** `MDB_USE_HASH`
is defined at exactly two places in `mdb.c`: `mdb.c:211`, under
`MDB_USE_POSIX_SEM`, and `mdb.c:378-379`, under `_WIN32`. This fork's `build.zig`
sets `MDB_USE_POSIX_SEM` for macOS only (`build.zig:193-195`); the Linux backends
set `MDB_USE_POSIX_MUTEX` and `MDB_USE_ROBUST` instead (`build.zig:180-183`). So
the FNV-1a public-domain code is a **third** term, layered on top of the two core
terms, compiled for `aarch64-macos-none` and `x86_64-windows-gnu` and not for the
three Linux targets — which still carry both core terms, the Hedenfalk grant
included.

`wasm32-wasi` produces no binary at all: it is in `refused_check_targets`
(`build.zig:145-147`), `refusalFor` returns "there is no shared-lock backend"
(`build.zig:266-270`) and `refuseTarget` fails with `error.UnsupportedTarget`
(`build.zig:322-329`). No compiled terms apply there, and none are claimed. A
refusal is a result this build reports, not a target it silently drops
(`build.zig:140-144`).

**Corrected here after review.** The first draft of this entry said a record
naming only "OLDAP-2.8" "would have been wrong on two of six targets and right on
four". That was wrong in both halves and has been fixed in all five files: the
Linux cores are **not** covered by OLDAP-2.8 alone, and there is no wasm binary to
be right or wrong about. The right statement is that the Hedenfalk grant made the
old record wrong uniformly, and that FNV-1a is the one term whose reach has to be
tabulated per target.

The per-target split is `SOURCE-CONFIRMED` from the `build.zig` macro lists, not
an observed compile. The Windows row additionally assumes the target defines
`_WIN32`, which is its convention and what `build.zig:197-202` reasons from; no
gate here compiled `mdb.c` for that target and inspected the preprocessor output.
`NOTICE.md` records that split explicitly so the rows are not read as equally firm.

**Fix.** Documentation only, in all five owning files:

* `NOTICE.md` — a new section itemising every term with path and line range; a
  per-file compiled/compiled-conditionally/carried-only table for the five
  encryption-related files; the `chacha8.c`/`chacha8.h` table rows replaced with
  what those files actually say; the man-page row corrected, since all five do
  carry a copyright line and a licence pointer in a roff comment
  (`mdb_copy.1:2-3` and its four siblings) and were only ever notice-*silent*, not
  notice-free; OLDAP conditions 1 and 2 extended to the notices they now retain;
  and the "nothing else" sentence replaced by a correction that keeps the original
  claim visible and marks it wrong.
* `UPSTREAM.md` — the header table's Licence and Copyright rows qualified; the
  excluded-files table given the reason those files are not notice-free; the
  "other 34" section naming `chacha8.c`, `chacha8.h` and the man pages; a new
  re-sync step 9, on the ground that `CHANGES:9` of this very release is ITS#10540
  "cleanup outdated license notices", so the retained set is moving upstream.
* `README.zig.md` — the Licence section's "nothing else" claim replaced with the
  three-term table.
* `FORK-NOTES.md` — decision 11 and lesson L15, in the condition/symptom/fix/
  target-bound shape, with the conditional-compilation rule as the transferable
  part.

Two of those first-draft statements were wrong and were corrected in all five files
on review: the claim about which targets the old record got wrong (see above), and
the sentence saying the D. J. Bernstein dedication "covers the pair in substance",
which assigned a term to `chacha8.h` by association. The corrected version states
what each file says about itself and stops there.

**What did not change.** No byte under `libraries/liblmdb/` was touched; all five
edited files are fork-written and none is hashed by `UPSTREAM.sha256`, so the
integrity record is untouched. The check was re-run after the edits: **43 of 43
`OK`**, which is what establishes that the licence bytes the new per-path table
describes are the bytes on disk. `build.zig`, `build.zig.zon`, the C sources and
CI were not edited.

**Target bound.** Any re-sync: read the new tree's licence-bearing headers again
and re-derive the table rather than carrying it forward. A file-count check cannot
establish "and nothing else". Three rules that generalise beyond LMDB:
`MDB_USE_HASH`-style conditionals mean a licence claim has to be stated per target
or it is not a claim at all; a **refused** target has no compiled terms to describe
at all, so do not extend a target matrix over a target the build does not produce;
and one file's terms are never another file's terms, however obviously the second
includes the first.

## 26. The materialised package stopped being an argument and became a receipt

**Condition.** Entries 19 and 24 left one thing resting on reading the manifest:
that a package materialised out of `.paths` would carry a file behind every one of
the 43 digest lines, and would therefore build. The repository-root run proves the
bytes; it cannot prove they arrive.

**Fix.** Documentation only. Three receipts, run by the driver from a build root
outside this repository, are now in the gate table:

| Step | Observed | Receipt |
|---|---|---|
| `zig fetch --global-cache-dir <scratch> <this package path>` | exit 0, identity printed: `lmdb-1.0.1-tSeszSGBEAA4iYj2VgUVljPe8OfyeloZXM03YepgsSeU` | `…-lmdb-external-driver-package-fetch-323.log` |
| `sha256sum -c UPSTREAM.sha256` inside the fetched package | exit 0, **43 of 43 `OK`** | `…-lmdb-materialized-package-integrity-332.log` |
| `zig build run` in that package's `consumer/` | exit 0, `consumer: linked LMDB 1.0.1` and `consumer: committed records persisted, abandoned ones did not` | `…-lmdb-materialized-package-consumer-339.log` |

The third row is the one that closes the gap rather than restating it:
`consumer/build.zig.zon` resolves `.path = ".."`, so inside the fetched tree that
resolves to the **filtered copy**. Nothing in the build could reach this working
tree, so a green consumer there is evidence about the package and not about the
checkout it was copied from. That is what a tests-in-a-checkout run cannot say,
which is why the earlier consumer row (212) is not treated as the same evidence.

**What this does and does not say.** Full source closure through `.paths` is now
observed rather than argued: the engine, upstream's other tools, the headers, the
build definitions, the man pages and release notes, and `LICENSE`/`COPYRIGHT` are
all inside the copy a dependent receives, so OLDAP-2.8's conditions travel with
the bytes they govern. It is **not** a registry or publication proof. The fetch
resolved a local directory; nothing was published, pushed, uploaded or resolved
from a registry, and the printed identity is the identity of that directory, not a
`.url` hash. `wasm32-wasi` is still the configure-time `error.UnsupportedTarget`
refusal (218), `-fsys=lmdb` is still unrun, no cross target was executed by any of
this, and `.github/workflows/verify.yml` has still never run — these are driver
runs with receipts, not CI. That the shipped native tree is unchanged from
upstream is a separate and older receipt,
`git diff --exit-code 6f0a32496a5aadee15a5e5103c479bd3355ae273 -- libraries/liblmdb`
at exit 0 with empty output (`…-lmdb-pinned-native-pristine-diff-266.log`); the
fetch did not observe it and does not replace it.

**What did not change.** Nothing under `libraries/liblmdb/` was touched, no byte
of `UPSTREAM.sha256` was rewritten, and `build.zig`, `build.zig.zon`, `zig/*.zig`,
the fixture and CI were not edited. This entry and the three table rows it
references are the whole change.

**Target bound.** Any manifest change that adds, removes or renames a `.paths`
entry: re-fetch, re-run the record inside the fetched tree, and re-run the
consumer there. A repository-root `sha256sum -c` cannot stand in for the second
of those three, because it cannot fail on an entry `.paths` forgot to ship.

## 27. The cross gate became the published 53-platform matrix, and a settings-only profile states how

**Condition.** The cross gate for this package was the six-target `check`
matrix, which compiles and never runs. The addition wave widened the gate to
`~/.local/bin/cross-test` over the published Zig 0.16.0 Tier 1/2 table, which
drives `zig build test -Dtarget=<target>` and either executes the test binary on
a detected runner or reports the cell **build-only**.

**The change.** Three files, none of them C.

1. **New `cross-test.profile.sh` at the package root.** One assignment and the
   comments around it:

   ```bash
   CROSS_BUILD_STEP=test
   ```

   No `CROSS_MATRIX`, no `TARGETS`, no `cross_build_command`,
   `cross_artifact`, `cross_run_command` or `cross_count_tests`, no
   `CROSS_BUILD_ARGS`, no host path, no resource limit. The comments say why
   each is absent. Runner policy therefore stays with the harness, so a target
   with no detected runner is reported as build-only and never as a pass, and
   the published matrix stays whole — including every platform this build has
   no shared-lock backend for.
2. **`build.zig.zon` `.paths`**, which now names it. It is Bash the harness
   sources, not documentation, and a dependent that fetches the package should
   get the same gate the tree was measured through. `.paths` goes from 15 to 16
   entries.
3. **`NOTICE.md` and `UPSTREAM.sha256`'s header**, which record it as this
   fork's own file with **no licence asserted**, and keep it out of the
   integrity record, which covers upstream's bytes and the corpus.

**`test` was already real work and stayed that way.** `build.zig:788` is
`b.step("test", …).dependOn(&b.addRunArtifact(test_artifact).step)` over an
`addTest` at `:778`, so every selected target compiles the C core, the translated
`lmdb.h`, the facade and the test binary and then either runs them or does not.
No step, target or flag was added. The only build-graph change is the two switch
arms described next; `check`, `interop`, `consumer`, `smoke` and the six-target
matrix are untouched.

**The BSD and macCatalyst refusals were this fork's, and they are gone.**
`lockBackend` and `loaderSystemLibraries` each gained one arm: macCatalyst joins
the existing macOS arms (`MDB_USE_POSIX_SEM`, no extra library), and
`.freebsd/.netbsd/.openbsd` take an **empty** macro list, which leaves `mdb.c`'s
own ladder to choose. The refusal that started this was observed:
`cross-test` run `20261002-040728-7930-27044` over `x86_64-freebsd` — exit 1,
`build=fail`, `run=not_run`, `reason=build_failed`, 31.39 s, log
`local://foundation-cross-test-before-lmdb-bsd.log`, with no C translation unit
compiled at all because the refusal happens in `build.zig` at configure.

**The macros are observed, not assumed.**
`zig cc -target TARGET -E -dM libraries/liblmdb/mdb.c` on the pinned Zig 0.16.0,
exit 0 for all four targets (`local://foundation-cross-test-lmdb-target-macros.json`):

| Target | Observed predefines | Backend `mdb.c:175-231` selects |
|---|---|---|
| FreeBSD | `BSD=199506`, `__FreeBSD__=14`, `__FreeBSD_version=1400500` | its own arm at `:175-179` — POSIX mutex, robust |
| NetBSD | `BSD=199506`, `__NetBSD__=1` | the `BSD` arm at `:183-194` — SysV semaphores, with `:203-205` supplying `union semun` |
| OpenBSD | `BSD=199306`, `__OpenBSD__=1` | the same `BSD` arm — SysV semaphores |
| macCatalyst | `BSD=199506`, `__APPLE__=1` | the `__APPLE__` arm at `:184-186` — POSIX named semaphores |

**Why the BSDs take no macro.** Naming a backend would import Linux's or Apple's
choice into a format that is recorded on disk: `MDB_LOCK_TYPE` (mdb.c:965-981)
is `8` for SysV semaphores and a `pthread_mutex_t`-derived value for POSIX
mutexes, it is written into the lock file and checked on open (mdb.c:6119,
:6132). Letting the ladder run leaves the type a native LMDB built on the
platform with the same libc headers would record — the only one that can open its
databases.

**The loader decision is each platform's own documentation.** `dlopen`, `dlsym`
and `dlclose` (module.c:52-62, :78) take nothing extra on the BSDs either:
FreeBSD's `dlopen(3)` records `LIBRARY: Standard C Library (libc, -lc)` and
states libdl is not required; NetBSD's `dlopen(3)` says the interface is
automatically included in every dynamically linked program and is not a library
to link against; OpenBSD's `dlopen(3)` documents the runtime-linker interface
directly and its base system has no libdl.

**What the matrix will now attempt, from the source.** 52 of the 53 published
cells reach the compiler — 20 Linux, 2 macOS, 2 macCatalyst, 4 Windows and 24
BSD (6 FreeBSD, 9 NetBSD, 9 OpenBSD) — and `wasm32-wasi` is still refused, by
name, with its own printed reason. Before the two arms landed it was 26 allowed
and 27 refused, WASI among them. The six-target `check` baseline is deliberately
unchanged — five supported and one refused — because a target is selected by
`-Dtarget=` and the fast baseline is not widened.

**A note on the Linux cells' C library.** The published triples carry no ABI
suffix, and this compiler's default for them is musl
(`musl`/`musleabi`/`musleabihf`/`muslabi64`), not glibc. So the 20 Linux cells
are musl targets unless a run says otherwise, and a glibc `--libc-runtimes`
directory must not be assumed to be what they link. The six-target `check`
baseline is separate and explicit — it names `*-linux-gnu` — and is unchanged.
**No native source was touched in this entry.**

**Nothing under `libraries/liblmdb/` moved.** `mdb.c`, `midl.c` and `module.c`
are still the whole archive, `module.c` included: it is the dynamic crypto-module
loader, it is in upstream's `liblmdb.a` (`liblmdb/Makefile:87-88`), and upstream's
own `mdb_dump` links it unconditionally. No WASI filesystem or thread stub was
introduced anywhere, and the WASI cell stays a refusal rather than a build.

**Not claimed.** `PENDING-VERIFICATION`. At the time this entry was written,
`bash -n` over the new profile, `cross-test --list` with and without it, and the
full 53-cell run were the parent's; none had been executed from this package, and
no cell of the matrix was reported green here. **Entry 28 supersedes that**: all
three have since run, and the matrix's own distribution is recorded there. The
six-target `check` matrix keeps its own receipts and is unchanged.

**Target bound.** Any package whose cross gate is driven by a harness that
discovers a root profile. The profile is where a package would silently narrow a
matrix or take a runner decision that is not its own; keeping it to one
assignment and documenting every absence is what stops it being that.

## 28. The 53-cell matrix ran, twelve cells would not translate, and the three repairs that fixed them

**Condition.** Entry 27 opened the gate and then stopped: the profile was written
and the arms landed, but no cell had been executed. The first real run over all
53 published targets — `cross-test` run `20261002-042808-21249-5135`, mode
`zig-build`, `--build-jobs 4 --build-timeout 1800`, run timeout 300 s,
`bookkeeping_failure: false`
(`local://foundation-cross-test-matrix-lmdb.json`) — returned **1 pass**
(`x86_64-linux`), **21 build-only**, **19 run-failures**, and **13 build
failures**: the nine NetBSD targets, `mips64-openbsd` and `mips64el-openbsd`,
`hexagon-linux`, and `wasm32-wasi`, which is the designed refusal and is not a
defect. Twelve of those thirteen were this build's own translator failing on
headers it had never read, and each had its own cause.

**The change.** Three fork-side files, none of them C.

1. **The header is preprocessed by the real compiler before the translator reads
   it** (`build.zig`, `preprocessedHeader`, wired into `addTranslateC`). Aro is
   not the preprocessor this repository's C is compiled by, and two header
   families do not survive it: NetBSD's `__END_DECLS` is
   `__END_PUBLIC_DECLS`, whose `_Pragma("GCC visibility pop")` Aro 0.16 leaves in
   the token stream, so `sys/types.h:263`, `sys/endian.h:74` and `sys/bswap.h:23`
   each stop at "unknown type name 'pragma'"; and
   `generic-openbsd/mips64/endian.h:40` will not define `BYTE_ORDER` unless
   `__MIPSEL__` or `__MIPSEB__` is defined, which Aro's MIPS table does not.
   `zig cc -E -dD` is the compiler that compiles the C core for these same
   targets, so the fix is to let it expand the header and hand the translator the
   result rather than to invent the predefine the real compiler supplies. `-dD`
   keeps the `#define` lines so `c.MDB_REVERSEKEY`, `c.MDB_CURRENT` and
   `c.MDB_NODUPDATA` survive as constants. Both steps were run on the real
   headers for both families and both exit zero
   (`local://foundation-cross-test-header-preprocessing.json`). Fixes 11 cells.
2. **`CursorOp` takes the translated enum's own tag type**: `enum(c.MDB_cursor_op)`
   instead of a written-down width (`zig/root.zig:642`). `translate-c` gives a C
   enum the integer type the target's ABI gives it — `c_uint` where every enum
   gets its full width, `u8` on `hexagon` — so the facade was asserting a width
   `lmdb.h:436-465` never promised and `hexagon-linux` failed with
   `zig/root.zig:1400:58: error: expected type 'u8', found 'c_uint'`. Fixes 1.
3. **A compiler-owned `__int128` bridge, before the real header**
   (`translate.h`, guarded on `__SIZEOF_INT128__`). NetBSD's `__ALIGNBYTES`
   macros name `__int128_t` without the implicit declaration that Clang's own
   preprocessor emits alongside them, so after change 1 the two AArch64 NetBSD
   targets got as far as `lmdb_preprocessed.zig:1150:43: error: use of undeclared
   identifier '__int128_t'`. The bridge restates only Clang's builtin integer
   types under the compiler's own capability macro, alters no LMDB declaration
   and no ABI, and follows the convention the PCRE2 package in this workspace
   already uses. Fixes 2.

**What each run then measured.** The second run, `20261002-055451-11875-7326`
(`local://foundation-cross-test-corrected-lmdb.json`), left exactly the three
expected failures: `aarch64-netbsd`, `aarch64_be-netbsd` (change 3, not yet made)
and `wasm32-wasi` (the refusal). The final run,
`20261002-061717-7494-31221` (`local://foundation-cross-test-final-lmdb.json`),
distributed all 53 cells as:

| Cells | Status | Meaning |
|---|---|---|
| 1 | `pass` | `x86_64-linux`, `Build Summary: 7/7 steps succeeded; 25/25 tests passed` |
| 32 | `build_only` | compiled, `run=unavailable`, exit 0 — **no runner on this host**, so not a pass: 2 macOS, 2 macCatalyst, 4 Windows, 6 FreeBSD, 9 NetBSD, 9 OpenBSD |
| 19 | `fail` / `tests_failed` | foreign Linux: build exit 0, then `run test lmdb-tests 0 pass, 25 fail (25 total)` and `Build Summary: 5/7 steps succeeded (1 failed); 0/25 tests passed (25 failed)` |
| 1 | `fail` / `build_failed` | `wasm32-wasi`, the configure refusal, printing the reason and stopping in `refuseTarget` at `build.zig:376:5` before any C is compiled |

**52 of 53 cells reach the compiler**, which is what entry 27 asserted from the
source and what this run observed.

**The 19 run-failures were diagnosed once, not nineteen times.** Only
`aarch64-linux` was probed. A diagnostic C program built with
`-DMDB_USE_POSIX_MUTEX=1 -DMDB_USE_ROBUST=1` and run under `/bin/qemu-aarch64`
10.0.12 reports `mdb_env_open rc=38 Function not implemented` with `lock.mdb
exists=1 data.mdb exists=0`, and `qemu-aarch64 -strace` puts
`get_robust_list(0,…,1,3,0) = -1 errno=38 (Function not implemented)` right after
the `lock.mdb` `mmap`. The same binary opens cleanly with `MDB_NOLOCK` — and
leaves no `lock.mdb` at all — a `-DMDB_USE_ROBUST=0` build opens cleanly, and the
`ROBUST=1` build opens on `x86_64-linux`. **No production locking was weakened**:
`lockBackend`'s `.linux` arm is unchanged, and both of the configurations that
would have made those cells pass were diagnostic commands, never shipped
(`local://foundation-cross-test-lmdb-open-diagnostics.json`). The other eighteen
fail with an identical test signature under the same QEMU runners and the shared
cause is **inferred from them, not separately established for each**.

**Superseded on one point by §29, and kept as history.** When this entry was
written, `aarch64-linux` had been probed and the other eighteen were inferred
from its signature, and saying so was the honest state of the record. All
nineteen have since been run individually and every runner answers `ENOSYS`, so
the paragraph above is superseded on exactly that point — not vindicated, and not
wrong: it was true about the evidence and the evidence has since been extended.
What is still missing is a **guest**, not a cause.

**Native and baseline.** After the three repairs, `zig build test smoke install
-Doptimize=Debug` is exit 0 with `12/12 steps succeeded; 25/25 tests passed` in
3.369 s, `zig build test smoke -Doptimize=ReleaseSafe` is exit 0 with `10/10
steps succeeded; 25/25 tests passed` in 20.501 s, and `consumer/`'s own `zig build
run` is exit 0 with `7/7 steps succeeded` in 2.763 s
(`local://foundation-cross-test-stable-lmdb-native-Debug.log`, `-ReleaseSafe.log`,
`-consumer.log`). The six-target `check` baseline re-runs as **5 success and 1
refusal**, the five at `8/8 steps succeeded` rather than `7/7` because change 1
adds the `preprocess lmdb.h` step, and `wasm32-wasi` still refuses
(`local://foundation-cross-test-baseline-before-sdk-corrections.json`). The
profile's own gates are now observed too: `bash -n`, `cross-test --list` and
`cross-test --no-profile --list` all exit 0, and both listings name the same 53
targets, so the profile demonstrably does not narrow the matrix
(`local://foundation-cross-test-profile-verification.json`).

**Nothing under `libraries/liblmdb/` moved**, no byte of `UPSTREAM.sha256` was
rewritten, and the WASI cell is still a refusal rather than a build. Changes 1 and
3 touch how this package *reads* its own bundled header; neither copies a
declaration into `translate.h`, so the header a dependent compiles against is
still upstream's byte for byte.

**Not claimed.** The package rows — `zig fetch`, the 43-line record inside the
fetched copy, and the consumer inside it — were last observed against the tree as
it stood **before** these three repairs
(`local://foundation-expansion-lmdb-delivery-settled-filtered-package-fetch-448.log`,
`-delivery-final-package-integrity-457.log`,
`-delivery-final-package-consumer-458.log`), and the final filtered round over
the current tree **had not run** when this entry was written. It has since: the
workspace package-regression round of 2026-10-02T12:13–12:18Z fetched this
package (`lmdb-1.0.1-tSeszSGFEQCKyjxN9BejhfjEWphAgfZqtC9Qbzh22EgG`, 16 `.paths`
entries, 61/61 files), checked all 43 records in the source and 43/43 again
inside the fetched copy, and ran the consumer inside that copy to exit 0 — see
the open items under entry 29 and the gate table in `README.zig.md`. It still
does not cover the tree as it stands after this wave's two `build.zig` changes
(§29 and §30). `zig build interop` now has one receipt on this tree, and only
for the explicit `-Dtarget=x86_64-linux-gnu` selection (§30); the installed-C
program still has none. `-fsys=lmdb`, CI, and any publication or registry
resolution remain exactly where entry 27 left them.

**Target bound.** Any fork that translates a vendored C header with a toolchain
other than the one that compiles it. The translator's inputs are the headers, and
the headers are written against a different preprocessor's predefines and pragma
handling; the repair is to read them with the compiler that compiles the C, not to
fake the predefines they turn on.

## 29. The WASI reason was measured rather than assumed, and the nineteen foreign Linux cells are each observed

**Condition.** The portability wave widened this package's cross gate and put
two questions to the record that had been answered by reading rather than by
running: *why* is `wasm32-wasi` refused, and *what exactly* fails on the
nineteen foreign Linux cells. The first answer was written from a header set —
"no `<sys/mman.h>`, so no `mmap`" — and the second was one probed cell plus
eighteen read off its signature.

**Symptom.** Two claims that are not true and that no gate in this package could
have caught. WASI SDK 34 ships an optional emulated mman archive, so
`<sys/mman.h>` compiles with `_WASI_EMULATED_MMAN` and `mmap` links: "there is
no `mmap`" is false. And "eighteen inferences" was always a statement about the
evidence rather than about the world — every one of those runners could be asked,
and none was.

**Fix, on the WASI side.** Measure the facility on the real provider and write
the refusal in those terms. `refusalFor`'s WASI detail now says: WASI has no
POSIX named-semaphore or SysV-semaphore backend and its
`pthread_mutexattr_setrobust` rejects robust locking; the emulated mman **does**
provide `<sys/mman.h>` and `mmap`, but implements a `malloc`/`pread` snapshot,
not shared file mappings or write-back, and `msync` is unavailable; WASI threads
share one module's memory, not independent processes; so neither facility
supplies LMDB's shared locking and persistence.
`OBSERVED` (`local://foundation-portability-wasi-lmdb-sdk34-corrected-proof.json`,
built for `wasm32-wasi` against `wasi-sysroot-34.0` and run on Wasmtime 46.0.3):
`pshared=0 robust=28 second_snapshot=31 persisted=31` — `PTHREAD_PROCESS_SHARED`
**accepted**, the robust attribute **rejected with `EINVAL`**, the `0x52`
written through a `MAP_SHARED` mapping read back `0x31` from a second mapping of
the same file and `0x31` from the file after `munmap`, and `msync` is not in that
archive at all — an attempted call to it failed to link. **The refusal is
unchanged**: same guard, same `error.UnsupportedTarget`, same refusal of
`MDB_NOLOCK`, no macro moved, no upstream byte touched, and **no LMDB C compiled
for WASI by the SDK** — that probe is a foreign program linked against the SDK's
own emulated mman, not `mdb.c`.

**Fix, on the nineteen.** One probe, compiled per cell with the real compiler and
run under that cell's own `qemu-*`, asking the runner rather than the suite.
`OBSERVED` (`local://foundation-portability-robust-initial-diagnostics.json`): all
nineteen compiled, and every run answered `get_robust_list rc=-1 errno=38
length=0` and `robust shared mutex init rc=38` on fifteen of the cells, and
`errno=89` with `robust shared mutex init rc=89` on `mips-linux`, `mipsel-linux`,
`mips64-linux` and `mips64el-linux`, where `ENOSYS` is 89. The same source run
natively on `x86_64-linux`, on this host's own kernel, gives
`get_robust_list rc=0 errno=0 length=24`, `robust shared mutex init rc=0` and
`lock after owner death rc=130 expected=130` with exit 0; the child leaves by
`_Exit` while owning the mutex, so only the kernel's robust list can mark owner
death, and the `pthread_mutex_consistent` and relock that follow did not fail.
That control is scoped to `x86_64-linux` on this host and to this probe; it is
not evidence about any other architecture's kernel. A
native 32-bit `x86-linux` run was recorded `UNAVAILABLE` — an exec-format
refusal, not a robust failure — which does not weaken the `qemu-i386` evidence
for that cell.

**Not changed, deliberately.** No `MDB_NOLOCK`, no `MDB_USE_ROBUST=0`, no
`get_robust_list` shim that answers success, no weakened lock and no remapped
status code: `mdb_env_open` still returns the runner's code unchanged and
`posixStatus` still reports it as `error.UnexpectedStatus`.

**Not claimed.** Those nineteen cells have no runtime evidence against a kernel
that owns the robust list. They are not unrunnable, though, and are not
reported as unavailable: each of them runs on this host's own `qemu-*` runner and
fails. What this host has is no semantics-preserving provider for them — no
foreign kernel or rootfs, no full-system emulator for any of these
architectures, no other hardware — and upstream QEMU linux-user cannot serve as
one, since it answers `ENOSYS` for both robust-list syscalls unconditionally,
with no option, flag or environment variable that changes it. Bringing in a
provider of our own was never forbidden here and is not what is missing; nothing
of that kind has been built or measured. And **no gate of this package has been
re-run over this wave's tree**: not `zig build check -Dtarget=wasm32-wasi`
for the corrected reason text, not the native Debug/ReleaseSafe/consumer
re-verification, not the six-target `check` baseline, not the 53-cell matrix,
not `zig build interop`, not the installed-C surface, not `sha256sum -c
UPSTREAM.sha256`, and not `zig fetch` with the 43-line record and the consumer
inside the fetched copy. Every one of them is `PENDING-VERIFICATION`. The 43
records cover `libraries/liblmdb/` and `testdata/corpus.txt`, neither of which
this wave moved — but an argument is not a receipt.

**Target bound.** WASI SDK 34 and its optional emulated mman; QEMU linux-user
10.0.12 or newer on a Linux host, for any foreign Linux target whose guest libc
is musl and whose library takes `PTHREAD_MUTEX_ROBUST`. The general form of both
halves is in `FORK-NOTES.md` L19 and L20.

## 30. `-Dtarget=x86_64-linux-gnu` now runs what it compiled, because the predicate is the one `Run` itself asks

**Condition.** Two of this package's steps exist only if they *execute*.
`consumer` spawns a nested `zig build` inside `consumer/` and has to choose
between `run` and `install` (`build.zig:828`); `interop` builds two programs and
has to choose whether to compare their output (`build.zig:748`). Both chose with
one predicate, and the predicate they chose with could not answer the question
they were asking.

**Symptom, before — `OBSERVED` by the driver, in the driver's session, with no
`local://` receipt file.** From `foundation-libs/lmdb`, with the host scratch
environment sourced:

```sh
taskset -c 0-3 /home/tmp2/gertullj/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig \
  build consumer interop -Dtarget=x86_64-linux-gnu -j4 \
  --cache-dir /home/tmp2/gertullj/cache/foundation-libs/portability-repair-01a0f400/explicit-native-before/lmdb \
  --global-cache-dir /home/tmp2/gertullj/cache/foundation-libs/portability-repair-01a0f400/zig-global \
  --prefix /home/tmp2/gertullj/scratch/foundation-libs/portability-repair-01a0f400/explicit-native-before/lmdb \
  --summary all --color off
```

Observed: `Build Summary: 9/9 steps succeeded`, `consumer success` with
`+- consumer package success 9s`, and `interop success` with
`+- compile exe lmdb-interop` and `+- compile exe mdb_dump`. **No
`mdb_dump interoperability` line and no consumer program output at all.** The
build succeeded at running nothing: the nested consumer build was *installed*,
and the two interoperability programs were compiled and then compared to
nothing. The exit status was 0, so the row could not fail.

**Why, `SOURCE-CONFIRMED` against the pinned compiler.** The predicate was
`Target.Query.isNative()`, which is `isNativeTriple() and ofmt == null`
(`lib/std/Target/Query.zig:396-398`) over `isNativeCpu() and isNativeOs() and
isNativeAbi()` (`:392-394`); `isNativeAbi()` demands `os_tag == null and abi ==
null` (`:388-390`), and `isNativeOs()` adds `dynamic_linker == null`,
`glibc_version == null` and `android_api_level == null` (`:383-386`). Writing the
target down at all is what makes the query false: `-Dtarget=x86_64-linux-gnu`
names the operating system and the ABI, so on an x86_64 Linux host — where
`getExternalExecutor` computes `os_match` and `cpu_ok` and reaches `.native`
(`lib/std/zig/system.zig:48-51`, `:71-81`) — the one triple that describes the
target this host can plainly execute was the one triple the gate skipped.

**Fix.** One function, `hostCanExecute` (`build.zig:883-918`), now answers for
both call sites, and it answers by asking the same question
`std.Build.Step.Run` asks about the artifact it is about to spawn
(`lib/std/Build/Step/Run.zig:1268`): `std.zig.system.getExternalExecutor` with
the two options `Run` fills in from the artifact, plus the executor switches the
build runner resolved and `std.Build` exposes (`build.zig:886-893`). The
returned executor is then mapped once: `.native, .rosetta => true` (`:895`),
`.qemu => !candidate.isGnuLibC() or b.libc_runtimes_dir != null` (`:910`),
`.wine, .wasmtime, .darling => true` (`:913`), `.bad_dl, .bad_os_or_cpu =>
false` (`:916`). The two options are filled from this package's own facts, not
guessed: every executable this build runs links libc, so `.link_libc = true`;
and QEMU reaches a foreign dynamic linker only when a libc-runtimes directory
was supplied, so `.qemu_fixes_dl = candidate.isGnuLibC() and
b.libc_runtimes_dir != null`. `runConsumer` forwards the switches this build
resolved to the nested build — `-fdarling`, `-fqemu`, `-frosetta`, `-fwasmtime`,
`-fwine` and `--libc-runtimes <dir>` (`build.zig:835-840`) — so the nested build
executes under the same executor the decision was made with.

**The `.qemu` arm is a second gate, and it is why the QEMU half stays
conservative.** `qemu_fixes_dl` cannot carry this decision: `getExternalExecutor`
enters the QEMU arm for a foreign CPU on `!cpu_ok` **alone**
(`lib/std/zig/system.zig:95`), whatever that option says, so the returned
executor is `.qemu` in exactly the case the option stops describing. What `Run`
then does with it is the fact that decides: it appends `-L <runtime triple>` for
a cross libc target and, with `b.libc_runtimes_dir` unset, calls `failForeign`
on `--libc-runtimes` (`lib/std/Build/Step/Run.zig:1290-1314`, the failure at
`:1310`) rather than skipping the run. So a foreign **GNU**-libc target with no
libc-runtimes directory is not a skip but a failure, and the honest answer is
no: `.qemu => !candidate.isGnuLibC() or b.libc_runtimes_dir != null` is that
test, and it leaves the consumer on `install` and the interoperability
comparison off — compile evidence, and labelled as such. `isGnuLibC()` is the
whole of `Run`'s `need_cross_libc` in this package (`Run.zig:1264-1266`): the
musl half of that disjunction also asks for `exe.linkage == .dynamic`, and both
executables here are made with `b.addExecutable` and given no `linkage`, so that
half never holds and the two now test the same fact.

**Symptom, after — `OBSERVED` by the driver, same session, no `local://` receipt
file.** The identical command with `explicit-native-before` replaced by
`explicit-native-after` in both `--cache-dir` and `--prefix`:

```sh
taskset -c 0-3 /home/tmp2/gertullj/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig \
  build consumer interop -Dtarget=x86_64-linux-gnu -j4 \
  --cache-dir /home/tmp2/gertullj/cache/foundation-libs/portability-repair-01a0f400/explicit-native-after/lmdb \
  --global-cache-dir /home/tmp2/gertullj/cache/foundation-libs/portability-repair-01a0f400/zig-global \
  --prefix /home/tmp2/gertullj/scratch/foundation-libs/portability-repair-01a0f400/explicit-native-after/lmdb \
  --summary all --color off
```

Observed: `consumer: linked LMDB 1.0.1`, `consumer: committed records persisted,
abandoned ones did not`, `6 records match mdb_dump -p byte for byte`,
`Build Summary: 10/10 steps succeeded`, `consumer success`, `interop success`,
`+- mdb_dump interoperability success 24ms`, **exit 0**. The step count moves
from 9 to 10 because the comparison is a step again instead of an absence, and
the six records are the six lines of the fixture's `[expect]` block
(`testdata/corpus.txt:31-37`), compared against upstream's own reader built from
this repository's sources.

**Preserved, deliberately, and stated as preservation rather than as
equivalence.** This entry changes the execution predicate and nothing else.
`lockBackend`'s `.linux` arm is not what this entry altered, so the robust
process-shared lock is still what `mdb_env_open` asks for on every Linux
target; no `MDB_NOLOCK`, no `MDB_USE_ROBUST=0`, no `get_robust_list` shim, no
remapped status code, and `posixStatus` still reports the runner's number as
`error.UnexpectedStatus`. The WASI refusal is upstream of this change in the
build graph itself: `build.zig:940` stops a refused target with
`refuseTarget` **before** `interop` (`:1032`) or `consumer` (`:1042`) is wired,
so no executor decision can be reached for `wasm32-wasi` at all, and
`refusalFor`'s reason text is untouched. `check` still selects its matrix by
`target.query.isNative()` (`build.zig:1012`) and still compiles without running
anything, which is what it is for.

**This cannot move the 53-cell matrix.** `test` and `smoke` never consulted this
predicate: `build.zig:989` and `:996-998` hand the artifacts to
`b.addRunArtifact`, and `Run` decides whether to spawn them from
`getExternalExecutor` itself, from the artifact, at run time. So the nineteen
foreign Linux cells — musl targets, since their published triples carry no ABI
suffix, and exactly the cells this predicate already answered *no* for — are
outside this entry's reach: their 25-failures-each result is an observation from
an earlier tree (§29) and their state over this tree is `PENDING-VERIFICATION`
with every other cell. Nothing here is evidence about any of them.

**Not claimed.**

* **The foreign-GNU-under-QEMU branch has never been exercised.** No run has
  asked `hostCanExecute` about a foreign GNU-libc target with
  `-fqemu` and no `--libc-runtimes`. The `.qemu` second gate is
  `SOURCE-CONFIRMED` against the pinned compiler's own `lib/std` at
  `lib/std/zig/system.zig:95` and `lib/std/Build/Step/Run.zig:1290-1314`, and it
  is `PENDING-VERIFICATION` as behaviour.
* **Both runs above are conversation-observed and have no `local://` receipt
  file.** They are recorded here with their argv and their observed lines so
  they can be repeated; the row they belong to in the single gate table is in
  `README.zig.md`, which this entry does not edit.
* **Every other gate is still `PENDING-VERIFICATION` over this tree**: `zig
  build test` and `zig build smoke` in Debug and ReleaseSafe, `consumer`'s own
  `zig build run`, the six-target `check` baseline, the 53-cell matrix, `zig
  build interop` on the default native selection, the installed-C surface, and
  `sha256sum -c UPSTREAM.sha256`. **No packaging round covers this tree** — the
  last one on record is the workspace package-regression run of
  2026-10-02T12:13–12:18Z, which predates this change — so `zig fetch`, the
  43-line integrity record inside the fetched copy and the consumer inside that
  copy are all outstanding. The matrix and the package re-proof are the parent's
  to run after the documentation freeze.
* **Nothing under `libraries/liblmdb/` moved**, no byte of `UPSTREAM.sha256` was
  rewritten, and no C source, macro or backend table was edited. The change is
  `build.zig` alone.

**Target bound.** Zig 0.16.0's `lib/std` as pinned by this package, for any fork
whose gate decides between *running* and *installing* or *comparing* with a
predicate of its own. The general form is in `FORK-NOTES.md` L21.

## What is deliberately still open

* **`zig build -fsys=lmdb` has not been run**, and no result is claimed for it. It
  needs an installed liblmdb with a matching header, and no such installation was
  used here. The installed-artifact receipts are this package's **own** `zig-out/`
  contents and the `zig cc` program run against them; neither is evidence for this
  row.
* **`.github/workflows/verify.yml` has never been executed.** No `act`, no runner
  and no push. Every command it names has a receipt outside a runner except
  `-fsys=lmdb`, which it does not run. The file is `SOURCE-CONFIRMED` against the
  tree.
* **The six-target `check` matrix executes nothing, and still compiles nothing
  else.** Five triples compiled and the sixth refused, both in the original round
  and in the re-run; `check` never runs a foreign binary, so every one of those
  rows is compile evidence only — and the Windows status table of entry 8 stays
  `SOURCE-CONFIRMED` as far as runtime behaviour goes, a Windows target having
  been compiled and never run.
* **The 53-cell matrix has run, and most of it is not a pass.** Final run
  `20261002-061717-7494-31221`: 1 `pass`, 32 `build_only`, 19 `fail` on tests,
  1 `fail` at configure (§28). **Build-only is not green** — 32 cells compiled and
  then reported `run=unavailable` because this host detects no runner for them. No
  blanket "the foreign targets pass" claim is made or supportable.
* **The 19 foreign Linux run-failures are all observed now, and none of them has
  ever run on a real guest kernel.** Each of the nineteen runners has been asked
  directly and answers `ENOSYS` — `errno=38` on fifteen of them and `89` on the
  four MIPS cells, where that is `ENOSYS`'s number — for both the raw
  `SYS_get_robust_list` call and the robust process-shared mutex, and that is
  the code `mdb_env_open`
  returns to all 25 tests on each cell as `error.UnexpectedStatus`. What they
  lack is a semantics-preserving provider — a guest kernel and a rootfs per
  architecture, or hardware; none is on this host, so this is a platform
  boundary and not a pending gate. See §29.
* **The last packaging round on record is older than this wave's tree.** The most
  recent one is the workspace package-regression run of 2026-10-02T12:13–12:18Z,
  not the `foundation-expansion-…` logs: `zig fetch` printed
  `lmdb-1.0.1-tSeszSGFEQCKyjxN9BejhfjEWphAgfZqtC9Qbzh22EgG` with 16 `.paths`
  entries and 61/61 files, all 43 records checked in the source and 43/43 again
  inside the fetched copy with the two manifests byte-identical, and the consumer
  inside that copy exited 0. It ran over the post-§28 tree and predates both of
  this wave's `build.zig` changes (§29 and §30), so no packaging round covers
  this wave's tree and nothing is claimed for one.
* **This wave has re-run two gates of this package, and only two.** Entry 30's
  driver-observed pair — `zig build consumer interop -Dtarget=x86_64-linux-gnu`,
  once before the `hostCanExecute` change and once after it — is the whole of it,
  and **neither has a `local://` receipt file**; both were observed in the
  driver's own session and are recorded in §30 with their argv. `zig build check
  -Dtarget=wasm32-wasi`, the native Debug/ReleaseSafe/consumer re-verification,
  the six-target `check` baseline, the 53-cell matrix, `zig build interop` on the
  default native selection, the installed-C surface, `sha256sum -c
  UPSTREAM.sha256` and the final filtered package round are all still
  `PENDING-VERIFICATION` over this tree; every receipt above names an earlier
  source state.
* **`zig build interop` has an observation on this tree, for one target
  selection only.** The `mdb_dump` comparison ran and matched, under the explicit
  `-Dtarget=x86_64-linux-gnu` selection (§30). The default native selection has no
  receipt over this tree, so the `7/7` and `8/8` step counts of entries 28 and 29
  were not re-measured here, and the installed-C program has not been re-run at
  all.
* **The foreign-GNU-under-QEMU branch of `hostCanExecute` is unexercised.** No
  run has asked it about a foreign GNU-libc target with `-fqemu` and no
  `--libc-runtimes`; the branch is `SOURCE-CONFIRMED` against the pinned
  compiler's own `lib/std` and `PENDING-VERIFICATION` as behaviour (§30).
* **The Windows and macOS rows carry no runtime evidence at all.** Nothing on
  this host runs a Windows or macOS binary, so those six cells are
  compile-only even when they build. `MDB_USE_POSIX_SEM` and the Win32 mutex
  path have never been *run* here.
* **`zig build install` does not carry the conditions text into the prefix.**
  Recorded in `NOTICE.md` under OLDAP-2.8 condition 2; the fix belongs to whoever
  owns `build.zig`.
* **No push, no publication and no remote was touched.** This package is local,
  uncommitted and unpublished, and remains so until the user says otherwise. The
  packaging receipts of entry 26 do not narrow this: `zig fetch` was given a local
  directory, so **registry resolution and `.url`/tarball dependency resolution
  remain untested** and no hash for either form exists.
* **The README's `.url` snippet is still a placeholder**, and stays one until a
  release is published and fetched by somebody. What entry 26 establishes is the
  `.path` form, in this tree and in a copy made from `.paths`.

## See also

* [`UPSTREAM.md`](UPSTREAM.md) — the pin, and what the integrity record does and
  does not establish.
* [`NOTICE.md`](NOTICE.md) — the per-path legal record: licence scope, the
  OLDAP-2.8 obligations, the other terms the tree retains, and every file this
  fork adds.
* [`README.zig.md`](README.zig.md) — how to build, import and call the package,
  with the full operation, lifetime, error, flag and bounds tables and the exact
  gate commands.
* [`FORK-NOTES.md`](FORK-NOTES.md) — the reasoning behind each entry above.
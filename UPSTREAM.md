# UPSTREAM.md — what this fork is a fork of

## Upstream

| | |
|---|---|
| Project | LMDB, the Lightning Memory-Mapped Database |
| Canonical repository | `https://github.com/LMDB/lmdb.git` |
| Pinned ref | tag `LMDB_1.0.1` |
| Pinned commit | `6f0a32496a5aadee15a5e5103c479bd3355ae273` |
| Version of the C library built here | `1.0.1` |
| Licence | The OpenLDAP Public License, Version 2.8, 17 August 2003 (OLDAP-2.8) — **upstream's own grant only**. Three further terms are retained in the tree; they are itemised in the second bullet below and per path in `NOTICE.md` |
| Copyright | Copyright 2011-2021 Howard Chu, Symas Corp. — plus the OpenLDAP Foundation on `midl.c`/`midl.h`, Martin Hedenfalk in `lmdb.h`/`mdb.c`, Landon Curt Noll in `mdb.c`, and D. J. Bernstein in `chacha8.c` |

Where each of those comes from, read out of the carried tree:

* The version is `libraries/liblmdb/lmdb.h:235-239`, which declares
  `MDB_VERSION_MAJOR`, `MDB_VERSION_MINOR` and `MDB_VERSION_PATCH` as `1`, `0`
  and `1`. `lmdb.h:245-246` composes them into `MDB_VERSION_FULL`, and
  `lmdb.h:249` records `MDB_VERSION_DATE` as `"Aug 6, 2026"`. It is the
  version of the C library, not a version of the Zig wrapper, and it is what
  `build.zig.zon` carries in `.version`; `build.zig:725-730` refuses to
  configure if the two drift apart.
* **Upstream's own two records of the version disagree, and this fork takes
  the header's.** `libraries/liblmdb/Makefile:36` still reads
  `LMDB_VERSION = 1.0.0`, and that string is what `Makefile:156` writes into
  the generated `lmdb.pc`. The header is the ABI the compiled code answers to:
  `mdb_version()` returns `MDB_VERSION_FULL`. So the header is the record here
  and the Makefile string is a stale packaging detail that upstream did not
  update at this tag. It is not corrected by this fork: `libraries/liblmdb/` is
  upstream's, byte for byte. No gate in this package pins the version string:
  the smoke program *prints* the version it linked against — a reading, not a
  pin — and the installed-C gate does not call `mdb_version()` at all, because it
  takes three out-parameters (`lmdb.h:575`) and a version assertion would be an
  assertion about the fork's own bookkeeping rather than about upstream.
* The licence is `libraries/liblmdb/LICENSE:1-2` ("The OpenLDAP Public
  License / Version 2.8, 17 August 2003"). The copyright line is
  `libraries/liblmdb/COPYRIGHT:1` ("Copyright 2011-2021 Howard Chu, Symas
  Corp."), and `COPYRIGHT:5-6` is what names the grant: redistribution "are
  permitted only as authorized by the OpenLDAP Public License". That sentence is
  restated in the header comment of 29 of the 42 files — `mdb.c:12`,
  `midl.c:11`, `module.c:8`, `mdb_dump.c:7`, `lmdb.h:144`, `midl.h:19`, and the
  other upstream tools and test programs — which is where a reader of the code
  will find the terms.
* **That sentence is the grant on upstream's own work, not the whole of the
  licence content of this directory.** Reading the headers found three further
  terms, two of them inside the compiled core. They are upstream's own retentions
  of other people's work, reproduced here because the directory is byte-identical
  to the pin. `NOTICE.md` carries the full per-path record; the short form is:

  | Term | Files | Lines |
  |---|---|---|
  | ISC-style, Martin Hedenfalk, "derived from btree.c" | `lmdb.h`, `mdb.c` | `lmdb.h:151-166`, `mdb.c:19-33` |
  | Public domain, Landon Curt Noll, FNV-1a | `mdb.c`, conditional | `mdb.c:5846-5872`, inside `#ifdef MDB_USE_HASH` at `mdb.c:5845` |
  | Public domain, D. J. Bernstein | `chacha8.c` | `chacha8.c:1-5` |

  `chacha8.h` carries no notice, no grant and no attribution in its own bytes;
  the D. J. Bernstein statement above is recorded for `chacha8.c` only and is not
  extended to the header, which is a separate file whose author wrote nothing about
  it. `crypto.c` and `cryptoc.c` are OLDAP-2.8, and their
  `#include <sodium.h>` (`crypto.c:15`, `cryptoc.c:15`) is a dependency on a
  library this package neither vendors, compiles nor links — a mention, not a
  grant, and this record does not read a licence into it.

  On the FNV-1a notice, the important part is what it does **not** change. The
  Hedenfalk grant is in `mdb.c` and `lmdb.h`, both compiled into every supported
  target's archive, so a record naming only OLDAP-2.8 was wrong on all five
  supported targets — not conditionally wrong. FNV-1a is a **third** term layered
  on top of those two, and it is the only one whose reach varies: present for
  `aarch64-macos-none` and `x86_64-windows-gnu`, absent from the three Linux
  cores, which still carry both core terms. `wasm32-wasi` produces no binary at all
  — `refused_check_targets` names it (`build.zig:145-147`) and the build stops with
  `error.UnsupportedTarget` — so no compiled terms apply there. `NOTICE.md`
  tabulates this per target and marks which rows are read and which inferred.

  The reason that refusal prints was corrected on 2026-10-02 against a
  measurement rather than against a header set: WASI SDK 34 **does** provide an
  optional emulated `<sys/mman.h>` and `mmap`, and what the SDK lacks is the
  shared mapping, the write-back and the independent-process robust lock that
  LMDB is made of (`local://foundation-portability-wasi-lmdb-sdk34-corrected-proof.json`;
  `CHANGELOG.md` §29). **That correction is entirely fork-side and moves nothing
  in this record**: no byte under `libraries/liblmdb/` changed, no digest was
  rewritten, `wasm32-wasi` still produces no binary, and so no compiled terms
  apply there now either.
* The workspace delivery record `local://foundation-expansion-sources.json`
  carries, verbatim: repo `https://github.com/LMDB/lmdb.git`, ref
  `LMDB_1.0.1`, commit `6f0a32496a5aadee15a5e5103c479bd3355ae273`, licence
  `OLDAP-2.8`.

**Tag signature: not verified here.** No GPG key was consulted while this file
was written, and no git command was run at all, so nothing in this document is
an observation of the clone's own state. Treat the commit id and the archive
digest below as the provenance anchors, not a signature check.

## Archive receipt

The workspace delivery record `local://foundation-expansion-source-archives.json`
holds a SHA-256 receipt for the deterministic `git archive` stream of the
**full repository tree** at that commit. For this library it reads, verbatim:

```
7c23a9c5a8e94fa36179ed7de22efd7c3c46eae565c95dc6bcf98e3bb1a3dcd7  -
```

The trailing `-` is `sha256sum`'s name for standard input: the digest is of
the archive stream as it was piped past the hasher, not of any file in this
repository. It was produced by the driver when the fork was imported. It is
recorded here so a later re-fetch can be compared against the same bytes.

## Import mechanism

A full clone of the canonical repository, so upstream's Git history is
present. The workspace delivery record states that every fork in this wave
keeps the upstream remote named `upstream`, a local `main`, and complete
upstream history. This fork adds no patch series on top of that history: the
Zig package is a set of new files in new regions.

The working tree this package is built from carries exactly two things: the
`libraries/liblmdb/` directory, and the files this fork wrote. Upstream's
`contrib/`, its documentation site and its own CI are not checked out here, so
"a full clone" is a statement about the history the repository holds and not
about what its working tree contains.

**No file under `libraries/liblmdb/` is modified.** `UPSTREAM.sha256` is what
says so from the bytes, over all 42 of them including
`libraries/liblmdb/.gitignore`, which is upstream's and **is** hashed. The
package-root `.gitignore` is one of the files this fork wrote: it restates none
of upstream's rules and removes none of them, and it is deliberately absent from
the integrity record because it is not byte-identical to anything at the pin
(see `NOTICE.md`).

## What this fork is

A Zig package that compiles upstream's own C library from
`libraries/liblmdb/` in this repository and publishes a small Zig facade over
the translated `lmdb.h`. Nothing of the database engine is reimplemented,
re-derived or reconfigured: there is no generated table, no patched upstream
source, no upstream Makefile run, and no download at build time.
`NOTICE.md` lists every file this fork adds or edits.

**Upstream ships no README, and there is therefore no `README.upstream.md` here.**
The working record for the pin — the driver's byte-verified upstream-README proof,
`local://foundation-contract-upstream-readme-proof.json` — carries
`"primary_readme": null` for this project, and that is not a gap in the import: at
commit `6f0a32496a5aadee15a5e5103c479bd3355ae273` the tree has no file named
`README`, `README.md` or `README.rst` at any depth. Of the 42 files this fork
carries, the prose ones are `intro.doc` and `upgrading.doc`, both under
`libraries/liblmdb/` and both OLDAP-2.8 (`intro.doc:2-6`, `upgrading.doc:2-6`),
alongside five roff man pages. Those stay at those original paths, unmodified.

The consequence for the documentation set is a rule, not an accident: **`README.md`
in this repository is fork-authored in full, from its first line**, and must never
be described as upstream's, as a copy of anything at the pin, or as "the upstream
README, relocated". There is nothing at the pin for it to be a copy of.

## Nix packaging, and what it is not

`package.nix` is the SDK's whole Nix surface: one uncurried derivation over this
directory, injected `{ lib, stdenv, zig, linkage ? "static" }`, returning one
output. `flake.nix` and `devenv.nix` call that same file identically, which is why
the variants live in the entry points rather than in it. No `../workspace` import,
no sibling dependency, no host account or store path, no build-time download, and
no Nix cross-compilation: the derivation refuses a `pkgsCross` stdenv because it
neither exercises nor documents that path, while a remote builder for its own
system is unaffected.

What is worth recording here, because it is a property of upstream's material
rather than of the packaging:

* **The derivation installs nothing of its own.** It runs `build.zig`'s real
  build once against `$out` with `-Dcpu=baseline -Dlinkage=<variant>` and both Zig
  caches under the builder's `TMPDIR`. The C flags, the source list, the header,
  the tools, the man pages, the `.pc` and the licence material all come from
  `build.zig`, so there is one writer per path.
* **The derivation never verifies `UPSTREAM.sha256`.** The integrity record is a
  gate the driver runs and records; turning it into an unobserved build step
  would report a result nobody took. The manifest reaches a dependent through
  `.paths`, as a record, not as something an output claims to satisfy.
* **There is no wholly-static claim anywhere.** The static archive still contains
  `module.c`, and the consumer's link line still has to resolve `dlopen`; that is
  what `Libs.private` records and why the README tells a static C consumer to pass
  `pkg-config --static`.
* **One platform gap is stated, not hidden.** `patchelf` rewrites ELF rpaths and
  does not read Mach-O, so the build-cache rpath Zig adds is removed on ELF and
  left on Darwin, where the `@loader_path/../lib` entry is added separately and the
  tools resolve the installed library regardless.

## The C core: three translation units, and why three

The whole library this package compiles is, by name:

```
libraries/liblmdb/mdb.c
libraries/liblmdb/midl.c
libraries/liblmdb/module.c
```

`build.zig:76-80` names them one by one rather than globbing the directory, so
a file appearing upstream cannot silently join the archive. That list is
upstream's own:

* `liblmdb/Makefile:87-88` — `liblmdb.a: mdb.o midl.o module.o`, and the
  recipe archives exactly those three objects.
* `liblmdb/Makefile:90-92` — the shared library is built from `mdb.lo midl.lo
  module.lo`, the same three units, recompiled position-independent.

**`module.c` stays in the archive even though this fork's Zig facade never
calls it.** It is the dynamic crypto-module loader: `mdb_modload`,
`mdb_modsetup` and `mdb_modunload`, all three declared in the public header
(`lmdb.h:1899-1918`). Two independent reasons, both from upstream:

1. Upstream puts `module.o` in `liblmdb.a` (`Makefile:87-88`) and every one of
   its tools links `-ldl` (`Makefile:97-105`). An archive that left `module.c`
   out would not be the library the pin names.
2. `mdb_dump.c` names all three entry points unconditionally
   (`mdb_dump.c:270`, `:275`, `:364`), so upstream's own reference tool does
   not link against a two-object archive. An earlier state of this fork
   dropped `module.c` from the shipped archive and compiled a second copy of it
   beside the tool; that was wrong twice over — it was not the pinned library,
   and it gave the tool a unit the installed archive does not have. It is
   recorded here and in `CHANGELOG.md` because the same reasoning generalises:
   *what the shipped archive contains is a property of the upstream library,
   not of which facade methods happen to exist.*

What is **not** in the core, with the rule that excludes each:

| Excluded | Upstream rule that puts it elsewhere |
|---|---|
| `chacha8.c`, `chacha8.h` | linked only into `mtest_enc` (`Makefile:113`); nothing in the three core units references it |
| `crypto.c` | the loadable `crypto.lm` module that `mtest_enc2`–`mtest_enc4` load (`Makefile:114-124`); a payload, not part of the library |
| `cryptoc.c` | named by no rule in that Makefile at all |
| `mdb_stat.c`, `mdb_copy.c`, `mdb_load.c`, `mdb_drop.c` | the other four upstream tools; none is compiled here |
| `mtest*.c`, `mplay.c` | upstream's own test programs; carried, compiled by nothing |

**Being outside the core does not mean being outside the licence record.** The
four cipher files above are excluded from the archive for a build reason, and
three of them carry terms that are not OLDAP-2.8: `chacha8.c` is public-domain
D. J. Bernstein code (`chacha8.c:1-5`), `chacha8.h` carries no notice at all, and
`crypto.c`/`cryptoc.c` are OLDAP-2.8 whose `<sodium.h>` include is a dependency
this package does not carry. They travel, so their terms travel, and
`NOTICE.md` records them per path. The reverse also holds: the exclusion is not a
licence judgement, and nothing here would be a reason to drop a file from
`.paths`.

## Headers: one installed, both shipped

`zig build` installs **one** header, `lmdb.h`, because that is the only header
upstream installs — `IHDRS = lmdb.h` (`Makefile:49`). `midl.h` is
upstream-internal and is not installed. That has not changed; what has changed is
everything else the install prefix now carries, which is listed under
"What an installed output contains" below.

Both are nevertheless **shipped** in `build.zig.zon` `.paths`, because the
compiled units need them by quoted name. Upstream records exactly this
dependency set in its own rules: `mdb.o: mdb.c lmdb.h midl.h`,
`midl.o: midl.c midl.h`, `module.lo: module.c lmdb.h`, `%.o: %.c lmdb.h`
(`Makefile:126-144`). The closure is `mdb.c` → `lmdb.h`, `midl.h`; `midl.h` →
`lmdb.h`; `module.c` → `lmdb.h`; `mdb_dump.c` → `lmdb.h`. What `module.c`
needs beyond that is the platform's own: `<windows.h>` or `<dlfcn.h>`,
`<stddef.h>`, `<string.h>` (`module.c:14-21`).

`translate.h` is the one header handed to `addTranslateC`, and its whole
content is `#include <lmdb.h>` — angle brackets, so a stray `lmdb.h` beside
the package root cannot win over the one `build.zig` put on the include path.

## The platform link dependency, and who owns it

Because `module.c` is inside the archive, the archive calls the platform's
dynamic loader. A static archive resolves nothing, so this has to be said
once, on the module that owns the unit:

| Target | Added system library | Why |
|---|---|---|
| Linux | `dl` | `module.c:51-66`, `:77-78` call `dlopen`/`dlsym`/`dlerror`/`dlclose`. Upstream's own reading is `LDL = -ldl` (`Makefile:31`), appended to the shared link line (`Makefile:92`) and recorded as `Libs: -llmdb -ldl -pthread` in the generated `lmdb.pc` (`Makefile:158`). |
| Windows | `kernel32` | `module.c:14-15` includes `<windows.h>`; `:33-49` and `:74-76` call `LoadLibrary`/`GetProcAddress`/`FreeLibrary`, which are kernel32 exports. There is no libdl on that platform for upstream's `LDL` to name. |
| macOS | none | Darwin takes the POSIX arm, and its `dl*` entry points are exported by libSystem, which is the C library `link_libc` already links. `LDL` is a GNU-ld name; the Makefile's only macOS mention is a soname option it leaves commented out (`Makefile:58-59`). |

`build.zig:453-455` declares it on the `core` module — the module that owns
`module.c` — not once per program, because Zig carries a static library's own
link objects onto the link line of everything that links it. One declaration
therefore reaches the facade, the tests, the smoke program, the
interoperability program, upstream's `mdb_dump` and the external consumer
package. `build.zig:251-253` panics rather than answering with an empty list
for any operating system `lockBackend` accepted but this function has no
decision for, so a new platform cannot lose its loader silently.

**In an installed `.pc`, the same dependency is recorded and it differs by
variant.** `build.zig` generates `lib/pkgconfig/lmdb.pc` — upstream writes one only
through its own Makefile (`Makefile:147-158`), which this fork does not run. In the
**static** variant the archive resolves nothing, so `Libs.private` carries the
loader dependency (`-ldl -pthread` on ELF, `-lkernel32` on Windows, empty on
Darwin) and a consumer who runs `pkg-config --static --libs lmdb` gets it. In the
**shared** variant the dependency is already a `DT_NEEDED` entry inside the shared
object, exactly as upstream's `Makefile:92` arranges, so `Libs.private` is empty
and re-adding the flags would be wrong. Upstream's own template puts all of it on
one `Libs:` line (`Makefile:158`), which is correct for neither variant and wrong
for one of them.

`mdb_dump` is compiled as a single translation unit and linked against **that
same complete archive** (`build.zig:612-617`), which is how upstream links it
(`Makefile:100-101`). Its `mdb_modload`/`mdb_modsetup`/`mdb_modunload`
references therefore resolve out of the archive a consumer of the installed
library gets, not out of a second copy of the unit compiled beside the tool.

`-pthread` is deliberately **not** repeated on the link line
(`build.zig:412-425`): upstream puts it on every line
(`Makefile:24`, `:158`), and Zig's libc carries the POSIX threads entry points
inside libc on every target this build supports, so asking the linker for a
separate `libpthread` would turn a complete library into a search for a file
that exists only on the machine running the build. The CI gate's plain C
consumer does repeat it (`.github/workflows/verify.yml:215-219`), because that link line is
`zig cc`'s and not Zig's build graph.

## What an installed output contains

`zig build --prefix <p>` writes, in both variants:

| Path | What | Upstream's own arrangement |
|---|---|---|
| `lib/liblmdb.a` or `lib/liblmdb.so.1.0.1` + symlinks | the three-unit library | `ILIBS`/`ILIBS2`, `Makefile:50-51`; upstream's shared name is `liblmdb.so.1.0` (`VEREXT = 1.0`, `Makefile:33-37`), this build's is `.so.1.0.1` because Zig names it for the pinned `version` |
| `include/lmdb.h` | the public header | `IHDRS`, `Makefile:49`, installed at `Makefile:77` |
| `lib/pkgconfig/lmdb.pc` | generated link metadata | upstream generates one at `Makefile:147-158`; three of its rows are answered differently here, recorded in `README.md` and `NOTICE.md` |
| `bin/mdb_stat`, `bin/mdb_copy`, `bin/mdb_dump`, `bin/mdb_load`, `bin/mdb_drop` | upstream's five tools, each linked against the artifact this variant produced | `IPROGS`, `Makefile:52`, installed at `Makefile:70` |
| `share/man/man1/mdb_*.1` | upstream's five man pages | `IDOCS`, `Makefile:53`, installed at `Makefile:78` |
| `share/lmdb/LICENSE`, `share/lmdb/COPYRIGHT` | upstream's licence text and copyright notice, byte-identical to the two files in this directory | upstream's `install:` copies **neither** (`Makefile:65-78`); OLDAP-2.8's conditions 2 and 3 need them in a binary distribution, so this build installs them |
| `bin/lmdb-smoke` | this fork's own smoke program, compiled and never run by `zig build` | no upstream counterpart |
| `share/lmdb/NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`, `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md` | this fork's own records | no upstream counterpart. They travel because the fork's files are under OLDAP-2.8 too, so condition 2 applies to their notices as well. `UPSTREAM.sha256` installs as a record: its paths are relative to the package root, so it is not runnable from a prefix |

**Two things are deliberately absent**, and both absences are upstream's own
arrangement rather than an omission here. `midl.h` is not installed, because
upstream installs only `lmdb.h`; it still ships in `.paths`, because the compiled
units include it. And upstream's `intro.doc` and `upgrading.doc` are not in
upstream's `install:` target either, so neither is in this build's install prefix;
they travel in `.paths` and stay at those original paths. The man pages that are
installed point a reader at `COPYRIGHT` and `LICENSE`, and both are installed
beside them at `share/lmdb/`.

**No data files.** LMDB has none, so that part of the install closure is empty by
fact rather than by omission. The sample databases `sample-mdb.txt` and
`sample-bdb.txt` are upstream's test fixtures for `mtest.c`, not runtime data, and
they travel in the package source without being installed.


## What is upstream's, and what ships

**All 42 files under `libraries/liblmdb/` are upstream's bytes, and all 42
ship.** `build.zig.zon` `.paths` names the directory itself rather than a list of
files inside it, so a dependent receives upstream's complete `liblmdb` directory
at that commit: the three core units, the reference tool, both headers, the
other four tools and their man pages, upstream's own test programs and sample
databases, its build definitions and release notes, its `.gitignore`, and the two
legal files.

That is a deliberate change from an earlier state of this fork, whose `.paths`
named sixteen individual paths and shipped only the eight files the compiled core
could reach. Shipping the directory is what makes the integrity record replayable
outside this repository: with all 42 present, `sha256sum -c UPSTREAM.sha256`
reports 43 `OK` lines in a package materialised from `.paths` alone, instead of
nine with 34 `No such file or directory`. It is also what makes the licence
obligation structural rather than remembered: condition 1 and condition 3 apply
to the whole of what upstream wrote, so the whole of it travels.

Eight of the 42 are what this build **compiles or installs**:

| Path | What it is |
|---|---|
| `libraries/liblmdb/mdb.c` | the engine: every page, B-tree, transaction, lock and map operation |
| `libraries/liblmdb/midl.c` | mid-level helpers the engine is written in terms of |
| `libraries/liblmdb/module.c` | the dynamic crypto-module loader, `mdb_modload`/`mdb_modsetup`/`mdb_modunload` |
| `libraries/liblmdb/mdb_dump.c` | upstream's own dump tool: the reference reader the `interop` gate compares against, built from this repository's sources so it is the reader of *this* pin and not of whatever happens to be installed on the host. It is the **only** tool unit this build compiles, and it links this package's complete archive |
| `libraries/liblmdb/lmdb.h` | the public header; installed into the prefix, and the header `addTranslateC` translates |
| `libraries/liblmdb/midl.h` | the internal header `midl.c` and `mdb.c` include; shipped because they include it, not installed |
| `libraries/liblmdb/LICENSE` | The OpenLDAP Public License, Version 2.8, verbatim |
| `libraries/liblmdb/COPYRIGHT` | the upstream copyright notice the redistribution conditions require be retained |

## The other 34: carried, shipped, referenced by nothing

They stay in this repository for provenance, re-sync diffs and audit, and they
travel with the package: the four unused tools (`mdb_stat.c`, `mdb_copy.c`,
`mdb_load.c`, `mdb_drop.c`) and the man pages, upstream's own test programs and
sample databases (`mtest.c` … `mtest6.c`, `mtest_enc.c`,
`mtest_enc2.c`–`mtest_enc4.c`, `mtest_remap.c`, `mplay.c`, `chacha8.c`,
`chacha8.h`, `crypto.c`, `cryptoc.c`, `sample-mdb.txt`, `sample-bdb.txt`),
`mdb_dump.1`, `Makefile`, `Doxyfile`, `CHANGES`, `intro.doc`, `upgrading.doc`,
`tooltag` and `libraries/liblmdb/.gitignore`. No build rule names any of them,
none is removed, and all of them are hashed by `UPSTREAM.sha256` so a re-fetch
can be diffed file by file rather than by eye.

Carrying them is not the same as licensing them uniformly, and three of these 34
are worth naming because their terms are not the tree's default:

* `chacha8.c` — public domain, D. J. Bernstein (`chacha8.c:1-5`). Not upstream's
  work, not OLDAP-2.8.
* `chacha8.h` — no copyright, no grant, no attribution; seven lines, three
  `#define`s and a prototype.
* the five man pages — each carries a copyright line and a pointer to the licence
  in a **roff comment**, so it is in the file's bytes and travels with it, but it
  is not the redistribution sentence and does not render: `mdb_copy.1:2-3`,
  `mdb_dump.1:2-3`, `mdb_drop.1:2-3`, `mdb_load.1:2-3`, `mdb_stat.1:2-3` all read
  `.\" Copyright <years> Howard Chu, Symas Corp. All Rights Reserved.` followed by
  `.\" Copying restrictions apply.  See COPYRIGHT/LICENSE.` That is why the 13
  files counted as "not restating the notice" include the man pages while still
  being neither notice-free nor unlicensed.

## Integrity

`UPSTREAM.sha256` holds **43 records**: the SHA-256 of all 42 upstream files in
`libraries/liblmdb/` plus `testdata/corpus.txt`, the independent known-answer
corpus the tests embed, one `<hex>  <path>` line each, in `sha256sum` format.
Check it with:

```
sha256sum -c UPSTREAM.sha256
```

**The per-file record and the archive receipt are different records and answer
different questions.** The archive digest above is one number for the whole
upstream tree as a `git archive` byte stream; it can only be replayed by
re-fetching and re-running `git archive`. This file is 43 numbers for
individual files in *this* working tree; it can be replayed with one command
and no network, and it says which file moved when one does.

The record and the manifest now cover the same set. `.paths` ships the whole
`libraries/liblmdb` directory plus `testdata/corpus.txt`, so all 43 lines have a
file behind them in a materialised package and this is no longer a
repository-root-only check. An earlier state of this fork shipped eight of the
42 upstream files and carried the other 34 for re-sync alone, which made those 34
lines report `No such file or directory` anywhere but this repository; that is
history now, not an expected result.

**Observed.** The check was run at the repository root and reported `OK` for all
42 upstream files and for `testdata/corpus.txt` — **43/43** — with no failure
line: `local://foundation-expansion-lmdb-immutable-source-fixture-integrity-219.log`.
The rest of the gate set, and what each of those receipts does and does not
establish, is in the single gate table in `README.zig.md`.

**Observed again, on a later tree, and still not on this one.** The workspace's
package-regression round of 2026-10-02T12:13–12:18Z checked this record twice —
43/43 in the source and 43/43 inside the package materialised from `.paths`
alone, the two manifests byte-identical at
`70ca3843962fcd8c4e6f103c8072d64625a2d7c61c527d8ec3e4ccddb7f0f6b9` — and its
final contract reports `state: PASSED` at 12:23:25Z
(`local://foundation-cross-test-package-regression.json`,
`local://foundation-cross-test-final-receipt-contract.json`). That round ran
over the post-`CHANGELOG.md` §28 tree and predates this repair wave's
`build.zig` change, so it is the last integrity evidence on record and **not** a
run over the current tree: `sha256sum -c UPSTREAM.sha256` over this wave's tree
is still outstanding. Neither round moved a byte under `libraries/liblmdb/`,
and neither did this wave — which is an argument, not a receipt, and is why the
row is still open.

**How the digests were produced.** Each file was read as raw bytes with Bun's
`Bun.file(path).arrayBuffer()` and hashed with `crypto.createHash("sha256")`
from `node:crypto`, on 2026-10-01 — 689093 bytes over 43 files. No shell
hashing command and no git command produced any of them.

**What the record establishes.** If it validates, the bytes a build compiles,
the bytes the fixture oracle compares against, and every upstream byte this
repository carries are the bytes this record pins, and any later edit to one of
those 43 files fails the check loudly.

**What it does not establish.** It is not a signature, not a Git object id, and
not a re-derivation from commit `6f0a32496a5aadee15a5e5103c479bd3355ae273`: it
is a hash of this working tree. That the tree equals that commit rests on the
import and on the archive digest above, both of which the driver recorded, not
on anything computed while writing this file. Replaying the check against
upstream is the parent's job and needs a re-fetch:

```
git -C <clone> archive --format=tar 6f0a32496a5aadee15a5e5103c479bd3355ae273 | sha256sum
```

The output must read
`7c23a9c5a8e94fa36179ed7de22efd7c3c46eae565c95dc6bcf98e3bb1a3dcd7  -`, and
`sha256sum -c UPSTREAM.sha256` must then report 43 records and no failures.
Nothing in this repository's build may depend on Git being present; `commit`
and `ref` in `build.zig:40-50` are the record of which tree the sources came
from, and only `version` is asserted at configure time.

## Synchronising with a new upstream release

1. `git fetch upstream`, check out the new tag, and read its `lmdb.h`
   `MDB_VERSION_MAJOR`/`MINOR`/`PATCH`. Those three macros, not the tag
   spelling, are the version. If `Makefile`'s `LMDB_VERSION` disagrees with the
   header again, record that here rather than "fixing" upstream's file.
2. Replace `libraries/liblmdb/` wholesale from the new commit. Do not
   hand-patch upstream files to make a build problem go away.
3. Re-derive the core list against the new `Makefile`: `liblmdb.a`'s
   prerequisite line is the authority for what the archive contains, and a new
   or removed object must be a decision in `build.zig`, not a silent change.
4. Re-derive the header closure from the new sources' quoted `#include`s and
   check it against what the build compiles. `.paths` no longer names individual
   files under `libraries/liblmdb/` — it names the directory — so there is no
   manifest entry left to drift; the CI licence job's digest of all 42 files is
   what fails if any of them moved, and a missing or changed file is a failed
   `sha256sum -c UPSTREAM.sha256` rather than a failed closure computation.
5. Re-read `liblmdb/Makefile`'s `LDL`, `IHDRS` and `lmdb.pc` recipe. A new
   platform loader or a new installed header is a change to
   `loaderSystemLibraries` and to `installHeader`.
6. Re-read the lock-backend ladder in `mdb.c`; a new `#elif` arm is a new row
   for `lockBackend` and `supported_check_targets`, or a new entry for
   `refused_check_targets` with the reason printed.
7. Regenerate `UPSTREAM.sha256` over the same path set — all of
   `libraries/liblmdb/` plus `testdata/corpus.txt` — and bump the count and byte
   total in its header if they moved. The record is byte-stable otherwise, and
   nothing this fork writes is in it.
8. Update the archive receipt above, the pin in `build.zig`, `.version` in
   `build.zig.zon`, `version` in `package.nix`, this file, `README.md`,
   `NOTICE.md`, `FORK-LICENSE.md`, `README.zig.md`, and add one numbered
   `CHANGELOG.md` entry. `build.zig` already refuses to configure when the
   manifest and the compiled pin disagree, and `package.nix` fails the build for
   the same reason; what no tool checks is `package.nix` against the manifest,
   so that pairing is on you.
9. Re-read whether the new tag ships a README. If one appears, preserve those
   exact bytes as `README.upstream.md` with its digest in this file, and say which
   upstream path they came from. If it still does not, leave the absence recorded
   in "What this fork is" and do **not** let the fork's own `README.md` be
   described as an upstream file.
10. Re-read the licence-bearing headers of the new tree and update `NOTICE.md`'s
   per-path table. Do not assume the terms are the ones this release carries:
   `CHANGES:9` records ITS#10540 "cleanup outdated license notices" **in this
   very release**, so the set of notices upstream carries is one upstream is
   actively editing. A new tag can add, remove or re-scope a retained third-party
   notice, and the way to find out is to read the headers, not to carry this
   document's table forward.

## See also

* `README.md` — this fork's README: current native-source deviations, current
  native-build deviations with their dated history, the build/run/test matrix,
  and consumption. **Not an upstream file**: upstream ships no README at this pin.
* `NOTICE.md` — the per-path legal record: the OLDAP-2.8 terms and how they are
  met, **the three further terms the tree retains** with their paths and lines,
  the **complete per-file inventory of all 42 upstream files**, which files the build
  compiles versus only carries, what an installed output installs under which term,
  where the licence text and copyright notice actually live, and every file this
  fork adds.
* `FORK-LICENSE.md` — the grant for every file this fork writes: its authority,
  its SPDX identifier, the full file list, what it does not reach, and where
  licence material is installed in each delivery path.
* `README.zig.md` — how to build, import and call the package, with the full
  operation, lifetime, error, flag and bounds tables, and the **single gate
  table** every observed result and its receipt are recorded in.
* `CHANGELOG.md` — numbered fork-only divergences, each with the gate it rests
  on and a link to the receipt.
* `FORK-NOTES.md` — the problems met while doing this, and what was decided,
  in condition/symptom/fix/target-bound form.
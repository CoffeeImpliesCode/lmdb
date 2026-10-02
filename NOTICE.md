# NOTICE

## Upstream work

LMDB, the Lightning Memory-Mapped Database, is the work of Howard Chu and Symas
Corp. and upstream's own code is distributed under the OpenLDAP Public License,
Version 2.8. That is **not** the only term in the tree: upstream retained
third-party notices in two of its own files, and one shipped file is not
upstream's work at all. Every one of them is itemised by path and line below,
under "OLDAP-2.8 is not the only term in this tree". The
repository this fork is built from is `https://github.com/LMDB/lmdb.git` at tag
`LMDB_1.0.1`, commit `6f0a32496a5aadee15a5e5103c479bd3355ae273`; the pin, the
version read out of `libraries/liblmdb/lmdb.h`, and where each of those came
from are in [`UPSTREAM.md`](UPSTREAM.md).

Two files under `libraries/liblmdb/` carry the licence record itself, and all 42
files of that directory travel with the package:

* `libraries/liblmdb/LICENSE:1-2` — "The OpenLDAP Public License / Version 2.8,
  17 August 2003", followed by the three conditions of redistribution and the
  warranty disclaimer, verbatim and unedited.
* `libraries/liblmdb/COPYRIGHT:1` — "Copyright 2011-2021 Howard Chu, Symas
  Corp." — and `COPYRIGHT:5-6`, which is what names the grant: redistribution
  "are permitted only as authorized by the OpenLDAP Public License".

The same sentence is restated in the header comment of 29 of the 42 files under
`libraries/liblmdb/`, so a reader of the code finds the terms where the code is.
The six files this package **compiles or installs** are all among those 29. The
CI licence job is the digest itself now — `sha256sum -c UPSTREAM.sha256`, all 43
records — rather than a computed closure over a written-out list: a digest of
the file that carries a notice cannot be satisfied by a different file asserting
that the notice is there, which is the stronger form of the same check.

### OLDAP-2.8 is not the only term in this tree

The paragraph above counts files that restate the **OpenLDAP** sentence. It does
not say that OLDAP-2.8 is the only licence present, and it is not. Three further
terms sit in `libraries/liblmdb/`, each in the file that names it. Two of the
three are inside the compiled core.

The whole inventory, read out of the carried bytes:

| Term | Files | Where it is written |
|---|---|---|
| **OLDAP-2.8**, Howard Chu / Symas Corp. | 29 of 42, enumerated below | the redistribution sentence, and the licence text itself in `LICENSE` and `COPYRIGHT` |
| **ISC-style**, Martin Hedenfalk, btree.c-derived | `libraries/liblmdb/lmdb.h`, `libraries/liblmdb/mdb.c` | `lmdb.h:151-166` and `mdb.c:19-33`, each closing at the `*/` on `lmdb.h:167` / `mdb.c:34` |
| **Public domain**, D. J. Bernstein | `libraries/liblmdb/chacha8.c` | `chacha8.c:1-5` |
| **Public domain**, Landon Curt Noll, FNV-1a | `libraries/liblmdb/mdb.c`, conditionally | `mdb.c:5846-5872`, inside `#ifdef MDB_USE_HASH` at `mdb.c:5845` |
| **No notice at all** | `libraries/liblmdb/chacha8.h` | the whole file is 7 lines; it carries no copyright, no grant and no attribution |

**The 29, by name.** `COPYRIGHT`, `crypto.c`, `cryptoc.c`, `intro.doc`,
`lmdb.h`, `mdb.c`, `mdb_copy.c`, `mdb_drop.c`, `mdb_dump.c`, `mdb_load.c`,
`mdb_stat.c`, `midl.c`, `midl.h`, `module.c`, `mplay.c`, `mtest.c`, `mtest2.c`,
`mtest3.c`, `mtest4.c`, `mtest5.c`, `mtest6.c`, `mtest_enc.c`, `mtest_enc2.c`,
`mtest_enc3.c`, `mtest_enc4.c`, `mtest_remap.c`, `sample-bdb.txt`,
`sample-mdb.txt`, `upgrading.doc`. Counted by the presence of the string
"authorized by the OpenLDAP" in each file, which is the sentence that names the
grant; the 13 that do not contain it are accounted for in "The 13 files that do not
restate it" below, and 29 + 13 = 42.

**Two of the 29 name a second copyright holder.** `midl.c:6-7` and `midl.h:14-15`
read "Copyright 2000-2026 The OpenLDAP Foundation." followed by "Portions
Copyright 2001-2026 Howard Chu, Symas Corp.", under the same OLDAP-2.8 sentence
(`midl.c:11`, `midl.h:19`). Both files carry the identical header apart from the
`@file`/`@brief` lines. That is one licence with two holders named on it, not a
second licence, and it is recorded because a binary redistribution of the library
reproduces `midl.c`'s notice in object form through the archive.

### The btree.c derivation, in the two files this package compiles

This is the material finding, because it is not only in files this package
carries but in the engine and the public header. `lmdb.h:152` says "This code is
derived from btree.c written by Martin Hedenfalk." and `mdb.c:19` says the same,
and each is followed by `Copyright (c) 2009, 2010 Martin Hedenfalk
<martin@bzero.se>` (`lmdb.h:154`, `mdb.c:21`) and by the grant, verbatim at
`lmdb.h:156-158` and `mdb.c:23-25`:

> Permission to use, copy, modify, and distribute this software for any purpose
> with or without fee is hereby granted, provided that the above copyright notice
> and this permission notice appear in all copies.

followed by the warranty disclaimer at `lmdb.h:160-166` and `mdb.c:27-33`. That
grant carries its own condition — "the above copyright notice and this permission
notice appear in all copies" — which is satisfied the same way OLDAP condition 1
is: the notice is inside the shipped source and is covered by `UPSTREAM.sha256`.
The two grants coexist on one file rather than competing; nothing in either text
asks to be the sole grant, and this fork reads them as cumulative, which is what
keeping both notices byte-identical achieves.

### The FNV-1a notice is conditional, and which targets compile it

`mdb.c:5845` opens `#ifdef MDB_USE_HASH`. Inside it, `mdb.c:5846-5872` is the
notice: `@(#) $Id: hash_64a.c,v 5.1 2009/06/30 09:01:38 chongo Exp $`, "Please do
not copyright this code. This code is in the public domain.", Landon Curt Noll's
disclaimer, and his attribution. `mdb_hash()` follows at `mdb.c:5874`.

`MDB_USE_HASH` is defined in exactly two places in `mdb.c`, and whether this
package turns either on is a per-target fact decided by the fork's own
`build.zig`:

| Target | How `MDB_USE_HASH` is reached | FNV block compiled |
|---|---|---|
| `aarch64-macos-none` | `build.zig:205-207` defines `MDB_USE_POSIX_SEM=1`, and `mdb.c:210-212` turns that into `# define MDB_USE_HASH 1` | yes |
| `x86_64-windows-gnu` | `mdb.c:378-379`, `#ifdef _WIN32` / `#define MDB_USE_HASH 1` | yes |
| `x86_64-`, `aarch64-`, `riscv64-linux-gnu` | `build.zig:185-188` defines only `MDB_USE_POSIX_MUTEX` and `MDB_USE_ROBUST`; `MDB_USE_POSIX_SEM` stays undefined and `_WIN32` is not defined | no |
| `wasm32-wasi` | **not built** — `refused_check_targets` names it (`build.zig:150-152`) and `refusalFor` returns "there is no shared-lock backend" (`build.zig:309-313`), so `refuseTarget` fails the build with `error.UnsupportedTarget` (`build.zig:370-376`). **No binary and therefore no compiled terms.** The notice is still in the source that ships | n/a — no binary |

**What is read and what is inferred in that table.** The `build.zig` citations are
`SOURCE-CONFIRMED` — those are the macro lists the build actually passes, and the
WASI row is a refusal, not a configuration. The Windows row additionally assumes
that compiling `mdb.c` for a Windows target defines `_WIN32`, which is the
target's own convention and is what `build.zig:209-213` reasons from when it
writes "The target itself is the selection" for the `.windows` backend. No gate in
this record compiled `mdb.c` for `x86_64-windows-gnu` and inspected the
preprocessor output, so that row is an inference from the target definition and
from `mdb.c:378-379`, not an observed preprocessor result. The macOS and Linux
rows follow from the macro lists alone.

**This conditional is a third term, and it is not what made the old record wrong.**
`mdb.c` carries two terms that are compiled on **every** target that produces a
binary: OLDAP-2.8 from the file header, and the Hedenfalk grant from
`mdb.c:19-33`. Both are in the core, so a record that said only "OLDAP-2.8" was
wrong on **all five** supported targets, not on some of them. The FNV-1a
public-domain notice is an **additional** term on top of those two, and it is the
only one whose reach varies:

* `aarch64-macos-none` and `x86_64-windows-gnu` — three compiled terms.
* `x86_64-`, `aarch64-` and `riscv64-linux-gnu` — two compiled terms, both in the
  core. These are **not** "covered by OLDAP-2.8 alone"; they still carry the
  Hedenfalk grant.
* `wasm32-wasi` — no binary at all. The refusal is a result this build reports,
  not a target it silently drops (`build.zig:140-144`), so no compiled terms apply
  and none are claimed. The notices remain textual in the source that ships,
  because they are inside the source either way.

The notice text is present in the shipped file for every target regardless, since
the `#ifdef` is in the file. What varies is whether the FNV-1a **code** is part of
the archive, and the honest way to state that is per target, as above.

### `crypto.c` mentions libsodium; that is a dependency, not a grant

`crypto.c:15` and `cryptoc.c:15` both `#include <sodium.h>`, and
`crypto.c:19-21` / `cryptoc.c:19-22` are macros over
`crypto_aead_chacha20poly1305_ietf_*`. **No libsodium source is vendored in this
repository and this package neither compiles nor links any of these two files**,
so no libsodium licence text is owed by this distribution and none is invented
here. Upstream's own rule for the dependency is `Makefile:124`,
`$(CC) -shared $(CFLAGS) -o $@ $^ -lsodium`, under the `crypto.lm: crypto.c` target
at `Makefile:123` — that is, a link flag on the loadable module target and nowhere
else. `-lsodium` appears exactly once in that Makefile. This fork's `build.zig`
names neither `crypto.c` nor `cryptoc.c` and passes no sodium flag, so the
dependency is not part of this package at all. What the two files **are** is
OLDAP-2.8, Howard Chu: their own headers (`crypto.c:3-11`, `cryptoc.c:3-11`) say so
and grant nothing further.

### `chacha8.h` carries no notice, and this record does not supply one

`libraries/liblmdb/chacha8.h` is seven lines: two `#include`s, three `#define`s and
one prototype. It has **no copyright line, no licence grant and no attribution in
its own bytes.** That is the whole of what is known about it from the file itself,
and it is stated that way deliberately.

Its companion `chacha8.c` does carry a notice — `chacha-merged.c version 20080118`,
`D. J. Bernstein`, `Public domain.` (`chacha8.c:1-5`) — and the D. J. Bernstein
public-domain statement is recorded **for `chacha8.c` only**. This record does not
extend it to `chacha8.h`. `chacha8.c` says nothing about `chacha8.h`; the two are
separate files with separate bytes, and inferring a term for the header from the
source file that includes it would be this fork assigning a grant its own author
never wrote. **Assigning one file's terms to another by association is a legal
interpretation, not a reading, and it is not made here.** The earlier wording of
this section said the DJB dedication "covers the pair in substance"; that has been
removed for that reason.

Both files are carried byte-identical and neither is compiled by this package, so
the practical consequence is small — but the record's job is to be right when it is
small. A reader who wants to know what governs `chacha8.h` should be told the file
does not say, and that deciding otherwise is upstream's call, not this fork's.

### The 13 files that do not restate it, and why that is not a gap

| Files | Why |
|---|---|
| `libraries/liblmdb/LICENSE` | It is the licence text itself. It **is** in `.paths`, and it must be: OLDAP-2.8 condition 3 asks for a verbatim copy of it |
| `Makefile`, `Doxyfile`, `CHANGES`, `tooltag`, `.gitignore` | Upstream's build, documentation, release and VCS tooling. **All five ship** like everything else here — `.paths` names the whole directory — so "tooling" describes what a compiler would consume if it consumed them, not whether a dependent receives them. This build compiles none of them: no rule in `build.zig` reads the `Makefile`, the `Doxyfile` or `tooltag`, and `CHANGES` and `.gitignore` are not C at all |
| `mdb_copy.1`, `mdb_dump.1`, `mdb_drop.1`, `mdb_load.1`, `mdb_stat.1` | roff man pages, not source — but **not notice-free**. Each carries a copyright line and a licence pointer inside a roff comment (`mdb_copy.1:2-3`, `mdb_dump.1:2-3`, `mdb_drop.1:2-3`, `mdb_load.1:2-3`, `mdb_stat.1:2-3`): `.\" Copyright <years> Howard Chu, Symas Corp. All Rights Reserved.` and `.\" Copying restrictions apply.  See COPYRIGHT/LICENSE.` They are counted here because they do not restate the **redistribution sentence**, not because they carry no terms |
| `chacha8.c` | **Not a gap, and not OLDAP-2.8.** It is public-domain D. J. Bernstein code (`chacha8.c:1-5`), not upstream's OLDAP work, so it has no OLDAP sentence to restate. See "OLDAP-2.8 is not the only term in this tree" above |
| `chacha8.h` | Carries no notice of any kind in its own bytes, so there is nothing to restate and no grant to name. Its companion `chacha8.c` carries the DJB public-domain statement **for that file**; this record does not extend it to the header. See "`chacha8.h` carries no notice" above |

All 42 travel with a dependent now, `.paths` naming the whole directory. That
matters for one of them above all — `LICENSE` is the condition-3 verbatim copy
and is now there whether or not anyone remembers to add it — but the twelve that
restate nothing travel too: they are part of upstream's release, and shipping a
directory with holes in it is a re-sync bug waiting to happen.
`COPYRIGHT` is not among the 13 because it restates the sentence at
`COPYRIGHT:5-6`, which is where the grant is named. See "Integrity" in
`UPSTREAM.md` for the digest that covers all of them.

### An upstream disagreement between two copyright lines, neither corrected here

`libraries/liblmdb/lmdb.h:141` says:

```
 *       @copyright Copyright 2011-2026 Howard Chu, Symas Corp. All rights reserved.
```

while `libraries/liblmdb/COPYRIGHT:1` says "Copyright 2011-2021 Howard Chu, Symas
Corp.". Two upstream files, two years, one upstream work. Both are upstream's
bytes, both ship, and this fork edits neither and picks neither: the two are
recorded here so that a future re-sync does not mistake the newer header line
for a change introduced here. `lmdb.h` is the header `zig build` installs
(`build.zig:748-756`), so a binary-form redistribution of this package carries
the 2011-2026 line in the installed header and the 2011-2021 line in the
`COPYRIGHT` it ships beside it. That is upstream's arrangement, faithfully
carried.

## The grant, and how this fork meets it

OLDAP-2.8 is a permissive licence with three conditions. They are quoted from
the shipped text so that the obligations below can be checked against the file
rather than against this paragraph.

**1.** "Redistributions in source form must retain copyright statements and
notices," (`LICENSE:8-9`).
**2.** "Redistributions in binary form must reproduce applicable copyright
statements and notices, this list of conditions, and the following disclaimer in
the documentation and/or other materials provided with the distribution"
(`LICENSE:11-14`).
**3.** "Redistributions must contain a verbatim copy of this document."
(`LICENSE:16`)

What this package does about each:

* **Condition 1.** No file under `libraries/liblmdb/` is modified. That is
  checkable from the bytes rather than asserted here: `UPSTREAM.sha256` holds the
  SHA-256 of all 42 of them, and the check has been run — **43 of 43 records
  `OK`**, every upstream file and the one independent fixture
  (`local://foundation-expansion-lmdb-immutable-source-fixture-integrity-219.log`)
  — so upstream's notices are intact by observation. The notices are also in the
  sources themselves, in all six of the files the build compiles or installs.
  Those six carry more than the OLDAP sentence: `lmdb.h` and `mdb.c` also carry
  the Hedenfalk grant at `lmdb.h:151-166` and `mdb.c:19-33`, and `mdb.c` carries
  the FNV-1a public-domain notice at `mdb.c:5846-5872`. Condition 1 is therefore
  retaining three distinct notices in the compiled core, not one.
* **Condition 2.** The distribution carries them: `.paths` ships
  `libraries/liblmdb/LICENSE` and `libraries/liblmdb/COPYRIGHT`, and the
  installed `lmdb.h` restates the copyright line and the redistribution sentence
  and the Hedenfalk copyright and
  permission notice in its own header (`lmdb.h:141-146` and `lmdb.h:151-166`).
  Condition 2 asks for "applicable copyright statements and notices", and those
  two ranges are the applicable ones in the one header the prefix receives. One
  honest limit is worth naming.
  `zig build install` writes `liblmdb.a` and `lmdb.h` into `zig-out/` and copies
  neither legal file there (`build.zig:748-756`), so **a downstream that ships
  only `zig-out/` and nothing else has shipped a binary form without the
  accompanying conditions text.** Condition 2 asks for it "in the documentation
  and/or other materials provided with the distribution", and a downstream
  shipping the package source has them; one shipping the install tree alone has
  to add the two files itself. The fix — an `installHeader`-shaped step that
  copies `LICENSE` and `COPYRIGHT` into the prefix — belongs to whoever owns
  `build.zig`, not to this record. It is named here rather than left for
  someone to find.
* **Condition 3.** `libraries/liblmdb/LICENSE` is in `.paths`, verbatim, 2214
  bytes, unedited, and is hashed in `UPSTREAM.sha256`.

OLDAP-2.8 has **no** patent grant and therefore no patent-grant termination
clause, and it requires **no** `NOTICE` file, no statement of changed files and
no modified-sources marking — those are Zlib and Apache-2.0 obligations, not
this licence's. This file is the per-file record AGENTS §8 asks every fork to
keep; it is **not** a licence artefact and satisfying it is not a condition of
the grant. That is stated so its absence from `.paths` is not read as an
omission.

### No sublicensing is invented anywhere

Upstream's own grant on its own code is OLDAP-2.8, and this package does not
relicense it, does not offer it under a second grant, does not assert that the
Zig facade is a separate work of the OpenLDAP Foundation, and does not claim any
licence over upstream's name or marks. `COPYRIGHT:12` and `LICENSE:43` both note
that "OpenLDAP is a registered trademark of the OpenLDAP Foundation", and this
package uses the name only to identify whose work it is.

The earlier wording of this section said the grant on the C was "OLDAP-2.8 and
nothing else". **That was wrong**, and it is recorded here rather than quietly
replaced: the retained tree carries three further terms, itemised with their
paths and lines under "OLDAP-2.8 is not the only term in this tree". Two are
upstream's own retentions of third-party terms — the Martin Hedenfalk btree.c
grant in `lmdb.h` and `mdb.c`, and the public-domain FNV-1a notice in `mdb.c`
— and one is a file that is not upstream's work at all, the public-domain
`chacha8.c`. The corrected statement is that OLDAP-2.8 is the licence on
upstream's own contributions and that the tree additionally carries those
upstream-attributed terms unchanged.

What has not changed, and is the point of the correction: **this fork adds no
grant of its own over any upstream byte, and none is read into these files that
upstream does not state.** The Hedenfalk grant and the public-domain dedications
are upstream's retentions, reproduced here because `libraries/liblmdb/` is
byte-identical to the pin; this record names them so they are not mistaken for
absent, and it does not extend, re-scope or combine them.

The fork's own files — `build.zig`, `build.zig.zon`, `translate.h`,
`zig/root.zig`, `tests.zig`, `smoke.zig`, `cross-test.profile.sh`,
`testdata/interop.zig`, `consumer/`, `.github/workflows/verify.yml`, this
document set and the fixture — carry no licence statement of their own in this
repository, and this record does not invent one for them. OLDAP-2.8 imposes no
condition that they have one. This
repository is private and unpublished; the moment it is published the question
of a licence for the fork's own files becomes the owner's decision, and it is
recorded here as **PENDING-VERIFICATION** rather than answered.

## What this fork changed

**Nothing under `libraries/liblmdb/` is modified, added or removed.** All 42
files of that directory are upstream's, carried whole; `UPSTREAM.sha256` covers
every one of them. Every other file in the package is a file this fork wrote:

| Path | What it is |
|---|---|
| `build.zig` | the build graph: the three-unit core, the `translate.h` translation, the `lmdb` module, the six-target `check` matrix, `interop`, `consumer` |
| `build.zig.zon` | the package manifest, `.version = "1.0.1"`, and the 16-entry `.paths` that ships the whole `libraries/liblmdb` directory |
| `translate.h` | the single translation unit handed to `addTranslateC`; its whole content is `#include <lmdb.h>` |
| `zig/root.zig` | the Zig facade over the translated `lmdb.h` |
| `tests.zig` | the behavioural tests — 25 of them |
| `smoke.zig` | the deterministic smoke program |
| `cross-test.profile.sh` | the settings-only `cross-test` profile this package is measured through: it fixes the build step to `test` and deliberately names no target, no runner and no host path, so the whole published platform matrix stays whole and a cell with no detected runner is reported as build-only. It is Bash that `cross-test` sources, not documentation, and it is in `.paths` because a dependent receives the same gate the tree was measured with |
| `testdata/corpus.txt` | the independent known-answer corpus — see below |
| `testdata/interop.zig` | the reference interoperability program run against upstream's `mdb_dump` |
| `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig`, `consumer/.gitignore` | a separate package that depends on this one by relative path, to prove `dep.module("lmdb")` resolves from outside |
| `.github/workflows/verify.yml` | this repository's own CI, six jobs. LMDB ships no GitHub Actions workflow, so there was no upstream file to retarget |
| `UPSTREAM.md`, `UPSTREAM.sha256`, `NOTICE.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md` | the provenance, licence, usage and divergence set |

Two of those deserve a sentence of their own:

* **`.gitignore` at the package root is a fork file, not an upstream one.** It
  does not restate and does not remove upstream's ignore rules:
  `libraries/liblmdb/.gitignore` is upstream's, is carried unmodified, and **is**
  hashed in `UPSTREAM.sha256`. The root file adds `.zig-cache/`, `zig-out/`,
  `consumer/.zig-cache/` and `consumer/zig-out/`, none of which swallows an
  upstream pattern or a file this fork adds. It is deliberately absent from
  `UPSTREAM.sha256`: it is not byte-identical to anything at the pin.
* **`.github/workflows/verify.yml` is not in `.paths`.** Upstream's own CI, its
  documentation site and its `contrib/` tree are not carried here either; a
  dependent receives the library and the licence, not this repository's
  workflow.

## The independent fixture, and what it is

`testdata/corpus.txt` is not upstream's and not this fork's chemistry — it is
six key/value records of its own, written by hand:

```
Zulu    fourth      alpha   first       alphabet  sixth
beta    second      delta   (empty)     gamma     third
```

`tests.zig` embeds it with `@embedFile` and walks the database against its
`[expect]` block; `testdata/interop.zig` writes it through the facade and
compares the **body of upstream's own `mdb_dump -p`** against it byte for byte.
Nothing in the file was produced by, or copied from, the library under test.
That is what makes it an oracle rather than a snapshot of this fork's own
behaviour.

It is hashed in `UPSTREAM.sha256` — the one non-upstream file in that record —
because a silent edit to it moves every published expectation in the package at
once, which is exactly the edit the integrity record exists to make loud.

Its restriction is part of its provenance and is checked, not assumed:
`interop.zig` refuses any corpus byte that `mdb_dump -p` would escape, so the
plain rendering the comparison uses *is* upstream's rendering for this input.

## The encryption sources below

`libraries/liblmdb/` carries encryption material — `chacha8.c`, `chacha8.h`,
`crypto.c` (the loadable `crypto.lm` module) and `cryptoc.c` — and `module.c`, the
dynamic module loader, is one of the three units this package **compiles into
`liblmdb.a`**. None of it is reachable from this fork's facade, and all of it now
travels: the four cipher files with the rest of the directory, `module.c` because
the library is. Nothing here compiles the cipher files, links them, or names them
in any build rule.

Their terms are **not** uniform, and the difference is the reason they are listed
separately here rather than lumped in with the OLDAP files:

| File | Compiled by this package | Terms, and where they are written |
|---|---|---|
| `module.c` | **yes** — third unit of `liblmdb.a` (`build.zig:76-80`) | OLDAP-2.8, Howard Chu (`module.c:4-12`); also `#include <dlfcn.h>` or `<windows.h>` (`module.c:14-18`), the platform's own loader, not a vendored dependency |
| `chacha8.c` | no | **Public domain, D. J. Bernstein** (`chacha8.c:1-5`). Not upstream's OLDAP work and not a grant from upstream |
| `chacha8.h` | no | **No notice of any kind.** See "`chacha8.h` carries no notice" above |
| `crypto.c` | no | OLDAP-2.8, Howard Chu (`crypto.c:3-11`); `#include <sodium.h>` (`crypto.c:15`) is a dependency on a library that is **not** vendored here and grants nothing |
| `cryptoc.c` | no | OLDAP-2.8, Howard Chu (`cryptoc.c:3-11`); same `<sodium.h>` dependency at `cryptoc.c:15`, same answer |

So one file of the five is compiled and is OLDAP-2.8; two are OLDAP-2.8 and are
merely carried; one is third-party public domain; one carries nothing at all. No
build rule in this repository reaches any of the four uncompiled ones, so none of
their terms is discharged or owed by what this package builds — they are recorded
because they ship.

`module.c` being the exception is worth being explicit about: it is compiled, so
its OLDAP-2.8 notice is a live obligation on the shipped `liblmdb.a`, and it is
the reason OLDAP condition 1 covers three notices in the core rather than two.

That is recorded here so a reader is not surprised by a `dlopen` in a database
library. Two honest statements about it:

1. **The facade exposes no crypto.** `mdb_modload`, `mdb_modsetup` and
   `mdb_modunload` are reachable only through `pub const c`, the unmodified
   translated header. This package adds no key material, no random source, no
   cipher and no constant-time comparison.
2. **No cryptographic claim is made.** LMDB's encryption is upstream's, it is
   reached only by a caller who deliberately loads a module, and nothing here
   has been assessed for side-channel resistance, key derivation or misuse.
   `module.c` is in the archive because `liblmdb/Makefile:87-88` puts it there
   and `mdb_dump.c:270`, `:275` and `:364` name its three entry points
   unconditionally; the reasoning is in `UPSTREAM.md` and `CHANGELOG.md`.

For completeness, upstream itself compiles `chacha8.c` — but into a **test
binary**, not the library: `Makefile:113`, `mtest_enc: mtest_enc.o chacha8.o
liblmdb.a`. `crypto.c` is built into the loadable `crypto.lm` at `Makefile:123-124`,
and `cryptoc.c` is named by no rule in that Makefile at all. Neither of those
upstream rules is reproduced here; what this package does instead is name its
three core units one by one (`build.zig:76-80`) and never name these four.

## See also

* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the three translation units, the
  header closure, the loader dependency, and what the integrity record does and
  does not establish.
* [`UPSTREAM.sha256`](UPSTREAM.sha256) — the integrity record itself.
* [`README.zig.md`](README.zig.md) — how to build, import and call the package,
  with the operation, lifetime, error, flag and bounds tables and the exact gate
  commands.
* [`CHANGELOG.md`](CHANGELOG.md) — numbered fork-only divergences, each with its
  receipt.
* [`FORK-NOTES.md`](FORK-NOTES.md) — the decisions, their reasons, and the
  lessons in condition/symptom/fix/target-bound form.
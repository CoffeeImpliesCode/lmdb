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
Every file this package **compiles or installs** is among those 29 — the three
core units, both headers, the five tools and the two legal files — so nothing that
reaches a consumer is one of the thirteen that restate nothing. The
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

### The complete per-file inventory: all 42 files, every one of them

The two lists above answer two questions well — which files restate the OpenLDAP
sentence, and why the others do not — but neither of them is a per-file record, so
neither can be audited without re-reading every header. This is that record. It
covers **all 42 files under `libraries/liblmdb/`**, each named exactly once, with the
term that governs it, where that term is written in that file's own bytes, what this
package does with the file, and what an installed output carries.

It is **35 rows for 42 files**, and the arithmetic is worth giving rather than
rounding away. Thirty-three rows name one file each — the three core units
(`mdb.c`, `midl.c`, `module.c`), both headers, the five tool sources, the two legal
files, the five man pages, upstream's two prose files, the four files whose terms
are not OLDAP-2.8 or are absent (`crypto.c`, `cryptoc.c`, `chacha8.c`,
`chacha8.h`), `mplay.c`, `mtest_enc.c`, `mtest_remap.c` and the two sample
databases. Two rows name a group that shares one term verbatim: `mtest.c` …
`mtest6.c` (six files) and `mtest_enc2.c`, `mtest_enc3.c`, `mtest_enc4.c` (three).
33 + 1 + 1 = 35 rows over 33 + 6 + 3 = **42 files**, and each of the 29 that
restate the redistribution sentence and each of the 13 that do not appears here
exactly once.

Four columns matter and are kept apart on purpose. **Term** is what the file says,
or — where it says nothing — that it says nothing. **Where** is the line range in
that file, never another file's. **Role** is what the build does with it. **In
the Nix output** says whether an installed output carries the file, and names who
writes it there: the library, the header, the link metadata, the five tools, the
five man pages and upstream's two legal files all come out of `build.zig`'s own
install step. `package.nix` installs nothing of its own, so every "yes" in that
column has exactly one writer.

| File | Term | Where it is written | Role | In the Nix output |
|---|---|---|---|---|
| `LICENSE` | OLDAP-2.8, the licence text itself | `LICENSE:1-2` title, `:8-9` / `:11-14` / `:16` the three conditions; `:45` the OpenLDAP Foundation's own copyright paragraph | carried | **yes** — `$out/share/lmdb/LICENSE`, from `build.zig`; condition 3 requires this copy to travel |
| `COPYRIGHT` | OLDAP-2.8, Howard Chu / Symas Corp. | `COPYRIGHT:1` copyright, `:5-6` the sentence that names the grant, `:12` the trademark notice | carried | **yes** — `$out/share/lmdb/COPYRIGHT`, from `build.zig`; condition 2's notice |
| `lmdb.h` | OLDAP-2.8 **and** ISC-style, Martin Hedenfalk | OLDAP `lmdb.h:143-145`; Hedenfalk `lmdb.h:151-166`, closing `*/` at `:167`; copyright `:141` | **installed** public header, and the header `addTranslateC` translates | **yes** — `$out/include/lmdb.h` |
| `mdb.c` | OLDAP-2.8 **and** ISC-style **and**, conditionally, public domain (FNV-1a) | OLDAP `mdb.c:10-13`; Hedenfalk `mdb.c:19-33`, closing `*/` at `:34`; FNV-1a `mdb.c:5846-5872`, **inside** `#ifdef MDB_USE_HASH` at `mdb.c:5845`; copyright `:8` | **compiled** — unit 1 of 3 | into the installed library or shared object |
| `midl.c` | OLDAP-2.8, **two** copyright holders | `midl.c:6` The OpenLDAP Foundation, `:7` "Portions … Howard Chu, Symas Corp.", sentence `:10-12` | **compiled** — unit 2 of 3 | into the installed library or shared object |
| `midl.h` | OLDAP-2.8, **two** copyright holders | `midl.h:14` and `:15`, sentence `:18-20` | **compiled** dependency of units 1 and 2; **not installed** (`IHDRS = lmdb.h`, `Makefile:49`) | no — internal header, and upstream installs only `lmdb.h` |
| `module.c` | OLDAP-2.8, Howard Chu | `module.c:4-13` | **compiled** — unit 3 of 3; the dynamic crypto-module loader | into the installed library or shared object, and the reason `lmdb.pc` carries `Libs.private` in the static variant |
| `mdb_dump.c` | OLDAP-2.8 | `mdb_dump.c:3-8` | compiled **twice over**: once for the `interop` gate, and once as upstream's installed dump tool (`IPROGS`, `Makefile:52`), each linked against this package's own artifact | **yes** — `$out/bin/mdb_dump`, from `build.zig` |
| `mdb_stat.c` | OLDAP-2.8 | `mdb_stat.c:3-8` | upstream's tool (`Makefile:96-97`), compiled and installed | **yes** — `$out/bin/mdb_stat`, from `build.zig` |
| `mdb_copy.c` | OLDAP-2.8 | `mdb_copy.c:3-8` | upstream's tool (`Makefile:98-99`), compiled and installed | **yes** — `$out/bin/mdb_copy`, from `build.zig` |
| `mdb_load.c` | OLDAP-2.8 | `mdb_load.c:3-8` | upstream's tool (`Makefile:100-101`), compiled and installed | **yes** — `$out/bin/mdb_load`, from `build.zig` |
| `mdb_drop.c` | OLDAP-2.8 — with the year range `2016-2021` exactly as written | `mdb_drop.c:3` | upstream's tool (`Makefile:102-103`), compiled and installed | **yes** — `$out/bin/mdb_drop`, from `build.zig` |
| `mdb_dump.1` | copyright line and a licence **pointer** inside a roff comment; not the redistribution sentence and it does not render | `mdb_dump.1:2` "Copyright 2014-2026 …", `:3` "Copying restrictions apply.  See COPYRIGHT/LICENSE." | carried | **yes** — `$out/share/man/man1/mdb_dump.1`, from `build.zig` |
| `mdb_stat.1` | as above, years `2012-2026` | `mdb_stat.1:2-3` | carried | **yes** — `$out/share/man/man1/mdb_stat.1` |
| `mdb_copy.1` | as above, years `2012-2026` | `mdb_copy.1:2-3` | carried | **yes** — `$out/share/man/man1/mdb_copy.1` |
| `mdb_load.1` | as above, years `2014-2026` | `mdb_load.1:2-3` | carried | **yes** — `$out/share/man/man1/mdb_load.1` |
| `mdb_drop.1` | as above, years `2014-2026` | `mdb_drop.1:2-3` | carried | **yes** — `$out/share/man/man1/mdb_drop.1` |
| `intro.doc` | OLDAP-2.8 | `intro.doc:2` copyright, `:4-6` the sentence | carried; upstream's prose introduction. Neither upstream's own `install` target nor this build's copies it (`Makefile:65-78`) | no — travels in `.paths` only |
| `upgrading.doc` | OLDAP-2.8 | `upgrading.doc:2` copyright, `:4-6` the sentence | carried; upstream's upgrade notes, likewise not installed | no — travels in `.paths` only |
| `crypto.c` | OLDAP-2.8; its `#include <sodium.h>` is a dependency mention, not a grant | `crypto.c:3-12`; dependency at `crypto.c:15` | carried; the payload of the loadable `crypto.lm` (`Makefile:123-124`) | no |
| `cryptoc.c` | OLDAP-2.8; same `<sodium.h>` mention | `cryptoc.c:3-12`; dependency at `cryptoc.c:15` | carried; **named by no rule in upstream's Makefile at all** | no |
| `chacha8.c` | **public domain, D. J. Bernstein** — not OLDAP-2.8 | `chacha8.c:1-5` | carried; upstream links it only into the **test** binary `mtest_enc` (`Makefile:113`) | no |
| `chacha8.h` | **no notice of any kind.** No copyright, no grant, no attribution, in seven lines | the whole file | carried; compiled by nothing here or in `liblmdb.a` | no |
| `mplay.c` | OLDAP-2.8 | `mplay.c:3-8` | carried; upstream's test program (`Makefile:121`) | no |
| `mtest.c`, `mtest2.c`, `mtest3.c`, `mtest4.c`, `mtest5.c`, `mtest6.c` | OLDAP-2.8 in each | `mtest.c:3-8`; `mtest2.c:3-8`; `mtest3.c:3-8`; `mtest4.c:3-8`; `mtest5.c:3-8`; `mtest6.c:3-8` | carried; upstream's test programs (`Makefile:106-111`) | no |
| `mtest_enc.c` | OLDAP-2.8 | `mtest_enc.c:3-8` | carried; upstream's encryption test (`Makefile:113`) | no |
| `mtest_enc2.c`, `mtest_enc3.c`, `mtest_enc4.c` | OLDAP-2.8 in each | `mtest_enc2.c:3-8`; `mtest_enc3.c:3-8`; `mtest_enc4.c:3-8` | carried; they **load** `crypto.lm` at run time (`Makefile:114-118`) | no |
| `mtest_remap.c` | OLDAP-2.8 | `mtest_remap.c:3-8` | carried; upstream's remap test (`Makefile:112`) | no |
| `sample-mdb.txt` | OLDAP-2.8 | `sample-mdb.txt:6` copyright, `:8-10` the sentence | carried; upstream's sample environment | no |
| `sample-bdb.txt` | OLDAP-2.8 | `sample-bdb.txt:6` copyright, `:8-10` the sentence | carried; upstream's sample environment, the comparison pair of the previous row | no |
| `Makefile` | **no term in its own bytes.** It is upstream's build definition and is OLDAP material by the tree, not by a notice in it | — | carried; **no rule in `build.zig` reads it** | no |
| `Doxyfile` | **no term in its own bytes** | — | carried; upstream's documentation configuration | no |
| `CHANGES` | **no term in its own bytes** | — | carried; upstream's release notes | no |
| `tooltag` | **no term in its own bytes** | — | carried; upstream's release tooling | no |
| `.gitignore` | **no term in its own bytes** | — | carried **and hashed** in `UPSTREAM.sha256`; upstream's, not the fork root's | no |

Four rows are the ones a single-label record gets wrong, and they are why this
table exists:

* `chacha8.c` is not OLDAP-2.8 at all, and is not upstream's work.
* `chacha8.h` carries nothing. The DJB public-domain statement is recorded for
  `chacha8.c` **only**; inferring it for the header would be this fork assigning
  a grant its own author never wrote.
* `mdb_drop.c:3` carries the year range `2016-2021`, which is not any other file's
  range and is not a year this fork can correct in upstream's bytes. It is
  recorded as read.
* `mdb.c` carries **three** terms, not one, and the third is conditional on
  `MDB_USE_HASH` — so its reach varies per target while the other two do not.

### The tools and the man pages: what an installed output carries, and under which term

Upstream's own `install` target names what a complete LMDB installation is, and
it is a shorter list than "everything in the directory" and a longer one than
"the library":

```
install: $(ILIBS) $(IPROGS) $(IHDRS)          # Makefile:65
ILIBS  = liblmdb.a                             # Makefile:50
IHDRS  = lmdb.h                                # Makefile:49
IPROGS = mdb_stat mdb_copy mdb_dump mdb_load mdb_drop   # Makefile:52
IDOCS  = mdb_stat.1 mdb_copy.1 mdb_dump.1 mdb_load.1 mdb_drop.1   # Makefile:53
```

and it copies them to `$(bindir)`, `$(libdir)`, `$(includedir)` and
`$(mandir)/man1` respectively (`Makefile:66-78`), with the shared library
installed under its `SOFULL` name and two symlinks beside it (`Makefile:72-76`).

`build.zig`'s install step reproduces that set for both variants and `package.nix`
runs it: the library, `lmdb.h`, the generated `lmdb.pc`, upstream's five tools,
their five man pages and upstream's two legal files all come from there, and the
derivation adds nothing of its own. **Every one of those files is OLDAP-2.8**,
with the single exception of the tools' own man pages, which carry a copyright line and a
pointer to `COPYRIGHT`/`LICENSE` in a roff comment rather than the redistribution
sentence. That pointer resolves inside the output, because
`$out/share/lmdb/LICENSE` and `$out/share/lmdb/COPYRIGHT` are the same two files
the pointer names. No public-domain DJB file, no `<sodium.h>`-dependent file and
no upstream test program is installed into an output: none of them is part of a
usable LMDB installation, and the ones that travel in the package source keep
their own terms where they are, in the table above.

One honest limit belongs here. Upstream installs `$(ILIBS)` and `$(ILIBS2)` from
`install:` — both the static archive and the shared library — from a single
invocation (`Makefile:65`, `:71-76`). A Nix variant installs **one** of them,
because `static` and `shared` are separate derivations rather than one output
carrying both. Neither variant is upstream's `install` target reproduced whole,
and no output contains `liblmdb.so.1.0`: the shared variant's file is
`liblmdb.so.1.0.1` with symlinks `liblmdb.so.1` and `liblmdb.so`, which is Zig's
naming for `version = 1.0.1` and not upstream's `SOFULL` (`VEREXT = 1.0`,
`Makefile:33-37`). `README.md` records that as a current native-build deviation.

### `module.c` and the loader dependency in link metadata

`module.c` is the one compiled file whose licence record and whose link
metadata are the same subject, so both are recorded here rather than only in
`UPSTREAM.md`. It is unit 3 of 3 in `liblmdb.a` (`Makefile:87-88`, restated in
`build.zig`'s core-unit list), it is OLDAP-2.8 (`module.c:4-13`), and it calls
the platform's dynamic loader: `dlopen`/`dlsym`/`dlerror`/`dlclose` on POSIX
(`module.c:51-66`, `:77-78`, reached through `<dlfcn.h>` at `:17`) and
`LoadLibrary`/`GetProcAddress`/`FreeLibrary` on Windows (`module.c:33-49`,
`:74-76`, through `<windows.h>` at `:15`). Upstream records the requirement once,
as `LDL = -ldl` (`Makefile:31`), and puts it on the shared link line
(`Makefile:92`) and in the generated pkg-config file (`Makefile:158`).

What that means for the two Nix variants, and it is different in each:

| Variant | The `-ldl` dependency is… | Consequence for a consumer |
|---|---|---|
| `static` | **not** resolved by the archive. It must appear in the consumer's own link line | `lib/pkgconfig/lmdb.pc` records it as `Libs.private`, so `pkg-config --static --libs lmdb` yields it and a plain `pkg-config --libs lmdb` does not |
| `shared` | resolved **inside** the shared object, exactly as upstream's `Makefile:92` does | a consumer links `-llmdb` only; `Libs.private` is empty, because there is nothing left for the consumer to resolve |

On macOS and the other Darwin targets there is no such dependency to record:
Darwin takes the POSIX arm of `module.c` and its `dl*` entry points come from
libSystem, which the C library already is. The generated `lmdb.pc` therefore
carries an empty `Libs.private` there rather than a GNU-ld flag name that does not
apply, which is the same reason upstream leaves `-Wl,-current_version` commented
out (`Makefile:58-59`) and why `-pthread` is deliberately not repeated on Zig's
link line.

**The `.pc` file is generated by `build.zig`, not written by `package.nix` and not
installed from a template.** Upstream writes one at `Makefile:147-158` from
eight `echo` lines, this fork has no `lmdb.pc.in`, and the derivation therefore
does not create or overwrite it. Three rows of upstream's template are answered
differently here and each difference is deliberate: `Version:` states the pinned
`1.0.1` rather than upstream's hardcoded `LMDB_VERSION = 1.0.0` (`Makefile:36`);
the loader and thread flags move from `Libs:` into `Libs.private:` and only in the
static variant, because in the shared variant they are already inside the shared
object and re-adding them is wrong; and the file is made relocatable with
`prefix=${pcfiledir}/../..`, which upstream's version is not — upstream writes a
literal `prefix=$(prefix)` (`Makefile:148`) that a relocated copy would carry into
the wrong place. `README.md` records all three as current native-build deviations.

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
  sources themselves, in every file the build compiles or installs: the three core
  units, both headers, the five tools and the two legal files. Three of those
  carry more than the OLDAP sentence: `lmdb.h` and `mdb.c` also carry
  the Hedenfalk grant at `lmdb.h:151-166` and `mdb.c:19-33`, and `mdb.c` carries
  the FNV-1a public-domain notice at `mdb.c:5846-5872`. Condition 1 is therefore
  retaining three distinct notices in the compiled core, not one.
* **Condition 2.** The distribution carries them: `.paths` ships
  `libraries/liblmdb/LICENSE` and `libraries/liblmdb/COPYRIGHT`, and the
  installed `lmdb.h` restates the copyright line and the redistribution sentence
  and the Hedenfalk copyright and
  permission notice in its own header (`lmdb.h:141-146` and `lmdb.h:151-166`).
  Condition 2 asks for "applicable copyright statements and notices", and those
  two ranges are the applicable ones in the one header the prefix receives. Since
  the fork's own files are now under a grant too (see "The fork's own files are
  under a grant" above), this condition has **two** sets of applicable
  statements — upstream's and this fork's — and both have to reach a binary
  recipient. Three delivery paths, and they are not equally complete:

  | Delivery path | Library + header | Upstream `LICENSE`/`COPYRIGHT` | Fork's `NOTICE.md`/`FORK-LICENSE.md` |
  |---|---|---|---|
  | package source, via `.paths` (a `zig fetch` of this package) | built by the consumer | **yes** — `.paths` names the whole `libraries/liblmdb` directory | **yes** — `.paths` names the document set |
  | Nix output, via `package.nix` | **yes** — `build.zig`'s install step | **yes** — `share/lmdb/LICENSE` and `COPYRIGHT`, from the same bytes | **yes** — `share/lmdb/NOTICE.md` and `FORK-LICENSE.md`, with the rest of this fork's records |
  | `zig build install` on its own, the tree alone | **yes** — `build.zig`'s install step | **yes** — `share/lmdb/LICENSE` and `COPYRIGHT` | **yes** — the same records, written by the same step |

  **Both halves are now met on all three paths, and the gap this section used to
  name is closed.** An earlier state said `zig build install` wrote the library and
  the header and copied neither legal file there. `build.zig`'s install step now
  writes upstream's `LICENSE` and `COPYRIGHT` from the very same bytes under
  `libraries/liblmdb/`, and this fork's own eight records beside them, because
  applying OLDAP-2.8 to the packaging made its notices "applicable copyright
  statements and notices" in their own right. Nothing else writes any of those
  paths: `package.nix` installs nothing of its own. **Every row in this table is
  `PENDING-VERIFICATION` for this wave's tree**: each is a contract read out of
  `build.zig` and `package.nix`, and no gate has observed any install prefix since
  it changed.
* **Condition 3.** `libraries/liblmdb/LICENSE` is in `.paths`, verbatim, 2214
  bytes, unedited, and is hashed in `UPSTREAM.sha256`. It is also installed into
  every Nix output, so the verbatim copy travels with the binary there too.

OLDAP-2.8 has **no** patent grant and therefore no patent-grant termination
clause, and it requires **no** `NOTICE` file, no statement of changed files and
no modified-sources marking — those are Zlib and Apache-2.0 obligations, not
this licence's. This file is the per-file record AGENTS §8 asks every fork to
keep; it is **not** a licence artefact and satisfying it is not a condition of
the grant. That is stated so its absence from `.paths` is not read as an
omission.

### No sublicensing is invented anywhere

Upstream's own grant on its own code is OLDAP-2.8, and this package does not
relicense it, does not offer it under a second, competing grant, does not assert
that the Zig facade is a separate work of the OpenLDAP Foundation, and does not
claim any licence over upstream's name or marks. `COPYRIGHT:12` and `LICENSE:43`
both note that "OpenLDAP is a registered trademark of the OpenLDAP Foundation",
and this package uses the name only to identify whose work it is.

**One clause of this section needed amending when the fork's own files got a
grant, and it is amended here rather than left to be read two ways.** The
fork-authored files are now offered under OLDAP-2.8 as well. That is a grant over
*this fork's* files, not a second grant over *upstream's*, and it changes the
term on nothing upstream wrote. "Does not offer it under a second grant" means
**no upstream file is offered under two terms at once**; the fork's own
additions are a different set of files with their own history, and they were
never covered by upstream's grant in the first place. `FORK-LICENSE.md` states the
boundary in the form this section now uses.

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

### The fork's own files are under a grant, and it is the same term

Earlier revisions of this section said the fork's own files "carry no licence
statement of their own" and recorded the question as **PENDING-VERIFICATION**,
pending an owner decision. **That decision has been made**, and the earlier
wording is superseded by this one and by [`FORK-LICENSE.md`](FORK-LICENSE.md).

The repository owner authorized, for this migration wave, a **per-project licence
for fork-authored additions, matching the project's primary upstream terms where
appropriate** (`AGENTS.md` §8; the wave contract at
`local://foundation-contract-implementation.md` §"Licence authorization"). LMDB's
primary upstream term is OLDAP-2.8, and the term chosen for this fork's own files
is therefore **The OpenLDAP Public License, Version 2.8, 17 August 2003**,
SPDX identifier `OLDAP-2.8`, matching the primary upstream term rather than
inventing a second one. `FORK-LICENSE.md` carries the authorization, the full
file list it covers, what it explicitly does not cover, and the two clauses of
that text which constrain how the names in it may be used.

Three limits on that grant, which are stated here so they are not read the other
way:

* **It does not extend, narrow or re-scope any upstream term.** The ISC-style
  grant, both public-domain notices and `chacha8.h`'s silence keep exactly the
  scope the files themselves give them. Applying OLDAP-2.8 to the packaging
  changes nothing about what Howard Chu, the OpenLDAP Foundation, Martin
  Hedenfalk, Landon Curt Noll or D. J. Bernstein granted.
* **It attributes nothing to an upstream author.** The OpenLDAP Foundation is
  not an author of a single file listed in `FORK-LICENSE.md`, and this grant does
  not say it is — including where the licence text's own warranty paragraph
  names it. That paragraph is reproduced as part of a fixed document; it is a
  disclaimer travelling with a permission, not an authorship statement, and
  `FORK-LICENSE.md` says so in those words. No personal copyright identity is
  invented for the fork's files anywhere in this repository.
* **It is a grant, not a title.** OLDAP-2.8 says "Title to copyright in this
  Software shall at all times remain with copyright holders", and nothing here
  purports to transfer any title in upstream's work.

**One consequence is new and is an obligation this fork now has.** Before this
grant the fork's files carried no copyright statement, so OLDAP-2.8's
condition 2 — "Redistributions in binary form must reproduce applicable
copyright statements and notices, this list of conditions, and the following
disclaimer in the documentation and/or other materials provided with the
distribution" — had nothing of the fork's own to reproduce. It has something
now. All three delivery paths meet it: `build.zig`'s install step writes this
fork's records beside upstream's legal files at `share/lmdb/`, and `.paths`
carries them in a fetched package.

## What this fork changed

**Nothing under `libraries/liblmdb/` is modified, added or removed.** All 42
files of that directory are upstream's, carried whole; `UPSTREAM.sha256` covers
every one of them. Every other file in the package is a file this fork wrote:

| Path | What it is |
|---|---|
| `build.zig` | the build graph: the three-unit core, the `translate.h` translation, the `lmdb` module, the six-target `check` matrix, `interop`, `consumer` |
| `build.zig.zon` | the package manifest, `.version = "1.0.1"`, and the 23-entry `.paths` that ships the whole `libraries/liblmdb` directory alongside this fork's build, facade, consumer, profile, licence and packaging files |
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
| `README.md` | this fork's README: current native-source deviations, current native-build deviations and their dated history, the current build/run/test matrix, and consumption |
| `README.zig.md` | the Zig interface documentation, kept separate from `README.md` |
| `FORK-LICENSE.md` | the grant for every file this fork writes, its authority, its SPDX identifier, and what it does not cover |
| `package.nix` | the standalone source-only derivation, injected `{ lib, stdenv, zig, linkage ? "static" }`, called identically by `flake.nix` and `devenv.nix` |
| `flake.nix` | the pinned-nixpkgs entry points: `packages.<system>.static`, `.shared`, `.default` |
| `devenv.nix` | the canonical development shell: tools, namespaced `lmdb:*` tasks, and lazy `outputs.static` / `outputs.shared` |
| `devenv.yaml` | the pinned devenv `nixpkgs` input |
| `.envrc` | direnv integration for that devenv shell |
| `UPSTREAM.md`, `UPSTREAM.sha256`, `NOTICE.md`, `CHANGELOG.md`, `FORK-NOTES.md` | the provenance, integrity, licence, divergence and decision records |

**There is no `README.upstream.md` in this repository, and there is not
supposed to be one.** Upstream's tree at commit
`6f0a32496a5aadee15a5e5103c479bd3355ae273` carries **no README at any depth**:
the working record for the pin names no primary README, and the 42 files this
fork carries from upstream — all of `libraries/liblmdb/` — contain no file named
`README`, `README.md` or `README.rst`. The driver's byte-verified upstream-README
proof records `"primary_readme": null` for this project for exactly that reason.
`README.md` in this tree is therefore **fork-authored in full**, from the first
line, and it is never described as upstream's or as a copy of anything at the pin.
What upstream does ship in prose is `libraries/liblmdb/intro.doc` and
`libraries/liblmdb/upgrading.doc`, both OLDAP-2.8 (`intro.doc:2-6`,
`upgrading.doc:2-6`), together with the five roff man pages; those three kinds of
file stay at those original paths, unmodified, inside `.paths`, and none of them
is relocated, renamed or copied into the fork's documentation.

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
* [`FORK-LICENSE.md`](FORK-LICENSE.md) — the grant for every file this fork
  writes: its authority, its SPDX identifier, the full list it covers, what it
  does not cover, and where licence material is installed in each delivery path.
* [`README.md`](README.md) — this fork's README: native-source deviations,
  native-build deviations and their dated history, the current build/run/test
  matrix, and consumption.
* [`README.zig.md`](README.zig.md) — the Zig interface documentation, kept
  separate from `README.md`: how to build, import and call the package, with the
  operation, lifetime, error, flag and bounds tables and the exact gate commands.
* [`CHANGELOG.md`](CHANGELOG.md) — numbered fork-only divergences, each with its
  receipt.
* [`FORK-NOTES.md`](FORK-NOTES.md) — the decisions, their reasons, and the
  lessons in condition/symptom/fix/target-bound form.
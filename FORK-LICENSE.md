# FORK-LICENSE.md — the grant for the files this fork writes

What licence covers the code, build files, tests, documentation and packaging this
fork adds, and where every file that is *not* under that grant keeps its own terms.
[`NOTICE.md`](NOTICE.md) is the per-path audit of upstream's 42 files;
[`UPSTREAM.md`](UPSTREAM.md) is the source provenance.

## The authorization

The owner of this SDK authorized, for this migration wave, a **per-project licence
for fork-authored additions, matching the project's primary upstream terms where
appropriate** (`AGENTS.md` §8; the wave contract at
`local://foundation-contract-implementation.md` §"Licence authorization").

It covers fork-authored files only, and it extends no upstream grant. No personal
copyright identity is named here or invented anywhere in this repository, and no
fork-authored file is attributed to any upstream author.

Earlier records said the fork's own files carried no licence statement and recorded
the question as `PENDING-VERIFICATION`. That was the state before the authorization
above. This file supersedes it for the files it lists.

## The chosen grant

| | |
|---|---|
| Grant | The OpenLDAP Public License, Version 2.8, 17 August 2003 |
| SPDX identifier | `OLDAP-2.8` |
| Upstream term it matches | `libraries/liblmdb/LICENSE` — upstream's own text, 2214 bytes, unmodified |
| Files covered | every file under [What this grant covers](#what-this-grant-covers) |
| Files **not** covered | everything else; see [What it does not cover](#what-this-grant-does-not-cover) |

`OLDAP-2.8` is the SPDX short identifier for this licence. The licence itself is the
text in `libraries/liblmdb/LICENSE`, which ships verbatim and is never paraphrased.

### What the text says about this fork

Four clauses bear on a fork that adopts the same term, and all four are read from
the shipped file:

* `LICENSE:23-35` disclaims the software **in the OpenLDAP Foundation's name**.
  The Foundation is not an author of any file listed in this document and this
  grant does not say it is. That paragraph travels as part of a document the fork
  must reproduce verbatim (`LICENSE:16`); a disclaimer accompanying a permission
  is not an authorship statement.
* `LICENSE:37-38` restricts using the authors' and copyright holders' names to
  promote the sale or use of the Software without written permission, and
  `LICENSE:43` / `COPYRIGHT:12` mark **OpenLDAP** as the OpenLDAP Foundation's
  trademark. This repository uses *LMDB*, *OpenLDAP*, *Howard Chu*, *Symas Corp.*,
  *Martin Hedenfalk*, *Landon Curt Noll* and *D. J. Bernstein* only to satisfy
  attribution and to identify whose work each notice is. No mark is claimed.
* `LICENSE:39-41` — "Title to copyright in this Software shall at all times remain
  with copyright holders". Nothing here transfers title in upstream's work; what is
  granted is permission.

### What the grant obliges this fork to do

| Condition | How it is met |
|---|---|
| 1. source redistributions retain copyright statements and notices | `NOTICE.md`, this file, and `SPDX-License-Identifier: OLDAP-2.8` on newly authored files |
| 2. binary redistributions reproduce the applicable notices, the conditions and the disclaimer | `build.zig`'s install step writes upstream's `LICENSE` and `COPYRIGHT` **and this fork's own eight records** to `share/lmdb/`, so both applicable copyright statements reach a binary recipient on every install path |
| 3. redistributions contain a verbatim copy of the licence document | the same `libraries/liblmdb/LICENSE` bytes, in `.paths` and at `share/lmdb/` |

## What this grant covers

Every file below was written for this fork. Nothing in the list is upstream's or a
third party's. A file this fork authors later in this tree is covered without this
table being rewritten, unless `NOTICE.md` names it as something else.

| File | What it is |
|---|---|
| `build.zig`, `build.zig.zon` | build graph and package manifest |
| `translate.h` | the one header `addTranslateC` translates; its content is `#include <lmdb.h>` |
| `zig/root.zig` | the typed Zig facade, and `pub const c` for the whole translated surface |
| `tests.zig`, `smoke.zig` | the behavioural tests and the deterministic smoke program |
| `testdata/corpus.txt`, `testdata/interop.zig` | the independent known-answer corpus and the reference interoperability program |
| `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig`, `consumer/.gitignore` | a separate package that depends on this one by relative path |
| `cross-test.profile.sh` | the settings-only `cross-test` profile |
| `.gitignore` | the package-root ignore file this fork wrote; **distinct from** `libraries/liblmdb/.gitignore`, which is upstream's and is hashed in `UPSTREAM.sha256` |
| `.github/workflows/verify.yml` | this repository's own CI. LMDB ships no GitHub Actions workflow |
| `package.nix` | the derivation: injected `{ lib, stdenv, zig, linkage ? "static" }`, one output, called identically by `flake.nix` and `devenv.nix` |
| `flake.nix` | `packages.<system>.static`, `.shared`, `.default` |
| `devenv.nix`, `devenv.yaml`, `.envrc` | the canonical shell, its pinned input, and direnv integration |
| `README.md` | this fork's README. Fork-authored in full: upstream ships no README at this pin, so there is no `README.upstream.md` |
| `README.zig.md` | the Zig interface documentation, separate from `README.md` |
| `CHANGELOG.md`, `FORK-NOTES.md`, `UPSTREAM.md`, `NOTICE.md`, `FORK-LICENSE.md` | the divergence, decision, provenance, audit and grant records |
| `UPSTREAM.sha256` | 43 per-file digests: upstream's 42 files plus `testdata/corpus.txt` |

## What this grant does not cover

| Material | Its own term | Where it is stated |
|---|---|---|
| upstream's 29 of 42 files that restate the redistribution sentence | OLDAP-2.8, upstream's own grant | `libraries/liblmdb/LICENSE`, `libraries/liblmdb/COPYRIGHT`, and each file's header; per path in [`NOTICE.md`](NOTICE.md) |
| the ISC-style grant retained inside `lmdb.h` and `mdb.c` | Martin Hedenfalk's grant | `lmdb.h:151-166`, `mdb.c:19-33` |
| the public-domain FNV-1a notice in `mdb.c`, conditional on `MDB_USE_HASH` | Landon Curt Noll's dedication | `mdb.c:5846-5872`, with the `#ifdef` at `mdb.c:5845` named separately |
| `libraries/liblmdb/chacha8.c` | public domain, D. J. Bernstein | `chacha8.c:1-5` |
| `libraries/liblmdb/chacha8.h` | **no notice of any kind in its own bytes.** This grant supplies none and does not extend the previous file's dedication to it | the whole file, seven lines |
| upstream's five roff man pages | a copyright line and a licence **pointer** in a roff comment, not the redistribution sentence | `mdb_*.1:2-3`, each |
| `Makefile`, `Doxyfile`, `CHANGES`, `tooltag`, `libraries/liblmdb/.gitignore` | no term in their own bytes; upstream material under the tree's OLDAP-2.8 grant | [`NOTICE.md`](NOTICE.md) |

**No single label overrides those file-specific terms.** The Hedenfalk grant
carries its own condition — that its notice and permission appear in all copies —
and a redistributor of the archive is bound by it whether or not they read this
file.

Two retentions are upstream's own and this fork neither widens nor narrows them:
`crypto.c` and `cryptoc.c` mention `<sodium.h>` (`crypto.c:15`, `cryptoc.c:15`), a
dependency on a library this package neither vendors, compiles nor links, so no
libsodium text is owed here and none is invented; and `midl.c`/`midl.h` name two
copyright holders under one OLDAP-2.8 sentence (`midl.c:6-7`, `midl.h:14-15`).

## Identifier for newly authored files

```
SPDX-License-Identifier: OLDAP-2.8
```

In a C header or a `.c`/`.h` file a `/* … */` comment; in Zig, ZON, Nix, Bash or
YAML a `// …` or `# …` comment on its own line. It points at this record; the
per-file inventory in `NOTICE.md` is the authority for which term covers which
file.

**Never write it into a file under `libraries/liblmdb/`.** That directory is
upstream's, byte for byte, and is covered by `UPSTREAM.sha256`.

## Where licence material is installed

| Path | Written by | Contents |
|---|---|---|
| `lib/liblmdb.a`, or the shared library with its soname symlinks | `build.zig` | the three-unit library |
| `include/lmdb.h` | `build.zig` | the public header, carrying upstream's copyright line, the redistribution sentence and the Hedenfalk grant in its own bytes (`lmdb.h:141-166`) |
| `lib/pkgconfig/lmdb.pc` | `build.zig` | `Libs: -L${libdir} -llmdb`, with `Libs.private` carrying `module.c`'s loader dependency for the static variant only — `-ldl -pthread` on ELF, `-lkernel32` on Windows, empty on Darwin — and empty in the shared variant, where the dependency is already inside the shared object |
| `bin/mdb_stat`, `mdb_copy`, `mdb_dump`, `mdb_load`, `mdb_drop`, `bin/lmdb-smoke` | `build.zig` | upstream's five tools (`IPROGS`, `Makefile:52`) and this fork's smoke program |
| `share/man/man1/mdb_*.1` | `build.zig` | upstream's five man pages (`IDOCS`, `Makefile:53`) |
| `share/lmdb/LICENSE`, `share/lmdb/COPYRIGHT` | `build.zig` | upstream's licence text and copyright notice, byte-identical to the two files under `libraries/liblmdb/` |
| `share/lmdb/NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`, `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md` | `build.zig` | this fork's records. `UPSTREAM.sha256` installs as the record it is: its paths are relative to the package root, so it is not runnable from a prefix and the output does not claim otherwise |

`package.nix` installs nothing of its own: it runs that build once against `$out`,
so there is one writer per path.

## Status

| Claim | Status |
|---|---|
| The grant, the identifier, the file lists, the line numbers and the install paths | `SOURCE-CONFIRMED` — read out of the files named, at commit `6f0a32496a5aadee15a5e5103c479bd3355ae273` and in this working tree |
| That `build.zig -Dlinkage=…` and `package.nix` produce exactly those paths, in both variants | `PENDING-VERIFICATION` — no gate has observed the install layout since this wave's changes |
| The terms' own text | not restated: `libraries/liblmdb/LICENSE` and `COPYRIGHT` ship verbatim |

## See also

* [`NOTICE.md`](NOTICE.md) — the per-path legal record, the complete inventory of
  all 42 upstream files, and the delivery table for OLDAP-2.8's conditions.
* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the three translation units, the header
  closure, the loader dependency, and what the integrity record does and does not
  establish.
* [`README.md`](README.md) — native-source deviations, native-build deviations and
  their dated history, the build/run/test matrix, and consumption.
* [`CHANGELOG.md`](CHANGELOG.md) — numbered fork-only divergences, each with its
  receipt.
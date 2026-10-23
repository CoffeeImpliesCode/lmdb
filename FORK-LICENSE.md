# FORK-LICENSE.md

The OpenLDAP Public License, Version 2.8, covers only the fork-authored files listed below. Upstream and third-party files retain their own terms. `NOTICE.md` records per-path terms; `UPSTREAM.md` records provenance.

## Authorization

The owner authorized OLDAP-2.8 for fork-authored additions, matching the project's primary upstream terms where appropriate. No individual copyright identity is asserted, and no fork-authored file is attributed to an upstream author.

## Grant

| Field | Value |
|---|---|
| Grant | The OpenLDAP Public License, Version 2.8, 17 August 2003 |
| SPDX identifier | `OLDAP-2.8` |
| Grant text | `libraries/liblmdb/LICENSE`, upstream's own text, unchanged |
| Covered files | The fork-authored paths below |
| Excluded files | All other files; see “Not covered” |

`OLDAP-2.8` is the SPDX short identifier. The grant text is `libraries/liblmdb/LICENSE`, which remains verbatim and is included in `.paths` and the installed licence files.

The OpenLDAP Foundation disclaimer in the upstream licence remains part of that text; it does not identify the Foundation as a fork author. The grant transfers no upstream copyright title. Attribution names identify their respective works and holders; no trademark is claimed.

Redistributions must:

- Retain copyright statements and notices, including the `OLDAP-2.8` SPDX identifier on newly authored files.
- Reproduce applicable notices, conditions and disclaimers in binary distributions.
- Include a verbatim copy of the licence document.

## What this grant covers

Every path below is fork-authored; none is upstream or third-party work. Later fork-authored files are covered unless `NOTICE.md` identifies different terms.

| File | Scope |
|---|---|
| `build.zig`, `build.zig.zon` | Build graph and package manifest |
| `translate.h` | Fork wrapper that includes `<lmdb.h>` |
| `zig/root.zig` | Typed Zig facade and translated C surface |
| `tests.zig`, `smoke.zig` | Tests and smoke program |
| `testdata/corpus.txt`, `testdata/interop.zig` | Known-answer corpus and interoperability program |
| `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig`, `consumer/.gitignore` | Relative-path consumer package |
| `cross-test.profile.sh` | `cross-test` profile |
| `.gitignore` | Fork's root ignore file; distinct from upstream's `libraries/liblmdb/.gitignore`, recorded in `UPSTREAM.sha256` |
| `package.nix`, `flake.nix` | Nix package and flake outputs |
| `devenv.nix`, `devenv.yaml`, `.envrc` | Development environment configuration |
| `README.md` | Fork-authored; upstream has no README at this pin |
| `README.zig.md` | Zig interface reference |
| `CHANGELOG.md`, `FORK-NOTES.md`, `UPSTREAM.md`, `NOTICE.md`, `FORK-LICENSE.md` | Change, divergence, provenance and licence records |
| `UPSTREAM.sha256` | 43 per-file hashes: 42 upstream files and `testdata/corpus.txt` |

## Not covered

| Material | Terms and scope |
|---|---|
| Upstream's 29 of 42 files with redistribution sentences | Upstream OLDAP-2.8 grant in `libraries/liblmdb/LICENSE` and `libraries/liblmdb/COPYRIGHT`; `NOTICE.md` lists paths |
| `lmdb.h`, `mdb.c` | Martin Hedenfalk's separate ISC-style grant remains in each file |
| FNV-1a in `mdb.c` | Landon Curt Noll's public-domain dedication applies when `MDB_USE_HASH` is enabled |
| `libraries/liblmdb/chacha8.c` | Public domain, D. J. Bernstein |
| `libraries/liblmdb/chacha8.h` | No notice in the file; this grant adds none and does not extend `chacha8.c`'s dedication |
| Upstream's five roff man pages (`mdb_*.1`) | Copyright line and licence pointer, not the redistribution sentence |
| `Makefile`, `Doxyfile`, `CHANGES`, `tooltag`, `libraries/liblmdb/.gitignore` | No term in their own bytes; upstream's tree grant applies. `NOTICE.md` lists the paths. |

No single licence label overrides file-specific terms. Hedenfalk's grant requires its notice and permission in all copies, whether or not a redistributor reads this file.

`crypto.c` and `cryptoc.c` reference `<sodium.h>`, but libsodium is not vendored, compiled or linked; no libsodium text is included. `midl.c` and `midl.h` name two copyright holders under one OLDAP-2.8 sentence.

## SPDX identifier

```text
SPDX-License-Identifier: OLDAP-2.8
```

Use the language's comment syntax for newly authored files. Do not add this identifier under `libraries/liblmdb/`: that directory is upstream's and its files are recorded in `UPSTREAM.sha256`.

## Installed licence material

`build.zig` installs the upstream `LICENSE` and `COPYRIGHT` as `share/lmdb/LICENSE` and `share/lmdb/COPYRIGHT`, and the fork's `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`, `README.md`, `README.zig.md`, `CHANGELOG.md` and `FORK-NOTES.md` under `share/lmdb/`. `include/lmdb.h` retains upstream's copyright, redistribution sentence and Hedenfalk grant. The installed `UPSTREAM.sha256` keeps package-root-relative paths and is not runnable from the prefix. `package.nix` adds no separate install step.

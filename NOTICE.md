# NOTICE

## Scope

The package ships all 42 unchanged files under `libraries/liblmdb/` from the pinned LMDB `LMDB_1.0.1` tree. `chacha8.c` is third-party public-domain code, not an LMDB contribution; `chacha8.h` has no notice in its own bytes. `UPSTREAM.sha256` covers these files and fork-authored `testdata/corpus.txt`.

The fork's `OLDAP-2.8` grant covers fork-authored files only, as scoped in `FORK-LICENSE.md`; it does not extend upstream or third-party terms.

## Attribution

- LMDB: Howard Chu and Symas Corp. `COPYRIGHT`: `Copyright 2011-2021 Howard Chu, Symas Corp.`; `lmdb.h`: `Copyright 2011-2026 Howard Chu, Symas Corp. All rights reserved.` `COPYRIGHT` also records the OpenLDAP Foundation trademark.
- `midl.c` and `midl.h`: `Copyright 2000-2026 The OpenLDAP Foundation.` and `Portions Copyright 2001-2026 Howard Chu, Symas Corp.`
- Martin Hedenfalk: `Copyright (c) 2009, 2010 Martin Hedenfalk <martin@bzero.se>`; grant in `lmdb.h` and `mdb.c`.
- Landon Curt Noll: conditional public-domain FNV-1a code in `mdb.c`.
- D. J. Bernstein: `chacha8.c` states `Public domain.`; this does not extend to `chacha8.h`.

## Per-path terms

| Paths under `libraries/liblmdb/` | Term or exception |
|---|---|
| `LICENSE` | OpenLDAP Public License 2.8, 17 August 2003; full text. |
| `COPYRIGHT` | OLDAP-2.8; Howard Chu / Symas Corp. copyright and OpenLDAP grant pointer; OpenLDAP Foundation trademark. |
| `lmdb.h` | OLDAP-2.8; Howard Chu / Symas Corp.; Martin Hedenfalk grant, derived from `btree.c`. |
| `mdb.c` | OLDAP-2.8; Howard Chu / Symas Corp.; Hedenfalk grant and conditional FNV-1a public-domain notice by Landon Curt Noll. |
| `midl.c`, `midl.h` | OLDAP-2.8; OpenLDAP Foundation copyright and portions Howard Chu / Symas Corp. |
| `module.c`, `mdb_copy.c`, `mdb_drop.c`, `mdb_dump.c`, `mdb_load.c`, `mdb_stat.c`, `crypto.c`, `cryptoc.c`, `intro.doc`, `upgrading.doc`, `mplay.c`, `mtest.c`, `mtest2.c`, `mtest3.c`, `mtest4.c`, `mtest5.c`, `mtest6.c`, `mtest_enc.c`, `mtest_enc2.c`, `mtest_enc3.c`, `mtest_enc4.c`, `mtest_remap.c`, `sample-bdb.txt`, `sample-mdb.txt` | OLDAP-2.8; Howard Chu / Symas Corp. `mdb_drop.c` retains its distinct `2016-2021` range. `crypto.c` and `cryptoc.c` reference `<sodium.h>` as a dependency. |
| `mdb_copy.1`, `mdb_stat.1` | Howard Chu / Symas Corp. copyright, 2012-2026; roff-comment pointer to `COPYRIGHT`/`LICENSE`. |
| `mdb_dump.1`, `mdb_load.1`, `mdb_drop.1` | Howard Chu / Symas Corp. copyright, 2014-2026; roff-comment pointer to `COPYRIGHT`/`LICENSE`. |
| `chacha8.c` | Third-party public domain, D. J. Bernstein; not OLDAP-2.8. |
| `chacha8.h` | No copyright, grant, or attribution in its own bytes; no term inferred from `chacha8.c`. |
| `Makefile`, `Doxyfile`, `CHANGES`, `tooltag`, `.gitignore` | No term in own bytes; upstream repository files under the tree's OpenLDAP Public License 2.8, not the fork's grant. |

## Licence text

OpenLDAP Public License 2.8: `libraries/liblmdb/LICENSE`. Conditions include:

1. `Redistributions in source form must retain copyright statements and notices,`
2. `Redistributions in binary form must reproduce applicable copyright statements and notices, this list of conditions, and the following disclaimer in the documentation and/or other materials provided with the distribution`
3. `Redistributions must contain a verbatim copy of this document.`

Martin Hedenfalk's grant in `lmdb.h` and `mdb.c`:

> Permission to use, copy, modify, and distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

Conditional FNV-1a notice in `mdb.c`: `Please do not copyright this code. This code is in the public domain.`

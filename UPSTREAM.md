# Upstream

| Property | Value |
|---|---|
| Project | LMDB, the Lightning Memory-Mapped Database |
| Repository | `https://github.com/LMDB/lmdb.git` |
| Release | `LMDB_1.0.1`; library version `1.0.1`, dated Aug 6, 2026 in `lmdb.h` |
| Commit | `6f0a32496a5aadee15a5e5103c479bd3355ae273` |
| Acquisition | Full clone of the canonical repository; upstream history is present |
| Archive SHA-256 | `7c23a9c5a8e94fa36179ed7de22efd7c3c46eae565c95dc6bcf98e3bb1a3dcd7` (full-tree `git archive`) |
| Imported files | 42 files under `libraries/liblmdb/`, unchanged |
| Removed upstream files | None |
| Manifest | `UPSTREAM.sha256`: 42 imported files and fork-authored `testdata/corpus.txt` (43 records) |
| Principal licence | OpenLDAP Public License 2.8; see `NOTICE.md` for per-path terms and exceptions |

All 42 files under `libraries/liblmdb/` are shipped byte-for-byte from the pinned tree. `chacha8.c` is third-party public-domain code, not an LMDB contribution; `chacha8.h` has no notice in its own bytes.

`testdata/corpus.txt` is a fork-authored independent fixture, not upstream source.

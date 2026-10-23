# Fork notes

## Source changes

| File | Change and reason |
|---|---|
| `libraries/liblmdb/` | No files are changed, added, or removed; the upstream tree is kept intact. |
| `translate.h` | Selects the bundled or system `lmdb.h` and declares Clang's builtin `__int128` types when needed by target preprocessing. |
| `zig/root.zig` | Adds a typed Zig facade with target-specific status mapping and explicit environment, transaction, cursor, and database lifetimes. |
| `runtime/loader.zig` | Adds a process-wide loader with explicit path/name requests and publishes a table only after all required symbols resolve. |
| `runtime/library.zig` | Binds LMDB's synchronization functions, records the provider ABI requirements, and checks the resolved provider with `mdb_version`. |
| `runtime/graph.zig` | Builds a runtime dispatch from the target's translated declarations so runtime calls use the selected shared library. |
| `runtime/generate.zig` | Generates function wrappers and symbol tables from the translation output rather than duplicating LMDB declarations. |
| `runtime/sync.c`, `runtime/sync.h` | Provide prefixed synchronization functions for the runtime loader without colliding with other SDKs. |
| `tests.zig` | Adds behavioral tests for facade operations, ownership, and error boundaries. |
| `smoke.zig` | Adds a deterministic end-to-end exercise of the facade and database behavior. |
| `testdata/corpus.txt` | Supplies independent records for the interoperability comparison. |
| `testdata/interop.zig` | Writes the corpus through the facade and compares its rendering with upstream `mdb_dump -p`. |
| `consumer/build.zig` | Adds a separate package build that imports the published `lmdb` module and selects linkage/runtime modes. |
| `consumer/build.zig.zon` | Declares that independent consumer package and its local LMDB dependency. |
| `consumer/src/main.zig` | Exercises the consumer-facing API and requires explicit scratch space and, for runtime loading, a provider. |

## Build graph

- `core_sources` names `mdb.c`, `midl.c`, and `module.c`, matching upstream's archive and shared-library object lists. Tool sources are also explicit; all five upstream tools are built and installed.
- Bundled mode preprocesses `translate.h` for the selected target and compiles upstream's C sources. `-fsys=lmdb` instead uses pkg-config and the installed header beside the selected library.
- `-Dlinkage=static|dynamic` selects the delivered library; static is the default, and the shared build uses PIC where the target requires it. The install includes the header, generated pkg-config metadata, tools and manuals, and upstream licence files.
- Loader dependencies are attached to the core module: Linux uses `dl`, Windows uses `kernel32`, and Darwin needs no extra loader library. Static pkg-config metadata carries private loader dependencies.
- `-Druntime=true` generates a dispatch from the translated header and leaves the LMDB library unlinked; `lmdb.load` resolves the provider at runtime. The linked route uses the same translated facade without the dispatch.
- `check` compiles the core, facade, tests, smoke program, and interoperability program for its target set. The separate `interop` step builds upstream's `mdb_dump` from this tree and compares its deterministic output body with the fixture.

## Platform boundaries

- The lock backend is selected by target: robust POSIX mutexes on Linux, POSIX named semaphores on macOS, Win32 mutexes on Windows, and upstream's own selection on the BSD targets. `wasm32-wasi` is refused because it has no supported shared-lock backend and its emulated mapping does not provide shared mappings or write-back; `MDB_NOLOCK` is not used as a substitute.
- Runtime loading uses the platform loader on supported Unix targets and Windows. WASI, Emscripten, and freestanding targets have no supported dynamic loader.
- User-mode QEMU Linux runners return `ENOSYS` for robust-list syscalls. Foreign Linux execution that needs process-shared robust mutex owner-death recovery therefore requires a kernel-backed provider; the package does not weaken locking to make that emulation pass.

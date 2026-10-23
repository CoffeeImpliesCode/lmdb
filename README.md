# LMDB

LMDB 1.0.1 is the Lightning Memory-Mapped Database. This package wraps its upstream C library in a Zig facade.

## Source deviations

- The 42 files under `libraries/liblmdb/` are unchanged and shipped.
- Fork-authored additions provide header translation (`translate.h`), the Zig facade (`zig/`), runtime loading (`runtime/`), tests and smoke program, an interoperability fixture, and an independent consumer package.

## Build deviations

- The build compiles upstream's `mdb.c`, `midl.c`, and `module.c`; it does not invoke upstream's Makefile.
- Bundled mode translates the in-tree header. `-fsys=lmdb` uses pkg-config and the installed library's matching header.
- Static is the default. `-Dlinkage=dynamic` builds a shared library with the versioned name `liblmdb.so.1.0.1` and the `liblmdb.so.1` and `liblmdb.so` links.
- The install includes `lmdb.h`, generated pkg-config metadata, all five upstream tools and manuals, and the upstream licence and copyright files with the fork's notices.

## Support matrix

| Target family | Lock backend or boundary |
|---|---|
| Linux | Process-shared robust POSIX mutexes. |
| macOS | POSIX named semaphores. |
| Windows | Win32 mutexes. |
| BSD targets | Upstream selects the platform backend. |
| `wasm32-wasi` | Refused: the emulated mapping lacks shared mappings and write-back, and no supported shared-lock backend is available. |

`MDB_NOLOCK` is not used to make an unsupported target build. Runtime loading also requires a platform dynamic loader; WASI, Emscripten, and freestanding targets are unsupported for that mode.

## Consumption

A local dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .lmdb = .{ .path = "../lmdb" },
},
```

Import the facade module:

```zig
const dep = b.dependency("lmdb", .{ .target = target, .optimize = optimize });
exe_mod.addImport("lmdb", dep.module("lmdb"));
```

`dep.module("lmdb")` is the facade. `dep.module("c")` exposes the translated C API; in bundled mode, that module alone needs `dep.artifact("lmdb")`. The artifact is not registered in system mode.

Build options:

- `-Dlinkage=static|dynamic` selects the library; default is `static`.
- `-Dcpu=<model>` selects CPU features for the requested target.
- `-fsys=lmdb` selects an installed library; `-fno-sys=lmdb` selects bundled sources.
- `-Druntime=true` builds the runtime-loaded facade without linking LMDB; call `lmdb.load` with an explicit provider before database operations.

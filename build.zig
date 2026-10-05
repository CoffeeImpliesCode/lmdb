//! Build graph for the LMDB fork.
//!
//! Six things happen here and nothing else:
//!
//!   1. The upstream C core is compiled from an explicit three-file list out
//!      of `libraries/liblmdb` - the three objects `liblmdb.a` is made of
//!      upstream - for whichever target was asked for, with the shared-lock
//!      backend that build chooses from the resolved target and, because
//!      `module.c` is one of the three, the system library that platform keeps
//!      its dynamic-loader entry points in. `-Dlinkage=static|dynamic` picks
//!      which of upstream's two forms that is: the archive its `.o` objects
//!      make, or the shared object its separately compiled `.lo` objects make
//!      (`liblmdb/Makefile:87-94`, `:126-145`).
//!   2. `translate.h` is read for the same target - preprocessed for it by the
//!      same compiler that compiles the core in the default mode - so the Zig
//!      facade's `c` import is generated from the header that sits next to the
//!      code it binds.
//!   3. The facade module is registered under the name `lmdb`, carrying the
//!      library this build produced - or, in `-fsys=lmdb` mode, the installed
//!      one - and the header include path, so a dependent needs nothing but
//!      `dep.module("lmdb")`.
//!   4. The install prefix is the whole delivery and not only the library file:
//!      the one header upstream installs, upstream's own five command-line tools
//!      with the manual pages upstream installs for them,
//!      a generated `lmdb.pc` whose link metadata names what this variant
//!      really needs, and upstream's `LICENSE` and `COPYRIGHT` - the terms that
//!      have to travel with a redistributed LMDB. The terms and this fork's
//!      provenance records install at both `share/lmdb/` and
//!      `share/licenses/lmdb/`; the second spelling is the one every other
//!      package here uses and the one a recipient looks under first, and
//!      neither directory was moved to make room for the other.
//!   5. `check` compiles the core, the facade, the tests, the smoke program and
//!      the interoperability program - not the installed tools, which is what
//!      `zig build` itself builds - for the whole target matrix, and proves the
//!      one target in the matrix that has no lock backend is refused rather
//!      than quietly skipped.
//!   6. `interop` builds upstream's own `mdb_dump` from the sources in this
//!      repository and runs the interoperability program against it, so the
//!      package's primary fixture is a reference reader and not this facade
//!      agreeing with itself.
//!
//! Two option pairs shape this graph and they are orthogonal. `-Dlinkage`
//! chooses which of upstream's two forms this build delivers and installs.
//! `-Druntime` chooses how the facade reaches it: through a link line, which is
//! the default, or through a table an explicit `load` fills. Under `-Druntime`
//! nothing is linked into the module at all, so a caller may name a provider
//! this tree did not build - and the artifact is still built and installed, so
//! a caller may equally name the one it did.

// SPDX-License-Identifier: OLDAP-2.8
//
// The identifier matches the primary upstream grant this package ships -
// `libraries/liblmdb/LICENSE`, the OpenLDAP Public License v2.8, unmodified -
// and is the owner-authorized choice for this fork's own additions; the record
// is FORK-LICENSE.md. It belongs on fork-authored files only: nothing under
// `libraries/liblmdb/` carries it, because that tree is what UPSTREAM.sha256
// hashes byte for byte.

const std = @import("std");

const manifest = @import("build.zig.zon");

/// The runtime-loading build half, which the API role owns. It exposes
///
///     pub fn createModule(
///         b: *std.Build,
///         translate: *std.Build.Step.TranslateC,
///         target: std.Build.ResolvedTarget,
///         optimize: std.builtin.OptimizeMode,
///     ) *std.Build.Module
///
/// and `-Druntime` substitutes that one call for `translate.createModule()`.
/// It takes the `TranslateC` step this build has already made, so the generated
/// dispatch keeps the exact translated type and constant namespace instead of
/// compiling a second copy of the native extern structs and casting between
/// two modules that call them the same names.
///
/// `createCoreModule` builds the loader core for the *linked* branch, which has
/// no dispatch to carry `LoadSource` and `LoadError` and takes them from
/// `zig/root.zig:243` instead. The two branches must not both build it: the
/// runtime branch's `createModule` makes the one core instance the dispatch
/// uses and re-exports those two types from it, so a second instance would be
/// two nominally distinct `LoadSource` types, and a consumer naming one while
/// `lmdb.load` expects the other is a compile error at best.
///
/// The identifier is spelled out instead of `graph` because this file already
/// uses `graph` for the package `addLmdb` returns, and one name meaning two
/// things in the same file is how a wiring mistake hides.
const runtime_graph = @import("runtime/graph.zig");

/// The upstream release this fork is pinned to. `mdb.c`, `midl.c`, `module.c`
/// and `lmdb.h` are used byte-for-byte as they are at this commit, and so are
/// the five tool sources and the five manual pages the installed delivery
/// carries, which is why build.zig.zon ships the whole `libraries/liblmdb`
/// directory instead of naming files: `UPSTREAM.sha256` records every file in
/// it anyway. What is *compiled* is named file by file in `core_sources`,
/// `tool_sources` and `installed_tools` below, so a file appearing upstream
/// cannot join the archive or the installed set without being a decision in
/// this file.
///
/// Only `version` is asserted here, against build.zig.zon's `.version`, so a
/// manifest edit that claims a different LMDB cannot configure. `commit` and
/// `ref` are the record of which tree the sources came from, the same record
/// UPSTREAM.md carries; nothing in a build may depend on Git being present.
const upstream = struct {
    const repository = "https://github.com/LMDB/lmdb.git";
    const ref = "LMDB_1.0.1";
    const commit = "6f0a32496a5aadee15a5e5103c479bd3355ae273";

    /// lmdb.h:235-239 declares 1, 0 and 1 at that commit.
    const version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 1 };

    /// The ABI series of the shared library upstream builds from the same
    /// three objects: `LIBVER = 1`, `ABIVER = 0`, `VEREXT = $(LIBVER).$(ABIVER)`
    /// (liblmdb/Makefile:33-35) gives `SOVER = liblmdb.so.1` (:56), and
    /// `-Wl,-soname,$(SOVER)` (:57) records that as the soname. Zig names a
    /// shared library's soname from the major component of the version the
    /// artifact is given, so this is the value that has to equal
    /// `version.major` for the shared object this build produces to sit in the
    /// same ABI series as upstream's. `build()` asserts it; what the produced
    /// object actually records is the driver's to read out of the artifact.
    const soname_major: u32 = 1;

    /// Where the upstream C core lives in this repository.
    const source_dir = "libraries/liblmdb";
};

/// The whole library, and the whole library is three translation units.
///
/// `liblmdb/Makefile:87-88` builds `liblmdb.a` from `mdb.o midl.o module.o`
/// and `liblmdb/Makefile:90-92` builds the shared `liblmdb.so.1.0` from
/// `mdb.lo midl.lo module.lo` with the same three, so upstream ships these
/// objects in both forms and this build produces the same one. `module.c` is the
/// dynamic crypto-module loader - `mdb_modload`, `mdb_modsetup` and
/// `mdb_modunload`, all three declared in the public header at
/// lmdb.h:1899-1918 - and it is in `liblmdb.a`, so it is in whatever this
/// build produces: a package whose core left it out is not the library this pin
/// names, and upstream's own `mdb_dump` would not link against it. Whether this
/// fork's Zig facade happens to call those entry points is not a question this
/// list gets to ask. The C library is what is being reproduced here, and the C
/// tools that consume it name the loader whether or not they were given
/// `-m` (mdb_dump.c:270, :275, :364).
///
/// The cipher files behind upstream's own encryption test are not core and are
/// not here: `chacha8.c` is linked into `mtest_enc` (liblmdb/Makefile:113),
/// `crypto.c` is the loadable `crypto.lm` module the `mtest_enc2` through
/// `mtest_enc4` programs load (liblmdb/Makefile:114-124), and `cryptoc.c` is
/// named by no rule in that Makefile at all. Nothing in these three
/// references any of them. So the three translation units are named one by one
/// rather than globbed, and a file appearing upstream cannot silently join the
/// core.
const core_sources = [_][]const u8{
    "mdb.c",
    "midl.c",
    "module.c",
};

/// The upstream command-line tool the interoperability gate is measured
/// against, and nothing else from upstream's tree.
///
/// `mdb_dump` is upstream's own dump tool and nothing here reimplements it:
/// the gate runs it and compares its output against the facade's. It is
/// compiled alone and linked against the complete library this build produces,
/// which is how upstream links it - `mdb_dump: mdb_dump.o
/// liblmdb.a` and `$(CC) $(LDFLAGS) -o $@ $^ $(LDL)`
/// (liblmdb/Makefile:100-101) - so the `mdb_modload`, `mdb_modsetup` and
/// `mdb_modunload` references it makes unconditionally resolve to the same
/// `module.o` a consumer of the installed library gets, from the same library
/// this build produced rather than from a second copy of the unit compiled
/// beside the tool.
///
/// Named one by one, like the core: a tool appearing upstream cannot join the
/// reference oracle without being a decision in this file.
const tool_sources = [_][]const u8{
    "mdb_dump.c",
};

/// The command-line tools this package installs, and the manual page it
/// installs for each: upstream's own `IPROGS` (liblmdb/Makefile:52) with its
/// `IDOCS` (:53), in the order its install rule copies them (:70, :78).
///
/// Each one is built from the sources in this repository and linked against the
/// artifact this build produced. Upstream links all five the same way, against
/// its own archive (`mdb_stat: mdb_stat.o liblmdb.a` and its four siblings,
/// liblmdb/Makefile:96-105); this build follows the artifact rather than the
/// form, so under `-Dlinkage=dynamic` the tools are linked against the shared
/// object this build just produced and need it beside them at run time. Named
/// one by one, like the core and the oracle: a tool appearing upstream cannot
/// join the installed set without being a decision in this file.
const InstalledTool = struct {
    name: []const u8,
    source: []const u8,
    man_page: []const u8,
};

const installed_tools = [_]InstalledTool{
    .{ .name = "mdb_stat", .source = "mdb_stat.c", .man_page = "mdb_stat.1" },
    .{ .name = "mdb_copy", .source = "mdb_copy.c", .man_page = "mdb_copy.1" },
    .{ .name = "mdb_dump", .source = "mdb_dump.c", .man_page = "mdb_dump.1" },
    .{ .name = "mdb_load", .source = "mdb_load.c", .man_page = "mdb_load.1" },
    .{ .name = "mdb_drop", .source = "mdb_drop.c", .man_page = "mdb_drop.1" },
};

/// The terms that have to travel with a redistributed LMDB, installed byte for
/// byte out of the pinned tree: `LICENSE` is the OpenLDAP Public License v2.8
/// text upstream ships, and `COPYRIGHT` is upstream's own notice beside it.
/// Upstream's install rule copies neither (liblmdb/Makefile:65-78), and the
/// notices that are per file - the ISC-style grant inside the installed
/// `lmdb.h` (lmdb.h:151-166), the ones inside `mdb.c` (mdb.c:19-33 and the
/// conditional grant at :5846-5872 under the `MDB_USE_HASH` guard on :5845),
/// and the public-domain notice in the retained, uncompiled `chacha8.c` -
/// travel with the file each of them is written in.
const licence_files = [_][]const u8{
    "LICENSE",
    "COPYRIGHT",
};

/// The fork's own provenance records, installed beside upstream's legal files
/// for the same reason and into the same directory.
///
/// The owner authorized these additions under this package's primary upstream
/// terms, so a redistributed binary carries their notices as well as upstream's
/// ones: condition 2 asks for the notices that travel with the code, and the
/// fork's half is now one of them. `FORK-LICENSE.md` is the record of the
/// authorization and of which grant it is.
///
/// They travel as records, not as build inputs. `UPSTREAM.sha256` names paths
/// relative to the package root and cannot be run from an install prefix, so it
/// is installed as the record it is and not as something the prefix claims to
/// satisfy; nothing here reads any of them.
const provenance_files = [_][]const u8{
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
    "UPSTREAM.sha256",
    "README.md",
    "README.zig.md",
    "CHANGELOG.md",
    "FORK-NOTES.md",
};

/// Every licence, notice and provenance record installed under
/// `share/licenses/lmdb/`, as `source -> installed name` pairs.
///
/// `share/lmdb/` above already carries these bytes, and it keeps doing so: that
/// directory is where the two loops in `build` put upstream's terms and this
/// fork's records, and moving them would remove an installed path rather than
/// add one. `share/licenses/lmdb/` is the second spelling, and it is the one
/// every other package in this workspace uses, so a recipient who looks for
/// terms where a package's terms normally live finds them.
///
/// `LICENSE` is the OpenLDAP Public License v2.8 text upstream ships at
/// `libraries/liblmdb/LICENSE`, copied byte for byte and not rewritten, and
/// `COPYRIGHT` is upstream's own notice beside it. The remaining five are this
/// fork's records: the inventory, the owner-authorised grant, the pin, the
/// integrity digests and what this fork changed about the pinned tree. `README.md`
/// and `CHANGELOG.md` travel under `share/lmdb/` and are not repeated here; they
/// are this fork's documentation, not terms.
const licence_records = [_]struct { source: []const u8, installed: []const u8 }{
    .{ .source = "libraries/liblmdb/LICENSE", .installed = "LICENSE" },
    .{ .source = "libraries/liblmdb/COPYRIGHT", .installed = "COPYRIGHT" },
    .{ .source = "NOTICE.md", .installed = "NOTICE.md" },
    .{ .source = "FORK-LICENSE.md", .installed = "FORK-LICENSE.md" },
    .{ .source = "UPSTREAM.md", .installed = "UPSTREAM.md" },
    .{ .source = "FORK-NOTES.md", .installed = "FORK-NOTES.md" },
    .{ .source = "UPSTREAM.sha256", .installed = "UPSTREAM.sha256" },
};

/// The language level, pinned rather than inherited from the compiler default.
/// `mdb.c` uses GNU extensions (`__attribute__ ((cold))`, `__attribute__
/// ((section ...))`, `__func__`) and declares `_GNU_SOURCE` for itself at
/// mdb.c:35-37, so `gnu17` is what the source was written against. Nothing
/// else is forced: every other choice in mdb.c is made by its own `#ifdef`
/// ladder from the target, and overriding one of those from the command line
/// is how a build ends up with a different library from the same source.
const c_flags = [_][]const u8{
    "-std=gnu17",
};

/// The core's compile flags for the linkage that was asked for.
///
/// Upstream compiles the archive from `.o` objects and the shared object from
/// `.lo` objects, and the only difference between those two rules is `-fPIC`
/// (liblmdb/Makefile:126-139 against :144-145). So the static default keeps
/// exactly the flags this build has always used, and `-Dlinkage=dynamic` adds
/// the one upstream adds - on every target but Windows, where a PE/COFF object
/// has no position-independent form to need and `-fPIC` is not part of that
/// toolchain's vocabulary. Nothing else varies with the linkage: same language
/// level, same sources, same macros, same translation.
fn coreCFlags(linkage: std.builtin.LinkMode, os_tag: std.Target.Os.Tag) []const []const u8 {
    if (linkage == .dynamic and os_tag != .windows) return &.{ "-std=gnu17", "-fPIC" };
    return &c_flags;
}

/// Fork-authored roots. These are the only files outside build.zig that this
/// build knows how to compile, and they are named here so that a rename is a
/// one-line change rather than a discovery.
const facade_root = "zig/root.zig";
const test_root = "tests.zig";
const smoke_root = "smoke.zig";
const interop_root = "testdata/interop.zig";

/// The one C translation unit this build has the translator read. In the
/// default mode it is preprocessed first - see `preprocessedHeader`.
const translate_header = "translate.h";

/// The module a dependent reaches through `dep.module("lmdb")`, the C import
/// name inside `zig/root.zig`, and the two names the system library is known
/// by: pkg-config's `Name:` line says `lmdb (OpenLDAP)` and its `Libs:` line
/// says `-llmdb` (`liblmdb/Makefile:147-157`), so the query name and the
/// library name are both `lmdb`.
const module_name = "lmdb";
const c_import_name = "c";
const pkg_config_name = "lmdb";

/// The loader-core import name inside `zig/root.zig:243`. It is named in this
/// file because the linked configuration has to hand the facade that module
/// and the runtime configuration deliberately must not: the runtime branch
/// takes the two public types from the dispatch, which re-exports them from the
/// one core instance it built itself.
const rt_import_name = "rt";

/// The matrix `zig build check` compiles when it was not given a `-Dtarget`.
/// Each triple is a target whose lock backend this build names and whose C
/// sources it has been asked to compile.
const supported_check_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "aarch64-macos-none",
    "x86_64-windows-gnu",
    "riscv64-linux-gnu",
};

/// The rest of the matrix, named so it is never silently dropped. wasm32-wasi
/// has no lock backend at all - see `refusalFor` - so it is refused with a
/// message that says so, both when the whole matrix is checked and when it is
/// asked for by name with `-Dtarget=wasm32-wasi`. A target that cannot be
/// built is a result this build reports, not one it hides by omission.
const refused_check_targets = [_][]const u8{
    "wasm32-wasi",
};

/// One shared-lock backend: the macros that select it.
const LockBackend = struct {
    /// Each entry is the same macro, with the same value, that mdb.c's ladder
    /// would define for this platform. Redefining a macro with an identical
    /// replacement list is well defined (C11 6.10.3p2), so these are not
    /// overrides: they state the selection where it can be read, and they take
    /// the decision away from whatever the compiler happened to predefine.
    /// They are not redundant either. If a future edit made the ladder pick a
    /// second implementation, mdb.c:228-231 fails the compile with "Ambiguous
    /// shared-lock implementation" instead of the build quietly linking a
    /// database whose lock file no other tool can read.
    macros: []const Macro,
};

const Macro = struct { name: []const u8, value: []const u8 };

/// Chooses the shared-lock backend from the resolved target's OS.
///
/// The result is the only place this build decides anything about locking, and
/// it is driven by `target.result.os.tag`, which is the target being compiled.
/// Nothing here reads the machine running the build.
fn lockBackend(os_tag: std.Target.Os.Tag) ?LockBackend {
    return switch (os_tag) {
        // The backend is a process-shared robust POSIX mutex. mdb.c:223-224
        // reaches the same one on its own for a POSIX system that is not Apple,
        // Haiku or a BSD. Naming it here also pins the variant decision
        // mdb.c:354-362 would otherwise take from the target's own __ANDROID__
        // and __GLIBC__ macros: this package builds robust mutexes, and with
        // MDB_ROBUST_SUPPORTED (mdb.c:374-376, reached because EOWNERDEAD is
        // declared by <pthread.h>) the core recovers from a reader that died
        // holding the lock.
        .linux => .{ .macros = &.{
            .{ .name = "MDB_USE_POSIX_MUTEX", .value = "1" },
            .{ .name = "MDB_USE_ROBUST", .value = "1" },
        } },

        // The backend is a POSIX named semaphore, which is Apple's own,
        // selected by `#elif defined (__APPLE__)` at mdb.c:183-194.
        // MDB_USE_ROBUST must stay undefined here: mdb.c:184 tests
        // `defined(__APPLE__) && !defined(MDB_USE_ROBUST)` before it chooses
        // MDB_USE_POSIX_SEM, so defining it would fall through to
        // MDB_USE_SYSV_SEM (mdb.c:187-188), which is not the backend this
        // platform's own build of these sources selects.
        // Named semaphores have no owner-death recovery, which is why upstream
        // picked them for Apple and why this build does not pretend otherwise.
        // macCatalyst is this same arm: it is a Darwin target
        // (`lib/std/Target.zig:79-86` names `.maccatalyst` and `.macos` in one
        // `isDarwin()` case) and it predefines `__APPLE__`, observed by
        // `zig cc -target aarch64-maccatalyst -E -dM libraries/liblmdb/mdb.c`
        // on the pinned Zig 0.16.0
        // (`local://foundation-cross-test-lmdb-target-macros.json`).
        .macos, .maccatalyst => .{ .macros = &.{
            .{ .name = "MDB_USE_POSIX_SEM", .value = "1" },
        } },

        // The backend is the native Win32 mutex, and it needs no macro at all:
        // under _WIN32 mdb.c never reaches the POSIX arm (mdb.c:207-226) and
        // builds the whole mutex layer on the Win32 API (mdb.c:378-420),
        // CreateMutex/WaitForSingleObject/ReleaseMutex, and WAIT_ABANDONED as
        // MDB_OWNERDEAD. The target itself is the selection.
        .windows => .{ .macros = &.{} },

        // The BSDs take mdb.c's own ladder, unforced: no macro at all. What that
        // toolchain predefines is observed, and mdb.c:175-231 turns it into
        // exactly one backend each way — FreeBSD reaches its own arm at
        // mdb.c:175-179 (`__FreeBSD__`, `__FreeBSD_version` >= 1100110) and gets
        // POSIX_MUTEX + ROBUST; NetBSD and OpenBSD define `BSD` and so reach
        // mdb.c:183-194's SysV-semaphore arm, with mdb.c:203-205 supplying
        // NetBSD's `union semun`. Naming a backend here instead would import
        // Linux's or Apple's choice into an on-disk format: MDB_LOCK_TYPE
        // (mdb.c:965-981) is 8 for SysV semaphores and a `pthread_mutex_t`
        // value for POSIX mutexes, it is written into the lock file and checked
        // on open (mdb.c:6119, :6132), so the type a native LMDB built on the
        // platform with the same libc headers would record is the one that has
        // to match.
        .freebsd, .netbsd, .openbsd => .{ .macros = &.{} },

        else => null,
    };
}

/// The system libraries the core needs because `module.c` is inside it, named
/// from what that unit actually calls on each platform rather than from a
/// blanket rule.
///
/// `module.c` takes one of two arms: `<windows.h>` and the Win32 loader under
/// `_WIN32` (module.c:14-15, :33-49, :74-76), `<dlfcn.h>` and the POSIX loader
/// everywhere else (module.c:16-18, :50-67, :77-78). A static archive does not
/// resolve anything, so the calls it contains are resolved by whatever links the
/// artifact. It is driven by the resolved target's `os.tag`, the target being
/// compiled, and reads nothing about the machine running the build.
fn loaderSystemLibraries(os_tag: std.Target.Os.Tag) []const []const u8 {
    switch (os_tag) {
        // dlopen, dlsym and dlclose (module.c:52-62, :78) live in libdl on a
        // GNU/Linux system, and that is upstream's own reading of the same
        // requirement: `LDL = -ldl` (liblmdb/Makefile:31) is what it appends
        // to the shared library's link line (liblmdb/Makefile:92) and what the
        // installed pkg-config file records as `Libs: -llmdb -ldl -pthread`
        // (liblmdb/Makefile:158).
        .linux => return &.{"dl"},

        // The Win32 arm calls LoadLibrary, GetProcAddress and FreeLibrary
        // (module.c:35-42, :75) - `<windows.h>` maps `LoadLibrary` to its ANSI
        // or wide form - and those are kernel32 exports, not dlfcn ones. There
        // is no libdl on this platform for upstream's `LDL` to be naming, and
        // no libdl to name here either.
        .windows => return &.{"kernel32"},

        // Darwin takes the POSIX arm, and there the `dl*` entry points are
        // exported by libSystem, which is the C library itself on that
        // platform - the one `link_libc` links. So there is nothing left to add
        // here and no separate libdl to ask for. `LDL` is a GNU-ld name for the
        // Linux library, and upstream carries no Darwin alternative for it: the
        // one place its Makefile speaks about macOS is the soname option it
        // leaves commented out (liblmdb/Makefile:58-59).
        // macCatalyst takes this same arm: it is a Darwin target and so
        // resolves `dl*` out of libSystem like `.macos` does.
        .macos, .maccatalyst => return &.{},

        // The BSDs take this same empty answer, for the same reason and with
        // each platform's own manual behind it rather than by inference:
        // FreeBSD's dlopen(3) records `LIBRARY: Standard C Library (libc, -lc)`
        // and states that libdl is not required;
        // https://man.freebsd.org/cgi/man.cgi?query=dlopen&sektion=3&format=ascii .
        // NetBSD's dlopen(3) says the interface is "automatically included in
        // every dynamically linked program" and that it is not a library to
        // link against; https://man.netbsd.org/dlopen.3 . OpenBSD's dlopen(3)
        // documents the runtime linker's interface directly and there is no
        // libdl in its base system; https://man.openbsd.org/dlopen.3 .
        // Asking for `-ldl` here would be a hard link failure where no such
        // file exists and dead weight where it does.
        .freebsd, .netbsd, .openbsd => return &.{},

        // Unreachable by construction: `lockBackend` refuses every operating
        // system that is not one of the arms above, and it is called before
        // this one on every path that reaches it. Reported and then stopped,
        // rather than answered with an empty list, so that an operating system
        // added to `lockBackend` without a decision here fails the build
        // instead of quietly dropping the loader library its core needs.
        else => {
            std.log.err("lmdb: build.zig has no loader decision for {s}", .{@tagName(os_tag)});
            @panic("build.zig internal error: no loader decision for this operating system");
        },
    }
}

/// Why a target has no buildable LMDB, or null when it has one.
const Refusal = struct {
    /// One line, printed with the operating system name in front of it.
    summary: []const u8,
    /// The long form printed before the build fails.
    detail: []const u8,
};

fn refusalFor(os_tag: std.Target.Os.Tag) ?Refusal {
    if (lockBackend(os_tag) != null) return null;

    if (os_tag == .wasi) {
        return .{
            .summary = "LMDB has no buildable configuration for this target: there is no shared-lock backend.",
            .detail =
            \\mdb.c needs exactly one shared-lock implementation and offers four
            \\candidates, at mdb.c:175-231: the native Win32 mutex, a
            \\process-shared POSIX mutex, a POSIX named semaphore, and a SysV
            \\semaphore. Its fallback POSIX-mutex arm requires a mutex object
            \\stored in genuinely process-shared memory, with crash recovery.
            \\WASI has no POSIX named-semaphore or SysV-semaphore backend.
            \\Its pthread_mutexattr_setrobust rejects robust locking.
            \\Zig's optional wasi-emulated-mman does provide <sys/mman.h>
            \\and mmap, but implements a malloc/pread snapshot, not shared
            \\file mappings or write-back; msync is unavailable.
            \\WASI threads share one module's memory, not independent processes.
            \\Neither facility supplies LMDB's shared locking and persistence.
            \\
            \\MDB_NOLOCK is not used as a substitute, and is not a build
            \\configuration: it is a runtime flag for mdb_env_set_flags that
            \\drops the reader liveness table and the cross-process write lock.
            \\Building against it would produce a smaller and weaker library
            \\than the one pinned above, with different failure behaviour after
            \\a crash, so this package refuses the target instead.
            \\
            \\Build for a target this package names a backend for:
            \\x86_64-linux-gnu, aarch64-linux-gnu, riscv64-linux-gnu,
            \\aarch64-macos-none, x86_64-windows-gnu.
            ,
        };
    }

    return .{
        .summary = "no shared-lock backend is selected for this operating system.",
        .detail =
        \\mdb.c's ladder at mdb.c:175-231 has arms for Apple, the BSDs, Haiku
        \\and POSIX systems generally. This build names a decision for Linux,
        \\Apple - macOS and macCatalyst, the three BSDs and Windows; an
        \\operating system outside that set has no recorded decision here. That
        \\is not an aesthetic limit. The choice changes MDB_LOCK_TYPE
        \\(mdb.c:965-981), which is recorded in the lock file itself, so
        \\an environment opened with one backend cannot be opened by a build
        \\that chose another.
        \\
        \\Add the operating system to lockBackend above and to
        \\loaderSystemLibraries below. Leave its macro list empty when mdb.c's
        \\own ladder already selects a backend for the target's predefines -
        \\that is what the BSDs do - and name one only where upstream's ladder
        \\cannot reach a decision on its own.
        \\The six-target check matrix above is a compile-only baseline and is
        \\deliberately not widened by this; a target is selected by
        \\`-Dtarget=`.
        ,
    };
}

/// Prints why `target` cannot be built, and fails the build.
///
/// This is a real refusal, not a warning and not a stub: `zig build` and
/// `zig build check -Dtarget=<this target>` both stop here, and the text this
/// prints is what `.github/workflows/verify.yml` asserts on.
fn refuseTarget(b: *std.Build, target: std.Build.ResolvedTarget) error{UnsupportedTarget} {
    const refusal = refusalFor(target.result.os.tag) orelse
        @panic("build.zig internal error: refusalFor returned null for a target lockBackend accepted");
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    std.log.err("lmdb: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    return error.UnsupportedTarget;
}

/// Everything a dependent needs: the Zig facade with its translated C import
/// already bound, and the library itself when this package built it.
const LmdbPackage = struct {
    module: *std.Build.Module,
    /// Null in `-fsys=lmdb` mode, where the library is the system one.
    artifact: ?*std.Build.Step.Compile,
};

const LmdbOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// `-Dlinkage`: which of upstream's two forms of this library to build.
    /// Static is the default and is what this package has always delivered;
    /// dynamic builds the same three objects the way upstream's `.lo` rules
    /// build them. It says nothing about an installed library.
    linkage: std.builtin.LinkMode,
    /// Which kind of *installed* library `-fsys=lmdb` binds to. Dynamic unless
    /// `-Dlinkage` was actually given, because that is what
    /// `Module.linkSystemLibrary` already does when no preference is passed
    /// (`lib/std/Build/Module.zig`, `SystemLib.preferred_link_mode`). A plain
    /// `-fsys=lmdb` has to keep binding what it binds today, and the artifact
    /// default says nothing about this, so it is a separate field with its own
    /// default rather than a second reading of `linkage`.
    system_linkage: std.builtin.LinkMode,

    /// `-Druntime`: whether the facade reaches the native library through a
    /// link line or through a table an explicit `load` fills. It says nothing
    /// about which artifact is built, which is `linkage`; the two are read
    /// independently and neither implies the other.
    runtime_loaded: bool,
    /// `-fsys=lmdb`: link and translate the installed library and header
    /// instead of building this repository's.
    use_system: bool,
    /// Whether to register the facade as the package's public `lmdb` module.
    /// The cross-target matrix needs the private form: modules are registered
    /// by name against the whole build graph, so registering `lmdb` once per
    /// cross target would leave only the last of them reachable and silently
    /// stop checking the rest.
    register_module: bool,
};

/// `translate.h`, preprocessed for the target being built.
///
/// `zig translate-c` reads C with Aro, and Aro is not the preprocessor this
/// repository's C is compiled by. `lmdb.h:171-173` includes `<sys/types.h>`,
/// so every translation drags in the target's own C library headers, and on
/// eleven of the published 53-platform matrix targets those headers do not
/// survive that read:
///
///   * every NetBSD target, nine of them. `__END_DECLS` is
///     `__END_PUBLIC_DECLS` (`generic-netbsd/sys/cdefs.h:432`), which ends in
///     `_Pragma("GCC visibility pop")` (:413); Aro 0.16 leaves the pragma in
///     the token stream instead of executing it, and the trailing
///     `__END_DECLS` of `sys/types.h:263`, `sys/endian.h:74` and
///     `sys/bswap.h:23` each stop parsing with "unknown type name 'pragma'"
///     (`local://foundation-cross-test-matrix-lmdb-*-netbsd.log`).
///   * `mips64-openbsd` and `mips64el-openbsd`.
///     `generic-openbsd/mips64/endian.h:40` refuses to define `BYTE_ORDER`
///     unless `__MIPSEL__` or `__MIPSEB__` is defined and Aro's MIPS
///     predefined macro table defines neither
///     (`local://foundation-cross-test-matrix-lmdb-mips64-openbsd.log`).
///
/// Each is a property of the translator rather than of this header, and the
/// local repair in either case would be to invent the predefine the real
/// compiler supplies: `-D__MIPSEL__`, or a replacement for `_Pragma`. Those
/// macros decide what the C library headers mean, so faking them would
/// describe a target that does not exist. The compiler that compiles the C
/// core for these same targets is the one that already reads both correctly,
/// so the header goes through it first and the translator reads the result.
/// Both steps were run on the real headers for the two families above and
/// both exit zero (`local://foundation-cross-test-header-preprocessing.json`).
///
/// `-dD` keeps the `#define` lines beside the expanded text, so a macro a C
/// caller reads as a macro still reaches Zig as a constant: without it
/// `c.MDB_REVERSEKEY` (zig/root.zig:612), `c.MDB_CURRENT` (:1355) and
/// `c.MDB_NODUPDATA` (:1371) are expanded away and stop existing. The
/// `_Pragma` directives come through as the `#pragma` lines a preprocessor
/// emits, which is the form the translator already reads from a system
/// header. `c_flags` is not repeated here: it is a code-generation flag the
/// preprocessor neither needs nor acts on, and the translation line is given
/// no `-D` today either.
fn preprocessedHeader(b: *std.Build, options: LmdbOptions) std.Build.LazyPath {
    // `b.graph.zig_exe` is the compiler running this build script, so the
    // preprocessor is the same pinned one the C core is compiled by.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-dD" });
    run.setName("preprocess lmdb.h");
    if (!options.target.query.isNative()) {
        const triple = options.target.query.zigTriple(b.allocator) catch @panic("OOM");
        run.addArg("-target");
        run.addArg(triple);
    }
    // The bundled header, the same directory the C core is compiled against,
    // so `<lmdb.h>` names the header the core was built with and not a
    // header some system include path happens to carry. It is a `-I` of the
    // preprocessor rather than of the translation line because the preprocessed
    // file is what the translation line reads, and by then there is no
    // `#include` left in it to resolve.
    run.addPrefixedDirectoryArg("-I", b.path(upstream.source_dir));
    run.addArg("-o");
    const preprocessed = run.addOutputFileArg("lmdb_preprocessed.c");
    run.addFileArg(b.path(translate_header));
    return preprocessed;
}

fn addLmdb(b: *std.Build, options: LmdbOptions) error{UnsupportedTarget}!LmdbPackage {
    const backend = lockBackend(options.target.result.os.tag) orelse
        return refuseTarget(b, options.target);

    const translate_c = b.addTranslateC(.{
        // translate.h is nothing but `#include <lmdb.h>`, and which lmdb.h
        // that names is the whole content of this step. In the default mode
        // the translator reads what `zig cc` produced from that header for
        // this target, so the declarations it translates are the ones the
        // archive below was built against; `preprocessedHeader` says why, and
        // says what is on that line. In `-fsys` mode it reads the file itself,
        // which reaches the installed header through the target's own include
        // path.
        .root_source_file = if (options.use_system)
            b.path(translate_header)
        else
            preprocessedHeader(b, options),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    if (options.use_system) {
        // The installed header, and proof that an installed library exists at
        // all. `.force`, not `.yes`: on a failed query `.yes` falls back to a
        // bare `-llmdb`, which is a library that may not exist, and a
        // translation that silently finds no lmdb.h is worse than a build that
        // stops. No in-tree include path is added here, so the bare include in
        // translate.h can only resolve to the header installed next to the
        // library being linked.
        translate_c.linkSystemLibrary(pkg_config_name, .{ .use_pkg_config = .force });
    }

    const module_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path(facade_root),
        .target = options.target,
        // The requested mode, unmodified. Zig 0.16.0 mis-assigns the SSE
        // registers of an `extern "C"` call that has seven or more
        // integer-class arguments (spglib/build.zig:382-399 records that
        // observation for this compiler), so a facade needs a reason to build
        // its caller optimised in Debug. LMDB's widest public prototype takes
        // five parameters, so that boundary is outside this surface and this
        // build applies no override; if a future lmdb.h grows a wider entry
        // point, that is where the workaround belongs.
        .optimize = options.optimize,
        .link_libc = true,
    };
    const module = if (options.register_module)
        b.addModule(module_name, module_options)
    else
        b.createModule(module_options);
    // The runtime seam, and the only place in this file where the two
    // configurations differ in *what the module carries*.
    //
    // Linked, unchanged: the translated header is the `c` import, registered
    // when this is the package's published module, and the loader core is
    // imported as `rt` because the facade's own `LoadSource`/`LoadError` are
    // public types that have to be the same types a caller names in either
    // configuration (`zig/root.zig:243`, :264, :270). `runtime/graph.zig` says
    // the same thing from the other side, and that nothing of that module is
    // compiled in this configuration, so it costs two declarations here.
    //
    // Runtime-loaded: `c` is the generated dispatch instead, it is never
    // registered - a dependent has no business importing generated types under
    // `dep.module("c")` - and no `rt` import is added, because the dispatch
    // re-exports the two types from the core instance it built itself. The
    // facade's `@import("rt")` is resolved only where it is referenced, and the
    // comptime branch at `zig/root.zig:256` never reaches it in this branch.
    if (options.runtime_loaded) {
        module.addImport(c_import_name, runtime_graph.createModule(
            b,
            translate_c,
            options.target,
            options.optimize,
        ));
    } else {
        module.addImport(c_import_name, if (options.register_module)
            translate_c.addModule(c_import_name)
        else
            translate_c.createModule());
        module.addImport(rt_import_name, runtime_graph.createCoreModule(
            b,
            options.target,
            options.optimize,
        ));
    }

    var artifact: ?*std.Build.Step.Compile = null;
    if (options.use_system) {
        // The installed library, through the same `lmdb.pc` the translation
        // above queried. `.force` on both the translation and this facade keeps
        // the selected header and the link metadata coherent, and the first
        // named link entry wins.
        //
        // Guarded: under `-Druntime` the platform loader resolves the entry
        // points itself, so a hard link here would defeat that mode.
        if (!options.runtime_loaded) module.linkSystemLibrary(pkg_config_name, .{
            .use_pkg_config = .force,
            .preferred_link_mode = options.system_linkage,
        });
    } else {
        // Consumers that compile their own C against this module need the same
        // header the library was compiled with.
        module.addIncludePath(b.path(upstream.source_dir));

        // `.link_libc` on the core module below, plus the loader's system
        // library added to it a few lines further down, is the whole link
        // configuration. Upstream's own records put `-pthread` on the line
        // (liblmdb/Makefile:24, and `Libs: -llmdb -ldl -pthread` in lmdb.pc),
        // and it is repeated in the `zig cc` steps of
        // .github/workflows/verify.yml for the plain C consumers that link the
        // installed artifact directly. It is not repeated here because Zig's
        // libc carries the POSIX threads entry points inside libc itself on
        // every target this build supports, and asking the linker for a
        // separate libpthread
        // would turn a library that is already complete into a search for a
        // file that only exists on the machine running the build. `-ldl` is a
        // different matter and is not dropped: `module.c` is in the core and
        // calls it, which is why it is the one upstream puts on every tool's
        // line (liblmdb/Makefile:97-105) and in the installed `Libs:`.
        const core = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            // Zig leaves `Module.sanitize_c` null unless a module says
            // otherwise, and null emits no `-fsanitize-c` flag at all
            // (lib/std/Build/Module.zig:558-562), so the compiler's own
            // default stands; spglib's build.zig:521-524 records that default
            // as sanitising C sources in Debug. mdb.c is built on unsigned
            // wraparound in page, transaction and reader IDs, and on
            // narrowing conversions ISO C leaves undefined, which is exactly
            // the class of code that turns into diagnostics. The optimization
            // mode is untouched; only the C sanitizer is off.
            .sanitize_c = .off,
        });
        core.addIncludePath(b.path(upstream.source_dir));
        for (backend.macros) |macro| core.addCMacro(macro.name, macro.value);
        // The loader's system library is declared here, on the module that owns
        // `module.c`, and not once per program that links the result. Zig
        // carries a static library's own link objects onto the link line of
        // everything that links it
        // (lib/std/Build/Step/Compile.zig:1064-1088), so this one declaration
        // reaches the facade, the tests, the smoke program, the
        // interoperability program and upstream's `mdb_dump` - the same reach
        // upstream records for `-ldl` (liblmdb/Makefile:97-105, :158).
        //
        // For a static archive the entry is inert here - `zig build-lib` runs
        // no linker, and the archive carries the three upstream objects
        // unchanged - and it is what resolves `mdb_modload`'s `dlopen` in a
        // program that pulls `module.o` out of that archive. For the shared
        // object the same declaration is on the library's own link line, so
        // the loader records liblmdb's own dependency on `libdl`
        // (`lib/std/Build/Step/Compile.zig:1088-1159`), and a program linking
        // the shared object is right not to repeat it. It is a plain `-l` and
        // not a forced `-needed-l`: `module.o` really calls `dl*`, so
        // `--as-needed` keeps the entry exactly when the loader is used and
        // drops it when nothing pulls that object out of an archive.
        for (loaderSystemLibraries(options.target.result.os.tag)) |system_lib| {
            core.linkSystemLibrary(system_lib, .{ .use_pkg_config = .no });
        }
        core.addCSourceFiles(.{
            .root = b.path(upstream.source_dir),
            .files = &core_sources,
            // `-fPIC` for the shared object, and nothing added for the archive:
            // that one difference between upstream's `.lo` and `.o` rules is
            // all this option reaches in the C compiler line. `coreCFlags` says
            // why Windows is not given it.
            .flags = coreCFlags(options.linkage, options.target.result.os.tag),
        });
        // No -D for anything else. `_GNU_SOURCE`, `_FILE_OFFSET_BITS`, the
        // `BROKEN_FDATASYNC` probe, `MDB_DSYNC`, `MDB_RPAGE_CACHE` and
        // `MDB_USE_PWRITEV` are all decided inside mdb.c from the target's own
        // predefined macros. Setting any of them here from a configure run on
        // another machine would put one target's feature macros on another.
        artifact = b.addLibrary(.{
            .name = module_name,
            // Static is the default and is the artifact this package has always
            // produced; `-Dlinkage=dynamic` builds the same three objects as a
            // shared library. The version is the pinned release either way, and
            // in the shared case it is what gives the installed file its
            // `liblmdb.so.1` and `liblmdb.so` links - the same ABI series
            // string upstream's own soname names (`liblmdb/Makefile:56-57`).
            // Nothing is exported or hidden beyond what upstream ships: no
            // version script and no `-fvisibility=hidden` (`:90-94`), so the
            // shared object exports the non-static definitions of the three
            // units, which is upstream's own arrangement.
            .linkage = options.linkage,
            .version = upstream.version,
            .root_module = core,
        });
        // Deliberately absent under `-Druntime`. The artifact above is still
        // built and still installed - delivery and dispatch are separate
        // questions, and the point of the mode is that a caller may name a
        // provider this tree did not build - but linking it into this module
        // would let the linker resolve those symbols first, and the runtime
        // route would quietly be a linked one. Nothing else in the graph may
        // reference the archive for the same reason; the installed tools and
        // the interoperability oracle are separate executables that link it
        // deliberately, and neither imports `c`.
        if (!options.runtime_loaded) module.linkLibrary(artifact.?);
    }

    return .{ .module = module, .artifact = artifact };
}

/// Compiles, and never runs, the library, the tests, the smoke program and the
/// interoperability program for one target of the matrix.
///
/// Compiling those programs is what makes this a check of the facade rather
/// than of an unreferenced archive: Zig analyses a function body only when
/// something calls it, the tests call every public entry point, and the C
/// library is on the link line of all of them. Nothing here executes a target
/// binary, so every result is compile evidence for that target and not a claim
/// that a cross-built program ran.
///
/// The interoperability program is on this line for the same reason the others
/// are: a harness that compares this library with a reference one rots the
/// moment it stops being compiled, and a harness that never compiles is not
/// evidence of anything. What this step does not do is run it - the run is
/// `interop`, below, and only for a target this host can execute. The
/// linkage is the one the command line asked for, so the same matrix can be
/// compiled against the archive and against the shared object.
fn addTargetCheck(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) error{UnsupportedTarget}!void {
    const triple = query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    const cross_target = b.resolveTargetQuery(query);
    // The matrix always builds from this repository's sources: a system
    // liblmdb on the host says nothing about a foreign target, and the
    // refusal for a target with no lock backend has to come from this
    // repository's own decision table rather than from what happens to be
    // installed here.
    const graph = try addLmdb(b, .{
        .target = cross_target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime_loaded = runtime_loaded,
        // Unused here and deliberately so: this graph is never the system one.
        .system_linkage = linkage,
        .use_system = false,
        .register_module = false,
    });

    const test_artifact = b.addTest(.{
        .name = b.fmt("lmdb-tests-{s}", .{triple}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_root),
            .target = cross_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = module_name, .module = graph.module }},
        }),
    });
    step.dependOn(&test_artifact.step);

    const smoke_artifact = b.addExecutable(.{
        .name = b.fmt("lmdb-smoke-{s}", .{triple}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(smoke_root),
            .target = cross_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = module_name, .module = graph.module }},
        }),
    });
    step.dependOn(&smoke_artifact.step);

    const interop_artifact = b.addExecutable(.{
        .name = b.fmt("lmdb-interop-{s}", .{triple}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(interop_root),
            .target = cross_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = module_name, .module = graph.module }},
        }),
    });
    step.dependOn(&interop_artifact.step);
}

/// Builds the upstream reference tool and runs the interoperability program
/// against it, so the comparison that decides the fixture is made between this
/// package's writer and upstream's own reader.
///
/// The oracle is a program built here, out of the unmodified sources in this
/// repository, linked against the same core artifact and the same `lmdb.h` the
/// facade's translation came from. That is deliberate: an `mdb_dump` found on
/// the machine running the build would be some other version of the reader,
/// and agreeing with it would say nothing about the pin this package names.
///
/// Like the matrix, this always builds from this repository's sources whatever
/// `-fsys` says. The question here is whether *this* library and *upstream's*
/// reader agree; a system liblmdb answers a different one.
///
/// Both artifacts are built for whichever target was asked for, and the
/// program is run only when this host can execute that target
/// (`hostCanExecute`), which is the same rule `consumer` follows and for the
/// same reason. A target with no executor here is compiled without the
/// comparison, which is compile evidence and nothing more. The reference tool
/// is linked against the artifact the command line asked for, so the same
/// fixture is measured against the archive and against the shared object.
fn addInterop(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) error{UnsupportedTarget}!void {
    const backend = lockBackend(target.result.os.tag) orelse
        return refuseTarget(b, target);

    const graph = try addLmdb(b, .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime_loaded = runtime_loaded,
        // Unused here, as above: the oracle is always this repository's.
        .system_linkage = linkage,
        .use_system = false,
        .register_module = false,
    });

    const interop = b.addExecutable(.{
        .name = "lmdb-interop",
        .root_module = b.createModule(.{
            .root_source_file = b.path(interop_root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = module_name, .module = graph.module }},
        }),
    });

    const tools = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // The C sanitizer is off for the same reason and with the same
        // reading as it is for the core; see the note on `core` above.
        .sanitize_c = .off,
    });
    tools.addIncludePath(b.path(upstream.source_dir));
    for (backend.macros) |macro| tools.addCMacro(macro.name, macro.value);
    // Only the tool's own translation unit is compiled here. Everything else
    // `mdb_dump` needs is the library this package just built: `tools` links it
    // below. Under the archive that link also brings the loader's system
    // library with it, because the archive is produced by `core`, which is
    // where that dependency is declared, and Zig re-emits a static library's
    // own link objects for everything that links it
    // (`lib/std/Build/Step/Compile.zig:1064-1088`); under the shared object the
    // dependency is already recorded inside it and this executable reaches the
    // library through an rpath Zig adds for that case
    // (`lib/std/Build/Step/Compile.zig:1192-1199`), which is what lets the tool
    // be run out of the cache. Either way it is upstream's own arrangement
    // rather than a local one - `mdb_dump: mdb_dump.o liblmdb.a`, linked with
    // `$(LDL)` (liblmdb/Makefile:100-101), from an archive that already
    // contained `module.o` (liblmdb/Makefile:87-88).
    tools.addCSourceFiles(.{
        .root = b.path(upstream.source_dir),
        .files = &tool_sources,
        .flags = &c_flags,
    });
    tools.linkLibrary(graph.artifact.?);
    const reference = b.addExecutable(.{
        .name = "mdb_dump",
        .root_module = tools,
    });

    step.dependOn(&interop.step);
    step.dependOn(&reference.step);
    if (!hostCanExecute(b, target)) return;

    const run_interop = b.addRunArtifact(interop);
    run_interop.setName("mdb_dump interoperability");
    // One argument, so a path with a space in it stays one argument.
    run_interop.addPrefixedArtifactArg("--dump=", reference);
    // The program writes an environment into a scratch directory and removes
    // it again, so there is nothing here whose up-to-dateness could be
    // cached: the run is the result.
    run_interop.has_side_effects = true;
    step.dependOn(&run_interop.step);
}

/// The rpath an installed executable in this package needs, or null where the
/// platform has no such notion.
///
/// `bin/<program>` and `lib/lib<name>` are siblings under one prefix, so
/// `$ORIGIN/../lib` is the ELF spelling and `@loader_path/../lib` the Mach-O
/// one. Windows has neither: a DLL beside the executable is what its loader
/// looks for, and `liblmdb.dll` installs into `bin/` for exactly that reason.
///
/// Zig has already added an rpath to the library's own location in the build
/// cache to every executable that links a dynamic artifact
/// (`lib/std/Build/Step/Compile.zig:1192-1199`), which is what lets such a
/// program run out of the cache. This one is what lets the installed copy find
/// the installed library after the cache is gone. In the static variant it is an
/// unused entry and costs nothing.
fn installedRPath(os_tag: std.Target.Os.Tag) ?[]const u8 {
    return switch (os_tag) {
        .windows => null,
        .macos, .maccatalyst => "@loader_path/../lib",
        else => "$ORIGIN/../lib",
    };
}

/// Installs every carried licence text and provenance record under
/// `share/licenses/lmdb/`.
///
/// These are copies of files already in this repository, byte for byte;
/// nothing is rewritten, merged or truncated on the way out. `b.installFile`
/// takes a repository path and attaches its own step to the install step
/// (`lib/std/Build.zig:1675-1677`), so this needs no separate `dependOn` —
/// which is why the list above, and not a directory copy, is what makes the
/// install complete: a missing entry is a build failure naming the file.
fn installLicenceRecords(b: *std.Build) void {
    for (licence_records) |record| {
        b.installFile(record.source, b.fmt("share/licenses/{s}/{s}", .{ module_name, record.installed }));
    }
}

/// The link libraries a consumer of the *archive* has to add itself, read out
/// of the same per-target table the core's own link line is built from so the
/// two can never disagree about what a target needs.
fn pkgConfigPrivateLibs(b: *std.Build, os_tag: std.Target.Os.Tag) []const u8 {
    const system_libs = loaderSystemLibraries(os_tag);
    if (system_libs.len > 1) @panic("lmdb: build.zig internal error: more than one loader library for this operating system");
    // `-pthread` is upstream's own record (`THREADS`, liblmdb/Makefile:24) and
    // is not a flag on Windows, where the threads entry points are in the C
    // runtime itself.
    if (os_tag == .windows) {
        return if (system_libs.len == 0) "" else b.fmt("-l{s}", .{system_libs[0]});
    }
    if (system_libs.len == 0) return "-pthread";
    return b.fmt("-l{s} -pthread", .{system_libs[0]});
}

/// The `lmdb.pc` this variant needs, generated rather than copied.
///
/// Upstream generates one from its Makefile (liblmdb/Makefile:147-158) with a
/// single line for the library and a single line for everything a consumer has
/// to link beside it. Two facts make one line wrong for this package.
///
/// The first is that the two variants need different things. The archive's
/// `module.o` calls `dlopen`, so a static consumer needs the loader library and
/// the threads flag on its own link line; the shared object records both
/// itself, so a consumer that repeated them would link state the loaded library
/// already has. That is what `Libs.private` is for, and why it is only emitted
/// for the static variant: pkg-config adds `Libs.private` to a `--static`
/// query and leaves it out of an ordinary one, which is exactly the
/// distinction being recorded here.
///
/// The second is that only one of those libraries is a real file on any given
/// target: `-ldl` is a GNU/Linux name, there is no separate `libdl` on Darwin
/// or the BSDs, and the Windows loader entry points come from `kernel32`.
/// `pkgConfigPrivateLibs` reads that out of `loaderSystemLibraries` rather than
/// repeating it.
///
/// `Version:` is this pin, 1.0.1, where upstream's own rule hardcodes 1.0.0
/// (`LMDB_VERSION = 1.0.0`, liblmdb/Makefile:36) for the same 1.0.1 sources: a
/// generated file that misreports the library it sits next to is worse than
/// one that reports the release the sources came from.
///
/// `prefix` is derived from this file's own directory so the metadata is
/// correct wherever the prefix lands, which is what both `zig build install
/// --prefix` and a Nix output need. That spelling needs pkg-config 0.29 or
/// newer, or pkgconf; it is the reason the file says so rather than
/// hardcoding `/usr/local` the way upstream's rule does.
///
/// `Cflags` carries the `-I${includedir}` that upstream's rule never writes.
/// Its `Cflags: $(THREADS) $(XCFLAGS)` (liblmdb/Makefile:157) names the threads
/// flag and nothing else, because `XCFLAGS` is assigned nowhere in that
/// Makefile and expands empty — so upstream's file defines `includedir`
/// (`:150`), defines `libdir` (`:151`), and then never puts either on a
/// `Cflags:` or `Libs:` line. A consumer that takes `pkg-config --cflags lmdb`
/// gets no include path at all and cannot find `lmdb.h`, in an installed
/// prefix or any other. Both fields are written here, against the same
/// `includedir` and `libdir` the installed header and library actually live
/// under.
fn pkgConfigFile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    linkage: std.builtin.LinkMode,
) std.Build.LazyPath {
    // `-I${includedir}` is unconditional: there is exactly one installed
    // `lmdb.h`, on every target, and `installHeader` puts it under
    // `<prefix>/include`, which is what this resolves to. `-pthread` is
    // upstream's own record (`THREADS`, liblmdb/Makefile:24) and is not a flag
    // on Windows, where the threads entry points are in the C runtime itself.
    const cflags: []const u8 = if (target.result.os.tag == .windows)
        "-I${includedir}"
    else
        "-I${includedir} -pthread";
    const private = if (linkage == .dynamic)
        ""
    else
        pkgConfigPrivateLibs(b, target.result.os.tag);
    // The shared object records the loader and threads dependencies itself, so
    // there is nothing left for a `--static` consumer to resolve and the field
    // is dropped rather than emitted empty. A file ending in a bare
    // `Libs.private:` reads as an answer that was lost rather than as the
    // deliberate empty one it is, and `pkg-config --static --libs lmdb` cannot
    // tell the two apart either.
    const private_field: []const u8 = if (private.len == 0)
        ""
    else
        b.fmt("Libs.private: {s}\n", .{private});

    return b.addWriteFiles().add("lmdb.pc", b.fmt(
        \\# Generated by lmdb/build.zig from the sources in this package. Do not edit.
        \\# `prefix` is this file's own directory, so the metadata is right wherever
        \\# the prefix is placed; that spelling needs pkg-config 0.29+ or pkgconf.
        \\prefix=${{pcfiledir}}/../..
        \\exec_prefix=${{prefix}}
        \\includedir=${{prefix}}/include
        \\libdir=${{prefix}}/lib
        \\
        \\Name: lmdb (OpenLDAP)
        \\Description: OpenLDAP Lightning Memory Mapped Database library
        \\URL: https://www.openldap.org
        \\Version: {f}
        \\Cflags: {s}
        \\Libs: -L${{libdir}} -llmdb
        \\{s}
        \\
    , .{ upstream.version, cflags, private_field }));
}

/// Keeps the two halves of the matrix honest against each other.
///
/// The whole point of naming `refused_check_targets` is that the row is not
/// quietly absent, and the point of naming `supported_check_targets` is that
/// every row in it is real. Both are re-derived here through the same two
/// functions `build()` and `addTargetCheck` use, so an edit that adds a
/// backend, or a triple that stops resolving, fails any build of this package
/// rather than quietly shrinking what `check` proves.
fn checkMatrixPartition(b: *std.Build) void {
    for (supported_check_targets) |triple| {
        const resolved = b.resolveTargetQuery(parseTriple(b, triple));
        if (refusalFor(resolved.result.os.tag) != null) {
            @panic(b.fmt(
                "build.zig: {s} is in supported_check_targets but this build refuses its operating system",
                .{triple},
            ));
        }
    }
    for (refused_check_targets) |triple| {
        const resolved = b.resolveTargetQuery(parseTriple(b, triple));
        if (refusalFor(resolved.result.os.tag) == null) {
            @panic(b.fmt(
                "build.zig: {s} is in refused_check_targets but lockBackend now names a backend for it; move it to supported_check_targets and prove it builds",
                .{triple},
            ));
        }
    }
}

/// Resolves a target triple written the way `zig build -Dtarget=` writes it.
///
/// A triple is parsed into `std.Target.Query` through `Query.ParseOptions`,
/// whose `arch_os_abi` field holds the string; `std.Build.parseTargetQuery`
/// (lib/std/Build.zig) is the same entry point `standardTargetOptions` uses, so
/// this and `-Dtarget=` agree on what a triple means.
fn parseTriple(b: *std.Build, triple: []const u8) std.Target.Query {
    return std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch |err| {
        @panic(b.fmt("build.zig: {s} is not a target triple: {s}", .{ triple, @errorName(err) }));
    };
}

/// Runs the consumer package as its own `zig build` in `consumer/`.
///
/// The consumer is a separate package on purpose: a manifest dependency here
/// would close a cycle, because its manifest points back at this package by
/// path. Running it as a separate build is what makes the proof real - that a
/// package which only writes `b.dependency("lmdb", ...)` and
/// `dep.module("lmdb")` gets a working library.
///
/// The step is `run` for a target this host can execute (`hostCanExecute`) and
/// `install` for one it cannot, because a cross-compiled consumer binary does
/// not run here unless an executor was enabled for it, and a step that quietly
/// installed instead of running is the one thing this step exists to prevent.
///
/// Both shape options are forwarded, because `consumer/build.zig` declares both
/// and passes them into `b.dependency`: a consumer proof that silently built a
/// different graph from the one it was asked to prove would prove nothing. The
/// consumer program itself already handles the runtime shape - it calls
/// `load(.{ .path = ... })` under `lmdb.runtime_loaded` and reports which it
/// did (`consumer/src/main.zig:278-291`).
///
/// Everything else this build resolved travels with it. The target arrives as
/// the caller's *query* plus the CPU that query names, because the nested
/// graph runs this package's `build()` again as a path dependency and resolves
/// both from its own options; so does the system-integration choice, in the
/// spelling the runner knows and in both of its values. Then the executor
/// switches, both cache directories, the install prefix, the job width and
/// summary every `zig build` entry in this workspace is run with, and the
/// caller's own trailing `--` arguments. An argument left behind would not be
/// a smaller proof, it would be a proof of a configuration nobody asked for.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    use_system: bool,
    scratch: ?[]const u8,
    provider: ?[]const u8,
) *std.Build.Step.Run {
    const query = target.query;
    // `addArg` copies each argument, so these temporaries can go right after.
    const triple = query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    const cpu = query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // `b.graph.zig_exe` is the compiler running this build script, so the
    // nested build is the same toolchain rather than whatever is on PATH.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    // The CPU model and its feature set, which the triple does not carry:
    // `Query.zigTriple` spells arch, OS, versions and ABI, and `cpu` is a
    // separate standard option (`lib/std/Build.zig:1479-1483`). Written
    // unconditionally, in the same shape `std.Build` itself hands a
    // `ResolvedTarget` to a dependency (`lib/std/Build.zig:451-461`), so the
    // nested graph compiles the consumer this graph would have compiled.
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // The two options the consumer package declares for itself and hands to
    // `b.dependency`, spelled the way the build system spells them so that the
    // nested graph is the one this graph is. Forwarded unconditionally rather
    // than only when set: a nested build that resolved its own defaults could
    // prove a configuration nobody asked for.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    run.addArg(b.fmt("-Druntime={}", .{runtime_loaded}));
    // The system-integration choice, in the spelling the build runner knows
    // (`lib/compiler/build_runner.zig:1579-1580`) and in both of its values
    // rather than only the true one. `b.systemIntegrationOption` has already
    // resolved it to the answer this build acted on
    // (`lib/std/Build.zig:2726-2753`); the nested graph resolves it again from
    // its own runner record, and with no argument that record holds nothing, so
    // the nested graph falls back to its own default - bundled sources. What is
    // left is a step that reads as `zig build consumer -fsys=lmdb` and proves a
    // consumer compiled against this repository's copy rather than the
    // installed library the outer graph was configured with.
    run.addArg(if (use_system) "-fsys=lmdb" else "-fno-sys=lmdb");
    // The two values the consumer *program* needs, handed to the nested build
    // because a build script cannot reach a program's own arguments except
    // through one. They are passed only when given: the program reads
    // `LMDB_TEST_SCRATCH` and `LMDB_TEST_PROVIDER` as alternatives, refuses to
    // invent a database location, never consults `TMPDIR` and never touches
    // `/tmp` or the source tree, so a value invented here would be a database
    // the caller never agreed to.
    if (scratch) |dir| run.addArg(b.fmt("-Dscratch={s}", .{dir}));
    if (provider) |path| run.addArg(b.fmt("-Dprovider={s}", .{path}));
    // The executor switches this build resolved, so the nested build runs under
    // the same one `hostCanExecute` decided with: `-fwasmtime` is how a WASI
    // consumer executes here, and `--libc-runtimes` is the QEMU integration's
    // dynamic-linker support (`lib/compiler/build_runner.zig:325`).
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // The job width and the summary this workspace runs every `zig build`
    // entry with (`AGENTS.md`, verification interface). The runner reads `-j`
    // from its own argv and from nowhere else
    // (`lib/compiler/build_runner.zig:422-427`), and nothing can append one to
    // a `Run` step's command, so a nested build left without it derives its
    // own width - and the consumer this step proves then compiles at a
    // different width from the build that asked for it, and at a different
    // width again on whichever machine runs the gate. `--summary all` is two
    // tokens because the runner takes the mode as the next argument
    // (`lib/compiler/build_runner.zig:262-265`), and `all` is what prints the
    // steps this proof is made of rather than only the failures.
    run.addArg("-j8");
    run.addArgs(&.{ "--summary", "all" });
    // A null `path` means "the current directory", and the working directory is
    // already the consumer package, so the default is right. Two arguments,
    // not one `--cache-dir=...`: that is the form the build system emits to
    // the compiler itself, not to the build runner.
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // The global cache is inherited whole rather than given a subdirectory of
    // its own: it is the store the compiler resolves packages from, beside the
    // pinned lib directory (`lib/std/Build.zig:122-123`), so the nested build
    // has to resolve the one this build was given rather than one of its own.
    // Two arguments, the spelling the runner documents
    // (`lib/compiler/build_runner.zig:1675`) and the shape the build system
    // itself uses when it invokes the compiler
    // (`lib/std/Build/Step/Compile.zig:1478-1479`). Without the argument, a
    // caller who selected a global cache on this build's command line finds the
    // nested build resolving one of its own somewhere else.
    //
    // There is no guard on the path and no default for it, because that runner
    // builds the directory with its path set unconditionally
    // (`lib/compiler/build_runner.zig:73-76`, assigned to the graph at `:89`).
    // A null would mean this build was not started by that runner, and a
    // directory invented here would be a cache nobody selected - so the build
    // stops and says so instead.
    run.addArg("--global-cache-dir");
    run.addArg(b.graph.global_cache_root.path orelse
        @panic("build.zig: no global cache directory was set by the build runner"));
    // The install prefix this invocation resolved, handed on when the caller
    // named one. Left to its own resolution, the nested build installs into
    // `consumer/zig-out`: a build artefact inside a source package, rather than
    // the directory the caller asked for. A relative `--prefix` would resolve
    // against the working directory set above, `consumer/`, and not against
    // this build's root, so it is made absolute before it is handed on.
    // `DESTDIR` needs no forwarding, because the nested build inherits the
    // environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // The caller's own arguments, last and behind `--`, which is where
    // `consumer/build.zig:94` already picks them up and hands them to the
    // program. `-Dscratch` and `-Dprovider` above are the same two values
    // spelled as build options, and the program reads both spellings out of the
    // same argv (`consumer/src/main.zig:218`, `:245`), so a caller who wrote
    // `zig build consumer -- --scratch <dir>` reaches the program this step
    // runs rather than a nested build that never heard of the argument.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    // The nested build is the step's only observable effect.
    run.has_side_effects = true;
    return run;
}

/// True when this host can execute `target`'s binaries.
///
/// `std.zig.system.getExternalExecutor` (`lib/std/zig/system.zig:42`) is the
/// predicate `std.Build.Step.Run` asks about the artifact it is about to spawn
/// (`lib/std/Build/Step/Run.zig:1268`).  That replaces a predicate which could
/// not answer it: `Target.Query.isNative()` (`lib/std/Target/Query.zig:396-398`)
/// is `isNativeTriple() and ofmt == null`, and `isNativeTriple()` (`:392-394`)
/// demands `cpu_arch`, `os_tag` and `abi` all be null, so
/// `-Dtarget=x86_64-linux-gnu` was never "native" on an x86_64 Linux host:
/// `consumer` installed the nested build instead of running it, and `interop`
/// compiled its two programs and compared nothing.
///
/// Both options `Run` fills in from the artifact are filled in here from the
/// same facts: every executable this package runs links libc, and QEMU reaches
/// a foreign dynamic linker only with `--libc-runtimes`.  Its `need_cross_libc`
/// (`lib/std/Build/Step/Run.zig:1264-1266`) additionally asks for
/// `exe.linkage == .dynamic` on the musl half, and both executables are built
/// with `b.addExecutable` and no linkage, so that field is null there and the
/// half never contributes.
///
/// An external executor counts as available only when the build runner was
/// told it may use one: `-fwasmtime`, `-fqemu`, `-fwine` and `-fdarling` are
/// the build runner's own switches for that (`lib/compiler/build_runner.zig:388-407`,
/// exposed as `b.enable_wasmtime` and friends, `lib/std/Build.zig:71-79`), and
/// each names a separate program whose presence on `PATH` this script cannot
/// know.  `-frosetta` names none and `std.Build` reads `enable_rosetta`
/// nowhere, so it is forwarded for fidelity and never gates the decision.  A
/// target that still has no executor builds and installs, which is compile
/// evidence and nothing more.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // `Run`'s QEMU arm (`lib/std/Build/Step/Run.zig:1290-1314`) appends
        // `-L <runtime triple>` for a cross libc target and, with
        // `b.libc_runtimes_dir` unset, `failForeign` on `--libc-runtimes`
        // (`:1310`) instead of skipping the run. So on this target the missing
        // directory is not a skip but a failure, and the answer has to be no.
        //
        // `qemu_fixes_dl` above cannot carry that: `getExternalExecutor` enters
        // the QEMU arm for a foreign CPU on `!cpu_ok` alone
        // (`lib/std/zig/system.zig:95`), whatever that option says, so the
        // returned executor is `.qemu` in exactly the case the option stops
        // describing. `isGnuLibC` is the whole of `Run`'s `need_cross_libc`
        // here — every executable this build runs links libc, and none is
        // given a `linkage`, so the musl half never holds — and the two now
        // test the same fact.
        .qemu => !candidate.isGnuLibC() or b.libc_runtimes_dir != null,
        // Reachable only for an executor the switches above enabled, each of
        // which `Run` gates on the same switch and nothing else.
        .wine, .wasmtime, .darling => true,
        // Same OS and CPU with no dynamic linker to load, or an architecture
        // and system this build has no enabled executor for.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_system = b.systemIntegrationOption(pkg_config_name, .{});

    // Whether the facade reaches the native library through a link line or
    // through a table an explicit `load` fills. Default false, so every command
    // that exists today produces exactly the graph it produced before this
    // option did. Orthogonal to `-Dlinkage`: the artifact is built and
    // installed either way, and nothing in this file reads one to decide the
    // other.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. The facade keeps the same translated header and the same public types; each selected native function becomes a call through a table an explicit load(source) fills. The library is still built and installed; a caller may name either the provider this build produced or a compatible one",
    ) orelse false;

    // Which of upstream's two forms of the library to build. Static is the
    // default and is what this package has always delivered, so every command
    // that exists today still produces the artifact it produced before this
    // option did; the spelling is the enum's own (`-Dlinkage=static`,
    // `-Dlinkage=dynamic`), the same option name spglib and pcre2 use for
    // their own libraries.
    const linkage_option = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Build the LMDB artifact as a static archive (default) or as a shared library; named, it is also the preference -fsys=lmdb binds an installed liblmdb with",
    );
    const linkage = linkage_option orelse .static;

    // Two defaults, and the difference is deliberate rather than subtle. The
    // artifact this package builds is static unless asked otherwise; the
    // installed library `-fsys=lmdb` binds to is whatever the platform prefers
    // unless asked otherwise, which `Module.linkSystemLibrary` already makes
    // the shared one. An unqualified system build therefore changes nothing.
    const system_linkage = linkage_option orelse .dynamic;

    // build.zig.zon must not drift away from the release this build pins.
    const package_version = std.SemanticVersion.parse(manifest.version) catch {
        @panic("build.zig.zon: .version is not a semantic version");
    };
    if (package_version.order(upstream.version) != .eq) {
        @panic("build.zig.zon .version no longer matches the pinned upstream release");
    }

    // The shared object this build produces has to sit in the ABI series
    // upstream's own soname names, and Zig takes that series from the major
    // component of the version above. A release that moved the soname fails
    // here rather than shipping a library another tool's loader would not bind.
    if (upstream.version.major != upstream.soname_major) {
        @panic("lmdb: the pinned release's major version no longer matches liblmdb/Makefile's LIBVER");
    }

    // Every matrix row, supported or refused, is re-derived here before
    // anything is configured, on every invocation and not only on `check`.
    checkMatrixPartition(b);

    // Refused before anything else, so `-fsys=lmdb` cannot turn a refused
    // target into a different one, and so `check -Dtarget=<refused>` fails at
    // configure time with the reason rather than reaching the compiler.
    if (lockBackend(target.result.os.tag) == null) return refuseTarget(b, target);

    const graph = try addLmdb(b, .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime_loaded = runtime_loaded,
        .system_linkage = system_linkage,
        .use_system = use_system,
        .register_module = true,
    });

    if (graph.artifact) |artifact| {
        // The same decision `addLmdb` just made for the core, bound here
        // because the installed tools are compiled with it too - and bound in
        // this branch rather than above it, since in `-fsys=lmdb` mode this
        // whole block is not reached and nothing below needs it.
        const backend = lockBackend(target.result.os.tag) orelse
            return refuseTarget(b, target);

        b.installArtifact(artifact);
        // Installing the header also puts it on the include path of anything
        // that links this artifact, so a dependent that wants the C API does
        // not have to reach into this repository's tree for it. lmdb.h is the
        // only header upstream installs (`IHDRS = lmdb.h`,
        // liblmdb/Makefile:49); midl.h stays internal.
        artifact.installHeader(b.path(upstream.source_dir ++ "/lmdb.h"), "lmdb.h");

        // The link metadata this variant needs, generated rather than copied:
        // `pkgConfigFile` says what separates the two variants and why.
        // `addInstallFile` creates the step without attaching it to the install
        // step (`lib/std/Build/Step/InstallFile.zig:15-36`), so the dependency
        // is declared here rather than assumed; `b.installFile` below is the
        // form that attaches it.
        const pkg_config_install = b.addInstallFile(
            pkgConfigFile(b, target, linkage),
            "lib/pkgconfig/lmdb.pc",
        );
        b.getInstallStep().dependOn(&pkg_config_install.step);

        // Upstream's installed tool set - `IPROGS`, liblmdb/Makefile:52 - each
        // one built from the sources in this repository and linked against the
        // artifact above; `installed_tools` says why that is the same
        // arrangement upstream uses, and what it means under
        // `-Dlinkage=dynamic`. Its manual page is installed beside it, as
        // `IDOCS` (:53) is at :78. The tools are not in `check` and not in the
        // six-target matrix: they are the delivery, and this is where the
        // delivery is built.
        for (installed_tools) |tool| {
            const tool_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                // Off for the same reason, and with the same reading, as it is
                // for the core module above.
                .sanitize_c = .off,
            });
            tool_module.addIncludePath(b.path(upstream.source_dir));
            for (backend.macros) |macro| tool_module.addCMacro(macro.name, macro.value);
            tool_module.addCSourceFiles(.{
                .root = b.path(upstream.source_dir),
                .files = &.{tool.source},
                // No `-fPIC` whatever the linkage is: an executable is not a
                // shared object, and upstream's own tool rules add nothing to
                // theirs either (liblmdb/Makefile:141-145).
                .flags = &c_flags,
            });
            tool_module.linkLibrary(artifact);
            // Zig has already put an rpath to the library's place in the build
            // cache on this executable, which is what lets it be run out of the
            // cache. This one is what lets the installed copy find the
            // installed library once the cache is gone.
            if (installedRPath(target.result.os.tag)) |rpath| tool_module.addRPathSpecial(rpath);
            b.installArtifact(b.addExecutable(.{
                .name = tool.name,
                .root_module = tool_module,
            }));
            b.installFile(
                b.fmt("{s}/{s}", .{ upstream.source_dir, tool.man_page }),
                b.fmt("share/man/man1/{s}", .{tool.man_page}),
            );
        }

        // The terms that have to travel with a redistributed LMDB, byte for
        // byte out of the pinned tree: the OpenLDAP Public License v2.8 text
        // upstream ships as `LICENSE` and its own `COPYRIGHT` notice.
        // Upstream's install rule copies neither
        // (liblmdb/Makefile:65-78), which is a gap in upstream's install and
        // not an exemption: whoever receives the library still needs them.
        for (licence_files) |file| {
            b.installFile(b.fmt("{s}/{s}", .{ upstream.source_dir, file }), b.fmt("share/lmdb/{s}", .{file}));
        }

        // And the fork's own half of the same obligation, in the same directory.
        for (provenance_files) |file| {
            b.installFile(file, b.fmt("share/lmdb/{s}", .{file}));
        }

        // And the same obligation again at `share/licenses/lmdb/`, which is
        // where a package's terms are looked for by name and where the rest of
        // this workspace installs them. `share/lmdb/` above keeps every one of
        // these paths, so this adds the licence location rather than moving
        // the existing one.
        installLicenceRecords(b);
    }

    // `zig build` compiles the smoke program but does not run it: it is the
    // cheapest proof that the facade, the translated header and the library
    // agree on types, symbols and link-time dependencies, and a build that
    // executed a database would leave files behind.
    // Installed beside the library, so the shared variant needs the same rpath
    // an installed tool needs. In the static variant it is an unused entry and
    // nothing else changes.
    const smoke_module = b.createModule(.{
        .root_source_file = b.path(smoke_root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = module_name, .module = graph.module }},
    });
    if (installedRPath(target.result.os.tag)) |rpath| smoke_module.addRPathSpecial(rpath);
    const smoke = b.addExecutable(.{
        .name = "lmdb-smoke",
        .root_module = smoke_module,
    });
    b.getInstallStep().dependOn(&smoke.step);

    // `zig build test`: addTest compiles the behavioural tests and
    // addRunArtifact runs them. The test root is `tests.zig` itself, so a step
    // that discovers no tests and exits zero is not a possibility here the way
    // it is behind a re-exporting root.
    const test_artifact = b.addTest(.{
        .name = "lmdb-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = module_name, .module = graph.module }},
        }),
    });
    b.step("test", "Run the behavioural tests").dependOn(&b.addRunArtifact(test_artifact).step);

    // `zig build smoke`. A run artifact already depends on building the
    // executable, which depends on compiling the C core and linking the facade.
    // This deliberately does not depend on the install step: installing is
    // `zig build`'s job, and a smoke run that depended on the install layout
    // would be a different gate.
    const run_smoke = b.addRunArtifact(smoke);
    const smoke_step = b.step("smoke", "Run the deterministic smoke program");
    smoke_step.dependOn(&run_smoke.step);
    if (b.args) |args| run_smoke.addArgs(args);

    // `zig build check` compiles the C core, the facade, the tests, the smoke
    // program and the interoperability program without running any of them, so
    // a foreign target can be analysed on any host. Given `-Dtarget`, it checks
    // that one target and nothing else; without one, it walks
    // `supported_check_targets`. The refused row is not compiled and is not
    // omitted either: checkMatrixPartition re-derived and confirmed it above,
    // and asking for it by name fails with the printed reason.
    const check_step = b.step(
        "check",
        "Compile the C core, the facade, the tests, the smoke program and the interoperability program for the target matrix without running them",
    );
    if (!target.query.isNative()) {
        try addTargetCheck(b, check_step, target.query, optimize, linkage, runtime_loaded);
    } else {
        for (supported_check_targets) |triple| {
            try addTargetCheck(b, check_step, parseTriple(b, triple), optimize, linkage, runtime_loaded);
        }
    }

    // `zig build interop`. The reference interoperability gate, and the only
    // one in this package where neither half of the comparison is this
    // package's own wrapper: upstream's `mdb_dump`, built from the sources in
    // this repository, reads the environment this facade wrote and the two
    // bodies are compared byte for byte. It is deliberately not part of
    // `test` or `smoke` - both of those are gates a driver runs on every
    // commit of this package, and this one builds and runs two programs
    // instead of one.
    const interop_step = b.step(
        "interop",
        "Build upstream mdb_dump and compare its -p output with the fixture, byte for byte",
    );
    try addInterop(b, interop_step, target, optimize, linkage, runtime_loaded);

    // The consumer package is not part of the matrix: it is its own `zig
    // build`, run from inside consumer/. This step is that same proof driven
    // from here, so a consumer can be built or run for a target chosen on the
    // command line without changing directory.

    // Where the consumer program may put its one scratch environment, and which
    // provider a runtime-loaded consumer should open. Both exist because the
    // program requires them to be named: `consumer/src/main.zig` creates a
    // randomly named child of `--scratch` and removes that child and nothing
    // else, and under `-Druntime` it opens the `--provider` shared object before
    // anything else. Neither has a default here either - the program's own
    // message names what is missing, which is a better error than a directory
    // this file made up. A run therefore needs `-Dscratch=<dir>`, or
    // `LMDB_TEST_SCRATCH` in its environment, and under `-Druntime` a provider
    // named the same way.
    const scratch = b.option(
        []const u8,
        "scratch",
        "Directory the consumer program may create its one scratch database under; passed to it as --scratch <dir>. Ignored by every step but `consumer`",
    );
    const provider = b.option(
        []const u8,
        "provider",
        "Shared object a runtime-loaded consumer program should open, passed to it as --provider <path>. Needed only with -Druntime, and only by the `consumer` step",
    );
    const consumer_step = b.step(
        "consumer",
        "Build the consumer package in consumer/ against dep.module(\"lmdb\"), and run it when this host can execute the selected target",
    );
    consumer_step.dependOn(&runConsumer(
        b,
        target,
        optimize,
        linkage,
        runtime_loaded,
        use_system,
        scratch,
        provider,
    ).step);
}

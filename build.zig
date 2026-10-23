//! Build graph for the LMDB package: compile the C core, bind the Zig facade, and install its outputs.

// SPDX-License-Identifier: OLDAP-2.8
// See FORK-LICENSE.md for fork-authored files; vendored files retain upstream terms.

const std = @import("std");

const manifest = @import("build.zig.zon");

/// Runtime helpers build the loader from the translated C import.
/// The linked branch uses `createCoreModule`; runtime graph owns shared loader types.
const runtime_graph = @import("runtime/graph.zig");

/// Upstream identity and version; the build checks the version against the manifest.
const upstream = struct {
    const repository = "https://github.com/LMDB/lmdb.git";
    const ref = "LMDB_1.0.1";
    const commit = "6f0a32496a5aadee15a5e5103c479bd3355ae273";

    /// Version declared by upstream's public header.
    const version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 1 };

    /// Shared-library ABI major; it must match upstream's soname.
    const soname_major: u32 = 1;

    /// Directory containing the vendored C core.
    const source_dir = "libraries/liblmdb";
};

/// The library comprises these three upstream C translation units.
/// Keep the list explicit so tools and tests cannot enter the core.
const core_sources = [_][]const u8{
    "mdb.c",
    "midl.c",
    "module.c",
};

/// Upstream mdb_dump source used as the interoperability reference.
const tool_sources = [_][]const u8{
    "mdb_dump.c",
};

/// Upstream tools installed with their manual pages.
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

/// Upstream license and copyright files installed verbatim.
const licence_files = [_][]const u8{
    "LICENSE",
    "COPYRIGHT",
};

/// Fork provenance records installed beside upstream legal files.
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

/// Source-to-installed names for records copied under share/licenses/lmdb/.
const licence_records = [_]struct { source: []const u8, installed: []const u8 }{
    .{ .source = "libraries/liblmdb/LICENSE", .installed = "LICENSE" },
    .{ .source = "libraries/liblmdb/COPYRIGHT", .installed = "COPYRIGHT" },
    .{ .source = "NOTICE.md", .installed = "NOTICE.md" },
    .{ .source = "FORK-LICENSE.md", .installed = "FORK-LICENSE.md" },
    .{ .source = "UPSTREAM.md", .installed = "UPSTREAM.md" },
    .{ .source = "FORK-NOTES.md", .installed = "FORK-NOTES.md" },
    .{ .source = "UPSTREAM.sha256", .installed = "UPSTREAM.sha256" },
};

/// GNU17 is required by mdb.c's language extensions.
const c_flags = [_][]const u8{
    "-std=gnu17",
};

/// Shared non-Windows builds add PIC; static builds use the default flags.
fn coreCFlags(linkage: std.lang.LinkMode, os_tag: std.Target.Os.Tag) []const []const u8 {
    if (linkage == .dynamic and os_tag != .windows) return &.{ "-std=gnu17", "-fPIC" };
    return &c_flags;
}

/// Fork-authored Zig roots and tests compiled by this build.
const facade_root = "zig/root.zig";
const test_root = "tests.zig";
const smoke_root = "smoke.zig";
const interop_root = "testdata/interop.zig";

/// Header input for Zig translation.
const translate_header = "translate.h";

/// Public module, C import, and pkg-config names.
const module_name = "lmdb";
const c_import_name = "c";
const pkg_config_name = "lmdb";

/// Internal loader import for linked builds.
const rt_import_name = "rt";

/// Targets included in the default cross-check matrix.
const supported_check_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "aarch64-macos-none",
    "x86_64-windows-gnu",
    "riscv64-linux-gnu",
};

/// wasm32-wasi is refused because it has no LMDB lock backend.
const refused_check_targets = [_][]const u8{
    "wasm32-wasi",
};

/// Macro selection for the target's shared-lock backend.
const LockBackend = struct {
    /// Explicit C macros select one lock implementation.
    macros: []const Macro,
};

const Macro = struct { name: []const u8, value: []const u8 };

/// Select the shared-lock implementation from the target OS.
fn lockBackend(os_tag: std.Target.Os.Tag) ?LockBackend {
    return switch (os_tag) {
        // Linux uses robust process-shared POSIX mutexes.
        .linux => .{ .macros = &.{
            .{ .name = "MDB_USE_POSIX_MUTEX", .value = "1" },
            .{ .name = "MDB_USE_ROBUST", .value = "1" },
        } },

        // Darwin uses POSIX named semaphores; leave MDB_USE_ROBUST undefined.
        // This matches mdb.c's Apple branch, which has no owner-death recovery.
        .macos, .maccatalyst => .{ .macros = &.{
            .{ .name = "MDB_USE_POSIX_SEM", .value = "1" },
        } },

        // Windows uses native mutex APIs without selection macros.
        .windows => .{ .macros = &.{} },

        // Leave BSD selection to mdb.c; the chosen lock type affects lock-file compatibility.
        .freebsd, .netbsd, .openbsd => .{ .macros = &.{} },

        else => null,
    };
}

/// Target-specific system libraries used by module.c's dynamic loader.
fn loaderSystemLibraries(os_tag: std.Target.Os.Tag) []const []const u8 {
    switch (os_tag) {
        // GNU/Linux resolves dlfcn calls from libdl.
        .linux => return &.{"dl"},

        // Win32 loader APIs are provided by kernel32.
        .windows => return &.{"kernel32"},

        // Darwin resolves dl* from libSystem; no extra library is needed.
        .macos, .maccatalyst => return &.{},

        // BSD systems provide dl* without a separate libdl.
        .freebsd, .netbsd, .openbsd => return &.{},

        // Refuse unlisted operating systems rather than omit loader dependencies.
        else => {
            std.log.err("lmdb: build.zig has no loader decision for {s}", .{@tagName(os_tag)});
            @panic("build.zig internal error: no loader decision for this operating system");
        },
    }
}

const Refusal = struct {
    summary: []const u8,
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

/// Fails with the reason an unsupported target cannot build LMDB.
fn refuseTarget(b: *std.Build, target: std.Build.ResolvedTarget) error{UnsupportedTarget} {
    const refusal = refusalFor(target.result.os.tag) orelse
        @panic("build.zig internal error: refusalFor returned null for a target lockBackend accepted");
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    std.log.err("lmdb: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    return error.UnsupportedTarget;
}

/// Module and optional artifact produced for a dependency.
const LmdbPackage = struct {
    module: *std.Build.Module,
    /// Null when using the installed system library.
    artifact: ?*std.Build.Step.Compile,
};

const LmdbOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// Linkage for the bundled artifact.
    linkage: std.lang.LinkMode,
    /// Linkage requested from an installed system library.
    system_linkage: std.lang.LinkMode,

    /// Resolve C symbols at runtime instead of linking them.
    runtime_loaded: bool,
    /// Use the installed library and header instead of bundled sources.
    use_system: bool,
    /// Register the public module; cross-target builds keep it private.
    register_module: bool,
};

/// Preprocess the target's LMDB header with the build compiler before Zig translation.
/// This avoids Aro failures on some target headers and preserves macro definitions.
fn preprocessedHeader(b: *std.Build, options: LmdbOptions) std.Build.LazyPath {
    // Use the target compiler to preprocess the bundled header.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-dD" });
    run.setName("preprocess lmdb.h");
    if (!options.target.query.isNative()) {
        const triple = options.target.query.zigTriple(b.allocator) catch @panic("OOM");
        run.addArg("-target");
        run.addArg(triple);
    }
    // Include the bundled header; the preprocessed input has no includes left.
    run.addDirectoryArg2(b.path(upstream.source_dir), .{ .prefix = "-I" });
    run.addArg("-o");
    const preprocessed = run.addOutputFileArg2("lmdb_preprocessed.c", .{});
    run.addFileArg2(b.path(translate_header), .{});
    return preprocessed;
}

fn addLmdb(b: *std.Build, options: LmdbOptions) error{UnsupportedTarget}!LmdbPackage {
    const backend = lockBackend(options.target.result.os.tag) orelse
        return refuseTarget(b, options.target);

    const translate_c = b.addTranslateC(.{
        // Bundled builds translate the target-preprocessed header; system mode reads its installed header.
        .root_source_file = if (options.use_system)
            b.path(translate_header)
        else
            preprocessedHeader(b, options),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    if (options.use_system) {
        // Require installed pkg-config metadata and the paired header in system mode.
        // Do not fall back to an unverified library or bundled include path.
        translate_c.linkSystemLibrary(pkg_config_name, .{ .use_pkg_config = .force });
    }

    const module_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path(facade_root),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    };
    const module = if (options.register_module)
        b.addModule(module_name, module_options)
    else
        b.createModule(module_options);
    // Linked mode imports translated C and the loader core; runtime mode uses generated dispatch.
    // The runtime graph owns the shared LoadSource and LoadError types.
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
        // Use the installed library metadata selected for translation.
        // Runtime-loaded mode resolves symbols through its dispatch table.
        if (!options.runtime_loaded) module.linkSystemLibrary(pkg_config_name, .{
            .use_pkg_config = .force,
            .preferred_link_mode = options.system_linkage,
        });
    } else {
        // Expose the same bundled header used to compile the library.
        module.addIncludePath(b.path(upstream.source_dir));

        // Attach loader libraries to the core so dependents inherit them.
        // pthread symbols come from libc on supported targets.
        const core = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            .sanitize_c = .off,
        });
        core.addIncludePath(b.path(upstream.source_dir));
        for (backend.macros) |macro| core.addCMacro(macro.name, macro.value);
        // Declare loader libraries on the core so static dependents inherit them.
        // Shared libraries record their loader dependency directly.
        for (loaderSystemLibraries(options.target.result.os.tag)) |system_lib| {
            core.linkSystemLibrary(system_lib, .{ .use_pkg_config = .no });
        }
        core.addCSourceFiles(.{
            .root = b.path(upstream.source_dir),
            .files = &core_sources,
            // Shared builds add PIC where the target supports it.
            .flags = coreCFlags(options.linkage, options.target.result.os.tag),
        });
        // Let mdb.c select feature macros from the target compiler.
        artifact = b.addLibrary(.{
            .name = module_name,
            // Version sets the shared ABI name; exports follow upstream defaults.
            .linkage = options.linkage,
            .version = upstream.version,
            .root_module = core,
        });
        // Keep the artifact out of the facade in runtime-loading mode.
        if (!options.runtime_loaded) module.linkLibrary(artifact.?);
    }

    return .{ .module = module, .artifact = artifact };
}

/// Adds compile-only dependencies for the library and test programs.
/// Does not run target binaries.
fn addTargetCheck(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) error{UnsupportedTarget}!void {
    const triple = query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    const cross_target = b.resolveTargetQuery(query);
    // Matrix sub-builds always use bundled sources.
    const graph = try addLmdb(b, .{
        .target = cross_target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime_loaded = runtime_loaded,
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

/// Builds upstream mdb_dump and runs the interoperability comparison.
/// Executes only when this host can run the target.
fn addInterop(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) error{UnsupportedTarget}!void {
    const backend = lockBackend(target.result.os.tag) orelse
        return refuseTarget(b, target);

    const graph = try addLmdb(b, .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime_loaded = runtime_loaded,
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
        .sanitize_c = .off,
    });
    tools.addIncludePath(b.path(upstream.source_dir));
    for (backend.macros) |macro| tools.addCMacro(macro.name, macro.value);
    // Build mdb_dump from its upstream source and link this library.
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
    // Pass the artifact path as one argument.
    run_interop.addArtifactArg2(reference, .{ .prefix = "--dump=" });
    // The run mutates a scratch environment.
    run_interop.has_side_effects = true;
    step.dependOn(&run_interop.step);
}

/// Install-relative runtime path for binaries, or null where unsupported.
/// ELF and Mach-O use relative paths; Windows loads libraries beside executables.
fn installedRPath(os_tag: std.Target.Os.Tag) ?[]const u8 {
    return switch (os_tag) {
        .windows => null,
        .macos, .maccatalyst => "@loader_path/../lib",
        else => "$ORIGIN/../lib",
    };
}

/// Installs upstream license and fork provenance records under share/licenses/lmdb/.
fn installLicenceRecords(b: *std.Build) void {
    for (licence_records) |record| {
        b.installFile(record.source, b.fmt("share/licenses/{s}/{s}", .{ module_name, record.installed }));
    }
}

/// Extra link flags needed by static archive consumers.
fn pkgConfigPrivateLibs(b: *std.Build, os_tag: std.Target.Os.Tag) []const u8 {
    const system_libs = loaderSystemLibraries(os_tag);
    if (system_libs.len > 1) @panic("lmdb: build.zig internal error: more than one loader library for this operating system");
    // Windows thread entry points come from the C runtime.
    if (os_tag == .windows) {
        return if (system_libs.len == 0) "" else b.fmt("-l{s}", .{system_libs[0]});
    }
    if (system_libs.len == 0) return "-pthread";
    return b.fmt("-l{s} -pthread", .{system_libs[0]});
}

/// Generates target-specific pkg-config metadata for installed LMDB.
/// When required, static consumers get loader/thread flags in Libs.private; shared ones do not.
/// Cflags includes the installed header directory and the version matches the pin.
fn pkgConfigFile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    linkage: std.lang.LinkMode,
) std.Build.LazyPath {
    // Include the installed header; omit -pthread on Windows.
    const cflags: []const u8 = if (target.result.os.tag == .windows)
        "-I${includedir}"
    else
        "-I${includedir} -pthread";
    const private = if (linkage == .dynamic)
        ""
    else
        pkgConfigPrivateLibs(b, target.result.os.tag);
    // Omit Libs.private when no private dependencies are needed.
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

/// Ensures the target list is fully partitioned into supported and refused targets.
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

/// Parse a target triple with the build system's target-query parser.
fn parseTriple(b: *std.Build, triple: []const u8) std.Target.Query {
    return std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch |err| {
        @panic(b.fmt("build.zig: {s} is not a target triple: {s}", .{ triple, @errorName(err) }));
    };
}

/// Builds the consumer package against the public module.
/// Runs it only when the target is host-native.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    use_system: bool,
    scratch: ?[]const u8,
    provider: ?[]const u8,
) *std.Build.Step.Run {
    const query = target.query;
    const triple = query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    const cpu = query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // Use this build's Zig executable for the nested build.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    // Forward the CPU model because the target triple does not include it.
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Forward both package-shaping options to the consumer build.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    run.addArg(b.fmt("-Druntime={}", .{runtime_loaded}));
    // Preserve whether the outer build uses bundled sources or the installed library.
    run.addArg(if (use_system) "-fsys=lmdb" else "-fno-sys=lmdb");
    // Forward caller-supplied scratch and provider paths only.
    if (scratch) |dir| run.addArg(b.fmt("-Dscratch={s}", .{dir}));
    if (provider) |path| run.addArg(b.fmt("-Dprovider={s}", .{path}));
    // Keep nested builds on the same job width and summary settings.
    run.addArg("-j8");
    run.addArgs(&.{ "--summary", "all" });
    // Use a separate local cache for the consumer package.
    run.addArg("--cache-dir");
    _ = run.addOutputDirectoryArg2("consumer-cache", .{ .make_absolute = true });
    for ([_][]const u8{ "ZIG_GLOBAL_CACHE_DIR", "ZIG_LIB_DIR" }) |name| {
        if (b.graph.environ_map.get(name)) |value| run.setEnvironmentVariable(name, value);
    }
    // Separate nested build options from arguments passed to its run step.
    run.addArg("--");
    run.addPassthruArgs();
    run.has_side_effects = true;
    return run;
}

/// Returns whether the target can run natively on this host.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = .dynamic,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, &target.result, options)) {
        .native => true,
        else => false,
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_system = b.systemIntegrationOption(pkg_config_name, .{});

    // Runtime loading is independent of artifact linkage.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. The facade keeps the same translated header and the same public types; each selected native function becomes a call through a table an explicit load(source) fills. The library is still built and installed; a caller may name either the provider this build produced or a compatible one",
    ) orelse false;

    // Select the library artifact form; static is the default.
    const linkage_option = b.option(
        std.lang.LinkMode,
        "linkage",
        "Build the LMDB artifact as a static archive (default) or as a shared library; named, it is also the preference -fsys=lmdb binds an installed liblmdb with",
    );
    const linkage = linkage_option orelse .static;

    // Installed system libraries default to dynamic linkage.
    const system_linkage = linkage_option orelse .dynamic;

    // Keep the manifest version aligned with the upstream pin.
    const package_version = std.SemanticVersion.parse(manifest.version) catch {
        @panic("build.zig.zon: .version is not a semantic version");
    };
    if (package_version.order(upstream.version) != .eq) {
        @panic("build.zig.zon .version no longer matches the pinned upstream release");
    }

    // The shared ABI major must match upstream's soname.
    if (upstream.version.major != upstream.soname_major) {
        @panic("lmdb: the pinned release's major version no longer matches liblmdb/Makefile's LIBVER");
    }

    checkMatrixPartition(b);

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
        const backend = lockBackend(target.result.os.tag) orelse
            return refuseTarget(b, target);

        b.installArtifact(artifact);
        // Install the public lmdb.h; midl.h remains internal.
        artifact.installHeader(b.path(upstream.source_dir ++ "/lmdb.h"), "lmdb.h");

        // Attach the generated pkg-config file to the install step.
        const pkg_config_install = b.addInstallFile(
            pkgConfigFile(b, target, linkage),
            "lib/pkgconfig/lmdb.pc",
        );
        b.getInstallStep().dependOn(&pkg_config_install.step);

        // Build and install upstream tools with their manual pages.
        for (installed_tools) |tool| {
            const tool_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_c = .off,
            });
            tool_module.addIncludePath(b.path(upstream.source_dir));
            for (backend.macros) |macro| tool_module.addCMacro(macro.name, macro.value);
            tool_module.addCSourceFiles(.{
                .root = b.path(upstream.source_dir),
                .files = &.{tool.source},
                // Executable sources do not need PIC.
                .flags = &c_flags,
            });
            tool_module.linkLibrary(artifact);
            // Add the install-relative rpath for shared builds.
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

        // Install upstream LICENSE and COPYRIGHT with redistributed files.
        for (licence_files) |file| {
            b.installFile(b.fmt("{s}/{s}", .{ upstream.source_dir, file }), b.fmt("share/lmdb/{s}", .{file}));
        }

        // Install fork provenance beside upstream notices.
        for (provenance_files) |file| {
            b.installFile(file, b.fmt("share/lmdb/{s}", .{file}));
        }

        // Also install legal records under share/licenses/lmdb/.
        installLicenceRecords(b);
    }

    // Compile the smoke program in the install graph; leave execution to its step.
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

    // Build and run the behavioral test root.
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

    // Keep smoke execution separate from the install step.
    const run_smoke = b.addRunArtifact(smoke);
    const smoke_step = b.step("smoke", "Run the deterministic smoke program");
    smoke_step.dependOn(&run_smoke.step);
    run_smoke.addPassthruArgs();

    // Compile the selected target or full supported matrix without running binaries.
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

    // Run the upstream mdb_dump comparison as a separate step.
    const interop_step = b.step(
        "interop",
        "Build upstream mdb_dump and compare its -p output with the fixture, byte for byte",
    );
    try addInterop(b, interop_step, target, optimize, linkage, runtime_loaded);

    // Run the separate consumer package against this module.

    // The consumer requires named scratch storage; it never defaults to /tmp or the checkout.
    // Runtime mode also needs an explicit provider; no fallback is used.
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
        "Build the consumer package in consumer/ against dep.module(\"lmdb\"); run it only for a native target",
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

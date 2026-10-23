const std = @import("std");

/// Out-of-tree consumer for the published `lmdb` module.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Match the parent package's linkage and runtime defaults.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Which delivery form of the library to consume: a static archive (default) or a shared library",
    ) orelse .static;
    const runtime = b.option(
        bool,
        "runtime",
        "Consume the library in its runtime-loaded shape, where the facade reaches it through a table an explicit load(source) fills instead of a link line",
    ) orelse false;

    // Forward explicit paths; the program does not choose provider or scratch defaults.
    const scratch = b.option(
        []const u8,
        "scratch",
        "Directory the program may create its one scratch database under, passed to it as --scratch <dir>. It creates a randomly named child of it and removes that child and nothing else",
    );
    const provider = b.option(
        []const u8,
        "provider",
        "Shared object a runtime-loaded build should open, passed to it as --provider <path>. Needed only with -Druntime; a linked build reads no provider",
    );

    const dep = b.dependency("lmdb", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // LMDB's C core requires libc.
        .link_libc = true,
    });
    exe_mod.addImport("lmdb", dep.module("lmdb"));

    const exe = b.addExecutable(.{
        .name = "lmdb-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Build and run the consumer program");
    // Forward caller arguments after the build runner's `--`.
    if (scratch) |dir| run_exe.addArgs(&.{ "--scratch", dir });
    if (provider) |path| run_exe.addArgs(&.{ "--provider", path });
    if (b.args) |args| run_exe.addArgs(args);
    run_step.dependOn(&run_exe.step);
}

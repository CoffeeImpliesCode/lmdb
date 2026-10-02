const std = @import("std");

/// A package that consumes `lmdb` from outside.
///
/// This exists to prove one thing: that a dependent needs only
/// `dep.module("lmdb")` and gets a working, correctly linked library. No
/// include directory, no `-L`, no system library, no second module. If the
/// facade module stopped carrying its compiled C artifact, or the translated
/// header stopped matching the C source, this would stop building or stop
/// producing the right bytes, and nothing inside the library would notice.
///
/// Run it with `zig build run`. It exits non-zero when an observation
/// disagrees, so it is a check and not a demo.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("lmdb", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // The library's C core needs libc for its file, mapping and thread
        // primitives. Stating it here as well is redundant and keeps the
        // consumer's own requirement visible: this package is not portable to
        // a target without a C library either.
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
    run_step.dependOn(&run_exe.step);
}

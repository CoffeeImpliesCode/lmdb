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
///
/// The two shape options below are this package's own and are handed to the
/// dependency unchanged, because they name which configuration of *the
/// library* this consumer is proving. A proof that silently resolved its own
/// defaults instead would prove nothing. `zig build consumer` in the parent
/// forwards both, so `zig build consumer -Druntime=true` proves the
/// runtime-loaded shape here as well - and the program is already written for
/// it: it calls `load(.{ .path = ... })` under `lmdb.runtime_loaded` and prints
/// which shape it ran in (`consumer/src/main.zig:278-291`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The same two options `build.zig` declares, with the same defaults, so a
    // `zig build` here with no options proves exactly what `zig build consumer`
    // in the parent proves with none.
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

    // Two values that are handed to the *program*, not to this build. The
    // consumer program takes each as a flag and its value in the next argument
    // (`consumer/src/main.zig:254-264` matches the flag exactly and takes
    // `args[index + 1]`), so each is two arguments here rather than one
    // `--name=value` string - the `=` form would simply not be seen.
    //
    // Neither has a default here, and that is the point: the program refuses to
    // invent a database location and never consults `TMPDIR`, `/tmp` or the
    // source tree, so a caller that has not said where the environment goes
    // gets the program's own message naming what it needs rather than a
    // database somewhere nobody agreed to.
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
    // Two arguments per flag, and the program's own `--` arguments after them,
    // so `zig build run -- --scratch <dir>` reaches it without either option.
    if (scratch) |dir| run_exe.addArgs(&.{ "--scratch", dir });
    if (provider) |path| run_exe.addArgs(&.{ "--provider", path });
    if (b.args) |args| run_exe.addArgs(args);
    run_step.dependOn(&run_exe.step);
}

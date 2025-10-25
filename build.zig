const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (src/lib/root.zig)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build static library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zafxdp",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    // CLI executable (src/cmd/main.zig)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cmd/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("zafxdp_lib", lib_mod);

    const exe = b.addExecutable(.{
        .name = "zafxdp",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Library unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // E2E tests (src/lib/e2e_test.zig)
    const e2e_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    e2e_test_mod.addImport("xdp", lib_mod);

    const e2e_tests = b.addTest(.{
        .root_module = e2e_test_mod,
    });

    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    // Test steps
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const e2e_step = b.step("test-e2e", "Run end-to-end tests");
    e2e_step.dependOn(&run_e2e_tests.step);
}

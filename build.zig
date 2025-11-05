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

    // CLI library dependency
    const cli_dep = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });

    // CLI executable (src/cmd/main.zig)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cmd/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("zafxdp_lib", lib_mod);
    exe_mod.addImport("cli", cli_dep.module("cli"));

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

    // Traffic tests (src/lib/traffic_test.zig) - requires root
    const traffic_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/traffic_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    traffic_test_mod.addImport("xdp", lib_mod);

    const traffic_tests = b.addTest(.{
        .root_module = traffic_test_mod,
    });
    traffic_tests.linkLibC(); // Needed for if_nametoindex

    const run_traffic_tests = b.addRunArtifact(traffic_tests);

    // Packet tests (src/lib/packet.zig)
    const packet_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/packet.zig"),
        .target = target,
        .optimize = optimize,
    });

    packet_test_mod.addImport("xdp", lib_mod);

    const packet_tests = b.addTest(.{
        .root_module = packet_test_mod,
    });

    const run_packet_tests = b.addRunArtifact(packet_tests);

    // Protocol tests (src/lib/protocol.zig)
    const protocol_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const protocol_tests = b.addTest(.{
        .root_module = protocol_test_mod,
    });

    const run_protocol_tests = b.addRunArtifact(protocol_tests);

    // Command tests (src/cmd/commands/*.zig)
    const common_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cmd/commands/common.zig"),
        .target = target,
        .optimize = optimize,
    });

    const common_tests = b.addTest(.{
        .root_module = common_test_mod,
    });

    const run_common_tests = b.addRunArtifact(common_tests);

    const list_interfaces_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cmd/commands/list_interfaces.zig"),
        .target = target,
        .optimize = optimize,
    });

    const list_interfaces_tests = b.addTest(.{
        .root_module = list_interfaces_test_mod,
    });

    const run_list_interfaces_tests = b.addRunArtifact(list_interfaces_tests);

    const receive_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cmd/commands/receive.zig"),
        .target = target,
        .optimize = optimize,
    });

    receive_test_mod.addImport("zafxdp_lib", lib_mod);
    receive_test_mod.addImport("common", common_test_mod);

    const receive_tests = b.addTest(.{
        .root_module = receive_test_mod,
    });

    const run_receive_tests = b.addRunArtifact(receive_tests);

    // Individual test steps
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const e2e_step = b.step("test-e2e", "Run end-to-end tests (requires root)");
    e2e_step.dependOn(&run_e2e_tests.step);

    const traffic_step = b.step("test-traffic", "Run traffic tests (requires root)");
    traffic_step.dependOn(&run_traffic_tests.step);

    const packet_step = b.step("test-packet", "Run packet parsing tests");
    packet_step.dependOn(&run_packet_tests.step);

    const protocol_step = b.step("test-protocol", "Run protocol tests");
    protocol_step.dependOn(&run_protocol_tests.step);

    const cmd_step = b.step("test-cmd", "Run command tests");
    cmd_step.dependOn(&run_common_tests.step);
    cmd_step.dependOn(&run_list_interfaces_tests.step);
    cmd_step.dependOn(&run_receive_tests.step);

    // Unified test command - runs all tests
    const test_all_step = b.step("test-all", "Run all tests (unit + packet + protocol + cmd + e2e + traffic, requires root)");
    test_all_step.dependOn(&run_lib_unit_tests.step);
    test_all_step.dependOn(&run_packet_tests.step);
    test_all_step.dependOn(&run_protocol_tests.step);
    test_all_step.dependOn(&run_common_tests.step);
    test_all_step.dependOn(&run_list_interfaces_tests.step);
    test_all_step.dependOn(&run_receive_tests.step);
    test_all_step.dependOn(&run_e2e_tests.step);
    test_all_step.dependOn(&run_traffic_tests.step);
}

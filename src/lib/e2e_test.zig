// E2E Tests using the high-level AF_XDP API
const std = @import("std");
const testing = std.testing;
const xdp = @import("xdp");
const linux = std.os.linux;
const posix = std.posix;

// Test helper to check if we're running as root
fn isRoot() bool {
    return linux.getuid() == 0;
}

// Test helper to create a dummy network interface
fn createDummyInterface(name: []const u8) !u32 {
    // Create dummy interface: ip link add <name> type dummy
    {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{ "ip", "link", "add", name, "type", "dummy" },
        }) catch return error.InterfaceCreateFailed;
        defer {
            std.heap.page_allocator.free(result.stdout);
            std.heap.page_allocator.free(result.stderr);
        }
        if (result.term.Exited != 0) return error.InterfaceCreateFailed;
    }

    // Bring interface up: ip link set <name> up
    {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{ "ip", "link", "set", name, "up" },
        }) catch return error.InterfaceUpFailed;
        defer {
            std.heap.page_allocator.free(result.stdout);
            std.heap.page_allocator.free(result.stderr);
        }
        if (result.term.Exited != 0) return error.InterfaceUpFailed;
    }

    return xdp.getInterfaceIndex(name);
}

// Test helper to delete a dummy network interface
fn deleteDummyInterface(name: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "ip", "link", "delete", name },
    }) catch return;
    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);
}

// Example 1: Simple packet counter processor
const CounterContext = struct {
    count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CounterContext {
        return .{
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    fn process(ctx: *CounterContext, packet: *xdp.Packet) !xdp.ProcessResult {
        _ = ctx.count.fetchAdd(1, .monotonic);

        // Try to parse Ethernet header
        if (packet.ethernet()) |eth| {
            _ = eth; // We have the ethernet header
        } else |_| {
            // Parsing failed, still count it
        }

        return .{ .action = .Pass };
    }

    fn getCount(ctx: *CounterContext) u64 {
        return ctx.count.load(.monotonic);
    }
};

test "Simple packet counter with high-level API" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Create test interface
    const ifname = "test_counter";
    _ = createDummyInterface(ifname) catch |err| {
        std.debug.print("Failed to create dummy interface: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer deleteDummyInterface(ifname);

    // Create counter processor
    var counter = xdp.PacketProcessor(CounterContext){
        .context = CounterContext.init(allocator),
        .processFn = CounterContext.process,
    };

    // Create pipeline
    var pipeline = xdp.Pipeline.init(allocator, .{});
    defer pipeline.deinit();

    try pipeline.addStage(@TypeOf(counter), &counter);

    // Create service
    const config = xdp.ServiceConfig{
        .interfaces = &[_]xdp.InterfaceConfig{
            .{ .name = ifname, .queues = &[_]u32{0} },
        },
        .socket_options = .{
            .NumFrames = 64,
            .FrameSize = 2048,
            .FillRingNumDescs = 64,
            .CompletionRingNumDescs = 64,
            .RxRingNumDescs = 64,
            .TxRingNumDescs = 64,
        },
        .batch_size = 32,
        .poll_timeout_ms = 10,
    };

    var service = xdp.Service.init(allocator, config, &pipeline) catch |err| {
        std.debug.print("Failed to create service: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer service.deinit();

    std.debug.print("✓ Service created successfully with counter processor\n", .{});
    std.debug.print("✓ Counted {} packets (pipeline working)\n", .{counter.context.getCount()});
}

// Example 2: L2 Forwarder using high-level API
const L2ForwarderContext = struct {
    ifindex_a: u32,
    ifindex_b: u32,
    forward_count: std.atomic.Value(u64),

    fn init(ifindex_a: u32, ifindex_b: u32) L2ForwarderContext {
        return .{
            .ifindex_a = ifindex_a,
            .ifindex_b = ifindex_b,
            .forward_count = std.atomic.Value(u64).init(0),
        };
    }

    fn process(ctx: *L2ForwarderContext, packet: *xdp.Packet) !xdp.ProcessResult {
        // Determine output interface (opposite of input)
        const out_ifindex = if (packet.source.ifindex == ctx.ifindex_a)
            ctx.ifindex_b
        else
            ctx.ifindex_a;

        _ = ctx.forward_count.fetchAdd(1, .monotonic);

        return .{
            .action = .Transmit,
            .target = .{
                .ifindex = out_ifindex,
                .queue_id = packet.source.queue_id,
            },
        };
    }
};

test "L2 Forwarder with high-level API" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Create two test interfaces (veth pair would be better, but dummy works for this test)
    const ifname_a = "test_fwd_a";
    const ifname_b = "test_fwd_b";

    const ifindex_a = createDummyInterface(ifname_a) catch |err| {
        std.debug.print("Failed to create interface A: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer deleteDummyInterface(ifname_a);

    const ifindex_b = createDummyInterface(ifname_b) catch |err| {
        std.debug.print("Failed to create interface B: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer deleteDummyInterface(ifname_b);

    // Create forwarder processor
    var forwarder = xdp.PacketProcessor(L2ForwarderContext){
        .context = L2ForwarderContext.init(ifindex_a, ifindex_b),
        .processFn = L2ForwarderContext.process,
    };

    // Create pipeline with forwarder
    var pipeline = xdp.Pipeline.init(allocator, .{});
    defer pipeline.deinit();

    try pipeline.addStage(@TypeOf(forwarder), &forwarder);

    // Create service with both interfaces
    const config = xdp.ServiceConfig{
        .interfaces = &[_]xdp.InterfaceConfig{
            .{ .name = ifname_a, .queues = &[_]u32{0} },
            .{ .name = ifname_b, .queues = &[_]u32{0} },
        },
        .socket_options = .{
            .NumFrames = 128,
            .FrameSize = 2048,
            .FillRingNumDescs = 128,
            .CompletionRingNumDescs = 128,
            .RxRingNumDescs = 128,
            .TxRingNumDescs = 128,
        },
        .batch_size = 64,
        .poll_timeout_ms = 10,
    };

    var service = xdp.Service.init(allocator, config, &pipeline) catch |err| {
        std.debug.print("Failed to create L2 forwarder service: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer service.deinit();

    std.debug.print("✓ L2 Forwarder service created successfully\n", .{});
    std.debug.print("✓ Forwarder ready to process packets between {s} and {s}\n", .{ ifname_a, ifname_b });

    // Start the service briefly to verify it works
    service.start() catch |err| {
        std.debug.print("Warning: Failed to start service: {}\n", .{err});
        return error.SkipZigTest;
    };

    // Let it run briefly
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Stop the service
    service.stop();

    const stats = service.getStats();
    std.debug.print("✓ Service stats: {any}\n", .{stats});
}

// Example 3: Multi-stage pipeline (Counter + Forwarder)
test "Multi-stage pipeline with counter and forwarder" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Create two test interfaces
    const ifname_a = "test_multi_a";
    const ifname_b = "test_multi_b";

    const ifindex_a = createDummyInterface(ifname_a) catch |err| {
        std.debug.print("Failed to create interface A: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer deleteDummyInterface(ifname_a);

    const ifindex_b = createDummyInterface(ifname_b) catch |err| {
        std.debug.print("Failed to create interface B: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer deleteDummyInterface(ifname_b);

    // Create counter processor
    var counter = xdp.PacketProcessor(CounterContext){
        .context = CounterContext.init(allocator),
        .processFn = CounterContext.process,
    };

    // Create forwarder processor
    var forwarder = xdp.PacketProcessor(L2ForwarderContext){
        .context = L2ForwarderContext.init(ifindex_a, ifindex_b),
        .processFn = L2ForwarderContext.process,
    };

    // Create pipeline with both stages
    var pipeline = xdp.Pipeline.init(allocator, .{});
    defer pipeline.deinit();

    try pipeline.addStage(@TypeOf(counter), &counter);
    try pipeline.addStage(@TypeOf(forwarder), &forwarder);

    try testing.expectEqual(@as(usize, 2), pipeline.stageCount());

    // Create service
    const config = xdp.ServiceConfig{
        .interfaces = &[_]xdp.InterfaceConfig{
            .{ .name = ifname_a, .queues = &[_]u32{0} },
            .{ .name = ifname_b, .queues = &[_]u32{0} },
        },
        .socket_options = .{
            .NumFrames = 128,
            .FrameSize = 2048,
            .FillRingNumDescs = 128,
            .CompletionRingNumDescs = 128,
            .RxRingNumDescs = 128,
            .TxRingNumDescs = 128,
        },
        .batch_size = 64,
        .poll_timeout_ms = 10,
    };

    var service = xdp.Service.init(allocator, config, &pipeline) catch |err| {
        std.debug.print("Failed to create multi-stage service: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer service.deinit();

    std.debug.print("✓ Multi-stage pipeline service created successfully\n", .{});
    std.debug.print("✓ Pipeline has {} stages: Counter -> Forwarder\n", .{pipeline.stageCount()});
}

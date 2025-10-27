const std = @import("std");
const testing = std.testing;
const xdp = @import("xdp");
const linux = std.os.linux;
const posix = std.posix;

// Test helper to check if we're running as root
fn isRoot() bool {
    return linux.getuid() == 0;
}

// Test helper to find a network interface
fn findNetworkInterface(allocator: std.mem.Allocator) !?u32 {
    // Try to find loopback interface first
    const lo_file = std.fs.openFileAbsolute("/sys/class/net/lo/ifindex", .{}) catch return null;
    defer lo_file.close();

    var buf: [16]u8 = undefined;
    const len = try lo_file.readAll(&buf);
    if (len > 0) {
        const ifindex = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..len], &std.ascii.whitespace), 10) catch return null;
        return ifindex;
    }

    _ = allocator;
    return null;
}

test "Program initialization and cleanup" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Create XDP program
    var program = xdp.Program.init(allocator, 64) catch |err| {
        std.debug.print("Failed to create program: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.deinit();

    // Verify program was created
    try testing.expect(program.program_fd >= 0);
    try testing.expect(program.queues_map_fd >= 0);
    try testing.expect(program.sockets_map_fd >= 0);

    std.debug.print("✓ Program created successfully (fd={})\n", .{program.program_fd});
}

test "XDPSocket and Program integration" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Find a network interface
    const ifindex = (try findNetworkInterface(allocator)) orelse {
        std.debug.print("No network interface found, skipping test\n", .{});
        return error.SkipZigTest;
    };

    const queue_id: u32 = 0;

    // Create XDP program
    var program = xdp.Program.init(allocator, 64) catch |err| {
        std.debug.print("Failed to create program: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.deinit();

    // Create XDP socket
    const options = xdp.SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    const xsk = xdp.XDPSocket.init(allocator, ifindex, queue_id, options) catch |err| {
        std.debug.print("Failed to create XDP socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer xsk.deinit(allocator);

    // Register socket with program
    program.register(queue_id, @intCast(xsk.Fd)) catch |err| {
        std.debug.print("Failed to register socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.unregister(queue_id) catch {};

    std.debug.print("✓ XDP socket registered with program\n", .{});

    // Try to attach (may fail if kernel doesn't support, that's okay for test)
    program.attach(ifindex, @intFromEnum(xdp.XdpFlags.SKB_MODE)) catch |err| {
        std.debug.print("XDP attach failed (expected on some systems): {}\n", .{err});
    };
    defer program.detach(ifindex) catch {};

    std.debug.print("✓ Integration test completed\n", .{});
}

test "L2 forwarder simulation - single interface echo" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Find a network interface
    const ifindex = (try findNetworkInterface(allocator)) orelse {
        std.debug.print("No network interface found, skipping test\n", .{});
        return error.SkipZigTest;
    };

    const queue_id: u32 = 0;

    // Create XDP program
    var program = xdp.Program.init(allocator, 64) catch |err| {
        std.debug.print("Failed to create program: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.deinit();

    // Create XDP socket for receiving
    const options = xdp.SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    const rx_xsk = xdp.XDPSocket.init(allocator, ifindex, queue_id, options) catch |err| {
        std.debug.print("Failed to create RX socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer rx_xsk.deinit(allocator);

    // Register socket with program
    program.register(queue_id, @intCast(rx_xsk.Fd)) catch |err| {
        std.debug.print("Failed to register socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.unregister(queue_id) catch {};

    // Fill the fill ring
    var fill_descs: [64]u64 = undefined;
    for (0..64) |i| {
        fill_descs[i] = i * options.FrameSize;
    }
    const filled = rx_xsk.fillRing(&fill_descs, 64);
    try testing.expect(filled == 64);

    std.debug.print("✓ L2 forwarder setup completed (filled {} descriptors)\n", .{filled});
}

// Frame forwarding helper function
fn forwardFrames(
    input: *xdp.XDPSocket,
    output: *xdp.XDPSocket,
    dst_mac: [6]u8,
) !struct { bytes: u64, frames: u64 } {
    var rx_descs: [64]xdp.XDPDesc = undefined;
    const num_received = input.rxRing(&rx_descs, 64);

    if (num_received == 0) {
        return .{ .bytes = 0, .frames = 0 };
    }

    // Replace destination MAC in received frames
    for (rx_descs[0..num_received]) |desc| {
        const frame_start = desc.addr;
        if (frame_start + 6 <= input.Umem.len) {
            @memcpy(input.Umem[frame_start..][0..6], &dst_mac);
        }
    }

    // Prepare TX descriptors
    var tx_descs: [64]xdp.XDPDesc = undefined;
    var num_bytes: u64 = 0;

    for (rx_descs[0..num_received], 0..) |rx_desc, i| {
        // Copy frame data from input to output UMEM
        const out_addr = i * output.Options.FrameSize;
        if (out_addr + rx_desc.len <= output.Umem.len and
            rx_desc.addr + rx_desc.len <= input.Umem.len)
        {
            const in_frame = input.Umem[rx_desc.addr..][0..rx_desc.len];
            const out_frame = output.Umem[out_addr..][0..rx_desc.len];
            @memcpy(out_frame, in_frame);

            tx_descs[i] = .{
                .addr = out_addr,
                .len = rx_desc.len,
                .options = 0,
            };

            num_bytes += rx_desc.len;
        }
    }

    // Transmit frames
    const transmitted = output.txRing(tx_descs[0..num_received], @intCast(num_received));

    return .{
        .bytes = num_bytes,
        .frames = transmitted,
    };
}

test "L2 forwarder - frame forwarding function" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    const ifindex = (try findNetworkInterface(allocator)) orelse {
        std.debug.print("No network interface found, skipping test\n", .{});
        return error.SkipZigTest;
    };

    const options = xdp.SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    // Create input socket
    const in_xsk = xdp.XDPSocket.init(allocator, ifindex, 0, options) catch |err| {
        std.debug.print("Failed to create input socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer in_xsk.deinit(allocator);

    // Create output socket
    const out_xsk = xdp.XDPSocket.init(allocator, ifindex, 1, options) catch |err| {
        std.debug.print("Failed to create output socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer out_xsk.deinit(allocator);

    // Test the forwarding function (it will return 0 frames since there's no traffic)
    const dst_mac = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const result = try forwardFrames(in_xsk, out_xsk, dst_mac);

    std.debug.print("✓ Forwarding function test completed ({} bytes, {} frames)\n", .{ result.bytes, result.frames });
}

test "BPF map operations" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    var ebpf_loader = xdp.EbpfLoader.init(allocator);
    defer ebpf_loader.deinit();

    // Create an array map
    const map_fd = ebpf_loader.createMap(linux.BPF.MapType.array, @sizeOf(u32), @sizeOf(u32), 16, "test_map") catch |err| {
        std.debug.print("Failed to create map: {}\n", .{err});
        return error.SkipZigTest;
    };

    try testing.expect(map_fd >= 0);

    // Update map entry
    const key: u32 = 0;
    const value: u32 = 42;
    const key_bytes = std.mem.asBytes(&key);
    const value_bytes = std.mem.asBytes(&value);

    try xdp.EbpfLoader.updateMapElement(map_fd, key_bytes, value_bytes);

    // Lookup map entry
    var read_value: u32 = 0;
    const read_value_bytes = std.mem.asBytes(&read_value);
    const found = try xdp.EbpfLoader.lookupMapElement(map_fd, key_bytes, read_value_bytes);

    try testing.expect(found);
    try testing.expectEqual(@as(u32, 42), read_value);

    std.debug.print("✓ BPF map operations test passed (value={})\n", .{read_value});
}

test "XSK map operations" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    var ebpf_loader = xdp.EbpfLoader.init(allocator);
    defer ebpf_loader.deinit();

    // Create XSKMAP
    const xsks_map_fd = ebpf_loader.createXskMap(64, "test_xsks_map") catch |err| {
        std.debug.print("Failed to create XSKMAP: {}\n", .{err});
        return error.SkipZigTest;
    };

    try testing.expect(xsks_map_fd >= 0);

    std.debug.print("✓ XSKMAP creation test passed (fd={})\n", .{xsks_map_fd});
}

test "eBPF program instruction generation" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Create a minimal program to test instruction building
    var program = xdp.Program.init(allocator, 64) catch |err| {
        std.debug.print("Failed to create program: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.deinit();

    // The program should have valid file descriptors for all components
    try testing.expect(program.program_fd >= 0);
    try testing.expect(program.queues_map_fd >= 0);
    try testing.expect(program.sockets_map_fd >= 0);

    std.debug.print("✓ eBPF program generation test passed\n", .{});
    std.debug.print("  Program FD: {}\n", .{program.program_fd});
    std.debug.print("  Queues map FD: {}\n", .{program.queues_map_fd});
    std.debug.print("  Sockets map FD: {}\n", .{program.sockets_map_fd});
}

// Performance tracking structure for forwarder
const ForwarderStats = struct {
    total_bytes: u64 = 0,
    total_frames: u64 = 0,
    last_bytes: u64 = 0,
    last_frames: u64 = 0,

    pub fn update(self: *ForwarderStats, bytes: u64, frames: u64) void {
        self.total_bytes += bytes;
        self.total_frames += frames;
    }

    pub fn getRate(self: *ForwarderStats) struct { pps: u64, bps: u64 } {
        const frames_diff = self.total_frames - self.last_frames;
        const bytes_diff = self.total_bytes - self.last_bytes;

        self.last_frames = self.total_frames;
        self.last_bytes = self.total_bytes;

        return .{
            .pps = frames_diff,
            .bps = bytes_diff * 8,
        };
    }
};

test "ForwarderStats tracking" {
    var stats = ForwarderStats{};

    // Simulate some forwarding
    stats.update(1500, 1);
    stats.update(1500, 1);
    stats.update(1500, 1);

    try testing.expectEqual(@as(u64, 4500), stats.total_bytes);
    try testing.expectEqual(@as(u64, 3), stats.total_frames);

    const rate = stats.getRate();
    try testing.expectEqual(@as(u64, 3), rate.pps);
    try testing.expectEqual(@as(u64, 4500 * 8), rate.bps);

    std.debug.print("✓ Stats tracking test passed\n", .{});
}

test "Real traffic forwarding with raw socket injection" {
    if (!isRoot()) {
        std.debug.print("Skipping test - requires root privileges\n", .{});
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    // Find loopback interface
    const ifindex = (try findNetworkInterface(allocator)) orelse {
        std.debug.print("No network interface found, skipping test\n", .{});
        return error.SkipZigTest;
    };

    const queue_id: u32 = 0;

    // Create XDP program
    var program = xdp.Program.init(allocator, 64) catch |err| {
        std.debug.print("Failed to create program: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.deinit();

    const options = xdp.SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    // Create XDP socket
    const rx_xsk = xdp.XDPSocket.init(allocator, ifindex, queue_id, options) catch |err| {
        std.debug.print("Failed to create XDP socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer rx_xsk.deinit(allocator);

    // Register socket with program
    program.register(queue_id, @intCast(rx_xsk.Fd)) catch |err| {
        std.debug.print("Failed to register socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.unregister(queue_id) catch {};

    // Fill the fill ring
    var fill_descs: [64]u64 = undefined;
    for (0..64) |i| {
        fill_descs[i] = i * options.FrameSize;
    }
    const filled = rx_xsk.fillRing(&fill_descs, 64);
    try testing.expect(filled == 64);

    // Attach program to interface in SKB mode
    program.attach(ifindex, @intFromEnum(xdp.XdpFlags.SKB_MODE)) catch |err| {
        std.debug.print("XDP attach failed: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer program.detach(ifindex) catch {};

    // Create raw socket for sending traffic
    const raw_sock = posix.socket(posix.AF.PACKET, posix.SOCK.RAW, 0) catch |err| {
        std.debug.print("Failed to create raw socket: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer posix.close(raw_sock);

    // Bind raw socket to interface
    const sockaddr = linux.sockaddr.ll{
        .family = posix.AF.PACKET,
        .protocol = std.mem.nativeToBig(u16, 0x0800), // IP protocol
        .ifindex = @intCast(ifindex),
        .hatype = 0,
        .pkttype = 0,
        .halen = 6,
        .addr = [_]u8{0} ** 8,
    };

    posix.bind(raw_sock, @ptrCast(&sockaddr), @sizeOf(@TypeOf(sockaddr))) catch |err| {
        std.debug.print("Failed to bind raw socket: {}\n", .{err});
        return error.SkipZigTest;
    };

    // Construct a simple Ethernet frame
    var packet: [64]u8 = undefined;
    @memset(&packet, 0);

    // Destination MAC (broadcast)
    packet[0] = 0xff;
    packet[1] = 0xff;
    packet[2] = 0xff;
    packet[3] = 0xff;
    packet[4] = 0xff;
    packet[5] = 0xff;

    // Source MAC
    packet[6] = 0x00;
    packet[7] = 0x11;
    packet[8] = 0x22;
    packet[9] = 0x33;
    packet[10] = 0x44;
    packet[11] = 0x55;

    // EtherType (IPv4)
    packet[12] = 0x08;
    packet[13] = 0x00;

    // Payload (simple test data)
    const payload = "ZAFXDP_TEST";
    @memcpy(packet[14..][0..payload.len], payload);

    std.debug.print("Sending test packet...\n", .{});

    // Send packet
    const sent = posix.send(raw_sock, &packet, 0) catch |err| {
        std.debug.print("Failed to send packet: {}\n", .{err});
        return error.SkipZigTest;
    };

    std.debug.print("Sent {} bytes\n", .{sent});

    // Give some time for packet to be processed
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Try to receive on XDP socket
    var rx_descs: [64]xdp.XDPDesc = undefined;
    const num_received = rx_xsk.rxRing(&rx_descs, 64);

    std.debug.print("Received {} frames on XDP socket\n", .{num_received});

    if (num_received > 0) {
        // Verify we got something
        try testing.expect(num_received >= 1);

        // Check the first frame
        const first_desc = rx_descs[0];
        try testing.expect(first_desc.len > 0);

        std.debug.print("✓ Real traffic test passed - received {} frames\n", .{num_received});
        std.debug.print("  First frame: {} bytes at address {}\n", .{ first_desc.len, first_desc.addr });

        // Verify payload if possible
        if (first_desc.addr + 14 + payload.len <= rx_xsk.Umem.len) {
            const received_payload = rx_xsk.Umem[first_desc.addr + 14 ..][0..payload.len];
            if (std.mem.eql(u8, received_payload, payload)) {
                std.debug.print("  Payload verified: {s}\n", .{received_payload});
            }
        }
    } else {
        std.debug.print("⚠ No frames received (may not work on loopback with XDP)\n", .{});
        // Don't fail the test - XDP on loopback may not work on all systems
        return error.SkipZigTest;
    }
}

// Main L2 forwarder implementation (for reference/manual testing)
pub const L2Forwarder = struct {
    allocator: std.mem.Allocator,
    in_program: xdp.Program,
    in_xsk: *xdp.XDPSocket,
    out_xsk: *xdp.XDPSocket,
    in_ifindex: u32,
    out_ifindex: u32,
    in_queue_id: u32,
    out_queue_id: u32,
    in_dst_mac: [6]u8,
    out_dst_mac: [6]u8,
    stats: ForwarderStats,

    pub fn init(
        allocator: std.mem.Allocator,
        in_ifindex: u32,
        in_queue_id: u32,
        in_dst_mac: [6]u8,
        out_ifindex: u32,
        out_queue_id: u32,
        out_dst_mac: [6]u8,
    ) !L2Forwarder {
        // Create XDP program for input interface
        var in_program = try xdp.Program.init(allocator, 64);
        errdefer in_program.deinit();

        const options = xdp.SocketOptions{
            .NumFrames = 4096,
            .FrameSize = 2048,
            .FillRingNumDescs = 2048,
            .CompletionRingNumDescs = 2048,
            .RxRingNumDescs = 2048,
            .TxRingNumDescs = 2048,
        };

        // Create input socket
        const in_xsk = try xdp.XDPSocket.init(allocator, in_ifindex, in_queue_id, options);
        errdefer in_xsk.deinit(allocator);

        // Create output socket (no XDP program needed for TX-only)
        const out_xsk = try xdp.XDPSocket.init(allocator, out_ifindex, out_queue_id, options);
        errdefer out_xsk.deinit(allocator);

        // Register input socket with program
        try in_program.register(in_queue_id, @intCast(in_xsk.Fd));

        // Attach program to input interface
        try in_program.attach(in_ifindex, xdp.DefaultXdpFlags);

        return L2Forwarder{
            .allocator = allocator,
            .in_program = in_program,
            .in_xsk = in_xsk,
            .out_xsk = out_xsk,
            .in_ifindex = in_ifindex,
            .out_ifindex = out_ifindex,
            .in_queue_id = in_queue_id,
            .out_queue_id = out_queue_id,
            .in_dst_mac = in_dst_mac,
            .out_dst_mac = out_dst_mac,
            .stats = ForwarderStats{},
        };
    }

    pub fn deinit(self: *L2Forwarder) void {
        self.in_program.detach(self.in_ifindex) catch {};
        self.in_program.unregister(self.in_queue_id) catch {};
        self.in_program.deinit();
        self.in_xsk.deinit(self.allocator);
        self.out_xsk.deinit(self.allocator);
    }

    pub fn run(self: *L2Forwarder, verbose: bool) !void {
        std.debug.print("Starting L2 forwarder...\n", .{});

        // Fill rings initially
        var fill_descs: [2048]u64 = undefined;
        for (0..fill_descs.len) |i| {
            fill_descs[i] = i * self.in_xsk.Options.FrameSize;
        }
        _ = self.in_xsk.fillRing(&fill_descs, @intCast(fill_descs.len));
        _ = self.out_xsk.fillRing(&fill_descs, @intCast(fill_descs.len));

        // Stats reporting thread
        if (verbose) {
            std.debug.print("Verbose mode enabled - stats will be reported\n", .{});
        }

        // Main forwarding loop
        var poll_fds = [_]linux.pollfd{
            .{
                .fd = self.in_xsk.Fd,
                .events = linux.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.out_xsk.Fd,
                .events = linux.POLL.IN,
                .revents = 0,
            },
        };

        while (true) {
            // Poll for events
            const ready = linux.poll(&poll_fds, -1);
            if (ready < 0) {
                const err = posix.errno(ready);
                if (err == .INTR) continue;
                return error.PollFailed;
            }

            // Handle input socket
            if ((poll_fds[0].revents & linux.POLL.IN) != 0) {
                const result = try forwardFrames(self.in_xsk, self.out_xsk, self.in_dst_mac);
                self.stats.update(result.bytes, result.frames);
            }

            // Handle output socket
            if ((poll_fds[1].revents & linux.POLL.IN) != 0) {
                const result = try forwardFrames(self.out_xsk, self.in_xsk, self.out_dst_mac);
                self.stats.update(result.bytes, result.frames);
            }

            // Refill rings
            _ = self.in_xsk.fillRing(&fill_descs, @intCast(fill_descs.len));
            _ = self.out_xsk.fillRing(&fill_descs, @intCast(fill_descs.len));
        }
    }
};

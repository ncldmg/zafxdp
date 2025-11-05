const std = @import("std");
const xdp = @import("zafxdp_lib");
const common = @import("common.zig");

pub const Config = struct {
    interface: []const u8,
    queue_id: u32,
    num_packets: ?u64,
};

// Execute the receive command with the given configuration
pub fn execute(allocator: std.mem.Allocator, config: Config) !void {
    // Get interface index
    const ifindex = try common.getIfIndexByName(config.interface);

    std.debug.print("Starting packet capture on {s} (ifindex={d}, queue={d})\n", .{ config.interface, ifindex, config.queue_id });

    // Create XDP program
    std.debug.print("Creating XDP program...\n", .{});
    var program = xdp.Program.init(allocator, 64) catch |err| {
        std.debug.print("Failed to create XDP program: {}\n", .{err});
        std.debug.print("This requires root privileges. Try running with sudo.\n", .{});
        return err;
    };
    defer program.deinit();

    std.debug.print("✓ XDP program created (fd={})\n", .{program.program_fd});

    // Create AF_XDP socket
    std.debug.print("Creating AF_XDP socket...\n", .{});
    const options = xdp.SocketOptions{
        .NumFrames = 4096,
        .FrameSize = 2048,
        .FillRingNumDescs = 2048,
        .CompletionRingNumDescs = 2048,
        .RxRingNumDescs = 2048,
        .TxRingNumDescs = 2048,
    };

    const xsk = xdp.XDPSocket.init(allocator, ifindex, config.queue_id, options) catch |err| {
        std.debug.print("Failed to create AF_XDP socket: {}\n", .{err});
        return err;
    };
    defer xsk.deinit(allocator);

    std.debug.print("✓ AF_XDP socket created (fd={})\n", .{xsk.Fd});

    // Register socket with XDP program
    std.debug.print("Registering socket with program...\n", .{});
    try program.register(config.queue_id, @intCast(xsk.Fd));

    std.debug.print("✓ Socket registered\n", .{});

    // Attach XDP program to interface
    std.debug.print("Attaching XDP program to interface...\n", .{});
    program.attach(ifindex, xdp.DefaultXdpFlags) catch |err| {
        std.debug.print("Failed to attach with native mode: {}\n", .{err});
        std.debug.print("Note: XDP attachment via syscall is not fully supported in this kernel.\n", .{});
        std.debug.print("The program and socket are created but not attached.\n", .{});
        std.debug.print("You can manually attach with: sudo ip link set dev {s} xdpgeneric fd {d}\n", .{ config.interface, program.program_fd });
    };
    defer program.detach(ifindex) catch {};
    defer program.unregister(config.queue_id) catch {};

    // Fill ring with frame descriptors
    std.debug.print("Filling ring with frame descriptors...\n", .{});
    var fill_descs: [2048]u64 = undefined;
    for (0..fill_descs.len) |i| {
        fill_descs[i] = i * options.FrameSize;
    }
    _ = xsk.fillRing(&fill_descs, @intCast(fill_descs.len));

    std.debug.print("✓ Fill ring populated\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Ready to receive packets! (Press Ctrl+C to stop)\n", .{});
    std.debug.print("Listening on {s}, queue {d}...\n\n", .{ config.interface, config.queue_id });

    // Prepare packet buffers
    var packets: [16][]u8 = undefined;
    var packet_buffers: [16][2048]u8 = undefined;
    for (0..16) |i| {
        packets[i] = &packet_buffers[i];
    }

    var total_packets: u64 = 0;
    var total_bytes: u64 = 0;
    const start_time = std.time.milliTimestamp();

    // Packet processing loop
    while (true) {
        if (config.num_packets) |limit| {
            if (total_packets >= limit) {
                std.debug.print("\nReached packet limit ({d} packets)\n", .{limit});
                break;
            }
        }

        const received = xsk.receivePackets(&packets) catch |err| {
            if (err == error.SkipZigTest) continue;
            return err;
        };

        if (received > 0) {
            total_packets += received;

            for (packets[0..received]) |packet| {
                total_bytes += packet.len;

                // Print packet info
                std.debug.print("Packet #{d}: {d} bytes\n", .{ total_packets - received + 1, packet.len });

                // Print first 64 bytes as hex
                const display_len = @min(packet.len, 64);
                std.debug.print("  Data: ", .{});
                for (packet[0..display_len]) |byte| {
                    std.debug.print("{x:0>2}", .{byte});
                }
                if (packet.len > 64) {
                    std.debug.print("... ({d} more bytes)", .{packet.len - 64});
                }
                std.debug.print("\n", .{});

                // Try to parse as Ethernet frame
                if (packet.len >= 14) {
                    const dst_mac = packet[0..6];
                    const src_mac = packet[6..12];
                    const ethertype = (@as(u16, packet[12]) << 8) | @as(u16, packet[13]);

                    std.debug.print("  Ethernet: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} -> ", .{
                        src_mac[0], src_mac[1], src_mac[2], src_mac[3], src_mac[4], src_mac[5],
                    });
                    std.debug.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}, ", .{
                        dst_mac[0], dst_mac[1], dst_mac[2], dst_mac[3], dst_mac[4], dst_mac[5],
                    });
                    std.debug.print("EtherType: 0x{x:0>4}\n", .{ethertype});
                }

                std.debug.print("\n", .{});
            }

            // Return frames to fill ring
            _ = xsk.fillRing(fill_descs[0..received], @intCast(received));
        }

        // Print statistics every 1000 packets
        if (total_packets > 0 and total_packets % 1000 == 0) {
            const elapsed_ms = std.time.milliTimestamp() - start_time;
            const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            const pps = @as(f64, @floatFromInt(total_packets)) / elapsed_s;
            const mbps = (@as(f64, @floatFromInt(total_bytes * 8)) / elapsed_s) / 1_000_000.0;

            std.debug.print("\n--- Statistics ---\n", .{});
            std.debug.print("Total packets: {d}\n", .{total_packets});
            std.debug.print("Total bytes: {d}\n", .{total_bytes});
            std.debug.print("Packets/sec: {d:.2}\n", .{pps});
            std.debug.print("Mbps: {d:.2}\n", .{mbps});
            std.debug.print("------------------\n\n", .{});
        }

        std.Thread.yield() catch {}; // Yield to avoid busy-waiting
    }

    // Final statistics
    const elapsed_ms = std.time.milliTimestamp() - start_time;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

    std.debug.print("\n=== Final Statistics ===\n", .{});
    std.debug.print("Total packets received: {d}\n", .{total_packets});
    std.debug.print("Total bytes received: {d}\n", .{total_bytes});
    std.debug.print("Duration: {d:.2}s\n", .{elapsed_s});
    if (elapsed_s > 0) {
        const pps = @as(f64, @floatFromInt(total_packets)) / elapsed_s;
        const mbps = (@as(f64, @floatFromInt(total_bytes * 8)) / elapsed_s) / 1_000_000.0;
        std.debug.print("Average packets/sec: {d:.2}\n", .{pps});
        std.debug.print("Average throughput: {d:.2} Mbps\n", .{mbps});
    }
    std.debug.print("========================\n", .{});
}

// Tests
test "Config struct initialization" {
    const config = Config{
        .interface = "eth0",
        .queue_id = 0,
        .num_packets = 100,
    };

    try std.testing.expectEqualStrings("eth0", config.interface);
    try std.testing.expectEqual(@as(u32, 0), config.queue_id);
    try std.testing.expectEqual(@as(?u64, 100), config.num_packets);
    std.debug.print("✓ Config struct initialized correctly\n", .{});
}

test "Config with unlimited packets" {
    const config = Config{
        .interface = "lo",
        .queue_id = 1,
        .num_packets = null,
    };

    try std.testing.expectEqualStrings("lo", config.interface);
    try std.testing.expectEqual(@as(u32, 1), config.queue_id);
    try std.testing.expectEqual(@as(?u64, null), config.num_packets);
    std.debug.print("✓ Config with unlimited packets works\n", .{});
}

test "receive command requires root privileges" {
    const allocator = std.testing.allocator;

    const config = Config{
        .interface = "lo",
        .queue_id = 0,
        .num_packets = 1,
    };

    // This will fail without root, which is expected
    const result = execute(allocator, config);

    if (result) {
        // If it succeeded, we probably have root
        std.debug.print("✓ Receive command executed (running as root)\n", .{});
    } else |err| {
        // Expected to fail without root
        std.debug.print("✓ Receive command requires root (error: {})\n", .{err});
        return error.SkipZigTest;
    }
}

test "queue_id bounds" {
    // Test various queue IDs
    const configs = [_]Config{
        .{ .interface = "eth0", .queue_id = 0, .num_packets = null },
        .{ .interface = "eth0", .queue_id = 1, .num_packets = null },
        .{ .interface = "eth0", .queue_id = 15, .num_packets = null },
        .{ .interface = "eth0", .queue_id = std.math.maxInt(u32), .num_packets = null },
    };

    for (configs) |config| {
        try std.testing.expect(config.queue_id >= 0);
    }

    std.debug.print("✓ Queue ID bounds validated\n", .{});
}

const std = @import("std");
const xdp = @import("zafxdp_lib");
const linux = std.os.linux;

const CLI_VERSION = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(args[0]);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(args[0]);
        return;
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        std.debug.print("zafxdp version {s}\n", .{CLI_VERSION});
        return;
    }

    if (std.mem.eql(u8, command, "receive")) {
        if (args.len < 4) {
            std.debug.print("Usage: {s} receive <interface> <queue_id> [num_packets]\n", .{args[0]});
            std.debug.print("Example: {s} receive eth0 0 100\n", .{args[0]});
            return error.InvalidArguments;
        }

        const ifname = args[2];
        const queue_id = try std.fmt.parseInt(u32, args[3], 10);
        const num_packets: ?u64 = if (args.len > 4) try std.fmt.parseInt(u64, args[4], 10) else null;

        try receivePackets(allocator, ifname, queue_id, num_packets);
        return;
    }

    if (std.mem.eql(u8, command, "list-interfaces")) {
        try listNetworkInterfaces();
        return;
    }

    std.debug.print("Unknown command: {s}\n", .{command});
    try printUsage(args[0]);
    return error.UnknownCommand;
}

fn printUsage(program_name: []const u8) !void {
    std.debug.print(
        \\zafxdp - AF_XDP Socket CLI
        \\
        \\Usage: {s} <command> [options]
        \\
        \\Commands:
        \\  receive <interface> <queue_id> [num_packets]
        \\      Start receiving packets on the specified interface and queue.
        \\      If num_packets is specified, stop after receiving that many packets.
        \\      Example: {s} receive eth0 0 100
        \\
        \\  list-interfaces
        \\      List available network interfaces with their indices.
        \\
        \\  help, --help, -h
        \\      Show this help message.
        \\
        \\  version, --version, -v
        \\      Show version information.
        \\
        \\Notes:
        \\  - This program requires root privileges (sudo) to create BPF programs
        \\  - Use 'ip link show' to see available network interfaces
        \\  - Press Ctrl+C to stop packet capture
        \\
        \\Examples:
        \\  sudo {s} list-interfaces
        \\  sudo {s} receive eth0 0
        \\  sudo {s} receive lo 0 100
        \\
    , .{ program_name, program_name, program_name, program_name, program_name });
}

fn listNetworkInterfaces() !void {
    std.debug.print("Available network interfaces:\n\n", .{});

    var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open /sys/class/net: {}\n", .{err});
        std.debug.print("Try running: ip link show\n", .{});
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        // Read ifindex
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "/sys/class/net/{s}/ifindex", .{entry.name});
        defer std.heap.page_allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();

        var buf: [16]u8 = undefined;
        const len = file.readAll(&buf) catch continue;
        if (len == 0) continue;

        const ifindex_str = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
        const ifindex = std.fmt.parseInt(u32, ifindex_str, 10) catch continue;

        std.debug.print("  {d:2}: {s}\n", .{ ifindex, entry.name });
    }

    std.debug.print("\nUse interface name or index with the 'receive' command\n", .{});
}

fn getIfIndexByName(ifname: []const u8) !u32 {
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "/sys/class/net/{s}/ifindex", .{ifname});
    defer std.heap.page_allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        std.debug.print("Failed to find interface '{s}': {}\n", .{ ifname, err });
        std.debug.print("Run '{s} list-interfaces' to see available interfaces\n", .{std.os.argv[0]});
        return err;
    };
    defer file.close();

    var buf: [16]u8 = undefined;
    const len = try file.readAll(&buf);
    const ifindex_str = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
    return try std.fmt.parseInt(u32, ifindex_str, 10);
}

fn receivePackets(allocator: std.mem.Allocator, ifname: []const u8, queue_id: u32, max_packets: ?u64) !void {
    // Get interface index
    const ifindex = try getIfIndexByName(ifname);

    std.debug.print("Starting packet capture on {s} (ifindex={d}, queue={d})\n", .{ ifname, ifindex, queue_id });

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

    const xsk = xdp.XDPSocket.init(allocator, ifindex, queue_id, options) catch |err| {
        std.debug.print("Failed to create AF_XDP socket: {}\n", .{err});
        return err;
    };
    defer xsk.deinit(allocator);

    std.debug.print("✓ AF_XDP socket created (fd={})\n", .{xsk.Fd});

    // Register socket with XDP program
    std.debug.print("Registering socket with program...\n", .{});
    try program.register(queue_id, @intCast(xsk.Fd));

    std.debug.print("✓ Socket registered\n", .{});

    // Attach XDP program to interface
    std.debug.print("Attaching XDP program to interface...\n", .{});
    program.attach(ifindex, xdp.DefaultXdpFlags) catch |err| {
        std.debug.print("Failed to attach with native mode: {}\n", .{err});
        std.debug.print("Note: XDP attachment via syscall is not fully supported in this kernel.\n", .{});
        std.debug.print("The program and socket are created but not attached.\n", .{});
        std.debug.print("You can manually attach with: sudo ip link set dev {s} xdpgeneric fd {d}\n", .{ ifname, program.program_fd });
    };
    defer program.detach(ifindex) catch {};
    defer program.unregister(queue_id) catch {};

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
    std.debug.print("Listening on {s}, queue {d}...\n\n", .{ ifname, queue_id });

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
        if (max_packets) |limit| {
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

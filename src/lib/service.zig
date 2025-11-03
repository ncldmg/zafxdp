const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;

const xsk_mod = @import("xsk.zig");
const loader_mod = @import("loader.zig");
const Packet = @import("packet.zig").Packet;
const PacketSource = @import("packet.zig").PacketSource;
const Pipeline = @import("pipeline.zig").Pipeline;
const stats_mod = @import("stats.zig");

pub const XDPSocket = xsk_mod.XDPSocket;
pub const SocketOptions = xsk_mod.SocketOptions;
pub const XDPDesc = xsk_mod.XDPDesc;
pub const Program = loader_mod.Program;
pub const ServiceStats = stats_mod.ServiceStats;

// XDP flags for program attachment
pub const XdpFlags = enum(u32) {
    UPDATE_IF_NOEXIST = 1 << 0,
    SKB_MODE = 1 << 1,
    DRV_MODE = 1 << 2,
    HW_MODE = 1 << 3,
    REPLACE = 1 << 4,
};

pub const DefaultXdpFlags = @intFromEnum(XdpFlags.SKB_MODE) | @intFromEnum(XdpFlags.UPDATE_IF_NOEXIST);

// Interface configuration for service
pub const InterfaceConfig = struct {
    name: []const u8,
    queues: []const u32, // Which queues to bind to
};

// Service configuration
pub const ServiceConfig = struct {
    // Interfaces to attach to
    interfaces: []const InterfaceConfig,

    // Socket options (buffer sizes, etc.)
    socket_options: SocketOptions = .{
        .NumFrames = 2048,
        .FrameSize = 2048,
        .FillRingNumDescs = 1024,
        .CompletionRingNumDescs = 1024,
        .RxRingNumDescs = 1024,
        .TxRingNumDescs = 1024,
    },

    // XDP flags (SKB_MODE, DRV_MODE, etc.)
    xdp_flags: u32 = DefaultXdpFlags,

    // Batch size for packet processing
    batch_size: u32 = 64,

    // Enable statistics collection
    collect_stats: bool = true,

    // Poll timeout in milliseconds
    poll_timeout_ms: i32 = 100,
};

// Get interface index from name
pub fn getInterfaceIndex(name: []const u8) !u32 {
    const path = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "/sys/class/net/{s}/ifindex",
        .{name},
    );
    defer std.heap.page_allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buf: [16]u8 = undefined;
    const len = try file.readAll(&buf);
    const ifindex = try std.fmt.parseInt(
        u32,
        std.mem.trim(u8, buf[0..len], &std.ascii.whitespace),
        10,
    );

    return ifindex;
}

// Socket with associated metadata
const SocketInfo = struct {
    socket: *XDPSocket,
    ifindex: u32,
    queue_id: u32,
    interface_name: []const u8,
};

// High-level AF_XDP service
pub const Service = struct {
    allocator: mem.Allocator,
    config: ServiceConfig,
    program: Program,
    sockets: ArrayList(SocketInfo),
    pipeline: *Pipeline,
    stats: ServiceStats,
    running: std.atomic.Value(bool),
    workers: ArrayList(std.Thread),

    const Self = @This();

    pub fn init(allocator: mem.Allocator, config: ServiceConfig, pipeline: *Pipeline) !Self {
        var service = Self{
            .allocator = allocator,
            .config = config,
            .program = try Program.init(allocator, 256), // Support up to 256 queues
            .sockets = ArrayList(SocketInfo){},
            .pipeline = pipeline,
            .stats = ServiceStats.init(),
            .running = std.atomic.Value(bool).init(false),
            .workers = ArrayList(std.Thread){},
        };

        // Create sockets for each interface/queue
        for (config.interfaces) |iface_cfg| {
            const ifindex = try getInterfaceIndex(iface_cfg.name);

            for (iface_cfg.queues) |queue_id| {
                const socket = try XDPSocket.init(
                    allocator,
                    ifindex,
                    queue_id,
                    config.socket_options,
                );
                errdefer socket.deinit(allocator);

                try service.sockets.append(allocator, .{
                    .socket = socket,
                    .ifindex = ifindex,
                    .queue_id = queue_id,
                    .interface_name = iface_cfg.name,
                });

                // Register socket with XDP program
                try service.program.register(queue_id, @intCast(socket.Fd));

                // Pre-fill the fill ring with descriptors
                var fill_descs: [1024]u64 = undefined;
                for (0..config.socket_options.NumFrames) |i| {
                    if (i >= fill_descs.len) break;
                    fill_descs[i] = i * config.socket_options.FrameSize;
                }
                const fill_count = @min(config.socket_options.NumFrames, fill_descs.len);
                _ = socket.fillRing(fill_descs[0..fill_count], @intCast(fill_count));
            }

            // Attach XDP program to interface
            try service.program.attach(ifindex, config.xdp_flags);
        }

        return service;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Detach programs
        var detached_interfaces = std.AutoHashMap(u32, void).init(self.allocator);
        defer detached_interfaces.deinit();

        for (self.sockets.items) |info| {
            if (!detached_interfaces.contains(info.ifindex)) {
                self.program.detach(info.ifindex) catch {};
                detached_interfaces.put(info.ifindex, {}) catch {};
            }
        }

        // Unregister and cleanup sockets
        for (self.sockets.items) |info| {
            self.program.unregister(info.queue_id) catch {};
            info.socket.deinit(self.allocator);
        }
        self.sockets.deinit(self.allocator);

        self.workers.deinit(self.allocator);
        self.program.deinit();
    }

    // Start service (spawns worker threads)
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) {
            return error.AlreadyRunning;
        }

        self.running.store(true, .seq_cst);

        // Spawn one worker per socket
        for (self.sockets.items) |info| {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{
                info.socket,
                self.pipeline,
                &self.stats,
                &self.running,
                self.config.batch_size,
                PacketSource{
                    .ifindex = info.ifindex,
                    .queue_id = info.queue_id,
                    .interface_name = info.interface_name,
                },
                self.config.poll_timeout_ms,
            });
            try self.workers.append(self.allocator, thread);
        }
    }

    // Stop service (joins worker threads)
    pub fn stop(self: *Self) void {
        if (!self.running.load(.seq_cst)) {
            return;
        }

        self.running.store(false, .seq_cst);

        for (self.workers.items) |thread| {
            thread.join();
        }
        self.workers.clearRetainingCapacity();
    }

    // Get statistics snapshot
    pub fn getStats(self: *Self) stats_mod.StatsSnapshot {
        return self.stats.snapshot();
    }

    // Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats.reset();
    }
};

// Worker thread main loop
fn workerLoop(
    socket: *XDPSocket,
    pipeline: *Pipeline,
    stats: *ServiceStats,
    running: *std.atomic.Value(bool),
    batch_size: u32,
    source: PacketSource,
    poll_timeout_ms: i32,
) !void {
    var rx_descs: [128]XDPDesc = undefined;
    var packets: [128]Packet = undefined;
    var results: [128]@import("processor.zig").ProcessResult = undefined;
    var fill_descs: [128]u64 = undefined;

    // Prepare poll structure for socket
    var pollfds = [_]linux.pollfd{
        .{
            .fd = socket.Fd,
            .events = linux.POLL.IN,
            .revents = 0,
        },
    };

    while (running.load(.seq_cst)) {
        // Poll for incoming packets
        const poll_result = linux.poll(&pollfds, 1, poll_timeout_ms);
        if (poll_result < 0) {
            stats.recordError();
            continue;
        }

        if (poll_result == 0) {
            // Timeout, continue
            continue;
        }

        // Receive packets
        const received = socket.rxRing(rx_descs[0..batch_size], batch_size);
        if (received == 0) continue;

        // Convert descriptors to Packet objects
        var total_bytes: u64 = 0;
        for (0..received) |i| {
            const desc = rx_descs[i];
            const pkt_data = socket.Umem[desc.addr .. desc.addr + desc.len];

            packets[i] = Packet.init(pkt_data, desc, source);
            total_bytes += desc.len;
        }

        stats.recordPackets(@intCast(received), total_bytes);

        // Process through pipeline
        const processed = pipeline.processBatch(
            packets[0..received],
            results[0..received],
        ) catch |err| {
            std.debug.print("Pipeline error: {}\n", .{err});
            stats.recordError();
            // Refill and continue
            for (0..received) |i| {
                fill_descs[i] = rx_descs[i].addr;
            }
            _ = socket.fillRing(fill_descs[0..received], @intCast(received));
            continue;
        };

        // Handle results
        var tx_count: u32 = 0;
        var tx_descs: [128]XDPDesc = undefined;

        for (results[0..processed], 0..) |res, i| {
            switch (res.action) {
                .Drop => stats.recordDrop(),
                .Pass => stats.recordPass(),
                .Transmit => {
                    // Prepare for transmission
                    tx_descs[tx_count] = packets[i].desc;
                    tx_count += 1;
                    stats.recordTransmit(packets[i].len());
                },
                .Recirculate => {
                    // Not implemented in worker loop
                    stats.recordPass();
                },
            }
        }

        // Transmit packets if any
        if (tx_count > 0) {
            const queued = socket.txRing(tx_descs[0..tx_count], tx_count);
            if (queued > 0) {
                // Kick the socket to wake kernel
                socket.kick() catch |err| {
                    std.debug.print("Kick failed: {}\n", .{err});
                };
            }
        }

        // Refill RX ring
        for (0..received) |i| {
            fill_descs[i] = rx_descs[i].addr;
        }
        _ = socket.fillRing(fill_descs[0..received], @intCast(received));

        // Reclaim completed TX descriptors
        var comp_descs: [128]u64 = undefined;
        const completed = socket.completionRing(&comp_descs, tx_count);
        _ = completed; // These descriptors can be reused
    }
}

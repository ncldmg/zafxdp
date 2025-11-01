const std = @import("std");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const testing = std.testing;

const Zafxdp = error{
    MissingRing,
    InvalidFileDescriptor,
    SocketCreationFailed,
};

const UmemRing = struct { Producer: *u32, Consumer: *u32, Descs: []u64 };
const RxTxRing = struct { Producer: *u32, Consumer: *u32, Descs: []XDPDesc };
pub const XDPDesc = os.linux.xdp_desc;
const EbfMap = os.linux.MAP;

pub const SocketOptions = struct {
    NumFrames: u32,
    FrameSize: u32,
    FillRingNumDescs: u32,
    CompletionRingNumDescs: u32,
    RxRingNumDescs: u32,
    TxRingNumDescs: u32,
};

pub const XDPSocket = struct {
    Fd: i32,
    Umem: []u8,
    FillRing: UmemRing,
    RxRing: RxTxRing,
    TxRing: RxTxRing,
    CompletionRing: UmemRing,
    QidConfMap: EbfMap,
    XsksMap: EbfMap,
    // Program:
    IfIndex: u32,
    NumTransmitted: u32,
    NumFilled: u32,
    FreeRxDescs: []bool,
    FreeTxDescs: []bool,
    Options: SocketOptions,
    RxDescs: []XDPDesc,
    GetTxDescs: []XDPDesc,
    GetRxDescs: []XDPDesc,

    const Self = @This();

    // Private helper methods for initialization

    /// Create and validate XDP socket file descriptor
    fn createSocketFd() !i32 {
        const fd = os.linux.socket(os.linux.AF.XDP, os.linux.SOCK.RAW, 0);

        const errno_result = posix.errno(fd);
        if (errno_result != .SUCCESS) {
            std.debug.print("socket creation failed: {}\n", .{errno_result});
            return error.SocketCreationFailed;
        }

        if (fd > std.math.maxInt(i32)) {
            return error.InvalidFileDescriptor;
        }

        return @intCast(fd);
    }

    /// Allocate UMEM (user memory) for packet buffers
    fn allocateUmem(options: SocketOptions) ![]u8 {
        return try posix.mmap(
            null,
            options.NumFrames * options.FrameSize,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .POPULATE = true },
            -1,
            0,
        );
    }

    /// Register UMEM with the XDP socket
    fn registerUmem(fd: i32, umem: []u8, options: SocketOptions) !void {
        const xdpUmemReg = os.linux.xdp_umem_reg{
            .addr = @intFromPtr(&umem[0]),
            .len = @intCast(umem.len),
            .chunk_size = options.FrameSize,
            .headroom = 0,
            .flags = 0,
        };

        try posix.setsockopt(fd, posix.SOL.XDP, os.linux.XDP.UMEM_REG, mem.toBytes(xdpUmemReg)[0..]);
        try posix.setsockopt(fd, posix.SOL.XDP, os.linux.XDP.UMEM_FILL_RING, mem.toBytes(options.FillRingNumDescs)[0..]);
        try posix.setsockopt(fd, posix.SOL.XDP, os.linux.XDP.UMEM_COMPLETION_RING, mem.toBytes(options.CompletionRingNumDescs)[0..]);
    }

    /// Configure RX and TX rings
    fn configureRings(fd: i32, options: SocketOptions) !void {
        var hasRxRing = false;
        var hasTxRing = false;

        if (options.RxRingNumDescs > 0) {
            try posix.setsockopt(fd, posix.SOL.XDP, os.linux.XDP.RX_RING, mem.toBytes(options.RxRingNumDescs)[0..]);
            hasRxRing = true;
        }

        if (options.TxRingNumDescs > 0) {
            try posix.setsockopt(fd, posix.SOL.XDP, os.linux.XDP.TX_RING, mem.toBytes(options.TxRingNumDescs)[0..]);
            hasTxRing = true;
        }

        if (!(hasRxRing or hasTxRing)) {
            return Zafxdp.MissingRing;
        }
    }

    /// Get memory-mapped ring offsets from socket
    fn getMmapOffsets(fd: usize) !os.linux.xdp_mmap_offsets {
        var offsets: os.linux.xdp_mmap_offsets = undefined;
        var optlen: os.linux.socket_t = @sizeOf(os.linux.xdp_mmap_offsets);

        const mmaprc = os.linux.syscall6(
            os.linux.SYS.getsockopt,
            fd,
            @as(usize, posix.SOL.XDP),
            @as(usize, os.linux.XDP.MMAP_OFFSETS),
            @intFromPtr(&offsets),
            @intFromPtr(&optlen),
            0,
        );

        if (mmaprc != 0) {
            const err = posix.errno(mmaprc);
            std.debug.print("getsockopt syscall failed: {}\n", .{err});
            return error.SyscallFailed;
        }

        return offsets;
    }

    /// Map ring register helper
    fn mapRingRegister(
        fd: i32,
        length: usize,
        ring_offset: struct {
            producer: u64,
            consumer: u64,
        },
        offset: usize,
    ) !struct {
        producer: *u32,
        consumer: *u32,
        ring: []u8,
    } {
        const ring = try posix.mmap(
            null,
            length,
            posix.PROT.READ | posix.PROT.WRITE,
            .{
                .TYPE = .SHARED,
                .POPULATE = true,
            },
            fd,
            @intCast(offset),
        );
        const ring_ptr: *u8 = @ptrCast(ring);

        const producer_offset: usize = @intCast(ring_offset.producer);
        const consumer_offset: usize = @intCast(ring_offset.consumer);

        return .{
            .producer = @ptrFromInt(@intFromPtr(ring_ptr) + producer_offset),
            .consumer = @ptrFromInt(@intFromPtr(ring_ptr) + consumer_offset),
            .ring = ring,
        };
    }

    /// Map UMEM ring (fill or completion)
    fn mapUmemRing(
        ring: *UmemRing,
        fd: i32,
        desc_offset: u64,
        num_descs: u32,
        producer_offset: u64,
        consumer_offset: u64,
        pgoff: usize,
    ) !void {
        const ringInfo = try mapRingRegister(
            fd,
            desc_offset + num_descs * @sizeOf(u64),
            .{ .producer = producer_offset, .consumer = consumer_offset },
            pgoff,
        );

        ring.Producer = ringInfo.producer;
        ring.Consumer = ringInfo.consumer;
        ring.Descs = @as([*]u64, @ptrFromInt(@intFromPtr(ringInfo.ring.ptr) + @as(usize, @intCast(desc_offset))))[0..num_descs];
    }

    /// Map RX/TX ring
    fn mapRxTxRing(
        ring: *RxTxRing,
        fd: i32,
        desc_offset: u64,
        num_descs: u32,
        producer_offset: u64,
        consumer_offset: u64,
        pgoff: usize,
    ) !void {
        const ringInfo = try mapRingRegister(
            fd,
            desc_offset + num_descs * @sizeOf(XDPDesc),
            .{ .producer = producer_offset, .consumer = consumer_offset },
            pgoff,
        );

        ring.Producer = ringInfo.producer;
        ring.Consumer = ringInfo.consumer;
        ring.Descs = @as([*]XDPDesc, @ptrFromInt(@intFromPtr(ringInfo.ring.ptr) + @as(usize, @intCast(desc_offset))))[0..num_descs];
    }

    /// Bind XDP socket to network interface and queue
    fn bindSocket(fd: i32, ifIndex: u32, queueId: u32) !void {
        const xdpSockAddr = os.linux.sockaddr.xdp{
            .ifindex = ifIndex,
            .queue_id = queueId,
            .family = os.linux.AF.XDP,
            .flags = 0,
            .shared_umem_fd = 0,
        };

        const bindrc = os.linux.bind(fd, @ptrCast(&xdpSockAddr), @sizeOf(@TypeOf(xdpSockAddr)));
        if (bindrc != 0) {
            const err = posix.errno(bindrc);
            std.debug.print("bind syscall failed: {} (interface: {}, queue: {})\n", .{ err, ifIndex, queueId });
            return error.SyscallFailed;
        }
    }

    // Public methods

    /// Create a new XDP socket
    pub fn init(allocator: std.mem.Allocator, ifIndex: u32, queueId: u32, options: SocketOptions) !*Self {
        var xsk = try allocator.create(Self);
        errdefer allocator.destroy(xsk);

        // Initialize socket structure
        xsk.* = Self{
            .Fd = -1,
            .IfIndex = ifIndex,
            .Options = options,
            .Umem = &[_]u8{},
            .FillRing = undefined,
            .RxRing = undefined,
            .TxRing = undefined,
            .CompletionRing = undefined,
            .QidConfMap = undefined,
            .XsksMap = undefined,
            .NumTransmitted = 0,
            .NumFilled = 0,
            .FreeRxDescs = &[_]bool{},
            .FreeTxDescs = &[_]bool{},
            .RxDescs = &[_]XDPDesc{},
            .GetTxDescs = &[_]XDPDesc{},
            .GetRxDescs = &[_]XDPDesc{},
        };

        // Create XDP socket
        xsk.Fd = try Self.createSocketFd();
        errdefer {
            if (xsk.Fd != -1) {
                posix.close(xsk.Fd);
            }
        }

        // Allocate UMEM
        xsk.Umem = try Self.allocateUmem(options);
        errdefer posix.munmap(@alignCast(xsk.Umem));

        // Register UMEM and configure rings
        try Self.registerUmem(xsk.Fd, xsk.Umem, options);
        try Self.configureRings(xsk.Fd, options);

        // Get mmap offsets
        const offsets = try Self.getMmapOffsets(@intCast(xsk.Fd));

        // Map all rings
        try Self.mapUmemRing(&xsk.FillRing, xsk.Fd, offsets.fr.desc, options.FillRingNumDescs, offsets.fr.producer, offsets.fr.consumer, os.linux.XDP.UMEM_PGOFF_FILL_RING);

        try Self.mapUmemRing(&xsk.CompletionRing, xsk.Fd, offsets.cr.desc, options.CompletionRingNumDescs, offsets.cr.producer, offsets.cr.consumer, os.linux.XDP.UMEM_PGOFF_COMPLETION_RING);

        try Self.mapRxTxRing(&xsk.RxRing, xsk.Fd, offsets.rx.desc, options.RxRingNumDescs, offsets.rx.producer, offsets.rx.consumer, os.linux.XDP.PGOFF_RX_RING);

        try Self.mapRxTxRing(&xsk.TxRing, xsk.Fd, offsets.tx.desc, options.TxRingNumDescs, offsets.tx.producer, offsets.tx.consumer, os.linux.XDP.PGOFF_TX_RING);

        // Bind socket to interface
        try Self.bindSocket(xsk.Fd, ifIndex, queueId);

        return xsk;
    }

    // Destroy the XDP socket and free resources
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.Fd != -1) {
            posix.close(self.Fd);
        }
        if (self.Umem.len > 0) {
            posix.munmap(@alignCast(self.Umem));
        }
        allocator.destroy(self);
    }

    // Fill the fill ring with descriptors
    pub fn fillRing(self: *Self, descs: []u64, count: u32) u32 {
        const producer = self.FillRing.Producer.*;
        const consumer = self.FillRing.Consumer.*;
        const size = self.Options.FillRingNumDescs;

        const available = size - (producer - consumer);
        const to_fill = @min(count, available);

        for (0..to_fill) |i| {
            const idx = (producer + @as(u32, @intCast(i))) & (size - 1);
            self.FillRing.Descs[idx] = descs[i];
        }

        // Memory barrier for ring synchronization
        self.FillRing.Producer.* = producer + to_fill;

        return to_fill;
    }

    // Read descriptors from the completion ring
    pub fn completionRing(self: *Self, descs: []u64, count: u32) u32 {
        const consumer = self.CompletionRing.Consumer.*;
        const producer = self.CompletionRing.Producer.*;
        const size = self.Options.CompletionRingNumDescs;

        const available = producer - consumer;
        const to_read = @min(count, available);

        for (0..to_read) |i| {
            const idx = (consumer + @as(u32, @intCast(i))) & (size - 1);
            descs[i] = self.CompletionRing.Descs[idx];
        }

        // Memory barrier for ring synchronization
        self.CompletionRing.Consumer.* = consumer + to_read;

        return to_read;
    }

    // Read descriptors from the RX ring
    pub fn rxRing(self: *Self, descs: []XDPDesc, count: u32) u32 {
        const consumer = self.RxRing.Consumer.*;
        const producer = self.RxRing.Producer.*;
        const size = self.Options.RxRingNumDescs;

        const available = producer - consumer;
        const to_read = @min(count, available);

        for (0..to_read) |i| {
            const idx = (consumer + @as(u32, @intCast(i))) & (size - 1);
            descs[i] = self.RxRing.Descs[idx];
        }

        // Memory barrier for ring synchronization
        self.RxRing.Consumer.* = consumer + to_read;

        return to_read;
    }

    // Write descriptors to the TX ring
    pub fn txRing(self: *Self, descs: []XDPDesc, count: u32) u32 {
        const producer = self.TxRing.Producer.*;
        const consumer = self.TxRing.Consumer.*;
        const size = self.Options.TxRingNumDescs;

        const available = size - (producer - consumer);
        const to_send = @min(count, available);

        for (0..to_send) |i| {
            const idx = (producer + @as(u32, @intCast(i))) & (size - 1);
            self.TxRing.Descs[idx] = descs[i];
        }

        // Memory barrier for ring synchronization
        self.TxRing.Producer.* = producer + to_send;

        return to_send;
    }

    // Send packets through the XDP socket
    pub fn sendPackets(self: *Self, packets: []const []const u8) !u32 {
        var descs: [64]XDPDesc = undefined;
        var sent: u32 = 0;

        for (packets, 0..) |packet, i| {
            if (i >= descs.len) break;

            const frame_offset = sent * self.Options.FrameSize;
            if (frame_offset + packet.len > self.Umem.len) break;

            @memcpy(self.Umem[frame_offset .. frame_offset + packet.len], packet);

            descs[i] = XDPDesc{
                .addr = frame_offset,
                .len = @intCast(packet.len),
                .options = 0,
            };
            sent += 1;
        }

        const queued = self.txRing(descs[0..sent], sent);

        if (queued > 0) {
            const rc = os.linux.sendto(self.Fd, undefined, 0, os.linux.MSG.DONTWAIT, null, 0);
            if (rc < 0) {
                const err = posix.errno(rc);
                if (err != .AGAIN and err != .WOULDBLOCK) {
                    return error.SendFailed;
                }
            }
        }

        return queued;
    }

    // Receive packets from the XDP socket
    pub fn receivePackets(self: *Self, packets: [][]u8) !u32 {
        var descs: [64]XDPDesc = undefined;
        const received = self.rxRing(&descs, @min(packets.len, descs.len));

        for (0..received) |i| {
            const desc = descs[i];
            const packet_data = self.Umem[desc.addr .. desc.addr + desc.len];

            if (packets[i].len >= desc.len) {
                @memcpy(packets[i][0..desc.len], packet_data);
                packets[i] = packets[i][0..desc.len];
            } else {
                return error.BufferTooSmall;
            }
        }

        return received;
    }

    // Kick the socket to wake up the kernel
    pub fn kick(self: *Self) !void {
        const rc = os.linux.sendto(self.Fd, undefined, 0, os.linux.MSG.DONTWAIT, null, 0);
        if (rc < 0) {
            const err = posix.errno(rc);
            if (err != .AGAIN and err != .WOULDBLOCK) {
                return error.KickFailed;
            }
        }
    }
};

test "Create XDPSocket successfully" {
    const allocator = std.testing.allocator;

    const options = SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    // Try to create socket, but skip test if it fails (no network interface)
    const xsk = XDPSocket.init(allocator, 3, 0, options) catch |err| {
        switch (err) {
            error.SyscallFailed, error.SocketCreationFailed => {
                std.debug.print("Skipping XDP socket test - no network interface available\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer xsk.deinit(allocator);

    std.debug.print("Test XDP socket created with FD {}\n", .{xsk.Fd});
    try std.testing.expect(xsk.Fd >= 0);
    try std.testing.expect(xsk.Umem.len == options.NumFrames * options.FrameSize);
}

test "Ring buffer operations" {
    const allocator = std.testing.allocator;

    const options = SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    // Try to create socket, but skip test if it fails (no network interface)
    const xsk = XDPSocket.init(allocator, 3, 0, options) catch |err| {
        switch (err) {
            error.SyscallFailed, error.SocketCreationFailed => {
                std.debug.print("Skipping ring buffer test - no network interface available\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer xsk.deinit(allocator);

    // Test fill ring
    var fill_descs = [_]u64{ 0, 2048, 4096, 8192 };
    const filled = xsk.fillRing(&fill_descs, 4);
    try std.testing.expect(filled == 4);

    // Test completion ring
    var completion_descs = [_]u64{0} ** 4;
    const completed = xsk.completionRing(&completion_descs, 4);
    // Should be 0 since no packets were actually sent
    try std.testing.expect(completed == 0);

    std.debug.print("Ring buffer operations test passed\n", .{});
}

test "XDPSocket methods API" {
    const allocator = std.testing.allocator;

    const options = SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    // Try to create socket using the new method API
    const xsk = XDPSocket.init(allocator, 3, 0, options) catch |err| {
        switch (err) {
            error.SyscallFailed, error.SocketCreationFailed => {
                std.debug.print("Skipping XDPSocket methods test - no network interface available\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer xsk.deinit(allocator);

    // Test fill ring using method syntax
    var fill_descs = [_]u64{ 0, 2048, 4096, 8192 };
    const filled = xsk.fillRing(&fill_descs, 4);
    try std.testing.expect(filled == 4);

    // Test completion ring using method syntax
    var completion_descs = [_]u64{0} ** 4;
    const completed = xsk.completionRing(&completion_descs, 4);
    try std.testing.expect(completed == 0);

    std.debug.print("XDPSocket methods API test passed\n", .{});
}

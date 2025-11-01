const std = @import("std");

/// Service statistics with atomic counters
pub const ServiceStats = struct {
    packets_received: std.atomic.Value(u64),
    packets_transmitted: std.atomic.Value(u64),
    packets_dropped: std.atomic.Value(u64),
    packets_passed: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    bytes_transmitted: std.atomic.Value(u64),
    errors: std.atomic.Value(u64),
    start_time: i64,

    const Self = @This();

    pub fn init() Self {
        return .{
            .packets_received = std.atomic.Value(u64).init(0),
            .packets_transmitted = std.atomic.Value(u64).init(0),
            .packets_dropped = std.atomic.Value(u64).init(0),
            .packets_passed = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .bytes_transmitted = std.atomic.Value(u64).init(0),
            .errors = std.atomic.Value(u64).init(0),
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn recordPackets(self: *Self, count: u32, bytes: u64) void {
        _ = self.packets_received.fetchAdd(count, .monotonic);
        _ = self.bytes_received.fetchAdd(bytes, .monotonic);
    }

    pub fn recordTransmit(self: *Self, bytes: u64) void {
        _ = self.packets_transmitted.fetchAdd(1, .monotonic);
        _ = self.bytes_transmitted.fetchAdd(bytes, .monotonic);
    }

    pub fn recordDrop(self: *Self) void {
        _ = self.packets_dropped.fetchAdd(1, .monotonic);
    }

    pub fn recordPass(self: *Self) void {
        _ = self.packets_passed.fetchAdd(1, .monotonic);
    }

    pub fn recordError(self: *Self) void {
        _ = self.errors.fetchAdd(1, .monotonic);
    }

    pub fn snapshot(self: *const Self) StatsSnapshot {
        return .{
            .packets_received = self.packets_received.load(.monotonic),
            .packets_transmitted = self.packets_transmitted.load(.monotonic),
            .packets_dropped = self.packets_dropped.load(.monotonic),
            .packets_passed = self.packets_passed.load(.monotonic),
            .bytes_received = self.bytes_received.load(.monotonic),
            .bytes_transmitted = self.bytes_transmitted.load(.monotonic),
            .errors = self.errors.load(.monotonic),
            .elapsed_ms = std.time.milliTimestamp() - self.start_time,
        };
    }

    pub fn reset(self: *Self) void {
        self.packets_received.store(0, .monotonic);
        self.packets_transmitted.store(0, .monotonic);
        self.packets_dropped.store(0, .monotonic);
        self.packets_passed.store(0, .monotonic);
        self.bytes_received.store(0, .monotonic);
        self.bytes_transmitted.store(0, .monotonic);
        self.errors.store(0, .monotonic);
        self.start_time = std.time.milliTimestamp();
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const snap = self.snapshot();
        try snap.format("", .{}, writer);
    }
};

/// Immutable snapshot of statistics
pub const StatsSnapshot = struct {
    packets_received: u64,
    packets_transmitted: u64,
    packets_dropped: u64,
    packets_passed: u64,
    bytes_received: u64,
    bytes_transmitted: u64,
    errors: u64,
    elapsed_ms: i64,

    pub fn rxPps(self: StatsSnapshot) u64 {
        if (self.elapsed_ms <= 0) return 0;
        return self.packets_received * 1000 / @as(u64, @intCast(self.elapsed_ms));
    }

    pub fn txPps(self: StatsSnapshot) u64 {
        if (self.elapsed_ms <= 0) return 0;
        return self.packets_transmitted * 1000 / @as(u64, @intCast(self.elapsed_ms));
    }

    pub fn rxBps(self: StatsSnapshot) u64 {
        if (self.elapsed_ms <= 0) return 0;
        return self.bytes_received * 1000 / @as(u64, @intCast(self.elapsed_ms));
    }

    pub fn txBps(self: StatsSnapshot) u64 {
        if (self.elapsed_ms <= 0) return 0;
        return self.bytes_transmitted * 1000 / @as(u64, @intCast(self.elapsed_ms));
    }

    pub fn format(
        self: StatsSnapshot,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        const elapsed_sec = @divFloor(self.elapsed_ms, 1000);

        try writer.print(
            "RX: {} pkts ({} pps, {} B/s) | TX: {} pkts ({} pps, {} B/s) | Drop: {} | Pass: {} | Errors: {} | Elapsed: {}s",
            .{
                self.packets_received,
                self.rxPps(),
                formatBytes(self.rxBps()),
                self.packets_transmitted,
                self.txPps(),
                formatBytes(self.txBps()),
                self.packets_dropped,
                self.packets_passed,
                self.errors,
                elapsed_sec,
            },
        );
    }
};

/// Format bytes with units (B, KB, MB, GB)
fn formatBytes(bytes: u64) []const u8 {
    // Note: This is a simplified version. For production, use allocator
    if (bytes < 1024) {
        return std.fmt.allocPrint(std.heap.page_allocator, "{}B", .{bytes}) catch "?B";
    } else if (bytes < 1024 * 1024) {
        return std.fmt.allocPrint(std.heap.page_allocator, "{d:.2}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "?KB";
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.allocPrint(std.heap.page_allocator, "{d:.2}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "?MB";
    } else {
        return std.fmt.allocPrint(std.heap.page_allocator, "{d:.2}GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch "?GB";
    }
}

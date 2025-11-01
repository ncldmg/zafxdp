const std = @import("std");
const Packet = @import("packet.zig").Packet;

// Packet processing decision
pub const PacketAction = enum {
    Drop, // Discard packet
    Pass, // Continue to next processor (or kernel if last)
    Transmit, // Send on specified interface/queue
    Recirculate, // Re-inject into processing pipeline
};

// Target for transmit action
pub const TransmitTarget = struct {
    ifindex: u32,
    queue_id: u32,
};

// Result of packet processing
pub const ProcessResult = struct {
    action: PacketAction,
    target: ?TransmitTarget = null, // Required for Transmit action
    modified: bool = false, // Did we modify packet data?
};

// Generic packet processor interface
// Context: User-defined state/config for the processor
pub fn PacketProcessor(comptime Context: type) type {
    return struct {
        const Self = @This();

        // User-defined context (state, config, counters)
        context: Context,

        // Process a single packet
        processFn: *const fn (ctx: *Context, packet: *Packet) anyerror!ProcessResult,

        // Optional: process batch of packets (for efficiency)
        processBatchFn: ?*const fn (ctx: *Context, packets: []Packet, results: []ProcessResult) anyerror!u32 = null,

        // Optional: lifecycle hooks
        initFn: ?*const fn (ctx: *Context) anyerror!void = null,
        deinitFn: ?*const fn (ctx: *Context) void = null,

        pub fn init(
            context: Context,
            processFn: *const fn (ctx: *Context, packet: *Packet) anyerror!ProcessResult,
        ) Self {
            return .{
                .context = context,
                .processFn = processFn,
            };
        }

        pub fn process(self: *Self, packet: *Packet) !ProcessResult {
            return self.processFn(&self.context, packet);
        }

        pub fn processBatch(self: *Self, packets: []Packet, results: []ProcessResult) !u32 {
            if (self.processBatchFn) |batchFn| {
                return batchFn(&self.context, packets, results);
            }

            // Fallback: process one-by-one
            for (packets, 0..) |*pkt, i| {
                results[i] = try self.process(pkt);
            }
            return @intCast(packets.len);
        }

        pub fn initContext(self: *Self) !void {
            if (self.initFn) |initF| {
                try initF(&self.context);
            }
        }

        pub fn deinitContext(self: *Self) void {
            if (self.deinitFn) |deinitF| {
                deinitF(&self.context);
            }
        }
    };
}

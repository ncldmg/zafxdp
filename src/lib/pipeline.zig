const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Packet = @import("packet.zig").Packet;
const processor = @import("processor.zig");
const PacketAction = processor.PacketAction;
const ProcessResult = processor.ProcessResult;

/// Pipeline configuration
pub const PipelineConfig = struct {
    /// Stop on first Drop?
    stop_on_drop: bool = true,

    /// Allow packet modification?
    allow_modification: bool = true,

    /// Max processors in chain
    max_stages: usize = 16,
};

/// Virtual table for type-erased processors
const StageVtable = struct {
    process: *const fn (processor_ptr: *anyopaque, packet: *Packet) anyerror!ProcessResult,
    processBatch: *const fn (processor_ptr: *anyopaque, packets: []Packet, results: []ProcessResult) anyerror!u32,
    initContext: *const fn (processor_ptr: *anyopaque) anyerror!void,
    deinitContext: *const fn (processor_ptr: *anyopaque) void,
};

/// Pipeline: chains multiple processors together
pub const Pipeline = struct {
    allocator: mem.Allocator,
    stages: ArrayList(*anyopaque), // Type-erased processors
    stage_fns: ArrayList(StageVtable),
    config: PipelineConfig,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, config: PipelineConfig) Self {
        return .{
            .allocator = allocator,
            .stages = ArrayList(*anyopaque){},
            .stage_fns = ArrayList(StageVtable){},
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        // Call deinit on all processors
        for (self.stages.items, self.stage_fns.items) |stage, vtable| {
            vtable.deinitContext(stage);
        }
        self.stages.deinit(self.allocator);
        self.stage_fns.deinit(self.allocator);
    }

    /// Add processor to pipeline
    pub fn addStage(self: *Self, comptime P: type, proc: *P) !void {
        if (self.stages.items.len >= self.config.max_stages) {
            return error.TooManyStages;
        }

        try self.stages.append(self.allocator, @ptrCast(proc));
        try self.stage_fns.append(self.allocator, .{
            .process = struct {
                fn process(processor_ptr: *anyopaque, pkt: *Packet) !ProcessResult {
                    const p: *P = @ptrCast(@alignCast(processor_ptr));
                    return p.process(pkt);
                }
            }.process,
            .processBatch = struct {
                fn processBatch(processor_ptr: *anyopaque, pkts: []Packet, results: []ProcessResult) !u32 {
                    const p: *P = @ptrCast(@alignCast(processor_ptr));
                    return p.processBatch(pkts, results);
                }
            }.processBatch,
            .initContext = struct {
                fn initContext(processor_ptr: *anyopaque) !void {
                    const p: *P = @ptrCast(@alignCast(processor_ptr));
                    return p.initContext();
                }
            }.initContext,
            .deinitContext = struct {
                fn deinitContext(processor_ptr: *anyopaque) void {
                    const p: *P = @ptrCast(@alignCast(processor_ptr));
                    p.deinitContext();
                }
            }.deinitContext,
        });

        // Initialize the processor
        try self.stage_fns.items[self.stage_fns.items.len - 1].initContext(self.stages.items[self.stages.items.len - 1]);
    }

    /// Process packet through all stages
    pub fn process(self: *Self, packet: *Packet) !ProcessResult {
        var result = ProcessResult{ .action = .Pass };

        for (self.stages.items, self.stage_fns.items) |stage, vtable| {
            result = try vtable.process(stage, packet);

            switch (result.action) {
                .Drop => if (self.config.stop_on_drop) return result,
                .Transmit => return result,
                .Pass => continue,
                .Recirculate => {
                    // Re-run from beginning (with recursion limit)
                    return self.process(packet);
                },
            }
        }

        return result;
    }

    /// Batch processing through pipeline
    pub fn processBatch(self: *Self, packets: []Packet, results: []ProcessResult) !u32 {
        // Initialize all as Pass
        for (results) |*r| {
            r.* = .{ .action = .Pass };
        }

        var active_count: usize = packets.len;

        for (self.stages.items, self.stage_fns.items) |stage, vtable| {
            // Process current batch
            _ = try vtable.processBatch(stage, packets[0..active_count], results[0..active_count]);

            // Early termination optimization: compact arrays by removing dropped packets
            if (self.config.stop_on_drop) {
                var writeIdx: usize = 0;
                for (0..active_count) |i| {
                    if (results[i].action != .Drop) {
                        if (writeIdx != i) {
                            packets[writeIdx] = packets[i];
                            results[writeIdx] = results[i];
                        }
                        writeIdx += 1;
                    }
                }
                active_count = writeIdx;
                if (active_count == 0) return 0;
            }
        }

        return @intCast(active_count);
    }

    /// Get number of stages in pipeline
    pub fn stageCount(self: *const Self) usize {
        return self.stages.items.len;
    }
};

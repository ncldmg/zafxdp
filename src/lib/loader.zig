const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const mem = std.mem;
const BPF = linux.BPF;
const ArrayList = std.ArrayList;

pub const LoaderError = error{
    FileNotFound,
    InvalidElfFormat,
    BpfLoadFailed,
    MapCreateFailed,
    MapUpdateFailed,
    InvalidMapType,
    OutOfMemory,
    AttachFailed,
    DetachFailed,
    NetlinkError,
};

// XDP Flags for attaching programs
pub const XdpFlags = enum(u32) {
    UPDATE_IF_NOEXIST = 1 << 0,
    SKB_MODE = 1 << 1,
    DRV_MODE = 1 << 2,
    HW_MODE = 1 << 3,
    REPLACE = 1 << 4,
};

pub const DefaultXdpFlags: u32 = @intFromEnum(XdpFlags.DRV_MODE) | @intFromEnum(XdpFlags.UPDATE_IF_NOEXIST);

pub const MapInfo = struct {
    fd: i32,
    type: BPF.MapType,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    name: []const u8,
};

pub const ProgramInfo = struct {
    fd: i32,
    type: BPF.ProgType,
    name: []const u8,
};

pub const EbpfLoader = struct {
    allocator: mem.Allocator,
    programs: ArrayList(ProgramInfo),
    maps: ArrayList(MapInfo),

    pub fn init(allocator: mem.Allocator) EbpfLoader {
        return EbpfLoader{
            .allocator = allocator,
            .programs = .{},
            .maps = .{},
        };
    }

    pub fn deinit(self: *EbpfLoader) void {
        // Close all program file descriptors and free names
        for (self.programs.items) |prog| {
            posix.close(prog.fd);
            self.allocator.free(prog.name);
        }

        // Close all map file descriptors and free names
        for (self.maps.items) |map| {
            posix.close(map.fd);
            self.allocator.free(map.name);
        }

        self.programs.deinit(self.allocator);
        self.maps.deinit(self.allocator);
    }

    pub fn loadProgramFromFile(self: *EbpfLoader, path: []const u8, prog_type: BPF.ProgType, prog_name: []const u8) LoaderError!i32 {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return LoaderError.FileNotFound,
            else => return LoaderError.FileNotFound,
        };
        defer file.close();

        const file_size = file.getEndPos() catch return LoaderError.InvalidElfFormat;
        const program_data = self.allocator.alloc(u8, file_size) catch return LoaderError.OutOfMemory;
        defer self.allocator.free(program_data);

        _ = file.readAll(program_data) catch return LoaderError.InvalidElfFormat;

        const insns: []const BPF.Insn = @alignCast(mem.bytesAsSlice(BPF.Insn, program_data));

        var attr = BPF.Attr{
            .prog_load = mem.zeroes(BPF.ProgLoadAttr),
        };

        attr.prog_load.prog_type = @intFromEnum(prog_type);
        attr.prog_load.insn_cnt = @intCast(insns.len);
        attr.prog_load.insns = @intFromPtr(insns.ptr);
        attr.prog_load.license = @intFromPtr("GPL".ptr);

        const result = linux.syscall3(linux.SYS.bpf, @intFromEnum(BPF.Cmd.prog_load), @intFromPtr(&attr), @sizeOf(BPF.ProgLoadAttr));
        const fd: isize = @bitCast(result);
        if (fd < 0) {
            std.debug.print("BPF program load failed with errno: {}\n", .{-fd});
            return LoaderError.BpfLoadFailed;
        }

        const prog_info = ProgramInfo{
            .fd = @intCast(fd),
            .type = prog_type,
            .name = try self.allocator.dupe(u8, prog_name),
        };

        self.programs.append(self.allocator, prog_info) catch return LoaderError.OutOfMemory;
        return @intCast(fd);
    }

    pub fn loadProgramFromInstructions(self: *EbpfLoader, insns: []const BPF.Insn, prog_type: BPF.ProgType, prog_name: []const u8) LoaderError!i32 {
        var attr = BPF.Attr{
            .prog_load = mem.zeroes(BPF.ProgLoadAttr),
        };

        attr.prog_load.prog_type = @intFromEnum(prog_type);
        attr.prog_load.insn_cnt = @intCast(insns.len);
        attr.prog_load.insns = @intFromPtr(insns.ptr);
        attr.prog_load.license = @intFromPtr("GPL\x00".ptr);

        const result = linux.syscall3(linux.SYS.bpf, @intFromEnum(BPF.Cmd.prog_load), @intFromPtr(&attr), @sizeOf(BPF.ProgLoadAttr));
        const fd: isize = @bitCast(result);
        if (fd < 0) {
            std.debug.print("BPF program load failed with errno: {}\n", .{-fd});
            return LoaderError.BpfLoadFailed;
        }

        const prog_info = ProgramInfo{
            .fd = @intCast(fd),
            .type = prog_type,
            .name = try self.allocator.dupe(u8, prog_name),
        };

        self.programs.append(self.allocator, prog_info) catch return LoaderError.OutOfMemory;
        return @intCast(fd);
    }

    pub fn createMap(self: *EbpfLoader, map_type: BPF.MapType, key_size: u32, value_size: u32, max_entries: u32, map_name: []const u8) LoaderError!i32 {
        var attr = BPF.Attr{
            .map_create = mem.zeroes(BPF.MapCreateAttr),
        };

        attr.map_create.map_type = @intFromEnum(map_type);
        attr.map_create.key_size = key_size;
        attr.map_create.value_size = value_size;
        attr.map_create.max_entries = max_entries;

        const result = linux.syscall3(linux.SYS.bpf, @intFromEnum(BPF.Cmd.map_create), @intFromPtr(&attr), @sizeOf(BPF.MapCreateAttr));
        const fd: isize = @bitCast(result);
        if (fd < 0) {
            std.debug.print("BPF map create failed with errno: {}\n", .{-fd});
            return LoaderError.MapCreateFailed;
        }

        const map_info = MapInfo{
            .fd = @intCast(fd),
            .type = map_type,
            .key_size = key_size,
            .value_size = value_size,
            .max_entries = max_entries,
            .name = try self.allocator.dupe(u8, map_name),
        };

        self.maps.append(self.allocator, map_info) catch return LoaderError.OutOfMemory;
        return @intCast(fd);
    }

    pub fn updateMapElement(map_fd: i32, key: []const u8, value: []const u8) LoaderError!void {
        var attr = BPF.Attr{
            .map_elem = mem.zeroes(BPF.MapElemAttr),
        };

        attr.map_elem.map_fd = @intCast(map_fd);
        attr.map_elem.key = @intFromPtr(key.ptr);
        attr.map_elem.result.value = @intFromPtr(value.ptr);

        const result_raw = linux.syscall3(linux.SYS.bpf, @intFromEnum(BPF.Cmd.map_update_elem), @intFromPtr(&attr), @sizeOf(BPF.MapElemAttr));
        const result: isize = @bitCast(result_raw);
        if (result < 0) {
            return LoaderError.MapUpdateFailed;
        }
    }

    pub fn lookupMapElement(map_fd: i32, key: []const u8, value: []u8) LoaderError!bool {
        var attr = BPF.Attr{
            .map_elem = mem.zeroes(BPF.MapElemAttr),
        };

        attr.map_elem.map_fd = @intCast(map_fd);
        attr.map_elem.key = @intFromPtr(key.ptr);
        attr.map_elem.result.value = @intFromPtr(value.ptr);

        const result_raw = linux.syscall3(linux.SYS.bpf, @intFromEnum(BPF.Cmd.map_lookup_elem), @intFromPtr(&attr), @sizeOf(BPF.MapElemAttr));
        const result: isize = @bitCast(result_raw);
        return result >= 0;
    }

    pub fn deleteMapElement(map_fd: i32, key: []const u8) LoaderError!void {
        var attr = BPF.Attr{
            .map_elem = mem.zeroes(BPF.MapElemAttr),
        };

        attr.map_elem.map_fd = @intCast(map_fd);
        attr.map_elem.key = @intFromPtr(key.ptr);

        const result_raw = linux.syscall3(linux.SYS.bpf, @intFromEnum(BPF.Cmd.map_delete_elem), @intFromPtr(&attr), @sizeOf(BPF.MapElemAttr));
        const result: isize = @bitCast(result_raw);
        if (result < 0) {
            return LoaderError.MapUpdateFailed;
        }
    }

    pub fn createXskMap(self: *EbpfLoader, max_entries: u32, map_name: []const u8) LoaderError!i32 {
        return self.createMap(BPF.MapType.xskmap, @sizeOf(u32), @sizeOf(u32), max_entries, map_name);
    }

    pub fn updateXskMapEntry(self: *EbpfLoader, map_fd: i32, queue_index: u32, xsk_fd: u32) LoaderError!void {
        const key_bytes = mem.asBytes(&queue_index);
        const value_bytes = mem.asBytes(&xsk_fd);
        return self.updateMapElement(map_fd, key_bytes, value_bytes);
    }

    pub fn findProgramByName(self: *EbpfLoader, name: []const u8) ?*ProgramInfo {
        for (self.programs.items) |*prog| {
            if (mem.eql(u8, prog.name, name)) {
                return prog;
            }
        }
        return null;
    }

    pub fn findMapByName(self: *EbpfLoader, name: []const u8) ?*MapInfo {
        for (self.maps.items) |*map| {
            if (mem.eql(u8, map.name, name)) {
                return map;
            }
        }
        return null;
    }

    pub fn getProgramCount(self: *EbpfLoader) usize {
        return self.programs.items.len;
    }

    pub fn getMapCount(self: *EbpfLoader) usize {
        return self.maps.items.len;
    }

    pub fn attachXdpProgram(self: *EbpfLoader, prog_fd: i32, ifindex: u32, flags: u32) LoaderError!void {
        _ = self;
        return attachProgram(ifindex, prog_fd, flags);
    }

    pub fn detachXdpProgram(self: *EbpfLoader, ifindex: u32) LoaderError!void {
        _ = self;
        return removeProgram(ifindex);
    }
};

// Convenience functions for common operations
pub fn loadAfXdpProgram(allocator: mem.Allocator, object_file: []const u8) LoaderError!EbpfLoader {
    var loader = EbpfLoader.init(allocator);

    // Load the XDP program
    _ = loader.loadProgramFromFile(object_file, BPF.ProgType.xdp, "xsk_redir_prog") catch |err| {
        loader.deinit();
        return err;
    };

    // Create the XSK map (matching the one in afxdp.c)
    _ = loader.createXskMap(64, "xsks_map") catch |err| {
        loader.deinit();
        return err;
    };

    return loader;
}

pub fn printLoaderStatus(loader: *EbpfLoader, writer: anytype) !void {
    try writer.print("eBPF Loader Status:\n");
    try writer.print("  Programs loaded: {}\n", .{loader.getProgramCount()});
    try writer.print("  Maps created: {}\n", .{loader.getMapCount()});

    for (loader.programs.items, 0..) |prog, i| {
        try writer.print("  Program {}: {} (fd={})\n", .{ i, prog.name, prog.fd });
    }

    for (loader.maps.items, 0..) |map, i| {
        try writer.print("  Map {}: {} (fd={}, type={}, entries={})\n", .{ i, map.name, map.fd, @intFromEnum(map.type), map.max_entries });
    }
}

// Program structure that wraps the XDP program and maps.
pub const Program = struct {
    program_fd: i32,
    queues_map_fd: i32,
    sockets_map_fd: i32,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, max_queue_entries: u32) LoaderError!Program {
        var loader = EbpfLoader.init(allocator);
        errdefer loader.deinit();

        // Create the queues map (qidconf_map)
        const queues_fd = try loader.createMap(
            BPF.MapType.array,
            @sizeOf(u32),
            @sizeOf(u32),
            max_queue_entries,
            "qidconf_map",
        );

        // Create the sockets map (xsks_map)
        const sockets_fd = try loader.createXskMap(max_queue_entries, "xsks_map");

        // Build the XDP program instructions
        const insns = try buildXdpProgram(allocator, queues_fd, sockets_fd);
        defer allocator.free(insns);

        // Load the program
        const prog_fd = try loader.loadProgramFromInstructions(insns, BPF.ProgType.xdp, "xsk_ebpf");

        // Clean up the loader's internal data without closing the FDs
        // since we're transferring ownership to Program
        // Free the allocated names
        for (loader.programs.items) |prog| {
            allocator.free(prog.name);
        }
        for (loader.maps.items) |map| {
            allocator.free(map.name);
        }
        loader.programs.deinit(allocator);
        loader.maps.deinit(allocator);

        return Program{
            .program_fd = prog_fd,
            .queues_map_fd = queues_fd,
            .sockets_map_fd = sockets_fd,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Program) void {
        if (self.program_fd >= 0) {
            posix.close(self.program_fd);
        }
        if (self.queues_map_fd >= 0) {
            posix.close(self.queues_map_fd);
        }
        if (self.sockets_map_fd >= 0) {
            posix.close(self.sockets_map_fd);
        }
    }

    pub fn attach(self: *Program, ifindex: u32, flags: u32) LoaderError!void {
        return attachProgram(ifindex, self.program_fd, flags);
    }

    pub fn detach(self: *Program, ifindex: u32) LoaderError!void {
        _ = self;
        return removeProgram(ifindex);
    }

    pub fn register(self: *Program, queue_id: u32, socket_fd: u32) LoaderError!void {
        // Update the sockets map
        const key_bytes = mem.asBytes(&queue_id);
        const value_bytes = mem.asBytes(&socket_fd);
        try EbpfLoader.updateMapElement(self.sockets_map_fd, key_bytes, value_bytes);

        // Update the queues map
        const enabled: u32 = 1;
        const enabled_bytes = mem.asBytes(&enabled);
        try EbpfLoader.updateMapElement(self.queues_map_fd, key_bytes, enabled_bytes);
    }

    pub fn unregister(self: *Program, queue_id: u32) LoaderError!void {
        const key_bytes = mem.asBytes(&queue_id);
        try EbpfLoader.deleteMapElement(self.queues_map_fd, key_bytes);
        try EbpfLoader.deleteMapElement(self.sockets_map_fd, key_bytes);
    }
};

// Helper function to build XDP program instructions
// equivalent to Linux kernel's default AF_XDP program.
// int xdp_sock_prog(struct xdp_md *ctx) {
//    int *qidconf, index = ctx->rx_queue_index;
//
//    // Check if queue has registered AF_XDP socket
//    qidconf = bpf_map_lookup_elem(&qidconf_map, &index);
//    if (!qidconf)
//        return XDP_ABORTED;
//
//    // If registered, redirect to AF_XDP socket
//    if (*qidconf)
//        return bpf_redirect_map(&xsks_map, index, 0);
//
//    return XDP_PASS;
// }

// TODO: use zbpf lib
fn buildXdpProgram(allocator: mem.Allocator, qidconf_fd: i32, xsks_fd: i32) LoaderError![]BPF.Insn {
    var insns: ArrayList(BPF.Insn) = .{};
    errdefer insns.deinit(allocator);

    // r1 = *(u32 *)(r1 + 16) - load rx_queue_index from xdp_md
    try insns.append(allocator, BPF.Insn{ .code = 0x61, .dst = 1, .src = 1, .off = 16, .imm = 0 });

    // *(u32 *)(r10 - 4) = r1 - store queue index on stack
    try insns.append(allocator, BPF.Insn{ .code = 0x63, .dst = 10, .src = 1, .off = -4, .imm = 0 });

    // r2 = r10
    try insns.append(allocator, BPF.Insn{ .code = 0xbf, .dst = 2, .src = 10, .off = 0, .imm = 0 });

    // r2 += -4
    try insns.append(allocator, BPF.Insn{ .code = 0x07, .dst = 2, .src = 0, .off = 0, .imm = -4 });

    // Load map fd for qidconf_map (wide instruction)
    try insns.append(allocator, BPF.Insn{ .code = 0x18, .dst = 1, .src = 1, .off = 0, .imm = qidconf_fd });
    try insns.append(allocator, BPF.Insn{ .code = 0x00, .dst = 0, .src = 0, .off = 0, .imm = 0 });

    // call bpf_map_lookup_elem
    try insns.append(allocator, BPF.Insn{ .code = 0x85, .dst = 0, .src = 0, .off = 0, .imm = 1 });

    // r1 = r0
    try insns.append(allocator, BPF.Insn{ .code = 0xbf, .dst = 1, .src = 0, .off = 0, .imm = 0 });

    // r0 = 0
    try insns.append(allocator, BPF.Insn{ .code = 0xb4, .dst = 0, .src = 0, .off = 0, .imm = 0 });

    // if r1 == 0 goto +8 (exit with XDP_ABORTED = 0)
    try insns.append(allocator, BPF.Insn{ .code = 0x15, .dst = 1, .src = 0, .off = 8, .imm = 0 });

    // r0 = 2 (XDP_PASS)
    try insns.append(allocator, BPF.Insn{ .code = 0xb4, .dst = 0, .src = 0, .off = 0, .imm = 2 });

    // r1 = *(u32 *)(r1 + 0) - dereference the value
    try insns.append(allocator, BPF.Insn{ .code = 0x61, .dst = 1, .src = 1, .off = 0, .imm = 0 });

    // if r1 == 0 goto +5 (exit with XDP_PASS)
    try insns.append(allocator, BPF.Insn{ .code = 0x15, .dst = 1, .src = 0, .off = 5, .imm = 0 });

    // Load map fd for xsks_map (wide instruction)
    try insns.append(allocator, BPF.Insn{ .code = 0x18, .dst = 1, .src = 1, .off = 0, .imm = xsks_fd });
    try insns.append(allocator, BPF.Insn{ .code = 0x00, .dst = 0, .src = 0, .off = 0, .imm = 0 });

    // r2 = *(u32 *)(r10 - 4) - load queue index from stack
    try insns.append(allocator, BPF.Insn{ .code = 0x61, .dst = 2, .src = 10, .off = -4, .imm = 0 });

    // r3 = 0
    try insns.append(allocator, BPF.Insn{ .code = 0xb4, .dst = 3, .src = 0, .off = 0, .imm = 0 });

    // call bpf_redirect_map
    try insns.append(allocator, BPF.Insn{ .code = 0x85, .dst = 0, .src = 0, .off = 0, .imm = 51 });

    // exit
    try insns.append(allocator, BPF.Insn{ .code = 0x95, .dst = 0, .src = 0, .off = 0, .imm = 0 });

    return try insns.toOwnedSlice(allocator);
}

// TODO: implement netlink lib
// XDP-specific netlink attributes (from linux/if_link.h)
const IFLA_XDP = enum(c_ushort) {
    UNSPEC = 0,
    FD = 1,
    ATTACHED = 2,
    FLAGS = 3,
    PROG_ID = 4,
    DRV_PROG_ID = 5,
    SKB_PROG_ID = 6,
    HW_PROG_ID = 7,
    EXPECTED_FD = 8,

    _,
};

// Helper function to align netlink attribute length
fn nlmsgAlign(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

fn rtaAlign(len: usize) usize {
    return (len + linux.rtattr.ALIGNTO - 1) & ~@as(usize, linux.rtattr.ALIGNTO - 1);
}

// XDP program attachment using netlink
fn attachProgram(ifindex: u32, prog_fd: i32, flags: u32) LoaderError!void {
    // Create a netlink socket
    const sock = posix.socket(linux.AF.NETLINK, linux.SOCK.RAW, linux.NETLINK.ROUTE) catch {
        return LoaderError.NetlinkError;
    };
    defer posix.close(sock);

    // Bind the socket
    var addr: linux.sockaddr.nl = .{
        .pid = 0, // kernel will assign
        .groups = 0,
    };
    posix.bind(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)) catch {
        return LoaderError.NetlinkError;
    };

    // Build the netlink message
    var buf: [1024]u8 align(4) = undefined;
    @memset(&buf, 0);

    // Netlink message header
    const nlh: *linux.nlmsghdr = @ptrCast(@alignCast(&buf[0]));
    nlh.* = .{
        .len = @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg),
        .type = .RTM_SETLINK,
        .flags = linux.NLM_F_REQUEST | linux.NLM_F_ACK,
        .seq = 1,
        .pid = 0,
    };

    // Interface info message
    const ifi: *linux.ifinfomsg = @ptrCast(@alignCast(&buf[@sizeOf(linux.nlmsghdr)]));
    ifi.* = .{
        .family = linux.AF.UNSPEC,
        .type = 0,
        .index = @intCast(ifindex),
        .flags = 0,
        .change = 0,
    };

    // Current offset for attributes
    var offset = nlmsgAlign(@sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg));

    // Add XDP nested attribute
    const xdp_rta: *linux.rtattr = @ptrCast(@alignCast(&buf[offset]));
    const xdp_rta_start = offset;
    xdp_rta.len = @sizeOf(linux.rtattr);
    xdp_rta.type = .{ .link = .XDP };
    offset += @sizeOf(linux.rtattr);

    // Add IFLA_XDP_FD attribute
    const fd_rta: *linux.rtattr = @ptrCast(@alignCast(&buf[offset]));
    fd_rta.len = @intCast(@sizeOf(linux.rtattr) + @sizeOf(i32));
    fd_rta.type = .{ .link = @enumFromInt(@intFromEnum(IFLA_XDP.FD)) };
    offset += @sizeOf(linux.rtattr);

    const fd_ptr: *i32 = @ptrCast(@alignCast(&buf[offset]));
    fd_ptr.* = prog_fd;
    offset += @sizeOf(i32);
    offset = rtaAlign(offset);

    // Add IFLA_XDP_FLAGS attribute
    const flags_rta: *linux.rtattr = @ptrCast(@alignCast(&buf[offset]));
    flags_rta.len = @intCast(@sizeOf(linux.rtattr) + @sizeOf(u32));
    flags_rta.type = .{ .link = @enumFromInt(@intFromEnum(IFLA_XDP.FLAGS)) };
    offset += @sizeOf(linux.rtattr);

    const flags_ptr: *u32 = @ptrCast(@alignCast(&buf[offset]));
    flags_ptr.* = flags;
    offset += @sizeOf(u32);
    offset = rtaAlign(offset);

    // Update XDP nested attribute length
    xdp_rta.len = @intCast(offset - xdp_rta_start);

    // Update total message length
    nlh.len = @intCast(offset);

    // Send the message
    _ = posix.send(sock, buf[0..offset], 0) catch {
        return LoaderError.NetlinkError;
    };

    // Receive the acknowledgment
    var resp_buf: [4096]u8 align(4) = undefined;
    const recv_len = posix.recv(sock, &resp_buf, 0) catch {
        return LoaderError.NetlinkError;
    };

    // Parse the response
    const resp_nlh: *const linux.nlmsghdr = @ptrCast(@alignCast(&resp_buf[0]));
    if (resp_nlh.type == .ERROR) {
        // Error message contains errno in the payload
        if (recv_len >= @sizeOf(linux.nlmsghdr) + @sizeOf(i32)) {
            const errno_ptr: *const i32 = @ptrCast(@alignCast(&resp_buf[@sizeOf(linux.nlmsghdr)]));
            if (errno_ptr.* != 0) {
                std.debug.print("XDP attach failed with errno: {}\n", .{-errno_ptr.*});
                return LoaderError.AttachFailed;
            }
        }
    }
}

fn removeProgram(ifindex: u32) LoaderError!void {
    // Create a netlink socket
    const sock = posix.socket(linux.AF.NETLINK, linux.SOCK.RAW, linux.NETLINK.ROUTE) catch {
        return LoaderError.NetlinkError;
    };
    defer posix.close(sock);

    // Bind the socket
    var addr: linux.sockaddr.nl = .{
        .pid = 0,
        .groups = 0,
    };
    posix.bind(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)) catch {
        return LoaderError.NetlinkError;
    };

    // Build the netlink message
    var buf: [1024]u8 align(4) = undefined;
    @memset(&buf, 0);

    // Netlink message header
    const nlh: *linux.nlmsghdr = @ptrCast(@alignCast(&buf[0]));
    nlh.* = .{
        .len = @sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg),
        .type = .RTM_SETLINK,
        .flags = linux.NLM_F_REQUEST | linux.NLM_F_ACK,
        .seq = 1,
        .pid = 0,
    };

    // Interface info message
    const ifi: *linux.ifinfomsg = @ptrCast(@alignCast(&buf[@sizeOf(linux.nlmsghdr)]));
    ifi.* = .{
        .family = linux.AF.UNSPEC,
        .type = 0,
        .index = @intCast(ifindex),
        .flags = 0,
        .change = 0,
    };

    // Current offset for attributes
    var offset = nlmsgAlign(@sizeOf(linux.nlmsghdr) + @sizeOf(linux.ifinfomsg));

    // Add XDP nested attribute
    const xdp_rta: *linux.rtattr = @ptrCast(@alignCast(&buf[offset]));
    const xdp_rta_start = offset;
    xdp_rta.len = @sizeOf(linux.rtattr);
    xdp_rta.type = .{ .link = .XDP };
    offset += @sizeOf(linux.rtattr);

    // Add IFLA_XDP_FD attribute with -1 (detach)
    const fd_rta: *linux.rtattr = @ptrCast(@alignCast(&buf[offset]));
    fd_rta.len = @intCast(@sizeOf(linux.rtattr) + @sizeOf(i32));
    fd_rta.type = .{ .link = @enumFromInt(@intFromEnum(IFLA_XDP.FD)) };
    offset += @sizeOf(linux.rtattr);

    const fd_ptr: *i32 = @ptrCast(@alignCast(&buf[offset]));
    fd_ptr.* = -1; // -1 means detach
    offset += @sizeOf(i32);
    offset = rtaAlign(offset);

    // Update XDP nested attribute length
    xdp_rta.len = @intCast(offset - xdp_rta_start);

    // Update total message length
    nlh.len = @intCast(offset);

    // Send the message
    _ = posix.send(sock, buf[0..offset], 0) catch {
        return LoaderError.NetlinkError;
    };

    // Receive the acknowledgment
    var resp_buf: [4096]u8 align(4) = undefined;
    const recv_len = posix.recv(sock, &resp_buf, 0) catch {
        return LoaderError.NetlinkError;
    };

    // Parse the response
    const resp_nlh: *const linux.nlmsghdr = @ptrCast(@alignCast(&resp_buf[0]));
    if (resp_nlh.type == .ERROR) {
        if (recv_len >= @sizeOf(linux.nlmsghdr) + @sizeOf(i32)) {
            const errno_ptr: *const i32 = @ptrCast(@alignCast(&resp_buf[@sizeOf(linux.nlmsghdr)]));
            if (errno_ptr.* != 0) {
                std.debug.print("XDP detach failed with errno: {}\n", .{-errno_ptr.*});
                return LoaderError.DetachFailed;
            }
        }
    }
}

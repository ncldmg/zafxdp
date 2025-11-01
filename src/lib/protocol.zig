const std = @import("std");
const mem = std.mem;

/// Ethernet frame header (14 bytes)
pub const EthernetHeader = struct {
    destination: [6]u8,
    source: [6]u8,
    ethertype: u16,

    pub const SIZE = 14;

    pub fn parse(data: []const u8) !EthernetHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .destination = data[0..6].*,
            .source = data[6..12].*,
            .ethertype = mem.readInt(u16, data[12..14], .big),
        };
    }

    pub fn write(self: *const EthernetHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        @memcpy(buf[0..6], &self.destination);
        @memcpy(buf[6..12], &self.source);
        mem.writeInt(u16, buf[12..14], self.ethertype, .big);
    }

    pub fn format(
        self: EthernetHeader,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} -> {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} (0x{x:0>4})", .{
            self.source[0],      self.source[1],      self.source[2],
            self.source[3],      self.source[4],      self.source[5],
            self.destination[0], self.destination[1], self.destination[2],
            self.destination[3], self.destination[4], self.destination[5],
            self.ethertype,
        });
    }
};

pub const EtherType = struct {
    pub const IPv4: u16 = 0x0800;
    pub const ARP: u16 = 0x0806;
    pub const IPv6: u16 = 0x86DD;
};

/// IPv4 header (minimum 20 bytes)
pub const IPv4Header = struct {
    version: u4,
    ihl: u4, // Internet Header Length (in 32-bit words)
    dscp: u6,
    ecn: u2,
    total_length: u16,
    identification: u16,
    flags: u3,
    fragment_offset: u13,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    source: [4]u8,
    destination: [4]u8,

    pub const MIN_SIZE = 20;

    pub fn parse(data: []const u8) !IPv4Header {
        if (data.len < MIN_SIZE) return error.PacketTooShort;

        const version_ihl = data[0];
        const dscp_ecn = data[1];
        const flags_frag = mem.readInt(u16, data[6..8], .big);

        return .{
            .version = @truncate(version_ihl >> 4),
            .ihl = @truncate(version_ihl & 0x0F),
            .dscp = @truncate(dscp_ecn >> 2),
            .ecn = @truncate(dscp_ecn & 0x03),
            .total_length = mem.readInt(u16, data[2..4], .big),
            .identification = mem.readInt(u16, data[4..6], .big),
            .flags = @truncate(flags_frag >> 13),
            .fragment_offset = @truncate(flags_frag & 0x1FFF),
            .ttl = data[8],
            .protocol = data[9],
            .checksum = mem.readInt(u16, data[10..12], .big),
            .source = data[12..16].*,
            .destination = data[16..20].*,
        };
    }

    pub fn headerLength(self: *const IPv4Header) u8 {
        return @as(u8, self.ihl) * 4;
    }

    pub fn write(self: *const IPv4Header, buf: []u8) !void {
        if (buf.len < MIN_SIZE) return error.BufferTooSmall;

        buf[0] = (@as(u8, self.version) << 4) | self.ihl;
        buf[1] = (@as(u8, self.dscp) << 2) | self.ecn;
        mem.writeInt(u16, buf[2..4], self.total_length, .big);
        mem.writeInt(u16, buf[4..6], self.identification, .big);

        const flags_frag = (@as(u16, self.flags) << 13) | self.fragment_offset;
        mem.writeInt(u16, buf[6..8], flags_frag, .big);

        buf[8] = self.ttl;
        buf[9] = self.protocol;
        mem.writeInt(u16, buf[10..12], self.checksum, .big);
        @memcpy(buf[12..16], &self.source);
        @memcpy(buf[16..20], &self.destination);
    }

    pub fn calculateChecksum(self: *const IPv4Header) u16 {
        var sum: u32 = 0;
        var buf: [MIN_SIZE]u8 = undefined;
        self.write(&buf) catch unreachable;

        // Zero out checksum field
        buf[10] = 0;
        buf[11] = 0;

        // Sum 16-bit words
        var i: usize = 0;
        while (i < self.headerLength()) : (i += 2) {
            sum += mem.readInt(u16, buf[i .. i + 2], .big);
        }

        // Add carries
        while (sum >> 16 != 0) {
            sum = (sum & 0xFFFF) + (sum >> 16);
        }

        return ~@as(u16, @truncate(sum));
    }

    pub fn format(
        self: IPv4Header,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}.{}.{}.{} -> {}.{}.{}.{} proto={} ttl={} len={}", .{
            self.source[0],      self.source[1],      self.source[2],      self.source[3],
            self.destination[0], self.destination[1], self.destination[2], self.destination[3],
            self.protocol,
            self.ttl,
            self.total_length,
        });
    }
};

pub const IpProtocol = struct {
    pub const ICMP: u8 = 1;
    pub const TCP: u8 = 6;
    pub const UDP: u8 = 17;
    pub const ICMPv6: u8 = 58;
};

/// TCP header (minimum 20 bytes)
pub const TcpHeader = struct {
    source_port: u16,
    destination_port: u16,
    sequence_number: u32,
    acknowledgment_number: u32,
    data_offset: u4, // in 32-bit words
    reserved: u3,
    flags: TcpFlags,
    window_size: u16,
    checksum: u16,
    urgent_pointer: u16,

    pub const MIN_SIZE = 20;

    pub fn parse(data: []const u8) !TcpHeader {
        if (data.len < MIN_SIZE) return error.PacketTooShort;

        const offset_reserved_flags = mem.readInt(u16, data[12..14], .big);

        return .{
            .source_port = mem.readInt(u16, data[0..2], .big),
            .destination_port = mem.readInt(u16, data[2..4], .big),
            .sequence_number = mem.readInt(u32, data[4..8], .big),
            .acknowledgment_number = mem.readInt(u32, data[8..12], .big),
            .data_offset = @truncate(offset_reserved_flags >> 12),
            .reserved = @truncate((offset_reserved_flags >> 9) & 0x07),
            .flags = TcpFlags.fromByte(@truncate(offset_reserved_flags & 0x1FF)),
            .window_size = mem.readInt(u16, data[14..16], .big),
            .checksum = mem.readInt(u16, data[16..18], .big),
            .urgent_pointer = mem.readInt(u16, data[18..20], .big),
        };
    }

    pub fn headerLength(self: *const TcpHeader) u8 {
        return @as(u8, self.data_offset) * 4;
    }

    pub fn write(self: *const TcpHeader, buf: []u8) !void {
        if (buf.len < MIN_SIZE) return error.BufferTooSmall;

        mem.writeInt(u16, buf[0..2], self.source_port, .big);
        mem.writeInt(u16, buf[2..4], self.destination_port, .big);
        mem.writeInt(u32, buf[4..8], self.sequence_number, .big);
        mem.writeInt(u32, buf[8..12], self.acknowledgment_number, .big);

        const offset_reserved_flags = (@as(u16, self.data_offset) << 12) |
            (@as(u16, self.reserved) << 9) |
            self.flags.toByte();
        mem.writeInt(u16, buf[12..14], offset_reserved_flags, .big);

        mem.writeInt(u16, buf[14..16], self.window_size, .big);
        mem.writeInt(u16, buf[16..18], self.checksum, .big);
        mem.writeInt(u16, buf[18..20], self.urgent_pointer, .big);
    }

    pub fn format(
        self: TcpHeader,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}:{} -> {}:{} seq={} ack={} {}", .{
            self.source_port,
            self.destination_port,
            self.sequence_number,
            self.acknowledgment_number,
            self.flags,
        });
    }
};

pub const TcpFlags = packed struct {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,
    ns: bool = false,

    pub fn fromByte(byte: u9) TcpFlags {
        return @bitCast(byte);
    }

    pub fn toByte(self: TcpFlags) u9 {
        return @bitCast(self);
    }

    pub fn format(
        self: TcpFlags,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("[");
        var first = true;
        inline for (@typeInfo(TcpFlags).Struct.fields) |field| {
            if (@field(self, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeAll("]");
    }
};

/// UDP header (8 bytes)
pub const UdpHeader = struct {
    source_port: u16,
    destination_port: u16,
    length: u16,
    checksum: u16,

    pub const SIZE = 8;

    pub fn parse(data: []const u8) !UdpHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .source_port = mem.readInt(u16, data[0..2], .big),
            .destination_port = mem.readInt(u16, data[2..4], .big),
            .length = mem.readInt(u16, data[4..6], .big),
            .checksum = mem.readInt(u16, data[6..8], .big),
        };
    }

    pub fn write(self: *const UdpHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        mem.writeInt(u16, buf[0..2], self.source_port, .big);
        mem.writeInt(u16, buf[2..4], self.destination_port, .big);
        mem.writeInt(u16, buf[4..6], self.length, .big);
        mem.writeInt(u16, buf[6..8], self.checksum, .big);
    }

    pub fn format(
        self: UdpHeader,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}:{} -> {}:{} len={}", .{
            self.source_port,
            self.destination_port,
            self.length,
        });
    }
};

/// ICMP header (8 bytes minimum)
pub const IcmpHeader = struct {
    type: u8,
    code: u8,
    checksum: u16,
    rest_of_header: u32, // Depends on type/code

    pub const SIZE = 8;

    pub fn parse(data: []const u8) !IcmpHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .type = data[0],
            .code = data[1],
            .checksum = mem.readInt(u16, data[2..4], .big),
            .rest_of_header = mem.readInt(u32, data[4..8], .big),
        };
    }

    pub fn write(self: *const IcmpHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        buf[0] = self.type;
        buf[1] = self.code;
        mem.writeInt(u16, buf[2..4], self.checksum, .big);
        mem.writeInt(u32, buf[4..8], self.rest_of_header, .big);
    }
};

/// ARP packet (28 bytes for IPv4 over Ethernet)
pub const ArpHeader = struct {
    hardware_type: u16,
    protocol_type: u16,
    hardware_addr_len: u8,
    protocol_addr_len: u8,
    operation: u16,
    sender_hw_addr: [6]u8,
    sender_proto_addr: [4]u8,
    target_hw_addr: [6]u8,
    target_proto_addr: [4]u8,

    pub const SIZE = 28;

    pub fn parse(data: []const u8) !ArpHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .hardware_type = mem.readInt(u16, data[0..2], .big),
            .protocol_type = mem.readInt(u16, data[2..4], .big),
            .hardware_addr_len = data[4],
            .protocol_addr_len = data[5],
            .operation = mem.readInt(u16, data[6..8], .big),
            .sender_hw_addr = data[8..14].*,
            .sender_proto_addr = data[14..18].*,
            .target_hw_addr = data[18..24].*,
            .target_proto_addr = data[24..28].*,
        };
    }

    pub fn write(self: *const ArpHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        mem.writeInt(u16, buf[0..2], self.hardware_type, .big);
        mem.writeInt(u16, buf[2..4], self.protocol_type, .big);
        buf[4] = self.hardware_addr_len;
        buf[5] = self.protocol_addr_len;
        mem.writeInt(u16, buf[6..8], self.operation, .big);
        @memcpy(buf[8..14], &self.sender_hw_addr);
        @memcpy(buf[14..18], &self.sender_proto_addr);
        @memcpy(buf[18..24], &self.target_hw_addr);
        @memcpy(buf[24..28], &self.target_proto_addr);
    }
};

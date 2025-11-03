const std = @import("std");
const protocol = @import("protocol.zig");
const xsk = @import("xsk.zig");

pub const EthernetHeader = protocol.EthernetHeader;
pub const IPv4Header = protocol.IPv4Header;
pub const TcpHeader = protocol.TcpHeader;
pub const UdpHeader = protocol.UdpHeader;
pub const IcmpHeader = protocol.IcmpHeader;
pub const ArpHeader = protocol.ArpHeader;
pub const EtherType = protocol.EtherType;
pub const IpProtocol = protocol.IpProtocol;
pub const XDPDesc = xsk.XDPDesc;

// Source information for a packet
pub const PacketSource = struct {
    ifindex: u32,
    queue_id: u32,
    interface_name: ?[]const u8 = null,
};

// Cached packet metadata
pub const PacketMetadata = struct {
    ethernet: ?EthernetHeader = null,
    ipv4: ?IPv4Header = null,
    tcp: ?TcpHeader = null,
    udp: ?UdpHeader = null,
    icmp: ?IcmpHeader = null,
    arp: ?ArpHeader = null,

    // Offsets into packet data
    l2_offset: usize = 0,
    l3_offset: usize = 0,
    l4_offset: usize = 0,
    payload_offset: usize = 0,
};

// Zero-copy packet reference with lazy parsing
pub const Packet = struct {
    // Pointer to raw packet data in UMEM
    data: []u8,

    // XDP descriptor (contains offset, length, options)
    desc: XDPDesc,

    // Metadata parsed on-demand
    metadata: PacketMetadata,

    // Source interface/queue
    source: PacketSource,

    // Timestamp (if available)
    timestamp: ?i64 = null,

    const Self = @This();

    // Create a packet from UMEM data and descriptor
    pub fn init(data: []u8, desc: XDPDesc, source: PacketSource) Packet {
        return .{
            .data = data,
            .desc = desc,
            .metadata = .{},
            .source = source,
            .timestamp = null,
        };
    }

    // Get packet length
    pub fn len(self: *const Self) u32 {
        return self.desc.len;
    }

    // Get payload (entire packet data)
    pub fn payload(self: *Self) []u8 {
        return self.data[0..self.desc.len];
    }

    // Get raw packet data as const slice
    pub fn raw(self: *const Self) []const u8 {
        return self.data[0..self.desc.len];
    }

    // Parse Ethernet header (cached)
    pub fn ethernet(self: *Self) !*EthernetHeader {
        if (self.metadata.ethernet == null) {
            const eth = try EthernetHeader.parse(self.payload());
            self.metadata.ethernet = eth;
            self.metadata.l2_offset = 0;
            self.metadata.l3_offset = EthernetHeader.SIZE;
        }
        return &self.metadata.ethernet.?;
    }

    // Parse IPv4 header (cached)
    pub fn ipv4(self: *Self) !*IPv4Header {
        if (self.metadata.ipv4 == null) {
            // Ensure ethernet is parsed first
            _ = try self.ethernet();

            const l3_data = self.payload()[self.metadata.l3_offset..];
            const ip = try IPv4Header.parse(l3_data);
            self.metadata.ipv4 = ip;
            self.metadata.l4_offset = self.metadata.l3_offset + ip.headerLength();
        }
        return &self.metadata.ipv4.?;
    }

    // Parse TCP header (cached)
    pub fn tcp(self: *Self) !*TcpHeader {
        if (self.metadata.tcp == null) {
            // Ensure IPv4 is parsed first
            _ = try self.ipv4();

            const l4_data = self.payload()[self.metadata.l4_offset..];
            const tcp_hdr = try TcpHeader.parse(l4_data);
            self.metadata.tcp = tcp_hdr;
            self.metadata.payload_offset = self.metadata.l4_offset + tcp_hdr.headerLength();
        }
        return &self.metadata.tcp.?;
    }

    // Parse UDP header (cached)
    pub fn udp(self: *Self) !*UdpHeader {
        if (self.metadata.udp == null) {
            // Ensure IPv4 is parsed first
            _ = try self.ipv4();

            const l4_data = self.payload()[self.metadata.l4_offset..];
            const udp_hdr = try UdpHeader.parse(l4_data);
            self.metadata.udp = udp_hdr;
            self.metadata.payload_offset = self.metadata.l4_offset + UdpHeader.SIZE;
        }
        return &self.metadata.udp.?;
    }

    // Parse ICMP header (cached)
    pub fn icmp(self: *Self) !*IcmpHeader {
        if (self.metadata.icmp == null) {
            // Ensure IPv4 is parsed first
            _ = try self.ipv4();

            const l4_data = self.payload()[self.metadata.l4_offset..];
            const icmp_hdr = try IcmpHeader.parse(l4_data);
            self.metadata.icmp = icmp_hdr;
            self.metadata.payload_offset = self.metadata.l4_offset + IcmpHeader.SIZE;
        }
        return &self.metadata.icmp.?;
    }

    // Parse ARP packet (cached)
    pub fn arp(self: *Self) !*ArpHeader {
        if (self.metadata.arp == null) {
            // Ensure ethernet is parsed first
            _ = try self.ethernet();

            const l3_data = self.payload()[self.metadata.l3_offset..];
            const arp_hdr = try ArpHeader.parse(l3_data);
            self.metadata.arp = arp_hdr;
        }
        return &self.metadata.arp.?;
    }

    // Get L2 (Ethernet) data
    pub fn l2Data(self: *Self) []u8 {
        return self.payload()[self.metadata.l2_offset..];
    }

    // Get L3 (IP) data
    pub fn l3Data(self: *Self) ![]u8 {
        _ = try self.ethernet(); // Ensure offsets are set
        return self.payload()[self.metadata.l3_offset..];
    }

    // Get L4 (TCP/UDP) data
    pub fn l4Data(self: *Self) ![]u8 {
        _ = try self.ipv4(); // Ensure offsets are set
        return self.payload()[self.metadata.l4_offset..];
    }

    // Get application payload data
    pub fn payloadData(self: *Self) []u8 {
        if (self.metadata.payload_offset > 0) {
            return self.payload()[self.metadata.payload_offset..];
        }
        return self.payload();
    }

    // Modify the packet in place (write back to UMEM)
    pub fn modify(self: *Self, offset: usize, data: []const u8) !void {
        if (offset + data.len > self.desc.len) {
            return error.ModificationOutOfBounds;
        }
        @memcpy(self.data[offset .. offset + data.len], data);

        // Invalidate cached metadata if we modified headers
        if (offset < EthernetHeader.SIZE) {
            self.metadata.ethernet = null;
        }
        if (offset < self.metadata.l3_offset + IPv4Header.MIN_SIZE) {
            self.metadata.ipv4 = null;
        }
        if (offset < self.metadata.l4_offset + TcpHeader.MIN_SIZE) {
            self.metadata.tcp = null;
            self.metadata.udp = null;
        }
    }

    // Format packet for debug output
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Packet[len={}, if={}, queue={}]", .{
            self.len(),
            self.source.ifindex,
            self.source.queue_id,
        });
    }
};

// Tests
const testing = std.testing;

test "Protocol parsing with Packet API" {
    _ = testing.allocator;

    // Create a simple Ethernet frame with IPv4/UDP
    var frame_data: [128]u8 = undefined;
    @memset(&frame_data, 0);

    // Ethernet header
    const dst_mac = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const src_mac = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    @memcpy(frame_data[0..6], &dst_mac);
    @memcpy(frame_data[6..12], &src_mac);
    std.mem.writeInt(u16, frame_data[12..14], 0x0800, .big); // IPv4

    // Simple IPv4 header (version=4, ihl=5, total_length=20)
    frame_data[14] = 0x45; // version=4, ihl=5
    frame_data[15] = 0x00; // DSCP/ECN
    std.mem.writeInt(u16, frame_data[16..18], 48, .big); // total length
    frame_data[23] = 17; // protocol = UDP
    // Source IP: 192.168.1.1
    frame_data[26] = 192;
    frame_data[27] = 168;
    frame_data[28] = 1;
    frame_data[29] = 1;
    // Dest IP: 192.168.1.2
    frame_data[30] = 192;
    frame_data[31] = 168;
    frame_data[32] = 1;
    frame_data[33] = 2;

    // UDP header at offset 34
    std.mem.writeInt(u16, frame_data[34..36], 12345, .big); // src port
    std.mem.writeInt(u16, frame_data[36..38], 53, .big); // dst port (DNS)
    std.mem.writeInt(u16, frame_data[38..40], 28, .big); // length
    std.mem.writeInt(u16, frame_data[40..42], 0, .big); // checksum

    // Create a packet
    const desc = XDPDesc{
        .addr = 0,
        .len = 62,
        .options = 0,
    };

    var packet = Packet.init(&frame_data, desc, .{
        .ifindex = 1,
        .queue_id = 0,
    });

    // Parse Ethernet
    const eth = try packet.ethernet();
    try testing.expectEqual(@as(u16, 0x0800), eth.ethertype);
    try testing.expectEqualSlices(u8, &src_mac, &eth.source);

    // Parse IPv4
    const ipv4 = try packet.ipv4();
    try testing.expectEqual(@as(u8, 4), ipv4.version);
    try testing.expectEqual(@as(u8, 17), ipv4.protocol); // UDP
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &ipv4.source);

    // Parse UDP
    const udp = try packet.udp();
    try testing.expectEqual(@as(u16, 12345), udp.source_port);
    try testing.expectEqual(@as(u16, 53), udp.destination_port);

    std.debug.print("✓ Protocol parsing test passed\n", .{});
    std.debug.print("  Ethernet: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} -> {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
        eth.source[0],      eth.source[1],      eth.source[2],
        eth.source[3],      eth.source[4],      eth.source[5],
        eth.destination[0], eth.destination[1], eth.destination[2],
        eth.destination[3], eth.destination[4], eth.destination[5],
    });
    std.debug.print("  IPv4: {}.{}.{}.{} -> {}.{}.{}.{}\n", .{
        ipv4.source[0],      ipv4.source[1],      ipv4.source[2],      ipv4.source[3],
        ipv4.destination[0], ipv4.destination[1], ipv4.destination[2], ipv4.destination[3],
    });
    std.debug.print("  UDP: {} -> {}\n", .{ udp.source_port, udp.destination_port });
}

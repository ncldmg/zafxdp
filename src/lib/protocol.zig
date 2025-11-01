const std = @import("std");
const mem = std.mem;

// Ethernet frame header (14 bytes - Layer 2, always first in network frames)
pub const EthernetHeader = struct {
    destination: [6]u8, // Destination MAC address (48-bit hardware address, e.g., ff:ff:ff:ff:ff:ff for broadcast)
    source: [6]u8, // Source MAC address (48-bit hardware address of sender)
    ethertype: u16, // EtherType (identifies payload protocol: 0x0800=IPv4, 0x0806=ARP, 0x86DD=IPv6)

    pub const SIZE = 14;

    // Parse Ethernet header from raw frame bytes (no bit packing, all fields aligned)
    pub fn parse(data: []const u8) !EthernetHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .destination = data[0..6].*, // Bytes 0-5: convert slice to [6]u8 array
            .source = data[6..12].*, // Bytes 6-11: convert slice to [6]u8 array
            .ethertype = mem.readInt(u16, data[12..14], .big), // Bytes 12-13: 16-bit big-endian
        };
    }

    // Write Ethernet header to buffer
    pub fn write(self: *const EthernetHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        @memcpy(buf[0..6], &self.destination); // Bytes 0-5: copy destination MAC
        @memcpy(buf[6..12], &self.source); // Bytes 6-11: copy source MAC
        mem.writeInt(u16, buf[12..14], self.ethertype, .big); // Bytes 12-13: ethertype as big-endian
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

// Common EtherType values (identifies payload protocol in Ethernet frames)
pub const EtherType = struct {
    pub const IPv4: u16 = 0x0800; // Internet Protocol version 4
    pub const ARP: u16 = 0x0806; // Address Resolution Protocol
    pub const IPv6: u16 = 0x86DD; // Internet Protocol version 6
};

// IPv4 header (minimum 20 bytes)
pub const IPv4Header = struct {
    version: u4, // IP version (always 4 for IPv4)
    ihl: u4, // Internet Header Length (in 32-bit words, minimum 5 = 20 bytes)
    dscp: u6, // Differentiated Services Code Point (for QoS/priority)
    ecn: u2, // Explicit Congestion Notification (network congestion signaling)
    total_length: u16, // Total packet length including header and data (max 65535 bytes)
    identification: u16, // Unique identifier for fragments of a single packet
    flags: u3, // Control flags: bit 0=reserved, bit 1=Don't Fragment, bit 2=More Fragments
    fragment_offset: u13, // Position of this fragment in the original packet (in 8-byte units)
    ttl: u8, // Time To Live (hop count, decremented by each router)
    protocol: u8, // Upper layer protocol (1=ICMP, 6=TCP, 17=UDP, etc.)
    checksum: u16, // Header checksum for error detection (data is not checksummed)
    source: [4]u8, // Source IP address (4 bytes = 32 bits)
    destination: [4]u8, // Destination IP address (4 bytes = 32 bits)

    pub const MIN_SIZE = 20;

    pub fn parse(data: []const u8) !IPv4Header {
        if (data.len < MIN_SIZE) return error.PacketTooShort;

        // Byte 0: [version:4 bits][ihl:4 bits]
        const version_ihl = data[0];
        // Byte 1: [dscp:6 bits][ecn:2 bits]
        const dscp_ecn = data[1];
        // Bytes 6-7: [flags:3 bits][fragment_offset:13 bits]
        const flags_frag = mem.readInt(u16, data[6..8], .big);

        return .{
            .version = @truncate(version_ihl >> 4), // Shift right 4 bits to get upper 4 bits
            .ihl = @truncate(version_ihl & 0x0F), // Mask with 0x0F (0000_1111) to get lower 4 bits
            .dscp = @truncate(dscp_ecn >> 2), // Shift right 2 bits to get upper 6 bits
            .ecn = @truncate(dscp_ecn & 0x03), // Mask with 0x03 (0000_0011) to get lower 2 bits
            .total_length = mem.readInt(u16, data[2..4], .big), // Bytes 2-3: 16-bit big-endian
            .identification = mem.readInt(u16, data[4..6], .big), // Bytes 4-5: 16-bit big-endian
            .flags = @truncate(flags_frag >> 13), // Shift right 13 bits to get upper 3 bits
            .fragment_offset = @truncate(flags_frag & 0x1FFF), // Mask with 0x1FFF (0001_1111_1111_1111) to get lower 13 bits
            .ttl = data[8], // Byte 8: single byte value
            .protocol = data[9], // Byte 9: single byte value
            .checksum = mem.readInt(u16, data[10..12], .big), // Bytes 10-11: 16-bit big-endian
            .source = data[12..16].*, // Bytes 12-15: 4-byte array (convert slice to array)
            .destination = data[16..20].*, // Bytes 16-19: 4-byte array (convert slice to array)
        };
    }

    // Calculate actual header length in bytes (ihl is in 32-bit words)
    pub fn headerLength(self: *const IPv4Header) u8 {
        // Cast ihl to u8 before multiply to prevent overflow (ihl is u4, max value 15)
        // Example: ihl=5 → 5 × 4 = 20 bytes, ihl=6 → 6 × 4 = 24 bytes
        return @as(u8, self.ihl) * 4;
    }

    // Write IPv4 header to buffer (reverse of parse, packs fields into bytes)
    pub fn write(self: *const IPv4Header, buf: []u8) !void {
        if (buf.len < MIN_SIZE) return error.BufferTooSmall;

        // Byte 0: Pack version (upper 4 bits) and ihl (lower 4 bits)
        // Shift version left 4 bits, then OR with ihl
        // Example: version=4 (0100), ihl=5 (0101) → 0100_0101 = 0x45
        buf[0] = (@as(u8, self.version) << 4) | self.ihl;

        // Byte 1: Pack dscp (upper 6 bits) and ecn (lower 2 bits)
        // Shift dscp left 2 bits, then OR with ecn
        buf[1] = (@as(u8, self.dscp) << 2) | self.ecn;

        // Bytes 2-3: Total length as 16-bit big-endian
        mem.writeInt(u16, buf[2..4], self.total_length, .big);

        // Bytes 4-5: Identification as 16-bit big-endian
        mem.writeInt(u16, buf[4..6], self.identification, .big);

        // Bytes 6-7: Pack flags (upper 3 bits) and fragment_offset (lower 13 bits)
        // Shift flags left 13 bits, then OR with fragment_offset
        const flags_frag = (@as(u16, self.flags) << 13) | self.fragment_offset;
        mem.writeInt(u16, buf[6..8], flags_frag, .big);

        // Bytes 8-9: Single byte values
        buf[8] = self.ttl;
        buf[9] = self.protocol;

        // Bytes 10-11: Checksum as 16-bit big-endian
        mem.writeInt(u16, buf[10..12], self.checksum, .big);

        // Bytes 12-15: Source IP (copy 4-byte array)
        @memcpy(buf[12..16], &self.source);

        // Bytes 16-19: Destination IP (copy 4-byte array)
        @memcpy(buf[16..20], &self.destination);
    }

    // Calculate IPv4 header checksum using one's complement algorithm (RFC 791)
    pub fn calculateChecksum(self: *const IPv4Header) u16 {
        // Use u32 to accumulate sum and detect overflow (carries)
        var sum: u32 = 0;

        // Serialize header to bytes so we can process it in 16-bit chunks
        var buf: [MIN_SIZE]u8 = undefined;
        self.write(&buf) catch unreachable; // Can't fail with correctly sized buffer

        // Zero out checksum field (bytes 10-11) before calculation
        // The checksum is calculated with this field set to 0
        buf[10] = 0;
        buf[11] = 0;

        // Sum all 16-bit words in the header (step through 2 bytes at a time)
        // For standard 20-byte header: processes 10 words (20 bytes / 2)
        var i: usize = 0;
        while (i < self.headerLength()) : (i += 2) {
            sum += mem.readInt(u16, buf[i .. i + 2], .big);
        }

        // Add carries: fold any overflow (upper 16 bits) back into lower 16 bits
        // This implements one's complement addition
        // Example: if sum=0x1_FFFF, then (0xFFFF) + (0x1) = 0x1_0000, repeat until no carry
        while (sum >> 16 != 0) {
            sum = (sum & 0xFFFF) + (sum >> 16);
        }

        // Take one's complement (bitwise NOT) of the final sum
        // Truncate to u16 first, then invert all bits
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
            self.protocol,       self.ttl,            self.total_length,
        });
    }
};

// Common IP Protocol numbers (identifies payload protocol in IPv4/IPv6 packets)
pub const IpProtocol = struct {
    pub const ICMP: u8 = 1; // Internet Control Message Protocol (ping, error messages)
    pub const TCP: u8 = 6; // Transmission Control Protocol (reliable, connection-oriented)
    pub const UDP: u8 = 17; // User Datagram Protocol (unreliable, connectionless)
    pub const ICMPv6: u8 = 58; // ICMP for IPv6
};

// TCP header (minimum 20 bytes)
pub const TcpHeader = struct {
    source_port: u16, // Source port number (identifies sending application)
    destination_port: u16, // Destination port number (identifies receiving application)
    sequence_number: u32, // Sequence number (byte offset of first data byte in this segment)
    acknowledgment_number: u32, // Acknowledgment number (next expected byte from peer)
    data_offset: u4, // Header length in 32-bit words (minimum 5 = 20 bytes, max 15 = 60 bytes)
    reserved: u3, // Reserved bits (must be zero)
    flags: TcpFlags, // Control flags (SYN, ACK, FIN, RST, PSH, URG, ECE, CWR, NS)
    window_size: u16, // Receive window size (bytes peer is willing to accept)
    checksum: u16, // Header and data checksum (includes pseudo-header)
    urgent_pointer: u16, // Pointer to urgent data (only valid if URG flag is set)

    pub const MIN_SIZE = 20;

    pub fn parse(data: []const u8) !TcpHeader {
        if (data.len < MIN_SIZE) return error.PacketTooShort;

        // Bytes 12-13: [data_offset:4 bits][reserved:3 bits][flags:9 bits]
        const offset_reserved_flags = mem.readInt(u16, data[12..14], .big);

        return .{
            .source_port = mem.readInt(u16, data[0..2], .big), // Bytes 0-1
            .destination_port = mem.readInt(u16, data[2..4], .big), // Bytes 2-3
            .sequence_number = mem.readInt(u32, data[4..8], .big), // Bytes 4-7
            .acknowledgment_number = mem.readInt(u32, data[8..12], .big), // Bytes 8-11
            .data_offset = @truncate(offset_reserved_flags >> 12), // Upper 4 bits
            .reserved = @truncate((offset_reserved_flags >> 9) & 0x07), // Next 3 bits (mask with 0x07 = 0000_0111)
            .flags = TcpFlags.fromByte(@truncate(offset_reserved_flags & 0x1FF)), // Lower 9 bits (mask with 0x1FF = 0001_1111_1111)
            .window_size = mem.readInt(u16, data[14..16], .big), // Bytes 14-15
            .checksum = mem.readInt(u16, data[16..18], .big), // Bytes 16-17
            .urgent_pointer = mem.readInt(u16, data[18..20], .big), // Bytes 18-19
        };
    }

    // Calculate actual header length in bytes (data_offset is in 32-bit words)
    pub fn headerLength(self: *const TcpHeader) u8 {
        // Cast data_offset to u8 before multiply to prevent overflow (data_offset is u4, max value 15)
        // Example: data_offset=5 → 5 × 4 = 20 bytes, data_offset=6 → 6 × 4 = 24 bytes
        return @as(u8, self.data_offset) * 4;
    }

    // Write TCP header to buffer (reverse of parse, packs fields into bytes)
    pub fn write(self: *const TcpHeader, buf: []u8) !void {
        if (buf.len < MIN_SIZE) return error.BufferTooSmall;

        // Bytes 0-1: Source port
        mem.writeInt(u16, buf[0..2], self.source_port, .big);
        // Bytes 2-3: Destination port
        mem.writeInt(u16, buf[2..4], self.destination_port, .big);
        // Bytes 4-7: Sequence number
        mem.writeInt(u32, buf[4..8], self.sequence_number, .big);
        // Bytes 8-11: Acknowledgment number
        mem.writeInt(u32, buf[8..12], self.acknowledgment_number, .big);

        // Bytes 12-13: Pack data_offset (upper 4 bits), reserved (next 3 bits), flags (lower 9 bits)
        // Shift data_offset left 12 bits, reserved left 9 bits, then OR with flags
        const offset_reserved_flags = (@as(u16, self.data_offset) << 12) |
            (@as(u16, self.reserved) << 9) |
            self.flags.toByte();
        mem.writeInt(u16, buf[12..14], offset_reserved_flags, .big);

        // Bytes 14-15: Window size
        mem.writeInt(u16, buf[14..16], self.window_size, .big);
        // Bytes 16-17: Checksum
        mem.writeInt(u16, buf[16..18], self.checksum, .big);
        // Bytes 18-19: Urgent pointer
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

// TCP control flags (9 bits total)
// Uses 'packed struct' so fields map directly to bits in memory (no padding)
pub const TcpFlags = packed struct {
    fin: bool = false, // FIN: Finish (no more data from sender, connection teardown)
    syn: bool = false, // SYN: Synchronize (initiate connection, exchange initial sequence numbers)
    rst: bool = false, // RST: Reset (abort connection immediately, error condition)
    psh: bool = false, // PSH: Push (deliver data to application immediately, don't buffer)
    ack: bool = false, // ACK: Acknowledgment (acknowledgment_number field is valid)
    urg: bool = false, // URG: Urgent (urgent_pointer field is valid, priority data)
    ece: bool = false, // ECE: ECN Echo (congestion notification received from network)
    cwr: bool = false, // CWR: Congestion Window Reduced (sender reduced sending rate)
    ns: bool = false, // NS: Nonce Sum (experimental, protects against malicious ECN concealment)

    // Convert u9 value to TcpFlags (bit 0 = fin, bit 1 = syn, ..., bit 8 = ns)
    pub fn fromByte(byte: u9) TcpFlags {
        // @bitCast reinterprets the u9 bits as TcpFlags struct fields
        return @bitCast(byte);
    }

    // Convert TcpFlags to u9 value (for packing into TCP header)
    pub fn toByte(self: TcpFlags) u9 {
        // @bitCast reinterprets the TcpFlags struct fields as u9 bits
        return @bitCast(self);
    }

    // Format flags as human-readable string like "[syn,ack]" or "[fin,ack]"
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
        // Use compile-time reflection to iterate over all fields
        inline for (@typeInfo(TcpFlags).Struct.fields) |field| {
            // Check if this flag is set (true)
            if (@field(self, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name); // Print flag name (e.g., "syn")
                first = false;
            }
        }
        try writer.writeAll("]");
    }
};

// UDP header (fixed 8 bytes, much simpler than TCP)
pub const UdpHeader = struct {
    source_port: u16, // Source port number (identifies sending application)
    destination_port: u16, // Destination port number (identifies receiving application)
    length: u16, // Total length of UDP header + data (minimum 8 bytes)
    checksum: u16, // Optional checksum for header and data (0 = no checksum)

    pub const SIZE = 8;

    // Parse UDP header from raw bytes (no bit packing, all fields are aligned)
    pub fn parse(data: []const u8) !UdpHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .source_port = mem.readInt(u16, data[0..2], .big), // Bytes 0-1
            .destination_port = mem.readInt(u16, data[2..4], .big), // Bytes 2-3
            .length = mem.readInt(u16, data[4..6], .big), // Bytes 4-5
            .checksum = mem.readInt(u16, data[6..8], .big), // Bytes 6-7
        };
    }

    // Write UDP header to buffer (simpler than TCP, no bit packing needed)
    pub fn write(self: *const UdpHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        mem.writeInt(u16, buf[0..2], self.source_port, .big); // Bytes 0-1
        mem.writeInt(u16, buf[2..4], self.destination_port, .big); // Bytes 2-3
        mem.writeInt(u16, buf[4..6], self.length, .big); // Bytes 4-5
        mem.writeInt(u16, buf[6..8], self.checksum, .big); // Bytes 6-7
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

// ICMP header (8 bytes minimum, used for network diagnostics and error reporting)
pub const IcmpHeader = struct {
    type: u8, // Message type (0=Echo Reply, 8=Echo Request, 3=Dest Unreachable, etc.)
    code: u8, // Sub-type, meaning depends on type (e.g., for type 3: 0=net, 1=host, 3=port)
    checksum: u16, // Header and data checksum (uses same algorithm as IP checksum)
    rest_of_header: u32, // Varies by type/code (e.g., Echo uses ID+Sequence, others use different formats)

    pub const SIZE = 8;

    // Parse ICMP header from raw bytes
    pub fn parse(data: []const u8) !IcmpHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .type = data[0], // Byte 0
            .code = data[1], // Byte 1
            .checksum = mem.readInt(u16, data[2..4], .big), // Bytes 2-3
            .rest_of_header = mem.readInt(u32, data[4..8], .big), // Bytes 4-7 (interpretation depends on type)
        };
    }

    // Write ICMP header to buffer
    pub fn write(self: *const IcmpHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        buf[0] = self.type; // Byte 0
        buf[1] = self.code; // Byte 1
        mem.writeInt(u16, buf[2..4], self.checksum, .big); // Bytes 2-3
        mem.writeInt(u32, buf[4..8], self.rest_of_header, .big); // Bytes 4-7
    }
};

// ARP packet (28 bytes for IPv4 over Ethernet)
// Address Resolution Protocol: maps IP addresses to MAC addresses on local networks
pub const ArpHeader = struct {
    hardware_type: u16, // Hardware type (1 = Ethernet)
    protocol_type: u16, // Protocol type (0x0800 = IPv4)
    hardware_addr_len: u8, // Hardware address length in bytes (6 for MAC addresses)
    protocol_addr_len: u8, // Protocol address length in bytes (4 for IPv4)
    operation: u16, // Operation (1 = Request "who has IP?", 2 = Reply "I have IP")
    sender_hw_addr: [6]u8, // Sender's MAC address (who is sending this ARP packet)
    sender_proto_addr: [4]u8, // Sender's IP address
    target_hw_addr: [6]u8, // Target's MAC address (all zeros in requests, filled in replies)
    target_proto_addr: [4]u8, // Target's IP address (the IP we're looking for)

    pub const SIZE = 28;

    // Parse ARP header from raw bytes
    pub fn parse(data: []const u8) !ArpHeader {
        if (data.len < SIZE) return error.PacketTooShort;

        return .{
            .hardware_type = mem.readInt(u16, data[0..2], .big), // Bytes 0-1
            .protocol_type = mem.readInt(u16, data[2..4], .big), // Bytes 2-3
            .hardware_addr_len = data[4], // Byte 4
            .protocol_addr_len = data[5], // Byte 5
            .operation = mem.readInt(u16, data[6..8], .big), // Bytes 6-7
            .sender_hw_addr = data[8..14].*, // Bytes 8-13: convert slice to [6]u8 array
            .sender_proto_addr = data[14..18].*, // Bytes 14-17: convert slice to [4]u8 array
            .target_hw_addr = data[18..24].*, // Bytes 18-23: convert slice to [6]u8 array
            .target_proto_addr = data[24..28].*, // Bytes 24-27: convert slice to [4]u8 array
        };
    }

    // Write ARP header to buffer
    pub fn write(self: *const ArpHeader, buf: []u8) !void {
        if (buf.len < SIZE) return error.BufferTooSmall;
        mem.writeInt(u16, buf[0..2], self.hardware_type, .big); // Bytes 0-1
        mem.writeInt(u16, buf[2..4], self.protocol_type, .big); // Bytes 2-3
        buf[4] = self.hardware_addr_len; // Byte 4
        buf[5] = self.protocol_addr_len; // Byte 5
        mem.writeInt(u16, buf[6..8], self.operation, .big); // Bytes 6-7
        @memcpy(buf[8..14], &self.sender_hw_addr); // Bytes 8-13: copy 6-byte MAC
        @memcpy(buf[14..18], &self.sender_proto_addr); // Bytes 14-17: copy 4-byte IP
        @memcpy(buf[18..24], &self.target_hw_addr); // Bytes 18-23: copy 6-byte MAC
        @memcpy(buf[24..28], &self.target_proto_addr); // Bytes 24-27: copy 4-byte IP
    }
};

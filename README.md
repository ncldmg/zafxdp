# zafxdp - AF_XDP for Zig

A pure Zig implementation of AF_XDP (Address Family XDP) sockets with eBPF program loading, featuring both **low-level** and **high-level** APIs for building high-performance networking applications.

## Key Features

- **High-Level Service API**: Build complex networking services with minimal code
- **Zero-Copy Packet Processing**: Direct UMEM access with lazy protocol parsing
- **Composable Pipeline Architecture**: Chain multiple packet processors together
- **Protocol Parsers**: Built-in support for Ethernet, IPv4, TCP, UDP, ICMP, ARP
- **Multi-threaded Workers**: Automatic worker thread management per queue
- **Low-Level Control**: Direct access to XDP sockets and eBPF programs when needed

## Quick Start: High-Level API

Build a simple L2 packet forwarder in ~30 lines of code:

```zig
const std = @import("std");
const xdp = @import("zafxdp");

// Define your packet processing logic
const ForwarderContext = struct {
    dst_ifindex: u32,

    fn process(ctx: *ForwarderContext, packet: *xdp.Packet) !xdp.ProcessResult {
        return .{
            .action = .Transmit,
            .target = .{ .ifindex = ctx.dst_ifindex, .queue_id = packet.source.queue_id },
        };
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create processor
    var ctx = ForwarderContext{ .dst_ifindex = try xdp.getInterfaceIndex("eth1") };
    var processor = xdp.PacketProcessor(ForwarderContext){
        .context = ctx,
        .processFn = ForwarderContext.process,
    };

    // Create pipeline
    var pipeline = xdp.Pipeline.init(allocator, .{});
    defer pipeline.deinit();
    try pipeline.addStage(@TypeOf(processor), &processor);

    // Create and start service
    var service = try xdp.Service.init(allocator, .{
        .interfaces = &[_]xdp.InterfaceConfig{
            .{ .name = "eth0", .queues = &[_]u32{0} },
        },
    }, &pipeline);
    defer service.deinit();

    try service.start();
    std.time.sleep(10 * std.time.ns_per_s);
    service.stop();
}
```

**See [examples/](examples/) for more examples and [API_DESIGN.md](API_DESIGN.md) for the complete API documentation.**

---

## Project Structure

```
zafxdp/
├── src/
│   ├── lib/              # Library code
│   │   ├── root.zig      # Main API entry point (re-exports all APIs)
│   │   ├── xsk.zig       # AF_XDP socket implementation (low-level)
│   │   ├── loader.zig    # eBPF program loader (low-level)
│   │   ├── protocol.zig  # Protocol parsers (Ethernet, IPv4, TCP, UDP, etc.)
│   │   ├── packet.zig    # Zero-copy packet abstraction
│   │   ├── processor.zig # Packet processor interface
│   │   ├── pipeline.zig  # Pipeline for chaining processors
│   │   ├── stats.zig     # Statistics collection
│   │   └── service.zig   # High-level service management
│   └── cmd/              # CLI application
│       └── main.zig      # Command-line tool
├── examples/             # Example programs
│   ├── simple_forwarder.zig
│   └── README.md
├── API_DESIGN.md         # Detailed API documentation
└── build.zig             # Build configuration
```

Import the library using a single import:

```zig
const xdp = @import("zafxdp");

// High-level API (recommended):
// - xdp.Service, xdp.Pipeline, xdp.PacketProcessor
// - xdp.Packet, xdp.EthernetHeader, xdp.IPv4Header, etc.

// Low-level API (for advanced use):
// - xdp.XDPSocket, xdp.Program, xdp.EbpfLoader
```

---

## High-Level API Overview

The high-level API provides an abstraction for building complex networking services. It consists of:

### 1. Packet Abstraction

Zero-copy packet reference with lazy protocol parsing:

```zig
var packet: xdp.Packet = // ... received from service

// Parse protocols on-demand (cached)
const eth = try packet.ethernet();
const ip = try packet.ipv4();
const tcp = try packet.tcp();

std.debug.print("TCP {} -> {}\n", .{tcp.source_port, tcp.destination_port});
```

### 2. Packet Processor

Define custom packet processing logic:

```zig
const MyContext = struct {
    counter: u64 = 0,

    fn process(ctx: *MyContext, packet: *xdp.Packet) !xdp.ProcessResult {
        ctx.counter += 1;

        // Parse and inspect packet
        const eth = try packet.ethernet();
        if (eth.ethertype == xdp.EtherType.IPv4) {
            return .{ .action = .Pass };  // Continue processing
        }

        return .{ .action = .Drop };  // Drop non-IPv4 packets
    }
};
```

**Actions**: `Drop`, `Pass`, `Transmit`, `Recirculate`

### 3. Pipeline

Chain multiple processors together:

```zig
var pipeline = xdp.Pipeline.init(allocator, .{});
defer pipeline.deinit();

// Add processors in order
try pipeline.addStage(@TypeOf(mac_filter), &mac_filter);
try pipeline.addStage(@TypeOf(counter), &counter);
try pipeline.addStage(@TypeOf(forwarder), &forwarder);

// Packets flow through: MAC Filter -> Counter -> Forwarder
```

### 4. Service

High-level service managing sockets, workers, and statistics:

```zig
var service = try xdp.Service.init(allocator, .{
    .interfaces = &[_]xdp.InterfaceConfig{
        .{ .name = "eth0", .queues = &[_]u32{0, 1} },
    },
    .batch_size = 64,
    .poll_timeout_ms = 100,
}, &pipeline);
defer service.deinit();

try service.start();  // Spawns worker threads
// ... service is running ...
service.stop();       // Stops and joins workers

// Get statistics
const stats = service.getStats();
std.debug.print("RX: {} pkts, TX: {} pkts\n", .{
    stats.packets_received,
    stats.packets_transmitted
});
```

For complete documentation, see **[API_DESIGN.md](API_DESIGN.md)** and **[examples/](examples/)**.

---

## Low-Level API Overview

The library provides helpers to work with AF_XDP sockets.

```zig
const std = @import("std");
const xdp = @import("zafxdp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure socket options
    const options = xdp.SocketOptions{
        .NumFrames = 4096,
        .FrameSize = 2048,
        .FillRingNumDescs = 2048,
        .CompletionRingNumDescs = 2048,
        .RxRingNumDescs = 2048,
        .TxRingNumDescs = 2048,
    };

    // Create socket using init()
    const xsk = try xdp.XDPSocket.init(allocator, 2, 0, options);
    defer xsk.deinit(allocator);

    // Use methods on the socket instance
    var fill_descs = [_]u64{ 0, 2048, 4096, 8192 };
    const filled = xsk.fillRing(&fill_descs, 4);

    // Send packets
    const packets = [_][]const u8{
        "Hello, XDP!",
        "Second packet",
    };
    const sent = try xsk.sendPackets(&packets);

    // Receive packets
    var recv_buffers: [64][2048]u8 = undefined;
    var recv_slices: [64][]u8 = undefined;
    for (&recv_buffers, 0..) |*buf, i| {
        recv_slices[i] = buf[0..];
    }
    const received = try xsk.receivePackets(&recv_slices);

    // Kick to wake kernel
    try xsk.kick();
}
```

## Available Methods

### Socket Lifecycle
- `XDPSocket.init(allocator, ifIndex, queueId, options)` - Create new socket
- `socket.deinit(allocator)` - Destroy socket and free resources

### Ring Operations
- `socket.fillRing(descs, count)` - Fill the fill ring with buffer descriptors
- `socket.completionRing(descs, count)` - Read from completion ring
- `socket.rxRing(descs, count)` - Read from RX ring
- `socket.txRing(descs, count)` - Write to TX ring

### Packet Operations
- `socket.sendPackets(packets)` - Send packets through the socket
- `socket.receivePackets(packets)` - Receive packets from the socket
- `socket.kick()` - Wake up kernel to process queued packets

## Socket Options

```zig
const SocketOptions = struct {
    NumFrames: u32,              // Number of frames in UMEM
    FrameSize: u32,              // Size of each frame (typically 2048)
    FillRingNumDescs: u32,       // Fill ring size
    CompletionRingNumDescs: u32, // Completion ring size
    RxRingNumDescs: u32,         // RX ring size
    TxRingNumDescs: u32,         // TX ring size
};
```

## Error Handling

The library defines these errors:
- `error.MissingRing` - Neither RX nor TX ring configured
- `error.InvalidFileDescriptor` - File descriptor doesn't fit in i32
- `error.SocketCreationFailed` - Failed to create XDP socket
- `error.SyscallFailed` - System call failed
- `error.SendFailed` - Packet send failed
- `error.BufferTooSmall` - Receive buffer too small
- `error.KickFailed` - Failed to kick socket

---

# eBPF Program Loader

The loader provides functionality to load eBPF programs and manage BPF maps using only Zig. All APIs are available through the main `xdp` import. The `Program` struct provides a complete XDP program with automatic eBPF instruction generation.

```zig
const std = @import("std");
const xdp = @import("zafxdp");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. Create XDP program with auto-generated eBPF instructions
    var program = try xdp.Program.init(allocator, 64);
    defer program.deinit();

    // 2. Create AF_XDP socket
    const ifindex = 3; // Network interface index (use `ip link` to find)
    const queue_id = 0;

    const options = xdp.SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    const xsk = try xdp.XDPSocket.init(allocator, ifindex, queue_id, options);
    defer xsk.deinit(allocator);

    // 3. Register socket with XDP program
    try program.register(queue_id, @intCast(xsk.Fd));

    // 4. Attach XDP program to interface
    try program.attach(ifindex, xdp.DefaultXdpFlags);

    // 5. Process packets...
    std.debug.print("XDP program attached and ready!\n", .{});

    // 6. Cleanup (detach when done)
    try program.detach(ifindex);
    try program.unregister(queue_id);
}
```

### Program Methods

- `Program.init(allocator, max_queue_entries)` - Create XDP program with maps
- `program.deinit()` - Clean up program and maps
- `program.attach(ifindex, flags)` - Attach XDP program to network interface
- `program.detach(ifindex)` - Detach XDP program from interface
- `program.register(queue_id, socket_fd)` - Register AF_XDP socket to queue
- `program.unregister(queue_id)` - Unregister socket from queue

### XDP Flags

```zig
pub const XdpFlags = enum(u32) {
    UPDATE_IF_NOEXIST = 1 << 0,  // Only attach if no program exists
    SKB_MODE = 1 << 1,            // Generic XDP (slowest, always works)
    DRV_MODE = 1 << 2,            // Native XDP (requires driver support)
    HW_MODE = 1 << 3,             // Hardware offload (requires NIC support)
    REPLACE = 1 << 4,             // Replace existing program
};

// Default flags: Native mode + only if no program exists
pub const DefaultXdpFlags: u32 = XdpFlags.DRV_MODE | XdpFlags.UPDATE_IF_NOEXIST;
```

## Low-Level EbpfLoader API

For advanced use cases, you can use the `EbpfLoader` directly:

```zig
const std = @import("std");
const xdp = @import("zafxdp");
const linux = std.os.linux;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var ebpf_loader = xdp.EbpfLoader.init(allocator);
    defer ebpf_loader.deinit();

    // Create BPF maps
    const xsks_map_fd = try ebpf_loader.createXskMap(64, "xsks_map");
    const qidconf_map_fd = try ebpf_loader.createMap(
        linux.BPF.MapType.array,
        @sizeOf(u32),
        @sizeOf(u32),
        64,
        "qidconf_map"
    );

    // Build eBPF instructions manually
    const insns = [_]linux.BPF.Insn{
        // Your eBPF instructions here
        .{ .code = 0x95, .dst = 0, .src = 0, .off = 0, .imm = 0 }, // exit
    };

    // Load program from instructions
    const prog_fd = try ebpf_loader.loadProgramFromInstructions(
        &insns,
        linux.BPF.ProgType.xdp,
        "my_xdp_prog"
    );

    // Update map entries
    const queue_id: u32 = 0;
    const socket_fd: u32 = 42;
    try ebpf_loader.updateXskMapEntry(xsks_map_fd, queue_id, socket_fd);

    // Attach program to interface
    try ebpf_loader.attachXdpProgram(prog_fd, 3, xdp.DefaultXdpFlags);
}
```

### EbpfLoader Methods

#### Program Loading
- `loadProgramFromFile(path, prog_type, prog_name)` - Load from raw bytecode file
- `loadProgramFromInstructions(insns, prog_type, prog_name)` - Load from instruction array

#### Map Operations
- `createMap(map_type, key_size, value_size, max_entries, name)` - Create generic BPF map
- `createXskMap(max_entries, name)` - Create XSKMAP for AF_XDP sockets
- `updateMapElement(map_fd, key, value)` - Update map entry
- `lookupMapElement(map_fd, key, value)` - Lookup map entry
- `deleteMapElement(map_fd, key)` - Delete map entry
- `updateXskMapEntry(map_fd, queue_index, xsk_fd)` - Update XSKMAP entry

#### Program Management
- `findProgramByName(name)` - Find loaded program by name
- `findMapByName(name)` - Find created map by name
- `getProgramCount()` - Get number of loaded programs
- `getMapCount()` - Get number of created maps
- `attachXdpProgram(prog_fd, ifindex, flags)` - Attach XDP program
- `detachXdpProgram(ifindex)` - Detach XDP program

## Implementation Details

### Auto-Generated XDP Program

The `Program.init()` automatically generates an XDP program equivalent to the Linux kernel's default AF_XDP program:

```c
// Equivalent C code:
int xdp_sock_prog(struct xdp_md *ctx) {
    int *qidconf, index = ctx->rx_queue_index;

    // Check if queue has registered AF_XDP socket
    qidconf = bpf_map_lookup_elem(&qidconf_map, &index);
    if (!qidconf)
        return XDP_ABORTED;

    // If registered, redirect to AF_XDP socket
    if (*qidconf)
        return bpf_redirect_map(&xsks_map, index, 0);

    return XDP_PASS;
}
```

The Zig implementation builds this as raw eBPF bytecode in `buildXdpProgram()`.

### BPF Maps Used

Two BPF maps are created:

1. **qidconf_map** (ARRAY): Tracks which RX queues have registered sockets
   - Key: u32 (queue ID)
   - Value: u32 (1 = enabled, 0 = disabled)

2. **xsks_map** (XSKMAP): Holds AF_XDP socket file descriptors
   - Key: u32 (queue ID)
   - Value: u32 (socket FD)

### XDP Attachment Methods

The library uses `BPF_LINK_CREATE` syscall for XDP attachment, which provides:
- Better lifecycle management
- Automatic cleanup on program exit
- More reliable than older netlink methods

If attachment fails, the error message suggests the manual fallback:
```bash
ip link set dev <interface> xdpgeneric fd <prog_fd>
```

## Complete Example

Combining XDP socket + eBPF program for packet processing:

```zig
const std = @import("std");
const xdp = @import("zafxdp");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const ifindex = 3;
    const queue_id = 0;

    // Create XDP program
    var program = try xdp.Program.init(allocator, 64);
    defer program.deinit();

    // Create AF_XDP socket
    const options = xdp.SocketOptions{
        .NumFrames = 64,
        .FrameSize = 2048,
        .FillRingNumDescs = 64,
        .CompletionRingNumDescs = 64,
        .RxRingNumDescs = 64,
        .TxRingNumDescs = 64,
    };

    const xsk = try xdp.XDPSocket.init(allocator, ifindex, queue_id, options);
    defer xsk.deinit(allocator);

    // Register and attach
    try program.register(queue_id, @intCast(xsk.Fd));
    try program.attach(ifindex, xdp.DefaultXdpFlags);

    // Fill ring with file descriptors
    var fill_descs: [64]u64 = undefined;
    for (0..64) |i| {
        fill_descs[i] = i * options.FrameSize;
    }
    _ = xsk.fillRing(&fill_descs, 64);

    // Packet processing loop
    std.debug.print("Ready to receive packets on interface {}, queue {}\n",
                    .{ifindex, queue_id});

    var packets: [16][]u8 = undefined;
    var packet_buffers: [16][2048]u8 = undefined;
    for (0..16) |i| {
        packets[i] = &packet_buffers[i];
    }

    var total_packets: u64 = 0;
    while (true) {
        const received = try xsk.receivePackets(&packets);
        if (received > 0) {
            total_packets += received;
            std.debug.print("Received {} packets (total: {})\n",
                          .{received, total_packets});

            // Process packets here...
            for (packets[0..received]) |packet| {
                // Example: print first 32 bytes
                const len = @min(packet.len, 32);
                std.debug.print("Packet data: {x}\n", .{packet[0..len]});
            }

            // Return frames to fill ring
            _ = xsk.fillRing(fill_descs[0..received], @intCast(received));
        }

        std.time.sleep(1_000_000); // 1ms
    }
}
```

## Requirements

- Linux kernel 4.18+ (for AF_XDP support)
- Zig 0.15.1 (tested with this version)
- Elevated privileges (CAP_NET_ADMIN or root) for BPF operations
- Network interface supporting XDP (most modern NICs)

## Building

Build the library and CLI:

```bash
# Build library and CLI
zig build

# Run the CLI
zig build run -- help
```

### Using as a Library

The library can be used as a dependency in your Zig project:

```zig
// In your build.zig
const zafxdp = b.dependency("zafxdp", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zafxdp", zafxdp.module("zafxdp"));
```

## CLI Usage

The `zafxdp` CLI provides commands for packet capture and network interface management:

```bash
# List available network interfaces
./zig-out/bin/zafxdp list-interfaces

# Capture packets (requires root)
sudo ./zig-out/bin/zafxdp receive <interface> <queue_id> [num_packets]

# Examples:
sudo ./zig-out/bin/zafxdp receive lo 0        # Capture on loopback
sudo ./zig-out/bin/zafxdp receive eth0 0 100  # Capture 100 packets
```

The CLI demonstrates the full library functionality including:
- XDP program creation with auto-generated eBPF instructions
- AF_XDP socket setup and configuration
- Real-time packet capture and display
- Ethernet frame parsing
- Performance statistics

## Testing

```bash
make test          # unit tests
make test-e2e      # e2e tests
```

**Note**: E2E tests require root privileges because they create BPF programs and maps. Unit tests that require network access will skip gracefully if permissions are insufficient.

For more details, see:
- **[E2E_TESTS.md](E2E_TESTS.md)** - L2 forwarder implementation


## Troubleshooting

### "XDP attach failed"

Try these XDP modes in order of preference:

1. **DRV_MODE** (native, fastest): Requires driver support
   ```zig
   try program.attach(ifindex, @intFromEnum(xdp.XdpFlags.DRV_MODE));
   ```

2. **SKB_MODE** (generic, slower but always works):
   ```zig
   try program.attach(ifindex, @intFromEnum(xdp.XdpFlags.SKB_MODE));
   ```

3. **Manual attachment** via ip command:
   ```bash
   sudo ip link set dev eth0 xdpgeneric fd <prog_fd>
   ```

### Finding Interface Index

```bash
ip link show
# Look for the number before the interface name
# Example: "3: eth0: ..." means ifindex = 3
```

Or in Zig:
```zig
// Read /sys/class/net/<ifname>/ifindex
const file = try std.fs.openFileAbsolute("/sys/class/net/eth0/ifindex", .{});
defer file.close();
var buf: [16]u8 = undefined;
const len = try file.readAll(&buf);
const ifindex = try std.fmt.parseInt(u32, buf[0..len-1], 10);
```

## Testing

### Run All Tests (One Command)

```bash
sudo make test-all
```

This runs:
- ✓ Unit tests (basic functionality)
- ✓ Packet tests (protocol parsing)
- ✓ Protocol tests (header serialization)
- ✓ E2E tests (AF_XDP infrastructure)
- ✓ **Traffic tests** (real packet injection & reception) ⭐

### Individual Test Suites

```bash
# No root required
make test-unit           # Unit tests
make test-packet         # Packet parsing
make test-protocol       # Protocol headers

# Requires root
sudo make test-e2e       # Infrastructure setup
sudo make test-traffic   # Real traffic flow
```

### Example Test Output

```
$ sudo make test-traffic
✓ Created veth pair: veth_test_rx <-> veth_test_tx
✓ Created AF_XDP service on veth_test_rx
Injecting 10 test packets into veth_test_tx...
✓ Injected 10 packets

=== Results ===
Packets counted by processor: 8
Service stats:
  RX: 8 packets, 496 bytes  ← REAL TRAFFIC!
  TX: 0 packets, 0 bytes
✓ SUCCESS: Received 8 packets via AF_XDP!
```

### Documentation

- **[ARCHITECTUR.md](ARCHITECTURG.md)** - AF_XDP lib Architecture
- **[TESTING_GUIDE.md](TESTING_GUIDE.md)** - Testing guide
- **[AFXDP_TRAFFIC_TESTING.md](AFXDP_TRAFFIC_TESTING.md)** - Traffic testing


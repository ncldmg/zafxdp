# AF_XDP Traffic Testing Guide

This guide explains traffic testing with AF_XDP.

## Overview

The tests in `src/lib/traffic_test.zig` do the following:
- Create virtual network interfaces (veth pairs)
- Inject Ethernet frames into the network stack
- Receive packets via AF_XDP sockets
- Process packets through the pipeline
- Forward packets to other interfaces
- Verify packet counts and stats

---

## Architecture of Traffic Tests

```
┌─────────────┐                    ┌─────────────┐
│   veth_a    │ <─── connected ───>│   veth_b    │
│             │                    │             │
│ AF_XDP      │                    │ Raw Socket  │
│ Socket      │                    │ (inject)    │
│ (receive)   │                    │             │
└──────┬──────┘                    └──────┬──────┘
       │                                  │
       │ Packets received                 │ Packets injected
       │ via XDP                          │ via AF_PACKET
       ▼                                  │
┌──────────────┐                          │
│   Pipeline   │                          │
│  Processing  │◄─────────────────────────┘
│              │
│  - Counter   │
│  - Forwarder │
│  - etc.      │
└──────────────┘
```

---

## How Each Test Works

### Test 1: Basic Packet Injection and Reception

**What it does:**
1. Creates veth pair: `veth_test_rx` ↔ `veth_test_tx`
2. Sets up AF_XDP socket on `veth_test_rx`
3. Injects 10 packets into `veth_test_tx`
4. Packets appear on `veth_test_rx`
5. AF_XDP receives packets
6. Counter processor counts them
7. Verifies packet count > 0

**Key Functions:**

```zig
// 1. Create veth pair
try createVethPair("veth_test_rx", "veth_test_tx");

// 2. Build test packet
var packet_buf: [128]u8 = undefined;
const packet = buildTestPacket(&packet_buf, src_mac, dst_mac, payload);

// 3. Inject into one end
try injectPacket("veth_test_tx", packet);

// 4. AF_XDP receives on other end
// (happens automatically in service.start())

// 5. Check results
const stats = service.getStats();
// stats.packets_received should be > 0
```

### Test 2: Bidirectional Forwarding

**What it does:**
1. Creates veth pair: `veth_fwd_a` ↔ `veth_fwd_b`
2. Sets up AF_XDP on BOTH interfaces
3. Creates L2 forwarder processor
4. Injects packets into both ends
5. Forwarder swaps them (A→B and B→A)
6. Verifies bidirectional traffic works

**Architecture:**

```
                    Bidirectional L2 Forwarding Test

    ┌────────────────────────────────────────────────────────────┐
    │                      Test Process                          │
    │                                                            │
    │  ┌──────────────┐                    ┌──────────────┐     │
    │  │  Injector A  │                    │  Injector B  │     │
    │  │ (AF_PACKET)  │                    │ (AF_PACKET)  │     │
    │  └──────┬───────┘                    └───────┬──────┘     │
    │         │                                    │            │
    │         │ Send packets                       │ Send packets
    │         │ via raw socket                     │ via raw socket
    │         ▼                                    ▼            │
    └─────────┼────────────────────────────────────┼────────────┘
              │                                    │
              │                                    │
    ┌─────────▼────────┐           ┌──────────────▼─────────┐
    │   veth_fwd_a     │◄─────────►│    veth_fwd_b          │
    │                  │  Kernel   │                        │
    │ AF_XDP Socket #1 │  veth     │  AF_XDP Socket #2      │
    │                  │  pair     │                        │
    └─────────┬────────┘           └──────────┬─────────────┘
              │                               │
              │ RX: Packets from B            │ RX: Packets from A
              │                               │
              ▼                               ▼
    ┌─────────────────────────────────────────────────────────┐
    │              AF_XDP Service (Service.zig)               │
    │                                                         │
    │  ┌──────────────────────────────────────────────────┐  │
    │  │           L2 Forwarder Pipeline                  │  │
    │  │                                                  │  │
    │  │  RX from A ──► Process ──► TX to B              │  │
    │  │                                                  │  │
    │  │  RX from B ──► Process ──► TX to A              │  │
    │  │                                                  │  │
    │  │  (Swaps source/destination interfaces)          │  │
    │  └──────────────────────────────────────────────────┘  │
    └─────────────────────────────────────────────────────────┘

Flow Example:
  1. Injector A sends packet → veth_fwd_a
  2. AF_XDP RX on veth_fwd_a receives it
  3. L2 Forwarder processes: forward to veth_fwd_b
  4. AF_XDP TX on veth_fwd_b transmits it
  5. Packet appears on veth_fwd_b (visible to Injector B)

  (Same flow happens in reverse: B → A)

Verification:
  ✓ Service stats show RX packets on both interfaces
  ✓ Service stats show TX packets on both interfaces
  ✓ Confirms bidirectional forwarding works
```

---

## Running the Tests

### Prerequisites

```bash
# 1. Must run as root
sudo -s

# 2. Check kernel version (need 5.4+)
uname -r

# 3. Check if AF_XDP is available
ls /proc/net/xdp_stats 2>/dev/null && echo "AF_XDP available" || echo "AF_XDP not available"

# 4. Install iproute2 for veth management
apt-get install iproute2  # Debian/Ubuntu
dnf install iproute2      # Fedora/RHEL
```

### Run the Tests

```bash
# Run all traffic tests
sudo zig test src/lib/traffic_test.zig --summary all

# Run with verbose output
sudo zig test src/lib/traffic_test.zig --summary all 2>&1 | tee test_output.log
```

### Expected Output

```
✓ Created veth pair: veth_test_rx <-> veth_test_tx
✓ Created AF_XDP service on veth_test_rx
Injecting 10 test packets into veth_test_tx...
✓ Injected 10 packets

=== Results ===
Packets counted by processor: 8
Service stats:
  RX: 8 packets, 496 bytes
  TX: 0 packets, 0 bytes
  Dropped: 0
  Errors: 0
✓ SUCCESS: Received 8 packets via AF_XDP!
```

**Note:** You might not receive all 10 packets due to:
- Timing issues (packets sent before AF_XDP socket is ready)
- XDP mode (SKB mode on veth has different behavior than native mode)
- Kernel packet filtering

---

## Common Issues and Solutions

### Issue 1: "Permission Denied" / PERM Error

**Problem:** Not running as root

**Solution:**
```bash
sudo zig test src/lib/traffic_test.zig
```

### Issue 2: No Packets Received

**Possible causes:**

1. **Timing Issue** - Packets sent before AF_XDP socket is ready
   ```zig
   // Add more delay after starting service
   std.time.sleep(200 * std.time.ns_per_ms); // Instead of 100ms
   ```

2. **XDP Mode** - veth requires SKB mode, which is slower
   ```bash
   # Check XDP mode
   ip link show veth_test_rx | grep xdp

   # If you see "xdpgeneric" or "xdpdrv", good
   # If nothing, AF_XDP might not be attached
   ```

3. **Kernel Config** - AF_XDP not enabled
   ```bash
   # Check if AF_XDP is compiled in
   zgrep CONFIG_XDP_SOCKETS /proc/config.gz
   # Should show: CONFIG_XDP_SOCKETS=y
   ```

4. **Interface Not Up**
   ```bash
   ip link show veth_test_rx | grep "state UP"
   ```

### Issue 3: "Interface Not Found"

**Problem:** veth pair not created or already deleted

**Solution:**
```bash
# Check if interfaces exist
ip link show | grep veth_test

# Clean up stale interfaces
sudo ip link delete veth_test_rx 2>/dev/null
sudo ip link delete veth_test_tx 2>/dev/null

# Then re-run test
```

### Issue 4: Only Receiving Some Packets

**This is normal!** Reasons:
- Packet loss in SKB mode
- Timing windows
- Ring buffer full
- Kernel filtering

**Mitigation:**
```zig
// Increase ring sizes
.RxRingNumDescs = 256,  // Instead of 128
.FillRingNumDescs = 256,

// Add delays between packets
std.time.sleep(20 * std.time.ns_per_ms); // Between each injection

// Increase wait time
std.time.sleep(1000 * std.time.ns_per_ms); // 1 second
```

---

## Debugging Tips

### 1. Enable Debug Logging

```zig
// In service initialization
std.debug.print("Creating AF_XDP socket on {s}, queue {}\n", .{ifname, queue_id});

// In packet processing
std.debug.print("Received packet: len={}, src={}\n", .{packet.len(), packet.source.ifindex});
```

### 2. Check Kernel Messages

```bash
# Watch kernel logs for XDP errors
sudo dmesg -w | grep -i xdp
```

### 3. Use tcpdump to Verify Injection

```bash
# In one terminal: monitor veth_b
sudo tcpdump -i veth_test_tx -n -e

# In another terminal: run test
sudo zig test src/lib/traffic_test.zig

# You should see packets appear in tcpdump
```

### 4. Check AF_XDP Statistics

```bash
# After running test
cat /sys/class/net/veth_test_rx/statistics/rx_packets
cat /proc/net/xdp_stats
```

---

## Performance Testing

For throughput testing, modify the test:

```zig
test "High throughput packet injection" {
    // ... setup ...

    const num_packets = 100_000;
    const start = std.time.nanoTimestamp();

    for (0..num_packets) |i| {
        var packet_buf: [64]u8 = undefined;
        const packet = buildTestPacket(&packet_buf, ...);
        try injectPacket(veth_b, packet);
    }

    const end = std.time.nanoTimestamp();
    const duration_sec = @as(f64, @floatFromInt(end - start)) / 1_000_000_000.0;
    const pps = @as(f64, @floatFromInt(num_packets)) / duration_sec;

    std.debug.print("Injection rate: {d:.0} packets/sec\n", .{pps});

    // Wait for processing
    std.time.sleep(2 * std.time.ns_per_s);

    const stats = service.getStats();
    const rx_pps = @as(f64, @floatFromInt(stats.packets_received)) / duration_sec;

    std.debug.print("Reception rate: {d:.0} packets/sec\n", .{rx_pps});
    std.debug.print("Loss: {d:.2}%\n", .{
        (1.0 - @as(f64, @floatFromInt(stats.packets_received)) / @as(f64, @floatFromInt(num_packets))) * 100.0
    });
}
```


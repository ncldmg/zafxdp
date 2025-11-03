# Testing Guide

## Quick Start

### Run All Tests (One Command!)

```bash
# Using Make (recommended)
sudo make test-all

# Or using Zig directly
sudo zig build test-all --summary failures
```

---

## Test Categories

### 1. **Unit Tests** (No root required)
Tests individual functions and modules without network access.

```bash
make test-unit
# or
zig build test --summary failures
```

**What it tests:**
- ✓ Data structure operations
- ✓ Utility functions
- ✓ Pure logic (no I/O)

---

### 2. **Packet Parsing Tests** (No root required)
Tests protocol parsing with synthetic packets.

```bash
make test-packet
# or
zig build test-packet --summary failures
```

**What it tests:**
- ✓ Ethernet header parsing
- ✓ IPv4 header parsing
- ✓ TCP/UDP/ICMP header parsing
- ✓ Packet API (lazy parsing, caching)

**Example output:**
```
✓ Protocol parsing test passed
  Ethernet: 00:11:22:33:44:55 -> ff:ff:ff:ff:ff:ff
  IPv4: 192.168.1.1 -> 192.168.1.2
  UDP: 12345 -> 53
```

---

### 3. **Protocol Tests** (No root required)
Tests low-level protocol parsing and serialization.

```bash
make test-protocol
# or
zig build test-protocol --summary failures
```

**What it tests:**
- ✓ Header parsing from raw bytes
- ✓ Header serialization to bytes
- ✓ Checksum calculations
- ✓ Bit packing/unpacking

---

### 4. **End-to-End Tests** (Requires root)
Tests AF_XDP infrastructure setup without actual traffic.

```bash
sudo make test-e2e
# or
sudo zig build test-e2e --summary failures
```

**What it tests:**
- ✓ XDP socket creation
- ✓ Service initialization
- ✓ Pipeline configuration
- ✓ Multi-stage processing
- ✓ Interface binding

**Example output:**
```
✓ Service created successfully with counter processor
✓ Counted 0 packets (pipeline working)
✓ L2 Forwarder service created successfully
✓ Multi-stage pipeline service created successfully
```

---

### 5. **Traffic Tests** (Requires root) ⭐ NEW!
Tests actual packet sending and receiving through AF_XDP.

```bash
sudo make test-traffic
# or
sudo zig build test-traffic --summary failures
```

**What it tests:**
- ✓ Real packet injection (AF_PACKET)
- ✓ Veth pair creation
- ✓ AF_XDP packet reception
- ✓ Pipeline processing
- ✓ Packet forwarding
- ✓ Bidirectional traffic

**Example output:**
```
✓ Created veth pair: veth_test_rx <-> veth_test_tx
✓ Created AF_XDP service on veth_test_rx
Injecting 10 test packets into veth_test_tx...
✓ Injected 10 packets

=== Results ===
Packets counted by processor: 8
Service stats:
  RX: 8 packets, 496 bytes  ← REAL TRAFFIC!
  TX: 0 packets, 0 bytes
  Dropped: 0
  Errors: 0
✓ SUCCESS: Received 8 packets via AF_XDP!
```

---

## Test Hierarchy

```
make test-all
├── Unit Tests          (no root)
│   └── Basic functionality
├── Packet Tests        (no root)
│   └── Protocol parsing
├── Protocol Tests      (no root)
│   └── Header serialization
├── E2E Tests          (needs root)
│   └── Infrastructure setup
└── Traffic Tests      (needs root)
    └── Real packet flow ⭐
```

---

## Common Workflows

### Development Workflow (Fast Feedback)

```bash
# 1. Write code
vim src/lib/packet.zig

# 2. Run quick tests (no root needed)
make test-unit
make test-packet
make test-protocol

# 3. If all pass, run full suite
sudo make test-all
```

### Pre-Commit Workflow

```bash
# Run all tests before committing
sudo make test-all
```

### CI/CD Workflow

```bash
# Run in CI environment (needs root capabilities)
sudo zig build test-all --summary all
```

---

## Test Output Levels

### Summary Only (Default)
```bash
sudo make test-all
```
Shows only failed tests and summary.

### All Details
```bash
sudo zig build test-all --summary all
```
Shows all test names and results.

### Verbose (Debug)
```bash
sudo zig build test-all --verbose
```
Shows compilation commands and full output.

---

## Troubleshooting

### "Permission Denied" / PERM Errors

**Problem:** Not running as root for e2e/traffic tests

**Solution:**
```bash
sudo make test-all
# or
sudo -E zig build test-all  # -E preserves environment
```

### "No such file or directory" for veth interfaces

**Problem:** Previous test run didn't clean up

**Solution:**
```bash
# Clean up stale interfaces
sudo ip link delete veth_test_rx 2>/dev/null
sudo ip link delete veth_test_tx 2>/dev/null
sudo ip link delete veth_fwd_a 2>/dev/null
sudo ip link delete veth_fwd_b 2>/dev/null

# Then re-run tests
sudo make test-all
```

### Tests Pass But Show 0 Packets

**This is normal for e2e tests!** They only test infrastructure.

If you want to test **real traffic**, run:
```bash
sudo make test-traffic
```

This will inject actual packets and verify they're received.

### Traffic Tests Show < 10 Packets Received

**This is also normal!** Reasons:
- Timing windows (packets sent before socket ready)
- SKB mode overhead on veth interfaces
- Small ring buffers

As long as you see **> 0 packets**, the test is working.

---

## Running Specific Tests

### Run a Specific Test File

```bash
# Just packet tests
zig test src/lib/packet.zig --summary failures

# Just traffic tests (needs root + libc)
sudo zig test src/lib/traffic_test.zig -lc --summary failures
```

### Run a Specific Test Case

```bash
# Use --test-filter
zig test src/lib/packet.zig --test-filter "Protocol parsing"
```

---

## Integration with Git Hooks

### Pre-commit Hook

Create `.git/hooks/pre-commit`:

```bash
#!/bin/bash
set -e

echo "Running unit tests..."
make test-unit

echo "Running packet tests..."
make test-packet

echo "Running protocol tests..."
make test-protocol

echo "✓ All non-root tests passed!"
echo ""
echo "NOTE: Run 'sudo make test-all' before pushing to run full suite"
```

Make it executable:
```bash
chmod +x .git/hooks/pre-commit
```

### Pre-push Hook

Create `.git/hooks/pre-push`:

```bash
#!/bin/bash
set -e

echo "Running full test suite..."
sudo make test-all

echo "✓ All tests passed!"
```

---

## Performance Testing

### Measure Test Execution Time

```bash
time sudo make test-all
```

### Profile a Specific Test

```bash
# Run with timing
time sudo zig build test-traffic --summary failures

# Or use perf (Linux)
sudo perf stat zig build test-traffic
```

---

## Continuous Integration

### GitHub Actions Example

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: master

      - name: Run unit tests
        run: make test-unit

      - name: Run packet tests
        run: make test-packet

      - name: Run protocol tests
        run: make test-protocol

      # Root tests require special setup in CI
      - name: Run e2e tests
        run: sudo make test-e2e

      - name: Run traffic tests
        run: sudo make test-traffic
```

---

## Summary

### One Command to Rule Them All

```bash
sudo make test-all
```

This runs:
1. ✓ Unit tests (basic functionality)
2. ✓ Packet tests (parsing logic)
3. ✓ Protocol tests (serialization)
4. ✓ E2E tests (infrastructure)
5. ✓ Traffic tests (real packets) ⭐

### Quick Reference

| Command | Root? | What it tests |
|---------|-------|---------------|
| `make test-all` | Yes | Everything |
| `make test-unit` | No | Basic functions |
| `make test-packet` | No | Packet parsing |
| `make test-protocol` | No | Protocol headers |
| `make test-e2e` | Yes | Infrastructure |
| `make test-traffic` | Yes | Real traffic ⭐ |

### Help

```bash
make help
```

Shows all available commands!

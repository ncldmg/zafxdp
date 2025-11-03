# AF_XDP Architecture and Ring Buffers

This document provides visual representations of the AF_XDP socket architecture and how user space interacts with the kernel through shared memory rings.

## Overview

AF_XDP (Address Family XDP) provides a fast path for packet processing by allowing user space programs to bypass the kernel network stack and directly access network frames through shared memory rings.

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Space                                  │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                     Application (zafxdp)                      │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────────────┐   │  │
│  │  │  XDPSocket  │  │   Program   │  │   UMEM (User Memory) │   │  │
│  │  │   Struct    │  │   (eBPF)    │  │    Packet Buffers    │   │  │
│  │  └─────────────┘  └─────────────┘  └──────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────┘  │
│         │ mmap()          │ BPF syscall         │ mmap()            │
└─────────┼─────────────────┼─────────────────────┼──────────────────-┘
          │                 │                     │
          │                 ▼                     │
          │     ┌───────────────────────┐         │
          │     │    BPF Program VM     │         │
          │     │  (redirect to socket) │         │
          │     └───────────────────────┘         │
          │                 │                     │
══════════┼═════════════════┼═════════════════════┼══════════════════
          │     Kernel Space│                     │
          │                 │                     │
          ▼                 ▼                     ▼
  ┌───────────────────────────────────────────────────────┐
  │              AF_XDP Socket in Kernel                  │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
  │  │  Fill Ring  │  │   RX Ring   │  │   TX Ring   │    │
  │  │  (mmap'd)   │  │  (mmap'd)   │  │  (mmap'd)   │    │
  │  └─────────────┘  └─────────────┘  └─────────────┘    │
  │  ┌─────────────┐                                      │
  │  │ Completion  │                                      │
  │  │    Ring     │                                      │
  │  │  (mmap'd)   │                                      │
  │  └─────────────┘                                      │
  └───────────────────────────────────────────────────────┘
          │                 ▲                     │
          │                 │                     ▼
          ▼                 │         ┌───────────────────┐
  ┌───────────────┐         │         │   NIC TX Queue    │
  │ NIC RX Queue  │─────────┘         └───────────────────┘
  └───────────────┘
          ▲
          │
    ┌─────┴──────┐
    │  Network   │
    └────────────┘
```

## Ring Buffer Overview

AF_XDP uses four ring buffers for communication between user space and kernel:

```
┌──────────────────────────────────────────────────────────────────────┐
│                    UMEM (User Memory Region)                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ Frame 0  │  │ Frame 1  │  │ Frame 2  │  │ Frame 3  │  ...         │
│  │ 2048 B   │  │ 2048 B   │  │ 2048 B   │  │ 2048 B   │              │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘              │
└──────────────────────────────────────────────────────────────────────┘
       ▲              ▲              │              │
       │              │              │              │
       │              │              ▼              ▼
       │              │         Descriptors point to frames
       │              │
┌──────┴──────┐  ┌───┴────────┐  ┌─────────────┐  ┌──────────────┐
│  Fill Ring  │  │  RX Ring   │  │  TX Ring    │  │ Completion   │
│  (User→Kern)│  │ (Kern→User)│  │ (User→Kern) │  │  Ring        │
│             │  │            │  │             │  │ (Kern→User)  │
└─────────────┘  └────────────┘  └─────────────┘  └──────────────┘
```

### Ring Buffer Details

#### 1. Fill Ring (User → Kernel)
User space provides empty buffers for the kernel to fill with received packets.

```
Fill Ring - Detailed State Diagram
┌─────────────────────────────────────────────────────────────────────┐
│ Producer (User Space)              Consumer (Kernel)                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Ring State (Ring Size = 8, Cached = 4)                             │
│                                                                     │
│        Producer Index: 4 ─┐       ┌─ Consumer Index: 0              │
│                           ▼       ▼                                 │
│        ┌───┬───┬───┬───┬───┬───┬───┬───┐                            │
│  Ring: │ 0 │ 1 │ 2 │ 3 │   │   │   │   │  (indices wrap at 8)       │
│        └───┴───┴───┴───┴───┴───┴───┴───┘                            │
│         ▲               ▲                                           │
│         │               │                                           │
│     Consumed        Produced                                        │
│     (kernel         (user added,                                    │
│      took)          kernel not yet consumed)                        │
│                                                                     │
│  Producer View:                                                     │
│    - cached_prod = 4 (local copy, user updates)                     │
│    - cached_cons = 0 (cached kernel consumer, periodically read)    │
│    - available space = (ring_size - (cached_prod - cached_cons))    │
│    - available space = (8 - (4 - 0)) = 4 slots free                 │
│                                                                     │
│  Each Entry Format: u64                                             │
│  ┌──────────────────────────────────────────┐                       │
│  │  Frame Address (UMEM offset)             │                       │
│  │  Examples: 0, 2048, 4096, 6144, ...      │                       │
│  └──────────────────────────────────────────┘                       │
│                                                                     │
│  Operations:                                                        │
│  1. User checks available space before writing                      │
│  2. User writes frame addresses to ring[prod_idx & (size-1)]        │
│  3. User increments cached_prod                                     │
│  4. User updates shared producer index (visible to kernel)          │
   5. Kernel reads from ring[cons_idx & (size-1)]                     │
│  6. Kernel increments consumer index                                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

Example: Adding Frames to Fill Ring
────────────────────────────────────
Initial State:     After fillRing([0, 2048, 4096, 6144]):
prod=0, cons=0     prod=4, cons=0

    Empty              4 frames available for kernel
    ┌───┐              ┌───┬───┬───┬───┐
    │   │              │ 0 │2K │4K │6K │
    └───┘              └───┴───┴───┴───┘
```

#### 2. RX Ring (Kernel → User)
Kernel delivers received packets to user space.

```
RX Ring - Detailed State Diagram
┌─────────────────────────────────────────────────────────────────────┐
│ Producer (Kernel)                  Consumer (User Space)            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Ring State (Ring Size = 8, 3 packets received)                     │
│                                                                     │
│        Consumer Index: 0 ─┐       ┌─ Producer Index: 3              │
│                           ▼       ▼                                 │
│        ┌───────┬───────┬───────┬───────┬───┬───┬───┬───┐            │
│  Ring: │Desc 0 │Desc 1 │Desc 2 │       │   │   │   │   │            │
│        └───────┴───────┴───────┴───────┴───┴───┴───┴───┘            │
│         ▲                       ▲                                   │
│         │                       │                                   │
│      To Read               Just Produced                            │
│      (user               (kernel wrote,                             │
│       hasn't             user hasn't read)                          │
│       consumed)                                                     │
│                                                                     │
│  Consumer View:                                                     │
│    - cached_cons = 0 (local copy, user updates after reading)       │
│    - cached_prod = 3 (cached kernel producer, read before consume)  │
│    - available packets = (cached_prod - cached_cons)                │
│    - available packets = (3 - 0) = 3 packets to read                │
│                                                                     │
│  Descriptor Format (16 bytes per descriptor):                       │
│  ┌──────────────────────────────────────────┐                       │
│  │  +0: addr: u64    (UMEM frame offset)    │  8 bytes              │
│  │  +8: len: u32     (packet length)        │  4 bytes              │
│  │ +12: options: u32 (flags, reserved)      │  4 bytes              │
│  └──────────────────────────────────────────┘                       │
│                                                                     │
│  Example Descriptors:                                               │
│  Desc 0: {addr: 0,    len: 64,   options: 0}  ← Small packet        │
│  Desc 1: {addr: 2048, len: 1514, options: 0}  ← Full frame          │
│  Desc 2: {addr: 4096, len: 128,  options: 0}  ← Medium packet       │
│                                                                     │
│  Operations:                                                        │
│  1. Kernel receives packet into frame from Fill Ring                │
│  2. Kernel writes descriptor to ring[prod_idx & (size-1)]           │
│  3. Kernel increments producer index                                │
│  4. User polls: reads producer index to check for new packets       │
   5. User reads descriptor from ring[cons_idx & (size-1)]            │
│  6. User accesses packet data at UMEM + desc.addr                   │
│  7. User increments cached_cons                                     │
│  8. User updates shared consumer index                              │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

Packet Reception Timeline
─────────────────────────
Time  Event                        prod  cons  Available
────────────────────────────────────────────────────────
t0    Initial state                 0     0       0
t1    Kernel receives pkt #1        1     0       1  ← packet ready
t2    Kernel receives pkt #2        2     0       2
t3    Kernel receives pkt #3        3     0       3
t4    User reads pkt #1             3     1       2  ← user consumed
t5    User reads pkt #2             3     2       1
t6    User reads pkt #3             3     3       0  ← ring empty
```

#### 3. TX Ring (User → Kernel)
User space submits packets to transmit.

```
TX Ring
┌──────────────────────────────────────────────────┐
│ Producer (User Space)    Consumer (Kernel)       │
├──────────────────────────────────────────────────┤
│                                                  │
│    Write Index (user controls)                   │
│           │                                      │
│           ▼                                      │
│  ┌────────┬────────┬────────┬────────┐           │
│  │ Desc 0 │ Desc 1 │ Desc 2 │        │           │
│  └────────┴────────┴────────┴────────┘           │
│           ▲                                      │
│           │                                      │
│    Read Index (kernel controls)                  │
│                                                  │
│  Descriptor Format: (same as RX)                 │
│  ┌──────────────────────────────┐                │
│  │ addr: u64  (UMEM offset)     │                │
│  │ len: u32   (packet length)   │                │
│  │ options: u32                 │                │
│  └──────────────────────────────┘                │
└──────────────────────────────────────────────────┘
```

#### 4. Completion Ring (Kernel → User)
Kernel notifies user space when TX frames have been transmitted.

```
Completion Ring
┌─────────────────────────────────────────────┐
│ Producer (Kernel)    Consumer (User Space)  │
├─────────────────────────────────────────────┤
│                                             │
│    Write Index (kernel controls)            │
│           │                                 │
│           ▼                                 │
│  ┌───┬───┬───┬───┬───┬───┬───┬───┐          │
│  │ 0 │ 1 │ 2 │   │   │   │   │   │          │
│  └───┴───┴───┴───┴───┴───┴───┴───┘          │
│           ▲                                 │
│           │                                 │
│    Read Index (user controls)               │
│                                             │
│  Each entry = UMEM frame address (u64)      │
│  (frames now free to reuse)                 │
│                                             │
└─────────────────────────────────────────────┘
```

## Packet Reception Flow

```
1. Initialize
   ┌──────────────┐
   │ User Space   │
   │              │
   │ Fill Ring    │  ← User fills with frame addresses
   │ [0][1][2][3] │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │   Kernel     │
   │ Takes frames │
   │ from Fill    │
   └──────────────┘

2. Packet Arrives
   ┌──────────────┐
   │     NIC      │  Packet arrives
   │      │       │
   │      ▼       │
   │  RX Queue    │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │  XDP Program │  Executes on packet
   │  (eBPF)      │  → XDP_REDIRECT decision
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │   Kernel     │
   │ Writes to    │  Packet → Frame from Fill Ring
   │ RX Ring      │  Descriptor → RX Ring
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │ User Space   │
   │              │
   │   RX Ring    │  ← User reads descriptors
   │ [Desc0]      │
   │  │           │
   │  ▼           │
   │ UMEM[0]      │  ← Read packet data
   │ [packet...]  │
   └──────────────┘

3. Process & Return
   ┌──────────────┐
   │ User Space   │
   │              │
   │ Process pkt  │
   │              │
   │ Fill Ring    │  ← Return frame to Fill Ring
   │ [0]          │     for reuse
   └──────────────┘
```

## Packet Transmission Flow

```
1. Prepare Packet
   ┌──────────────┐
   │ User Space   │
   │              │
   │ UMEM[5]      │  Write packet data
   │ [packet...]  │
   │              │
   │ TX Ring      │  Write descriptor
   │ [Desc5]      │  {addr=5*2048, len=64}
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │   Kernel     │
   │ Reads from   │
   │ TX Ring      │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │     NIC      │
   │  TX Queue    │  Transmit packet
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │   Network    │  Packet sent
   └──────────────┘

2. Completion
   ┌──────────────┐
   │   Kernel     │
   │ Writes to    │  Frame address → Completion Ring
   │ Completion   │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │ User Space   │
   │              │
   │ Completion   │  ← Read completed frame addresses
   │ [5]          │
   │              │
   │ Frame 5 now  │  Reuse for RX or TX
   │ free!        │
   └──────────────┘
```

## Complete Packet Processing Cycle

```
Time →

User Space Actions:
    fillRing([0,1,2,3])  ←─────────┐
           │                       │ Recycle
           │                       │
           │     receivePackets()  │
           │            │          │
           │            ▼          │
           │      [process pkt]    │
           │            │          │
           │            ▼          │
           │     fillRing([0]) ────┘
           │
           │     sendPackets()
           │            │
           ▼            ▼
    ═══════════════════════════════════════
Kernel Actions:
           │            │
           ▼            ▼
    Get from Fill   Get from TX
           │            │
           ▼            ▼
    [RX Packet]    [TX Packet]
           │            │
           ▼            ▼
    Write RX Ring  Write Completion
           │            │
           ▼            ▼
    ═══════════════════════════════════════
User Space Reads:
           │            │
           ▼            ▼
    Read RX Ring   Read Completion
           │            │
           └────────────┘
```

## XDPSocket Structure in zafxdp

```
┌────────────────────────────────────────────────────────┐
│              XDPSocket (lib/xsk.zig)                   │
├────────────────────────────────────────────────────────┤
│                                                        │
│  Fields:                                               │
│  ┌──────────────────────────────────────────────┐      │
│  │ Fd: i32              ← Socket file descriptor│      │
│  │ Umem: []u8           ← mmap'd packet memory  │      │
│  │ Options: SocketOptions                       │      │
│  │                                              │      │
│  │ FillRing: RingBuffer                         │      │
│  │   └─ producer: u32 (user controlled)         │      │
│  │   └─ consumer: u32 (kernel controlled)       │      │
│  │   └─ ring: []u64 (frame addresses)           │      │
│  │                                              │      │
│  │ CompletionRing: RingBuffer                   │      │
│  │   └─ producer: u32 (kernel controlled)       │      │
│  │   └─ consumer: u32 (user controlled)         │      │
│  │   └─ ring: []u64 (frame addresses)           │      │
│  │                                              │      │
│  │ RxRing: RingBuffer                           │      │
│  │   └─ producer: u32 (kernel controlled)       │      │
│  │   └─ consumer: u32 (user controlled)         │      │
│  │   └─ ring: []XDPDesc                         │      │
│  │                                              │      │
│  │ TxRing: RingBuffer                           │      │
│  │   └─ producer: u32 (user controlled)         │      │
│  │   └─ consumer: u32 (kernel controlled)       │      │
│  │   └─ ring: []XDPDesc                         │      │
│  └──────────────────────────────────────────────┘      │
│                                                        │
│  Methods:                                              │
│  ┌──────────────────────────────────────────────┐      │
│  │ init()           - Create socket             │      │
│  │ deinit()         - Cleanup resources         │      │
│  │                                              │      │
│  │ fillRing()       - Add frames for RX         │      │
│  │ completionRing() - Get completed TX frames   │      │
│  │ rxRing()         - Get received packets      │      │
│  │ txRing()         - Submit packets for TX     │      │
│  │                                              │      │
│  │ receivePackets() - High-level RX             │      │
│  │ sendPackets()    - High-level TX             │      │
│  │ kick()           - Wake kernel               │      │
│  └──────────────────────────────────────────────┘      │
└────────────────────────────────────────────────────────┘
```

## Memory Layout Example

For a socket with 4 frames of 2048 bytes each:

```
UMEM Region (8192 bytes total)
┌──────────────────────────────────────────────────────────┐
│ Offset 0                                                 │
│ ┌────────────────────────────────────────────────────┐   │
│ │ Frame 0 (2048 bytes)                               │   │
│ │ [packet data...]                                   │   │
│ └────────────────────────────────────────────────────┘   │
│ Offset 2048                                              │
│ ┌────────────────────────────────────────────────────┐   │
│ │ Frame 1 (2048 bytes)                               │   │
│ │ [packet data...]                                   │   │
│ └────────────────────────────────────────────────────┘   │
│ Offset 4096                                              │
│ ┌────────────────────────────────────────────────────┐   │
│ │ Frame 2 (2048 bytes)                               │   │
│ │ [packet data...]                                   │   │
│ └────────────────────────────────────────────────────┘   │
│ Offset 6144                                              │
│ ┌────────────────────────────────────────────────────┐   │
│ │ Frame 3 (2048 bytes)                               │   │
│ │ [packet data...]                                   │   │
│ └────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘

Descriptors Reference Frames by Offset:
┌──────────────────────┐
│ XDPDesc              │
│  addr: 0             │ → Points to Frame 0
│  len: 64             │
│  options: 0          │
└──────────────────────┘

┌──────────────────────┐
│ XDPDesc              │
│  addr: 2048          │ → Points to Frame 1
│  len: 128            │
│  options: 0          │
└──────────────────────┘
```

## Performance Considerations

### Zero-Copy Operation
```
Traditional Network Stack:
┌─────────┐     ┌────────┐     ┌──────────┐
│   NIC   │ ──→ │ Kernel │ ──→ │   User   │
│  Buffer │     │ Buffer │     │  Buffer  │
└─────────┘     └────────┘     └──────────┘
              Copy #1         Copy #2

AF_XDP (Zero-Copy):
┌─────────┐                   ┌──────────┐
│   NIC   │ ───────────────→  │   UMEM   │
│  Buffer │   DMA Direct      │  (mmap)  │
└─────────┘                   └──────────┘
                              Shared Memory
                              (No Copies!)
```

### Lock-Free Ring Buffers
- Single Producer / Single Consumer design
- No locks or atomic operations needed
- Cache-line aligned for optimal performance
- User controls producer index for TX/Fill
- Kernel controls consumer index for TX/Fill
- Reversed for RX/Completion rings

## References

- [Linux AF_XDP Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [XDP Paper](https://www.usenix.org/conference/osdi18/presentation/hoiland-jorgensen)
- Implementation: `src/lib/xsk.zig`

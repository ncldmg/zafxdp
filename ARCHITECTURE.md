# AF_XDP Architecture and Ring Buffers

This document provides visual representations of the AF_XDP socket architecture and how user space interacts with the kernel through shared memory rings.

## Overview

AF_XDP (Address Family XDP) provides a fast path for packet processing by allowing user space programs to bypass the kernel network stack and directly access network frames through shared memory rings.

## High-Level Architecture

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

## Ring Buffer Architecture

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
Fill Ring
┌─────────────────────────────────────────────┐
│ Producer (User Space)    Consumer (Kernel)  │
├─────────────────────────────────────────────┤
│                                             │
│    Write Index (user controls)              │
│           │                                 │
│           ▼                                 │
│  ┌───┬───┬───┬───┬───┬───┬───┬───┐          │
│  │ 0 │ 1 │ 2 │ 3 │   │   │   │   │          │
│  └───┴───┴───┴───┴───┴───┴───┴───┘          │
│           ▲                                 │
│           │                                 │
│    Read Index (kernel controls)             │
│                                             │
│  Each entry = UMEM frame address (u64)      │
│                                             │
└─────────────────────────────────────────────┘
```

#### 2. RX Ring (Kernel → User)
Kernel delivers received packets to user space.

```
RX Ring
┌──────────────────────────────────────────────────┐
│ Producer (Kernel)    Consumer (User Space)       │
├──────────────────────────────────────────────────┤
│                                                  │
│    Write Index (kernel controls)                 │
│           │                                      │
│           ▼                                      │
│  ┌────────┬────────┬────────┬────────┐           │
│  │ Desc 0 │ Desc 1 │ Desc 2 │        │           │
│  └────────┴────────┴────────┴────────┘           │
│           ▲                                      │
│           │                                      │
│    Read Index (user controls)                    │
│                                                  │
│  Descriptor Format:                              │
│  ┌──────────────────────────────┐                │
│  │ addr: u64  (UMEM offset)     │                │
│  │ len: u32   (packet length)   │                │
│  │ options: u32                 │                │
│  └──────────────────────────────┘                │
└──────────────────────────────────────────────────┘
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
│  ┌──────────────────────────────────────────────┐    │
│  │ Fd: i32              ← Socket file descriptor│    │
│  │ Umem: []u8           ← mmap'd packet memory  │    │
│  │ Options: SocketOptions                       │    │
│  │                                               │    │
│  │ FillRing: RingBuffer                         │    │
│  │   └─ producer: u32 (user controlled)        │    │
│  │   └─ consumer: u32 (kernel controlled)      │    │
│  │   └─ ring: []u64 (frame addresses)          │    │
│  │                                               │    │
│  │ CompletionRing: RingBuffer                   │    │
│  │   └─ producer: u32 (kernel controlled)      │    │
│  │   └─ consumer: u32 (user controlled)        │    │
│  │   └─ ring: []u64 (frame addresses)          │    │
│  │                                               │    │
│  │ RxRing: RingBuffer                           │    │
│  │   └─ producer: u32 (kernel controlled)      │    │
│  │   └─ consumer: u32 (user controlled)        │    │
│  │   └─ ring: []XDPDesc                        │    │
│  │                                               │    │
│  │ TxRing: RingBuffer                           │    │
│  │   └─ producer: u32 (user controlled)        │    │
│  │   └─ consumer: u32 (kernel controlled)      │    │
│  │   └─ ring: []XDPDesc                        │    │
│  └──────────────────────────────────────────────┘    │
│                                                        │
│  Methods:                                              │
│  ┌──────────────────────────────────────────────┐    │
│  │ init()           - Create socket             │    │
│  │ deinit()         - Cleanup resources         │    │
│  │                                               │    │
│  │ fillRing()       - Add frames for RX         │    │
│  │ completionRing() - Get completed TX frames   │    │
│  │ rxRing()         - Get received packets      │    │
│  │ txRing()         - Submit packets for TX     │    │
│  │                                               │    │
│  │ receivePackets() - High-level RX            │    │
│  │ sendPackets()    - High-level TX            │    │
│  │ kick()           - Wake kernel              │    │
│  └──────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────┘
```

## Memory Layout Example

For a socket with 4 frames of 2048 bytes each:

```
UMEM Region (8192 bytes total)
┌──────────────────────────────────────────────────────────┐
│ Offset 0                                                 │
│ ┌────────────────────────────────────────────────────┐  │
│ │ Frame 0 (2048 bytes)                               │  │
│ │ [packet data...]                                   │  │
│ └────────────────────────────────────────────────────┘  │
│ Offset 2048                                              │
│ ┌────────────────────────────────────────────────────┐  │
│ │ Frame 1 (2048 bytes)                               │  │
│ │ [packet data...]                                   │  │
│ └────────────────────────────────────────────────────┘  │
│ Offset 4096                                              │
│ ┌────────────────────────────────────────────────────┐  │
│ │ Frame 2 (2048 bytes)                               │  │
│ │ [packet data...]                                   │  │
│ └────────────────────────────────────────────────────┘  │
│ Offset 6144                                              │
│ ┌────────────────────────────────────────────────────┐  │
│ │ Frame 3 (2048 bytes)                               │  │
│ │ [packet data...]                                   │  │
│ └────────────────────────────────────────────────────┘  │
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

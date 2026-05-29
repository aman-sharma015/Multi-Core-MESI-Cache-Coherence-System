# Multi-Core MESI Cache Coherence System

A SystemVerilog implementation of a multi-core cache coherence subsystem using the MESI (Modified, Exclusive, Shared, Invalid) protocol. The project models how modern multicore processors maintain a consistent view of shared memory while using private caches for performance.

---

## Overview

In multicore processors, each CPU core typically maintains a private cache to reduce memory access latency. While this improves performance, it introduces a consistency problem: multiple caches may contain copies of the same memory block, and modifications made by one core must be propagated correctly to all others.

This project implements a snoop-based MESI cache coherence protocol that ensures data consistency across multiple cores. Each core is equipped with an independent cache controller, while a centralized bus controller manages arbitration, coherence broadcasts, memory transactions, and cache-to-cache transfers.

The design models realistic coherence behavior including cache hits, cache misses, ownership transfers, invalidations, writebacks, and synchronization between competing requests.

---

## Features

### MESI Protocol Support

* Modified (M)
* Exclusive (E)
* Shared (S)
* Invalid (I)

### Bus Transactions

* BUS_READ
* BUS_READX
* BUS_UPGR
* BUS_WB
* BUS_FLUSH

### Cache Operations

* Read hits and misses
* Write hits and misses
* Dirty line eviction
* Writeback handling
* Cache line allocation
* Byte-enable writes

### Coherence Mechanisms

* Snoop-based coherence
* Peer cache invalidation
* Cache-to-cache transfers
* Ownership upgrades
* Shared line tracking
* Dirty data flushing

### Bus Controller Features

* Round-robin arbitration
* Snoop response collection
* Memory transaction management
* Per-core completion signaling
* Data broadcast synchronization

---

## System Architecture

```text
                    +----------------------+
                    |    Bus Controller    |
                    +----------+-----------+
                               |
                               |
                  +------------+------------+
                  | Shared Coherence Bus    |
                  +------------+------------+
                               |
         +-----------+---------+---------+-----------+
         |           |                   |           |
         v           v                   v           v

    +---------+ +---------+       +---------+ +---------+
    | Cache 0 | | Cache 1 |  ...  | Cache N | | Cache N |
    +---------+ +---------+       +---------+ +---------+
         |           |                   |           |
         v           v                   v           v

      CPU 0       CPU 1              CPU N-1      CPU N

                               |
                               v

                     +------------------+
                     |   Main Memory    |
                     +------------------+
```

---

## Cache Controller FSM

The cache controller manages CPU requests, cache hits, misses, allocations, writebacks, and coherence actions.

```text
IDLE
 |
 v
COMPARE_TAG
 |
 +--> Hit --------------------> IDLE
 |
 +--> Miss
        |
        +--> WRITE_BACK
        |
        +--> ALLOCATE
```

### States

| State       | Description                           |
| ----------- | ------------------------------------- |
| IDLE        | Waiting for CPU requests              |
| COMPARE_TAG | Performs tag lookup and hit detection |
| WRITE_BACK  | Handles dirty evictions and upgrades  |
| ALLOCATE    | Installs newly fetched cache lines    |

---

## Bus Controller FSM

The bus controller coordinates coherence operations between all caches.

```text
ARB_IDLE
    |
    v
ARB_SNOOP
    |
    +--> ARB_SNOOP_WAIT
    |
    +--> ARB_MEM
              |
              v
        ARB_MEM_DONE
```

### States

| State          | Description                           |
| -------------- | ------------------------------------- |
| ARB_IDLE       | Arbitration and transaction selection |
| ARB_SNOOP      | Collects snoop responses              |
| ARB_SNOOP_WAIT | Synchronization delay for upgrades    |
| ARB_MEM        | Handles memory transactions           |
| ARB_MEM_DONE   | Ensures stable data before completion |

---

## MESI State Behavior

### Modified (M)

* Dirty copy exists only in one cache
* Memory contains stale data
* Read by another core triggers flush
* Eviction requires writeback

### Exclusive (E)

* Clean copy exists only in one cache
* Matches memory contents
* Can upgrade to Modified without bus traffic

### Shared (S)

* Multiple caches may contain the line
* Matches memory contents
* Writes require invalidation of peer copies

### Invalid (I)

* Line is not present or has been invalidated
* Access results in a cache miss

---

## Supported Coherence Scenarios

### Read Miss

1. Cache miss detected
2. BUS_READ issued
3. Peer caches snoop request
4. Data fetched from memory or peer cache
5. Line installed as Exclusive or Shared

### Write Miss

1. Cache miss detected
2. BUS_READX issued
3. Peer copies invalidated
4. Data fetched
5. Line installed as Modified

### Shared-to-Modified Upgrade

1. Core holds Shared line
2. Write request arrives
3. BUS_UPGR broadcast issued
4. Peer Shared copies invalidated
5. Line transitions to Modified

### Dirty Eviction

1. Modified line selected for replacement
2. BUS_WB issued
3. Dirty data written to memory
4. New line allocated

---

## Design Parameters

| Parameter  | Description               |
| ---------- | ------------------------- |
| ADDR_WIDTH | Address width             |
| DATA_WIDTH | Data width                |
| BLOCK_SIZE | Words per cache line      |
| NUM_LINES  | Number of cache lines     |
| NUM_CORES  | Number of processor cores |

---

## Project Structure

```text
mesi-multicore-cache-coherence
│
├── rtl
│   └── design_commented.sv
│
├── docs
│   ├── architecture.md
│   ├── cache_controller_fsm.md
│   ├── bus_controller_fsm.md
│   └── mesi_protocol.md
│
├── tb
│   └── testbench.sv
│
├── images
│
├── LICENSE
│
└── README.md
```

---

## Verification Objectives

The design is intended to verify:

* Correct MESI state transitions
* Read hit behavior
* Write hit behavior
* Read miss handling
* Write miss handling
* Dirty writebacks
* Upgrade transactions
* Peer invalidations
* Cache-to-cache transfers
* Memory consistency

---

## Applications

* Computer Architecture Research
* Cache Coherence Studies
* Hardware Design Education
* Processor Design Projects
* SystemVerilog Learning
* Digital Design Verification

---

## Future Improvements

Potential extensions include:

* MOESI protocol support
* Directory-based coherence
* Multi-level cache hierarchy
* Non-blocking caches
* Performance counters
* Formal verification
* AXI memory interface integration

---

## Author

Aman Sharma

A SystemVerilog implementation exploring multicore cache coherence, snooping protocols, bus arbitration, and memory consistency mechanisms.

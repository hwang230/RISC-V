# L1 and complete subsystem verification

These tests specify the intended behavior of the in-progress L1 RTL. They
instantiate real design modules, fail on compiler errors or incorrect behavior,
and leave all RTL files unchanged. They can be rerun as each feature is added.

## Interface contract

Both L1 caches have four ways, 64-byte lines, 32-bit aligned words, fixed lookup
latency, and rank-based LRU replacement. L1I is read-only. L1D is **write-back,
write-allocate**, unlike the write-through L2.

The CPU asserts `i_read` with `iaddr`, or `d_read`/`d_write` with `daddr` and
`wdata`. A request is latched on the rising edge while L1 is idle. The driver
deasserts the request on a falling edge and waits for completion. `waitrequest`
must be high while servicing the request and low in its response cycle;
`instr`/`data` is sampled in that response cycle. There is no CPU response-ready
signal, so completion is not stallable. Simultaneous `d_write` and `d_read`
select the write, matching the draft controller's priority.

Cache misses fetch sixteen ordered words. A clean victim needs no writes. A
dirty L1D victim must write all sixteen words to the victim's original line
address before refilling the incoming line. Every write-back word has one AW,
one W, and one B handshake, even when AWREADY and WREADY arrive separately.

## Standalone tests

| Bench | Coverage |
| --- | --- |
| `tb_l1i.sv` | Reset, cold miss, hits and word offsets, line boundaries, independent sets/tags, four-way fill, LRU hit updates and eviction, invalid-way preference, AR/R delays, request latching/blocking, consecutive requests, random fetches |
| `tb_l1d.sv` | Reset including dirty bits, read hits/misses, write hits/misses, allocation, read-after-write, clean and dirty replacement on reads and writes, full-line write-back addresses/data, split AW/W acceptance, backend delays, CPU request priority/latching, random loads/stores |

Each standalone cache connects to `controllable_dram`, which acts as the lower
memory level and supplies configurable channel delays. Scoreboards maintain
architectural data independently of the DUT and check transaction counts,
line contents, tags, validity, and replacement state. The L1D reference also
tracks backing data separately: a dirty cached value may legitimately differ
from lower memory until eviction. Conflict reads drain dirty data for final
memory comparisons; reset is not used as a substitute for write-back.

```sh
tclsh test/memory/run_l1i.tcl --random-iters 0
tclsh test/memory/run_l1d.tcl --random-iters 0
tclsh test/memory/run_l1d.tcl --seeds 1,7,42 --random-iters 1000 --waves
```

## Full subsystem

`tb_memory_subsystem.sv` drives the CPU-facing ports of `memory_system.sv`, so
all traffic passes through the public wrapper into real L1I and L1D modules,
the shared real L2, and real DRAM. The scoreboard observes the wrapper's
internal hierarchy for protocol and cache-state checks.

It checks cold instruction/data refills, L1 hits without lower requests, L1
replacement that can hit in L2, write allocation, dirty write-back reaching
DRAM through L2, read-back after eviction, overlapping instruction/data misses,
seeded mixed traffic, and read/write-back at the last valid DRAM word. The
testbench verifies that its range guard classifies `MEM_SIZE` as the first
invalid address and checks every accepted AXI address against the configured
memory range. Memory is preloaded before testing; caches must populate
themselves through their actual interfaces.

Instruction and data address regions are separate. These caches have no
snoop/invalidation interface or implemented `FENCE.I`; the suite does not assume
instruction reads observe dirty L1D stores. CPU-level data writes update the
architectural reference immediately; lower-memory references advance only at
write-back. Once dirty data is drained, DRAM must match architectural memory.
The CPU-facing wrapper has no invalid-address response contract, so the tests
do not inject an out-of-range CPU request; they verify the range guard and the
highest valid address instead.

```sh
tclsh test/memory/run_memory_subsystem.tcl --random-iters 0
tclsh test/memory/run_memory_subsystem.tcl --seed 42 --random-iters 500
tclsh test/memory/run_all.tcl --keep-going
```

## `memory_system` wrapper

The wrapper exposes instruction and data CPU request/response ports and
instantiates `l1i_cache`, `l1d_cache`, `l2_cache`, and `DRAM`. L1I and L1D use
separate AXI-Lite interfaces to the shared L2; L2's memory interface connects
to DRAM. `d_waitrequest` indicates completion for both data reads and writes.
The current L1 CPU interface does not return a separate response code.

Defaults are 32-bit addresses/data, 64-byte cache lines, four ways, 64 KiB L1I
and L1D caches, 256 KiB L2, lookup latencies of 5/20 cycles, and a 1 MiB DRAM
with 100-cycle latency. These values can be changed with parameters, except
address/data width, line size, and associativity are currently constrained to
32 bits, 64 bytes, and four ways. The AXI and L1 interfaces themselves have
fixed 32-bit signal widths.

To compile-check just the wrapper and the modules it includes:

```sh
verilator --lint-only --timing -Wno-fatal -Wno-MODDUP \
  --top-module memory_system -Isrc/memory src/memory/memory_system.sv
```

The full-system testbench instantiates this wrapper and runs the directed and
random CPU traffic through its public ports. It also inspects internal cache
and AXI signals to retain detailed protocol and state checks.

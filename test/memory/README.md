# Memory subsystem verification

Self-checking SystemVerilog tests implementing
[`l2_dram_verification_plan.md`](../../src/memory/l2_dram_verification_plan.md).
Standalone L1I/L1D and full L1I + L1D + L2 + DRAM tests extend the backend suite;
their contract and coverage are described in [L1_VERIFICATION.md](L1_VERIFICATION.md).
The Tcl scripts build and run Verilator directly; no Vivado, Questa, UVM, or
custom C++ harness is required. All failures use `$fatal`; successful benches
print a unique `PASS: tb_...` line. The runner requires both exit status zero
and that marker, and stops the full regression at its first failure.

## Run

Requires Tcl 8.5+, Verilator with timing support, Make, and a C++ compiler
supporting coroutines. See the [Verilator command reference](https://verilator.org/guide/latest/exe_verilator.html)
for `--binary`, `--timing`, `--assert`, and waveform options.
Verilator 5.052 is the validation version. Older releases such as 5.020 can
reject the RTL's nonblocking array reset loops with `BLKLOOPINIT`.

The L1 and subsystem benches exercise the current RTL directly and report
compile or behavioral failures without substituting behavioral cache models.
Use `--keep-going` to collect results from every layer after a failure.

From the repository root:

```sh
# Directed scenarios followed by 200 random operations per layer.
tclsh test/memory/run_all.tcl

# Each layer independently.
tclsh test/memory/run_dram.tcl
tclsh test/memory/run_l2_protocol.tcl
tclsh test/memory/run_l2_integration.tcl
tclsh test/memory/run_l1i.tcl
tclsh test/memory/run_l1d.tcl
tclsh test/memory/run_memory_subsystem.tcl
tclsh test/memory/run_memory_widths.tcl

# Check progress as RTL is implemented; lint does not imply simulation passed.
tclsh test/memory/run_all.tcl --lint-only --keep-going
tclsh test/memory/run_all.tcl --keep-going --random-iters 0

# Directed only, or reproducible regression over several seeds.
tclsh test/memory/run_all.tcl --random-iters 0
tclsh test/memory/run_all.tcl --seeds 1,7,42 --random-iters 1000

# Record FST waveforms; preserve the RTL's production latencies if desired.
tclsh test/memory/run_l2_integration.tcl --waves --l2-latency 20 --dram-latency 100

# Faster geometry for debugging; 64-byte lines and four ways are retained.
tclsh test/memory/run_all.tcl --l1-cache-size 1024 --cache-size 4096 --l1-latency 1 --l2-latency 1 --dram-latency 1

tclsh test/memory/run_all.tcl --help
tclsh test/memory/run_all.tcl --dry-run
```

Scripts resolve source paths relative to themselves, so they work from any
working directory. `--verilator PATH` (or environment variable `VERILATOR`)
selects an executable. `--jobs N` controls compile parallelism. `--build-dir`
selects the artifact directory; its default is the ignored `test/memory/build`.
Each layer has `build.log`, `seed_N.log`, `obj_OS_ARCH/Vtb_...`, and optional `seed_N.fst`.
Repeated runs with the same seed overwrite that seed's logs and waveform.
Wave tracing is limited to three hierarchy levels; ordinary assertions still
inspect complete cache and memory data.

The default L2 size is the RTL's 256 KiB with four ways and 64-byte lines.
Default L1 size is 64 KiB per cache. Default simulation latencies are L1=2,
L2=3 and DRAM=4 cycles. Valid L2 cache sizes are
powers of two from 1024 through 262144 bytes. Real integration uses the actual
`DRAM` module with 1 MiB of storage; the DRAM unit test uses 64 KiB, enough for
all unit-test addresses. Each xorshift seed is reproducible across simulators.
`--random-iters` accepts 0 through 100000. Random traffic only starts after the
directed tests in that bench pass; `run_all.tcl` runs DRAM, L2 protocol, L2/DRAM
integration, L1I, L1D, and the complete subsystem in that order. L1 sizes accept
powers of two from 1024 through 65536 bytes; full-system geometry must also meet
the constraints described in the L1 verification document. `--keep-going`
continues after a layer fails but still exits nonzero if any layer fails.

## Files and plan coverage

| File | Responsibility |
| --- | --- |
| `tb_dram.sv` | DRAM tests 0–10, randomized traffic, reference memory, exact latency, channel counts, response stability, and memory-range boundary |
| `controllable_dram.sv` | Behavioral backend with independent ARREADY, RVALID, AWREADY, WREADY, and BVALID delays |
| `tb_l2.sv` | Shared L1 drivers, independent cache and memory scoreboards, directed and random scenarios |
| `tb_l2_protocol.sv` | Layer 2 top: L2 attached to the controllable model |
| `tb_l2_integration.sv` | Layer 3 top: L2 attached to real DRAM RTL |
| `l2_assertions.sv` | Continuous checks for state/owner, blocking, stable stalled requests/responses, refill progression, and write-response ordering |
| `tb_l1i.sv` | CPU fetches through real L1I against the controllable backend |
| `tb_l1d.sv` | CPU loads/stores through real L1D, including dirty eviction and write allocation |
| `tb_memory_subsystem.sv` | CPU traffic through both real L1 caches, shared L2, and real DRAM |
| `tb_memory_widths.sv` | L1D/L2/DRAM read, store, dirty eviction, and reload at 32/32, 40/64, and 40/512 address/data widths |
| `run_common.tcl` | Compile options, input validation, logs, pass/fail handling |
| `run_*.tcl` | Entry points for each of the six layers and the complete regression |

| Plan scenarios | Checks |
| --- | --- |
| DRAM 0–4 | Reset, basic write/read, read-back, independent addresses, exact configured latency and counters |
| DRAM 5–9 | Split AW/W in both orders, RREADY/BREADY stalls, consecutive transactions without idle rising edges |
| DRAM 10 | Last valid word and testbench rejection of the first out-of-range address |
| L2 0–5 | Reset of every valid/rank entry, L1D/L1I miss/hit, same-line word selection, owner routing |
| L2 6–10 | Write hit/miss, both downstream AW/W orders, full allocation, write-through, read-after-write |
| L2 11–14 | Four-way fill, hit LRU update, fifth-tag eviction, invalid-way preference |
| L2 15–19 | All three arbitration priorities; a pending request during read miss, write miss, and write-through |
| L2 20–23 | Delayed ARREADY/RVALID and both L1 read response stalls, L1 write response stall; extra delayed backend BVALID case |
| L2 24–26 | Adjacent line boundary, same set/different tags, independent sets |
| Integration 1–10 | Real refills/hits, write-through and allocation, LRU eviction, instruction traffic, arbitration, sequential lines, mixed traffic, and final valid DRAM line |
| Random regression | L1I reads, L1D reads/writes, addresses, word offsets, locality, response stalls; randomized backend delays in layer 2 |

The L2 scoreboard derives hit, invalid selection, and LRU victim independently
from accepted requests. Every completed transaction checks the required number
of backend handshakes (zero reads on a hit, 16 ordered reads on a miss, exactly
one write-through on a write), the requested result, all valid lines in the
affected set, and matching backing data. Final sweeps compare every valid line
and every backing-memory word to the architectural reference.

Portable coverage counters report request types, hits/misses, invalid fills,
evictions, channel ordering and stalls, plus request-type × hit/miss and
request-type × replacement crosses. Mandatory directed categories must be
nonzero before PASS. These are procedural counters, not simulator covergroups
or a UCDB database. Global watchdogs bound stalled testbench waits.

## Scope and RTL notes

Only aligned full 32-bit writes are tested; `WSTRB` and partial writes remain
outside the plan. The instruction interface is read-only. The existing real
DRAM does not drive `bresp`, so its response code is not asserted or forced;
write ordering, response handshakes, latency, and memory contents are checked.
The controlled backend drives OKAY and its propagated response is checked.
A passing suite therefore does not certify the real DRAM's response code.
The boundary tests access the last valid DRAM word and classify `MEM_SIZE` as
out of range. No invalid CPU request is issued because the wrapper has no
defined invalid-address response.

RTL modules include the guarded AXI interface definition. The Verilator runner
also uses `-Wno-MODDUP` for compatibility with repeated source inclusion.
Other warnings remain visible in build logs and are nonfatal; compilation
errors and assertion failures remain fatal. Unknown-state behavior requires
separate four-state simulation; this suite targets Verilator.

The full-system bench drives the public CPU ports of `memory_system.sv` and
checks traffic across its L1I/L1D, shared L2, and DRAM hierarchy. Its
scoreboards also inspect internal cache and AXI state. The legacy
`L1_cache.sv` was removed; the wrapper includes the current `L1I_cache.sv` and
`L1D_cache.sv` modules.
`run_memory_widths.tcl` separately builds that hierarchy with 32-bit addresses
and data, with 40-bit addresses and 64-bit data, and with 40-bit addresses and
512-bit data. The final case exercises a single data beat per 64-byte line. The
width bench checks every data word position in a line, a dirty L1D write,
eviction to DRAM, reload from the updated backing memory, and an out-of-range
high address that must not alias the first DRAM word.
Reduced-latency or reduced-size runs are useful checks but do not replace runs
with default geometry and production latencies.

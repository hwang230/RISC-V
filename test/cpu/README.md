# CPU unit tests

Run the SystemVerilog unit benches with Verilator from the repository root:

```sh
tclsh test/cpu/run_cpu_units.tcl
tclsh test/cpu/run_decoder.tcl
```

The unit runner builds and runs 15 benches, including the existing default
32-bit ALU tests. Fetch is exercised at address/data widths 32/32, 40/64, and
40/128, including instruction-lane selection on wider memory responses.
Immediate generation runs all supported immediate formats at data widths 32
and 64. `tb_alu_widths.sv` also verifies:

- All operand pairs for every ALU operation at `DATA_WIDTH=2` and `8`, using
  a wider integer reference model. MAC uses a varying accumulator rather than
  exhaustively sweeping all three operands.
- Both register and immediate sources, every reserved operation code, and
  zero extension when `ADDR_WIDTH` is larger than `DATA_WIDTH`.
- Directed 64-bit arithmetic, comparisons, shifts above 31, masked shift amounts,
  high multiply results, division corner cases, and accumulator wraparound.
- Address truncation with `DATA_WIDTH=64` and `ADDR_WIDTH=32`.

The exhaustive 8-bit sweep performs over 1.6 million checks. Each test stops
with `$fatal` on a mismatch; the runner requires the suite PASS marker to succeed.
Build products are stored under `test/cpu/build/`.

DIV/REM use a separate 32-stage radix-2 ready/valid pipeline. Its unit bench
checks signed and unsigned quotient/remainder results at widths 2, 8, 32, and
64, including sustained requests, tags, output backpressure, reset flushing,
divide-by-zero, and signed overflow. The core currently waits for a divide
result before decoding younger instructions; the divider interface is
parameterized for tags and can be reused by a future out-of-order core.

## Integrated core tests

Run the standalone core suite, the generated directed programs, and the real
cache/DRAM programs in `assembly_files/`:

```sh
python3 test/cpu/run_core.py --suite all
```

The standalone memory model runs controlled instruction and data delays. The
hierarchy run uses the real `memory_system`, L1 caches, L2, and DRAM. Every
program is assembled by `test/cpu/rv32.py`, checked against its independent
RV32 reference model, and then loaded into the testbench.

`assembly_files/program9.s` is a steady-state compute benchmark with a loop
that fits in one instruction-cache line. `assembly_files/program10.s` is a
steady-state load benchmark that repeatedly reads one warmed data-cache line
and exercises the load-use path. `assembly_files/program11.s` is an
independent-instruction benchmark with eight parallel accumulator chains and
no memory operations in its hot loop. It establishes the single-issue baseline
for a future OOO/superscalar implementation. These benchmarks use 1000
iterations so compulsory misses are amortized across the measurement window.

Run only one class of tests:

```sh
python3 test/cpu/run_core.py --suite standalone
python3 test/cpu/run_core.py --suite programs
python3 test/cpu/run_core.py --suite programs --program assembly_files/program8.s
```

Add waveforms with `--waves`. The runner writes IPC and stall data to
`test/cpu/build/core/ipc.csv`, merged line coverage to
`test/cpu/build/core/coverage.info`, and annotated source under
`test/cpu/build/core/annotated/`.

The real-memory runner accepts cache and latency parameters for performance
sweeps:

```sh
python3 test/cpu/run_core.py --suite programs \
  --l1-size 16384 --l2-size 65536 \
  --l1-latency 2 --l2-latency 10 --dram-latency 50
```

These values change simulated IPC and stall behavior. They do not produce
physical area or maximum-frequency numbers. Those require synthesis and
static timing analysis for a target FPGA or standard-cell library. The current
workspace has Verilator but no Yosys/OpenROAD or vendor synthesis tool.

IPC is calculated as retired instructions divided by elapsed clock cycles.
The retirement event is the valid MEM/WB entry, so instruction-cache waits,
data-cache waits, load-use bubbles, and redirects are included in the cycle
count. Use the same CSV columns and benchmark image when comparing this core
with a Tomasulo or multicore implementation.

## Validation roadmap

When the core and toolchain support the required environment, validate in
this order:

1. Run the RISC-V Architectural Tests for ISA compliance and functional
   correctness.
2. Run Embench as the primary embedded performance benchmark.
3. Run CoreMark as a standard integer-performance comparison.
4. Add branch-prediction workloads covering tight backward loops, nested
   loops, biased and alternating branches, correlated branches, and indirect
   jumps.

For each performance run, the CSV records IPC, total cycles, conditional
branches, branch predictions, taken branches, branch mispredictions, cache
wait cycles, load-use stalls, FIFO-empty/FIFO-full cycles, conditional-branch
flush cycles, execute-busy cycles, and redirects. `I-wait` and `D-wait` count
only cycles with a corresponding cache request. FIFO-empty counts fetch
starvation while the backend could advance; FIFO-full shows fetch-buffer
pressure, usually during a data-side stall. These counters intentionally
overlap (for example, FIFO-full and D-wait can occur in the same cycle), so
they are observability signals rather than additive CPI bins. The two-bit BHT is initialized to
strongly not-taken and uses saturating updates. Keep the same program image and
memory configuration when comparing
the in-order core with future branch predictors, Tomasulo, or multicore
implementations. The architectural tests validate correctness; Embench,
CoreMark, and the custom workloads measure performance.

## Out-of-order backend and common retirement checking

`core.sv` remains the in-order baseline. Select `ooo_core.sv` or run both with:

```sh
python3 test/cpu/run_ooo_units.py
python3 test/cpu/run_core.py --backend both --suite all
python3 test/cpu/run_core.py --backend ooo --suite standalone --case ooo_traps_all
```

Both implementations expose the same `retire_*` trace: PC, instruction, optional
register write, optional store and optional synchronous trap with cause and tval.
The shared program scoreboard checks this interface against an independent
instruction-word reference, checks accepted memory writes separately (including
wrong-path writes), and compares all final architectural registers and modified
memory words. Pipeline internals are used only for performance counters and the
explicit DIV-overlap observation. The original in-order structural directed
bench remains part of `--backend inorder` and `--backend both`.

The reference's default behavior preserves the in-order implementation's inert
illegal encodings. Its machine mode (`reference(..., machine=True)`) implements
the OOO CSR/trap subset. The legacy `illegal` case gains a handler for OOO, so
that case is excluded from comparative IPC. All existing assembly programs use
the same instruction images for both backends. Generated programs run at
instruction/data delays `(0,0)`, `(1,5)` and `(7,2)`, with deterministic jitter
in the two delayed configurations. The real hierarchy still exercises the
actual L1/L2/DRAM handshakes.

OOO cases cover RAW/WAR/WAW, source/destination aliasing in three-source MAC,
`x0` destinations including faulting loads, repeated ROB wraparound, long
writeback contention, queue pressure, branch age recovery, stale divider
completion squashing, every supported trap, read-only CSR write intent,
unsupported CSR accesses, MRET and wrong-path system/memory effects. The fast
`ooo_overlap` run asserts that an independent ADD completes before an older
DIV, retires after DIV, and that the DIV-dependent ADD completes after DIV.
`test_rv32.py` includes handwritten CSR encodings and expected trap/return
results to check the oracle independently of the RTL.

Each backend writes separate `build/core/inorder/` or `build/core/ooo/` outputs.
Objects have an OS suffix so a Linux container and macOS do not reuse each
other's C++ objects. Per-run `*.metrics.json` contains queue and ROB occupancy
histograms, full cycles, dispatch stalls, operand and execution-unit wait cycles,
issue counts, writeback contention, recovery cycles and IPC. Histograms include
empty/full bins. Operand and unit waits count cycles with at least one affected
entry in the queue and can overlap other counters. IPC counts nonfaulting
retired instructions divided by all elapsed cycles; trap trace events are
reported separately. `build/core/ipc_comparison.csv` compares matching runs and
records cycle speedup as in-order cycles divided by OOO cycles.

## Capacity selection

After the complete correctness run, sweep reservation stations and storage:

```sh
python3 test/cpu/run_core.py --backend both --suite all --sweep
```

The default capacities are ROB 32, physical registers 64 and integer/multiply/
divider/memory issue queues 8/4/2/4. Override them using `--rob-entries`,
`--phys-regs`, `--int-entries`, `--mul-entries`, `--div-entries` and
`--mem-entries`. The sweep varies one capacity at a time over integer 4/8/12,
multiply 2/4/8, divider 1/2/4, memory 2/4/8, ROB 16/32/64 and physical registers
48/64/96. Every configuration runs the generated programs and all existing
assembly programs under all three standalone memory-delay configurations,
checking architecture on every run.

`build/core/sizing/sweep.csv` contains per-program results;
`recommendations.json` selects the smallest capacity within 2% of its group's
best aggregate cycles and flags individual run regressions over 5%. The combined
selection is reverified as another configuration. `report.md` summarizes it.
The runner then checks the combined configuration against the best measured
aggregate and fails if it exceeds the 2% cycle limit. It reports combined
per-run regressions above 5% against both the best aggregate configuration and
each run's individually fastest observed setting; a small aggregate change can
still hide a substantial regression in a compute-pressure workload.
Capacity is a storage proxy: physical area, inferred storage, timing and any
warnings must come from the Nangate45 synthesis/CTS reports before claiming
an area optimum.

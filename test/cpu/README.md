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

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

# ALU widths

`alu` has two elaboration-time parameters, both defaulting to 32:

| Parameter | Meaning |
| --- | --- |
| `DATA_WIDTH` | Width of register operands, immediate, accumulator, and `alu_result`. Must be a power of two and at least 2. |
| `ADDR_WIDTH` | Width of `alu_addr`, the address view of `alu_result`. Must be positive. |

All seven ALU submodules accept `DATA_WIDTH`, which the top-level ALU passes
down. They operate on data values, so address sizing is handled at the top.
Multiply/MAC intermediates use twice `DATA_WIDTH`; high-half multiplication,
signed division overflow, comparison results, and shift amounts scale with it.
Shifts use the low `$clog2(DATA_WIDTH)` bits of the second operand.

When the ALU calculates a load/store effective address, the core can consume
`alu_addr`. Arithmetic first wraps at `DATA_WIDTH`. A narrower `ADDR_WIDTH`
keeps the low result bits; a wider `ADDR_WIDTH` zero-extends that result and
does not recover any arithmetic carry. `alu_addr` is a combinational view of
every ALU result, so the core must use it only for appropriate memory operations.

```systemverilog
logic [DATA_WIDTH-1:0] rs1_val, rs2_val, rd_old_val, imm_val, alu_result;
logic [ADDR_WIDTH-1:0] effective_addr;

alu #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH)
) alu_stage (
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .rd_old_val(rd_old_val),
    .imm_val(imm_val),
    .cur_id_alu_op(cur_id_alu_op),
    .cur_id_alu_src_imm(cur_id_alu_src_imm),
    .alu_result(alu_result),
    .alu_addr(effective_addr)
);
```

If only the data result is needed, explicitly leave `.alu_addr()` open.
An individual submodule can also override its width, for example
`alu_multiply #(.DATA_WIDTH(64)) multiply_unit (...)`.

The surrounding CPU decoder, fetch, and memory hierarchy still target RV32.
Using a 64-bit ALU does not by itself implement an RV64 core.

Run the default CPU unit tests and the ALU width tests with:

```sh
tclsh test/cpu/run_cpu_units.tcl
```

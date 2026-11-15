# ASIC synthesis and early timing

Run the Nangate45 flow from this repository with:

```sh
./asic/run.sh place
```

The launcher uses the ORFS installation bundled in `openroad/orfs:latest`,
sources its `env.sh`, and mounts this repository at `/work`. It also mounts the
host OpenROAD-flow-scripts checkout at `/host-orfs` for reference; the host
checkout in this environment does not contain the installed Yosys binaries.
Flow databases, reports and logs persist under `asic/work/`. Pass an ORFS make
target such as `synth`, `floorplan` or `place` as the first argument. `NUM_CORES`
is fixed at four.

`config.mk` selects `core` and the Yosys slang SystemVerilog frontend. The
`CORE_ASIC_SYNTH` elaboration mode exposes the CPU's existing instruction and
data memory handshakes as top-level ports and omits the internal `memory_system`
instance. The normal simulation hierarchy is preserved. The memory hierarchy
contains behavioral cache and DRAM arrays without SRAM macro mapping in this
setup, so including it would turn large storage arrays into standard cells and
make the core-only first run misleading. The 31-word register file, branch
history table and fetch queues remain inside the CPU and are mapped to logic
and flip-flops in this run.

The SDC is an initial 10 ns / 100 MHz exploration constraint. Its 1 ns input
and output delays, 0.2 ns setup uncertainty, 0.1 ns hold uncertainty, 0.1 ns
clock transition and 5 fF output loads are provisional interface assumptions.
There are no false-path or multicycle exceptions; reset remains timed as a
synchronous input. This is not a signoff constraint set.

For this run, synthesis completed and `place` completed through detailed
placement with placement-based estimated parasitics. Reports are under
`asic/work/reports/nangate45/riscv_core/base/`; the mapped netlist and placed
ODB are under the corresponding `results` directory. The `SKIP_FLOORPLAN_REPAIR_TIMING`
setting avoids spending time on early floorplan resizing; placement still runs
timing-driven optimization and produces timing reports.

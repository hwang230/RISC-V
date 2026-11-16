# CPU synthesis, sizing and estimated post-CTS timing

Run from the repository root. The launcher uses the pinned ORFS Docker image;
no host OpenROAD or Yosys installation is required. Each run uses four cores
and a four-CPU container limit.

```sh
./src/asic/run.sh cts asic/config.mk asic/work/inorder
./src/asic/run.sh cts asic/ooo_config.mk asic/work/ooo_default
./src/asic/run.sh cts asic/ooo_config.mk asic/work/ooo_small \
  ROB_ENTRIES=16 PHYS_REGS=48 INT_ENTRIES=4 MUL_ENTRIES=2 DIV_ENTRIES=1 MEM_ENTRIES=2
python3 src/asic/report.py --work src/asic/work/inorder --design riscv_core \
  --output src/asic/work/inorder/summary.json
python3 src/asic/report.py --work src/asic/work/ooo_default \
  --output src/asic/work/ooo_default/summary.json
```

The first argument also accepts ORFS targets such as `synth`, `floorplan` and
`place`. The second and third arguments are relative to `src`, which is mounted
at `/work`. Extra arguments are make variable overrides. Separate work
directories prevent capacity candidates and the in-order baseline from sharing
cached results. Outputs under `src/asic/work/` are ignored by Git.

`config.mk` selects the existing in-order `core`; `ooo_config.mk` selects
`ooo_core`. Both use the Yosys slang frontend and `CORE_ASIC_SYNTH` to expose the
instruction/data handshakes without the behavioral cache/DRAM hierarchy. The
OOO default is ROB32, physical registers64 and integer/multiply/divider/memory
queues8/4/2/4. Queue and storage capacities can be overridden independently.
Architectural retirement ports remain observable and timed in both designs.

The register files, rename maps, ROB, issue queues, fetch queue and predictor
are synthesized as standard cells; no SRAM macros are inferred or substituted.
`summary.json` records mapped flip-flop count, synthesis area/cell count,
synthesis warning messages, CTS area/cell count, setup/hold slack and TNS, and
inserted hold buffers. `report.py` exits unsuccessfully for missing evidence or
negative setup/hold slack/TNS or reported timing violations. `--stage synth`
collects only synthesis evidence and does not claim timing acceptance.

Both designs use 10ns clocks, 1ns maximum input/output delays, 0ns minimum
input/output delays, 0.2ns setup uncertainty, 0.1ns hold uncertainty, 0.1ns input
and clock transitions, and provisional 5fF output loads. Hold repair remains
enabled. There are no false-path or multicycle exceptions; synchronous reset
is timed. OOO `4_cts_backend_paths.rpt` includes paths through scheduler,
physical-register-file, multiplier, rename and ROB cells as well as global
worst setup/hold paths.

Post-CTS timing uses estimated placement parasitics. These reports are not
signoff results; final routing, extraction and process-corner closure remain
separate work.

The `Verilator and Nangate45` GitHub Actions workflow first runs unit tests,
reference comparisons for both backends, and queue/storage capacity sweeps.
`test/cpu/build/core/sizing/recommendations.json` supplies the provisional
simulation choice. `sizing_manifest.py` generates the exact default,
one-capacity-at-a-time and selected physical candidates under identical
constraints. Remote jobs synthesize every candidate for area, then independently
run CTS for the in-order baseline and default/selected OOO configurations.
Artifacts retain logs, reports, metrics and timing constraints. Entry-count
savings are not treated as measured silicon area: compare real synthesis
summaries against cycle results and report the Pareto tradeoff.

The final `physical-sizing-comparison` artifact joins real synthesis area and
simulation cycles, lists Pareto candidates, flags per-run regressions over 5%,
and selects the minimum measured area within 2% of the fastest aggregate cycle
count among configurations with clean CTS evidence. Missing physical candidates
or no timing-clean candidate within that budget fail the reporting job. The
area-only proposal is listed separately when it still needs CTS validation.

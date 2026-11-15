export DESIGN_NICKNAME = riscv_memory
export DESIGN_NAME = asic_memory_top
export PLATFORM = nangate45

# Include the memory-system RTL and its local includes, but substitute an
# external DRAM blackbox for the behavioral simulation model.
export VERILOG_FILES = /work/memory/memory_system.sv /work/asic/dram_blackbox.sv /work/asic/memory_top.sv
export VERILOG_INCLUDE_DIRS = /work/memory
export VERILOG_DEFINES = -D ASIC_MEMORY_SYNTH
export SYNTH_HDL_FRONTEND = slang
export SYNTH_SLANG_ARGS += --unroll-limit=20000
# Nangate45 has no SRAM compiler/macros in this flow. Use compact cache
# capacities for a real flop-mapped hierarchy synthesis while keeping every
# inferred array below the explicit synthesis guard.
export SYNTH_MEMORY_MAX_BITS = 131072
export SDC_FILE = /work/asic/memory_constraint.sdc
export CORE_UTILIZATION ?= 35
export NUM_CORES = 4

export DESIGN_NICKNAME = riscv_core
export DESIGN_NAME = core
export PLATFORM = nangate45

# The only listed source is the real core RTL. Its local includes provide the
# package, decoder, fetch, register file, immediate generator and ALU sources.
# CORE_ASIC_SYNTH exposes the existing memory handshakes and removes the
# simulation cache/DRAM hierarchy from this ASIC synthesis boundary.
export VERILOG_FILES = /work/core.sv
export VERILOG_INCLUDE_DIRS = /work /work/alu
export VERILOG_DEFINES = -D CORE_ASIC_SYNTH
export SYNTH_HDL_FRONTEND = slang
export VERILOG_TOP_PARAMS = DATA_WIDTH 32 ADDR_WIDTH 32

export SDC_FILE = /work/asic/constraint.sdc
export CORE_UTILIZATION ?= 35
export PLACE_DENSITY_LB_ADDON = 0.15
export TNS_END_PERCENT = 100
export GPL_PLACE_IOS = 1
export NUM_CORES = 4
# Early timing characterization only: avoid a long, non-convergent repair loop
# before placement. Placement-stage parasitic timing reports remain enabled.
export SKIP_FLOORPLAN_REPAIR_TIMING = 1
# Keep the first post-CTS STA run bounded; CTS itself still inserts and
# balances the clock tree, while timing repair is deferred to later tuning.
export SKIP_CTS_REPAIR_TIMING = 1

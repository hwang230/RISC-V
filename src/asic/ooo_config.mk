include /work/asic/config.mk

export DESIGN_NICKNAME = riscv_ooo
export DESIGN_NAME = ooo_core
export VERILOG_FILES = /work/ooo_core.sv
export SDC_FILE = /work/asic/ooo_constraint.sdc

# Every candidate uses the same clock/interface assumptions and four cores.
# Override capacities on run.sh's command line after the work directory.
ROB_ENTRIES ?= 32
PHYS_REGS ?= 64
INT_ENTRIES ?= 8
MUL_ENTRIES ?= 4
DIV_ENTRIES ?= 2
MEM_ENTRIES ?= 4
export VERILOG_TOP_PARAMS = DATA_WIDTH 32 ADDR_WIDTH 32 \
    ROB_ENTRIES $(ROB_ENTRIES) PHYS_REGS $(PHYS_REGS) \
    INT_ENTRIES $(INT_ENTRIES) MUL_ENTRIES $(MUL_ENTRIES) \
    DIV_ENTRIES $(DIV_ENTRIES) MEM_ENTRIES $(MEM_ENTRIES)
export POST_CTS_TCL = /work/asic/timing_review.tcl
# The ROB is intentionally implemented as flip-flops, including the 64-entry
# sizing candidate. ORFS's default 4096-bit per-array guard is too small for
# its metadata. No memory is mocked or replaced with a black box.
export SYNTH_MEMORY_MAX_BITS = 32768

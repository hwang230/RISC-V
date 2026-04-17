# Hazard + loop/branch stress program for the pipelined RISC-V CPU
#
# What it exercises:
# - back-to-back RAW data hazards on ALU results
# - a store followed by a load from the same address
# - a load-use hazard: `lw x5, 0(x4)` followed immediately by `add x6, x5, x2`
# - a backward branch that forms a loop
#
# Expected final state after the loop finishes:
# - x1 = 45
# - x2 = 6
# - x3 = 6
# - mem[0] = 40
# - mem[1] = 45

    addi x1, x0, 0      # running result
    addi x2, x0, 1      # loop counter i
    addi x3, x0, 6      # loop limit
    addi x4, x0, 0      # base address for data memory

loop:
    add  x1, x1, x2     # RAW hazard on x1
    add  x7, x1, x2     # depends immediately on previous add
    sw   x7, 0(x4)      # store intermediate value
    lw   x5, 0(x4)      # read it back
    add  x6, x5, x2     # load-use hazard on x5
    add  x1, x6, x0     # RAW hazard on x6
    addi x2, x2, 1      # increment loop counter
    blt  x2, x3, loop   # backward branch

    sw   x1, 4(x4)      # store final result
done:
    jal  x0, done       # halt by looping forever

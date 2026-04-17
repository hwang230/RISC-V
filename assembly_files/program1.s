main:
    addi x2,  x0, 64         # base address in data memory
    addi x3,  x0, 7
    addi x4,  x0, 12
    addi x5,  x0, 1
    addi x15, x0, 19
    addi x16, x0, 4

    add  x6,  x3, x4         # x6  = 19
    sub  x7,  x4, x3         # x7  = 5
    and  x8,  x3, x4         # x8  = 4
    or   x9,  x3, x4         # x9  = 15
    xor  x10, x3, x4         # x10 = 11
    sll  x11, x5, x3         # x11 = 1 << 7 = 128

    addi x17, x0, -8
    sw   x15, 0(x2)          # MEM[64] = 19
    sw   x16, 4(x2)          # MEM[68] = 4
    addi x0,  x0, 0          # nop

    srl  x12, x11, x5        # x12 = 64
    sra  x13, x17, x5        # x13 = -4
    add  x14, x5, x0         # x14 = 1
    lw   x18, 0(x2)          # x18 = 19
    lw   x19, 4(x2)          # x19 = 4

    addi x0,  x0, 0          # nop
    addi x0,  x0, 0          # nop
    addi x0,  x0, 0          # nop

    beq  x18, x15, check_second
    jal  x0,  fail

check_second:
    bne  x19, x16, fail
    beq  x6,  x15, pass
    jal  x0,  fail

pass:
    jal  x0,  pass

fail:
    jal  x0,  fail

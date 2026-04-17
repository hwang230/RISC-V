main:
    addi x3,  x0, 5
    addi x4,  x0, 7
    addi x5,  x0, 1
    addi x6,  x0, 32
    lui  x7,  3
    addi x0,  x0, 0

    jal  x1,  worker
    jal  x0,  pass

worker:
    add  x10, x3, x4
    sub  x11, x4, x3
    or   x12, x3, x4
    and  x13, x3, x4
    sll  x14, x5, x3
    addi x0,  x0, 0

    beq  x14, x6, return_ok
    jal  x0,  fail

return_ok:
    jalr x0,  x1, 0

pass:
    jal  x0,  pass

fail:
    jal  x0,  fail

main:
    addi x1,  x0, 3
    addi x2,  x1, 4
    add  x3,  x2, x1
    sub  x4,  x3, x2
    and  x5,  x4, x3
    or   x6,  x5, x2
    xor  x7,  x6, x1

    sw   x7,  0(x0)
    lw   x8,  0(x0)
    add  x9,  x8, x7

    beq  x9,  x0, done
    addi x10, x9, 1
    addi x11, x10, 2

done:
    jal  x0,  done

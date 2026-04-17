main:
    addi x1,  x0, 1
    addi x2,  x1, 1
    addi x3,  x2, 1
    addi x4,  x3, 1
    addi x5,  x4, 1

    sw   x5,  0(x0)
    lw   x6,  0(x0)
    add  x7,  x6, x5
    sub  x8,  x7, x1

    beq  x8,  x7, done
    addi x9,  x8, 3
    add  x10, x9, x2

    sw   x10, 4(x0)
    lw   x11, 4(x0)
    add  x12, x11, x3

done:
    jal  x0,  done

main:
    addi x1,  x0, 5
    addi x2,  x0, 9
    add  x3,  x1, x2

    sw   x3,  16(x0) 
    addi x4,  x3, 7
    sw   x4,  20(x0)

    lw   x5,  16(x0)
    lw   x6,  20(x0)
    add  x7,  x5, x6

    sw   x7,  24(x0)
    lw   x8,  24(x0)

    bne  x8,  x7, done
    addi x9,  x8, -1
    add  x10, x9, x1

done:
    jal  x0,  done

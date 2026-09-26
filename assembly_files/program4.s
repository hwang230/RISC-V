main:
    addi x1, x0, 5           # x1 = 5
    addi x2, x1, 7           # RAW on x1, expect stall
    add  x3, x2, x1          # RAW on x2/x1, expect stall

    lui  x4, 0x80            # data base address 0x80000
    sw   x3, 0(x4)           # RAW on x3 and x4, expect stall
    lw   x5, 0(x4)           # x5 = 17
    add  x6, x5, x3          # RAW on load result x5, expect stall
    addi x7, x6, 1           # RAW on x6, expect stall
    sw   x7, 4(x4)           # MEM[0x80004] = 35
    lw   x8, 4(x4)           # x8 = 35
    add  x9, x8, x1          # x9 = 40

    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
done:
    jal x0, done

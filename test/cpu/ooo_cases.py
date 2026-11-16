"""Architectural programs stressing renaming, recovery, traps and queue pressure."""
import random


def with_trap_handler(source):
    """Give the legacy illegal-encoding program a machine trap environment."""
    return '''
        addi x30,x0,machine_handler
        csrrw x0,mtvec,x30
    '''+source+'''
        machine_handler:
        csrrs x26,mcause,x0
        csrrs x27,mtval,x0
        csrrs x28,mepc,x0
        addi x28,x28,4
        csrrw x0,mepc,x28
        mret
    '''


def cases():
    yield 'ooo_overlap', '''
        addi x1,x0,99
        addi x2,x0,3
        overlap_div: div x3,x1,x2
        overlap_add: add x4,x1,x2
        overlap_dep: add x5,x3,x2
        addi x6,x0,7
        done: jal x0,done
    '''
    yield 'ooo_rename_mac', '''
        addi x1,x0,93
        addi x2,x0,3
        div x3,x1,x2
        add x4,x3,x1
        addi x1,x0,7
        addi x3,x0,11
        add x5,x1,x3
        mac x3,x3,x3
        mac x3,x1,x3
        mac x1,x1,x1
        add x6,x4,x5
        addi x0,x0,31
        mul x0,x3,x1
        div x0,x4,x2
        mac x0,x1,x3
        add x7,x0,x0
        lui x20,0x80
        sw x3,0(x20)
        lw x0,0(x20)
        sw x1,4(x20)
        done: jal x0,done
    '''
    # More than two complete ROB revolutions, repeated WAW and read-before-write.
    pressure=['addi x1,x0,100','addi x2,x0,3','lui x20,0x80']
    for block in range(12):
        pressure += ['div x3,x1,x2']
        for n in range(12):
            r=4+n%10
            pressure += [f'add x{r},x3,x1',f'addi x1,x1,{n%3+1}',
                         f'mul x{r},x{r},x2',f'sw x{r},{4*((block*12+n)%32)}(x20)']
    yield 'ooo_resource_wraparound', '\n'.join(pressure+['done: jal x0,done'])
    # Both multiplier and divider stay busy; independent integer results compete
    # for the single writeback port while dependent users wake by physical tag.
    completions=['addi x1,x0,123','addi x2,x0,7']
    for n in range(90):
        completions += [f'div x{3+n%5},x1,x2',f'mul x{8+n%5},x1,x2',
                        f'add x{13+n%5},x1,x2',f'mac x{18+n%5},x1,x2']
    yield 'ooo_completion_pressure', '\n'.join(completions+['done: jal x0,done'])
    yield 'ooo_recovery_stale_div', '''
        addi x1,x0,99
        addi x2,x0,3
        lui x20,0x80
        div x3,x1,x2
        beq x3,x3,recovered
        div x4,x1,x2
        mul x5,x1,x2
        sw x1,0(x20)
        .word 0xffffffff
        lw x0,1(x20)
        recovered: addi x4,x0,19
        addi x5,x0,23
        add x6,x4,x5
        addi x7,x0,8
        loop: div x8,x1,x2
        beq x8,x8,next
        div x4,x1,x2
        sw x1,4(x20)
        next: addi x7,x7,-1
        bne x7,x0,loop
        sw x6,8(x20)
        done: jal x0,done
    '''
    yield 'ooo_branch_age_recovery', '''
        addi x1,x0,99
        addi x2,x0,3
        div x3,x1,x2
        beq x3,x3,outer
        beq x1,x1,wrong_target
        div x4,x1,x2
        wrong_target: addi x5,x0,-1
        outer: addi x5,x0,17
        addi x4,x0,27
        done: jal x0,done
    '''
    rng=random.Random(0x00c0ffee)
    random_ops=['lui x20,0x80']+[f'addi x{r},x0,{r*11}' for r in range(1,20)]
    for n in range(400):
        rd,a,b=[rng.randrange(0,20) for _ in range(3)]
        op=rng.choice(['add','sub','xor','sra','srl','mul','mulh','mulhsu','mulhu','div','rem','divu','remu','mac','addi','sw','lw'])
        if op=='addi': random_ops += [f'addi x{rd},x{a},{rng.randrange(-2048,2048)}']
        elif op in ('sw','lw'): random_ops += [f'{op} x{rd},{4*rng.randrange(64)}(x20)']
        else: random_ops += [f'{op} x{rd},x{a},x{b}']
    yield 'ooo_random_m', '\n'.join(random_ops+['done: jal x0,done'])
    yield from trap_cases()


def trap_cases():
    prefix='''
        addi x31,x0,handler
        csrrw x0,mtvec,x31
        lui x20,0x80
        addi x23,x20,256
        addi x1,x0,99
        addi x2,x0,3
        addi x5,x0,41
    '''
    handler='''
        done: jal x0,done
        handler:
        csrrs x26,mcause,x0
        csrrs x27,mtval,x0
        csrrs x28,mepc,x0
        sw x26,0(x23)
        sw x27,4(x23)
        sw x28,8(x23)
        addi x23,x23,12
        addi x28,x28,4
        csrrw x0,mepc,x28
        mret
    '''
    yield 'ooo_traps_all', prefix+'''
        csrrwi x0,mstatus,8
        div x3,x1,x2
        ecall
        add x4,x3,x2
        ebreak
        .word 0xffffffff
        .word 0x02001013
        .word 0x00003083
        .word 0x00103023
        .word 0x020040b3
        .word 0x00001067
        .word 0x002002ef
        jalr x5,x0,2
        .word 0x00000163
        .word 0x00101163
        lh x5,1(x20)
        lw x5,2(x20)
        lhu x0,1(x20)
        lw x0,1(x20)
        sh x1,1(x20)
        sw x1,2(x20)
        lb x6,1(x20)
        sb x1,3(x20)
        csrrs x6,mstatus,x0
        csrrs x7,mepc,x0
        fence
    '''+handler
    yield 'ooo_csr_restrictions', prefix+'''
        csrrs x6,misa,x0
        csrrw x7,misa,x0
        csrrs x8,misa,x0
        csrrw x9,mstatus,x1
        csrrs x10,mstatus,x0
        csrrwi x11,mscratch,31
        csrrsi x12,mscratch,3
        csrrci x13,mscratch,1
        csrrs x14,mscratch,x2
        csrrc x15,mscratch,x2
        csrrw x16,mscratch,x1
        csrrs x17,mscratch,x0
        csrrs x6,mvendorid,x0
        csrrs x6,marchid,x0
        csrrs x6,mimpid,x0
        csrrs x6,mhartid,x0
        csrrsi x6,mhartid,0
        csrrci x6,mhartid,0
        addi x6,x0,0
        csrrs x0,mhartid,x6
        csrrc x0,mhartid,x6
        csrrw x0,mhartid,x0
        csrrwi x0,mvendorid,0
        csrrsi x0,marchid,1
        csrrci x0,mimpid,1
        csrrs x0,0xc00,x0
        csrrw x0,0xb00,x0
        csrrs x0,0x100,x0
        csrrs x0,0x999,x0
        csrrw x0,mie,x1
        csrrw x0,mip,x1
        csrrs x6,mie,x0
        csrrs x7,mip,x0
        csrrw x0,mcause,x1
        csrrs x8,mcause,x0
        csrrwi x0,mepc,31
        csrrs x9,mepc,x0
        addi x10,x0,handler
        addi x10,x10,3
        csrrw x0,mtvec,x10
        csrrs x11,mtvec,x0
        ecall
        csrrs x12,mstatus,x0
    '''+handler
    # An older synchronous trap must supersede a younger resolved redirect.
    yield 'ooo_trap_over_branch', prefix+'''
        div x3,x1,x2
        .word 0xffffffff
        beq x1,x1,after_branch
        div x4,x1,x2
        sw x1,0(x20)
        after_branch: add x4,x3,x2
        sw x4,4(x20)
    '''+handler
    # Wrong-path system instructions and faults must neither touch CSRs nor trap.
    yield 'ooo_wrong_path_system', prefix+'''
        div x3,x1,x2
        beq x3,x3,good
        csrrw x0,mscratch,x1
        csrrw x0,mtvec,x0
        ecall
        ebreak
        .word 0xffffffff
        sw x1,0(x20)
        lw x0,1(x20)
        mret
        good: csrrs x6,mscratch,x0
        csrrs x7,mtvec,x0
        add x8,x3,x2
        sw x8,4(x20)
    '''+handler

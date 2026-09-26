"""Directed executable programs. Expected values come from rv32.reference."""
import random


def cases():
    yield 'smoke', '''
        addi x0,x0,99
        addi x1,x0,5
        addi x2,x1,7
        add x3,x2,x1
        sub x4,x3,x2
        lui x20,0x80
        sw x3,0(x20)
        lw x5,0(x20)
        add x6,x5,x3
        sw x6,4(x20)
        lw x7,4(x20)
        beq x7,x6,done
        addi x31,x0,-1
        done: jal x0,done
    '''
    memory = ['lui x20,0x80', 'lui x1,0x89abd', 'addi x1,x1,-529', 'sw x1,0(x20)']
    for lane in range(4):
        memory += [f'lb x2,{lane}(x20)', f'lbu x3,{lane}(x20)']
    for lane in (0,2):
        memory += [f'lh x4,{lane}(x20)', f'lhu x5,{lane}(x20)']
    memory += ['addi x6,x0,-128']
    for lane in range(4):
        memory += [f'sb x6,{lane}(x20)', 'lw x7,0(x20)']
    for lane in (0,2):
        memory += [f'sh x1,{lane}(x20)', 'lw x8,0(x20)']
    memory += ['lw x9,0(x20)', 'sw x9,64(x20)', 'lw x10,64(x20)',
               'sw x10,128(x20)', 'done: jal x0,done']
    yield 'load_store_lanes', '\n'.join(memory)
    control = ['addi x1,x0,-1', 'addi x2,x0,1', 'addi x3,x0,0', 'lui x20,0x80']
    for i,(op,a,b) in enumerate([('beq',1,1),('bne',1,2),('blt',1,2),('bge',2,1),('bltu',2,1),('bgeu',1,2)]):
        control += [f'{op} x{a},x{b},taken{i}', 'sw x1,0(x20)', f'taken{i}: addi x3,x3,1']
        # Invert operand relation (BEQ/BNE need equal/different explicitly).
        na,nb = (1,2) if op=='beq' else ((1,1) if op=='bne' else (b,a))
        control += [f'{op} x{na},x{nb},fail', 'addi x3,x3,1']
    control += ['addi x4,x0,3', 'loop: addi x4,x4,-1', 'bne x4,x0,loop',
                'jal x5,worker', 'jal x0,after', 'worker: addi x6,x5,0', 'jalr x0,0(x5)',
                'after: auipc x7,0', 'addi x7,x7,17', 'jalr x8,x7,0', 'sw x1,4(x20)',
                'auipc x9,1', 'jal x0,done', 'fail: sw x1,8(x20)', 'fail_loop: jal x0,fail_loop',
                'done: jal x0,done']
    yield 'control_flow', '\n'.join(control)
    math = ['addi x1,x0,-7', 'addi x2,x0,3', 'addi x3,x0,9', 'lui x20,0x80']
    for op in ('add','sub','sll','slt','sltu','xor','srl','sra','or','and','mul','mulh','mulhsu','mulhu','div','divu','rem','remu'):
        math += [f'{op} x4,x1,x2']
    for op in ('addi','slti','sltiu','xori','ori','andi'): math += [f'{op} x4,x1,-1']
    for op in ('slli','srli','srai'): math += [f'{op} x4,x1,31']
    math += ['mac x3,x1,x2', 'mac x3,x2,x2', 'sw x3,0(x20)', 'lw x3,0(x20)',
             'mac x3,x2,x2', 'add x5,x3,x2', 'sw x3,4(x20)', 'lui x1,0x80000', 'addi x2,x0,-1']
    for op in ('div','rem','divu','remu'): math += [f'{op} x4,x1,x2',f'{op} x4,x1,x0']
    math += ['done: jal x0,done']
    yield 'multiply_mac', '\n'.join(math)
    yield 'illegal', '''
        addi x1,x0,7
        .word 0xffffffff
        .word 0x02001013
        .word 0x00003083
        .word 0x00103023
        .word 0x020040b3
        addi x2,x1,1
        done: jal x0,done
    '''
    rng=random.Random(20260925)
    random_ops=['lui x20,0x80']+[f'addi x{r},x0,{r*7}' for r in range(1,16)]
    for _ in range(150):
        rd,a,b=[rng.randrange(1,16) for _ in range(3)]
        op=rng.choice(['add','sub','xor','and','or','slt','sltu','sll','sra','mul','addi','sw','lw'])
        if op=='addi': random_ops += [f'addi x{rd},x{a},{rng.randrange(-2048,2048)}']
        elif op in ('sw','lw'): random_ops += [f'{op} x{rd},{4*rng.randrange(32)}(x20)']
        else: random_ops += [f'{op} x{rd},x{a},x{b}']
    yield 'random_dependencies', '\n'.join(random_ops+['done: jal x0,done'])

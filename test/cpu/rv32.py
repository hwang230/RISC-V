"""Small, strict RV32IM + custom MAC assembler and independent ISA reference.

This is a test utility, not a general ELF/toolchain replacement. No pseudo
instruction expansion except nop, mv, j and ret; all instructions are 4 bytes.
"""
import re
from pathlib import Path

MASK = 0xffffffff
DATA_BASE = 0x80000
ALIASES = dict(zip(
    'zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6'.split(),
    range(32)))
ALIASES['fp'] = 8
R_OPS = {name: (f3, f7) for name, f3, f7 in [
    ('add',0,0), ('sub',0,32), ('sll',1,0), ('slt',2,0), ('sltu',3,0),
    ('xor',4,0), ('srl',5,0), ('sra',5,32), ('or',6,0), ('and',7,0),
    ('mul',0,1), ('mulh',1,1), ('mulhsu',2,1), ('mulhu',3,1),
    ('div',4,1), ('divu',5,1), ('rem',6,1), ('remu',7,1), ('mac',0,0)]}
I_OPS = dict(zip(['addi','slti','sltiu','xori','ori','andi'], [0,2,3,4,6,7]))
LOADS = dict(zip(['lb','lh','lw','lbu','lhu'], [0,1,2,4,5]))
STORES = dict(zip(['sb','sh','sw'], [0,1,2]))
BRANCHES = dict(zip(['beq','bne','blt','bge','bltu','bgeu'], [0,1,4,5,6,7]))


def reg(text):
    if text in ALIASES:
        return ALIASES[text]
    if re.fullmatch(r'x(?:[0-9]|[12][0-9]|3[01])', text):
        return int(text[1:])
    raise ValueError(f'invalid register {text}')


def sext(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def field(value, bits, signed=True, alignment=1):
    low, high = (-(1 << (bits-1)), (1 << (bits-1))-1) if signed else (0, (1 << bits)-1)
    if not low <= value <= high or value % alignment:
        raise ValueError(f'immediate {value} outside {low}..{high} or unaligned')
    return value & ((1 << bits)-1)


def assemble(source):
    labels, instructions = {}, []
    for number, line in enumerate(source.splitlines(), 1):
        line = line.split('#')[0].strip()
        while ':' in line:
            label, line = line.split(':', 1)
            if not re.fullmatch(r'[A-Za-z_.$][\w.$]*', label) or label in labels:
                raise ValueError(f'line {number}: invalid/duplicate label {label}')
            labels[label] = len(instructions)*4
            line = line.strip()
        if not line or line == '.text' or line.startswith(('.globl ', '.global ')):
            continue
        instructions.append((number, line))
    words = []
    for number, line in instructions:
        pc = len(words)*4
        parts = re.split(r'[\s,()]+', line.strip())
        op, args = parts[0], [a for a in parts[1:] if a]
        if op == 'nop': op, args = 'addi', ['x0','x0','0']
        if op == 'mv': op, args = 'addi', [*args,'0']
        if op == 'j': op, args = 'jal', ['x0',*args]
        if op == 'ret': op, args = 'jalr', ['x0','x1','0']
        def imm(token, relative=False):
            return labels[token] - (pc if relative else 0) if token in labels else int(token, 0)
        try:
            if op == '.word':
                if len(args) != 1: raise ValueError('expected one word')
                word = field(imm(args[0]),32,False)
            elif op in R_OPS:
                rd, r1, r2 = map(reg,args)
                f3,f7 = R_OPS[op]
                word = f7<<25 | r2<<20 | r1<<15 | f3<<12 | rd<<7 | (0x0b if op=='mac' else 0x33)
            elif op in I_OPS or op in ('slli','srli','srai'):
                rd, r1, value = args
                val = imm(value)
                f3 = I_OPS.get(op, 1 if op=='slli' else 5)
                encoded = (field(val,5,False) | (0x400 if op=='srai' else 0)) if op.endswith('li') or op=='srai' else field(val,12)
                word = encoded<<20 | reg(r1)<<15 | f3<<12 | reg(rd)<<7 | 0x13
            elif op in LOADS or op == 'jalr':
                rd, a, b = args
                # Both jalr rd, rs1, imm and jalr rd, imm(rs1).
                r1, val = (a, imm(b)) if op=='jalr' and (a.startswith('x') or a in ALIASES) else (b, imm(a))
                word = field(val,12)<<20 | reg(r1)<<15 | LOADS.get(op,0)<<12 | reg(rd)<<7 | (0x67 if op=='jalr' else 3)
            elif op in STORES:
                r2, value, r1 = args
                val = field(imm(value),12)
                word = (val>>5)<<25 | reg(r2)<<20 | reg(r1)<<15 | STORES[op]<<12 | (val&31)<<7 | 0x23
            elif op in BRANCHES:
                r1, r2, target = args
                val = field(imm(target,True),13,alignment=4)
                word = (val>>12)<<31 | ((val>>5)&63)<<25 | reg(r2)<<20 | reg(r1)<<15 | BRANCHES[op]<<12 | ((val>>1)&15)<<8 | ((val>>11)&1)<<7 | 0x63
            elif op in ('lui','auipc'):
                rd,value = args
                word = field(imm(value),20,False)<<12 | reg(rd)<<7 | (0x37 if op=='lui' else 0x17)
            elif op == 'jal':
                rd,target = args
                val = field(imm(target,True),21,alignment=4)
                word = (val>>20)<<31 | ((val>>1)&1023)<<21 | ((val>>11)&1)<<20 | ((val>>12)&255)<<12 | reg(rd)<<7 | 0x6f
            else:
                raise ValueError(f'unsupported instruction/directive {op}')
        except (ValueError, IndexError) as error:
            raise ValueError(f'line {number}: {line}: {error}') from error
        words.append(word)
    if not words: raise ValueError('empty program')
    return words, labels


def reference(words, stop_pc, max_steps=10000):
    """Decode machine words independently of the assembler's opcode tables.

    Uninitialized registers/data start at zero in this simulation harness.
    Illegal instructions are inert, matching the core's current no-trap policy.
    """
    regs = [0]*32
    memory = {i*4+j: (word>>(8*j))&255 for i,word in enumerate(words) for j in range(4)}
    trace, stores = [], []
    pc = 0
    for _ in range(max_steps):
        if pc == stop_pc: return trace, stores, regs, memory
        if pc % 4 or not 0 <= pc//4 < len(words): raise ValueError(f'PC outside program: {pc:#x}')
        ins = words[pc//4]
        opcode, rd, f3, r1, r2, f7 = ins&127, (ins>>7)&31, (ins>>12)&7, (ins>>15)&31, (ins>>20)&31, ins>>25
        a,b = regs[r1],regs[r2]
        sa,sb = sext(a,32),sext(b,32)
        value, dest, next_pc = 0,32,pc+4
        immediate = sext(ins>>20,12)
        if opcode in (0x37,0x17):
            value, dest = (ins&0xfffff000) + (pc if opcode==0x17 else 0),rd
        elif opcode == 0x6f:
            offset = sext(((ins>>31)<<20) | (((ins>>12)&255)<<12) | (((ins>>20)&1)<<11) | (((ins>>21)&1023)<<1),21)
            value,dest,next_pc = pc+4,rd,pc+offset
        elif opcode == 0x67 and f3==0:
            value,dest,next_pc = pc+4,rd,(a+immediate)&MASK&~1
        elif opcode == 0x63 and f3 in (0,1,4,5,6,7):
            taken = {0:a==b,1:a!=b,4:sa<sb,5:sa>=sb,6:a<b,7:a>=b}[f3]
            offset = sext(((ins>>31)<<12) | (((ins>>7)&1)<<11) | (((ins>>25)&63)<<5) | (((ins>>8)&15)<<1),13)
            if taken: next_pc = pc+offset
        elif opcode==0x03 and f3 in (0,1,2,4,5):
            size = 1 << (f3&3)
            addr = (a+immediate)&MASK
            if addr%size: raise ValueError('misaligned load unsupported')
            value = sum(memory.get(addr+j,0)<<(8*j) for j in range(size))
            if f3<4: value=sext(value,8*size)
            dest=rd
        elif opcode==0x23 and f3 in (0,1,2):
            addr=(a+sext(((ins>>25)<<5)|((ins>>7)&31),12))&MASK
            size=1<<f3
            if addr%size: raise ValueError('misaligned store unsupported')
            if addr < len(words)*4: raise ValueError('store overlaps code; use data base 0x80000')
            if addr+size > 0x100000: raise ValueError('store outside simulated memory')
            for j in range(size): memory[addr+j]=(b>>(j*8))&255
            stores.append((addr, (b&((1<<(8*size))-1))<<((addr&3)*8), ((1<<size)-1)<<(addr&3)))
        elif opcode==0x0b:
            value,dest=a*b+regs[rd],rd
        elif opcode==0x13:
            valid=True
            if f3==0: value=a+immediate
            elif f3==2: value=int(sa<immediate)
            elif f3==3: value=int(a<(immediate&MASK))
            elif f3==4: value=a^(immediate&MASK)
            elif f3==6: value=a|(immediate&MASK)
            elif f3==7: value=a&(immediate&MASK)
            elif f3==1 and f7==0: value=a<<r2
            elif f3==5 and f7 in (0,32): value=(sa if f7==32 else a)>>r2
            else: valid=False
            if valid: dest=rd
        elif opcode==0x33:
            valid=True
            if f7==1:
                if f3==0: value=a*b
                elif f3==1: value=(sa*sb)>>32
                elif f3==2: value=(sa*b)>>32
                elif f3==3: value=(a*b)>>32
                elif f3 in (4,6):
                    q = -1 if sb==0 else (abs(sa)//abs(sb))*(-1 if (sa<0)!=(sb<0) else 1)
                    value = q if f3==4 else (sa if sb==0 else sa-q*sb)
                elif f3==5: value=MASK if b==0 else a//b
                else: value=a if b==0 else a%b
            elif f7==0 or (f7==32 and f3 in (0,5)):
                value = {0:a-b if f7 else a+b,1:a<<(b&31),2:int(sa<sb),3:int(a<b),4:a^b,
                         5:(sa if f7 else a)>>(b&31),6:a|b,7:a&b}[f3]
            else: valid=False
            if valid: dest=rd
        value &= MASK
        if dest==0: dest=32
        if dest!=32: regs[dest]=value
        trace.append((pc,dest,value if dest!=32 else 0,ins))
        pc=next_pc&MASK
    raise ValueError(f'program did not reach stop PC {stop_pc:#x} in {max_steps} steps')


def image_files(path, out_dir, stop=None):
    words,labels=assemble(Path(path).read_text())
    if stop is None:
        stop_pc=labels.get('pass', labels.get('done',len(words)*4))
    else:
        stop_pc=labels[stop] if stop in labels else int(stop,0)
    # A self-loop prevents fall-through after a source without a done label.
    if stop_pc==len(words)*4: words.append(0x0000006f)
    trace,stores,regs,memory=reference(words,stop_pc)
    if not trace: raise ValueError('empty execution trace')
    out_dir=Path(out_dir)
    out_dir.mkdir(parents=True,exist_ok=True)
    stem=Path(path).stem
    image=out_dir/(stem+'.hex'); expected=out_dir/(stem+'.trace'); writes=out_dir/(stem+'.stores')
    image.write_text(''.join(f'{w:08x}\n' for w in words))
    expected.write_text(''.join(''.join(f'{v:08x}' for v in row)+'\n' for row in trace))
    writes.write_text(''.join(''.join(f'{v:08x}' for v in row)+'\n' for row in stores) or '0\n')
    return image,expected,writes,len(trace),len(stores),stop_pc,regs,memory

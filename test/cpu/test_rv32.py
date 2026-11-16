"""Known machine encodings and handwritten reference results protect the oracle."""
import unittest
from rv32 import assemble, reference


class RV32Tests(unittest.TestCase):
    def test_known_encodings(self):
        examples = {
            'addi x1,x0,5': 0x00500093,
            'addi x1,x2,-1': 0xfff10093,
            'add x1,x2,x3': 0x003100b3,
            'sub x1,x2,x3': 0x403100b3,
            'lw x1,4(x2)': 0x00412083,
            'sw x1,4(x2)': 0x00112223,
            'beq x1,x2,8': 0x00208463,
            'beq x1,x2,-4': 0xfe208ee3,
            'jal x1,8': 0x008000ef,
            'jal x1,-4': 0xffdff0ef,
            'jalr x0,x1,0': 0x00008067,
            'jalr x0,0(x1)': 0x00008067,
            'lui x1,0x80000': 0x800000b7,
            'auipc x1,1': 0x00001097,
            'srai x1,x2,31': 0x41f15093,
            'slli x1,x2,31': 0x01f11093,
            'mul x1,x2,x3': 0x023100b3,
            'mac x1,x2,x3': 0x0031008b,
            'nop': 0x00000013,
            'ret': 0x00008067,
            'csrrw x1,mscratch,x2': 0x340110f3,
            'csrrs x1,misa,x0': 0x301020f3,
            'csrrc x1,mstatus,x2': 0x300130f3,
            'csrrwi x1,mscratch,31': 0x340fd0f3,
            'csrrsi x1,mscratch,3': 0x3401e0f3,
            'csrrci x1,mscratch,1': 0x3400f0f3,
            'ecall': 0x00000073,
            'ebreak': 0x00100073,
            'mret': 0x30200073,
            'fence': 0x0ff0000f,
        }
        for source, expected in examples.items():
            with self.subTest(source=source):
                self.assertEqual(assemble(source)[0], [expected])

    def test_reject_invalid_input(self):
        for source in ('li x1,42','addi x32,x0,1','addi x1,x0,2048','slli x1,x2,32',
                       'beq x1,x2,2','jal x1,missing','.align 4','a: nop\na: nop'):
            with self.subTest(source=source), self.assertRaises(ValueError): assemble(source)

    def test_independent_machine_code_execution(self):
        # Hand-encoded addi x1,5; addi x2,x1,7; add x3,x2,x1; jal x0,0.
        trace,stores,regs,_=reference([0x00500093,0x00708113,0x001101b3,0x0000006f],12)
        self.assertEqual(regs[1:4],[5,12,17])
        self.assertEqual(len(trace),3)
        self.assertEqual(stores,[])

    def test_loop_memory_and_unsigned(self):
        words,labels=assemble('''
            lui x20,0x80
            addi x1,x0,-128
            sb x1,3(x20)
            lb x2,3(x20)
            lbu x3,3(x20)
            addi x4,x0,3
            loop: addi x4,x4,-1
            bne x4,x0,loop
            done: jal x0,done
        ''')
        _,stores,regs,memory=reference(words,labels['done'])
        self.assertEqual(regs[2:5],[0xffffff80,128,0])
        self.assertEqual(stores,[(0x80003,0x80000000,8)])
        self.assertEqual(memory[0x80003],128)

    def test_divide_corner_cases(self):
        words,labels=assemble('''
            lui x1,0x80000
            addi x2,x0,-1
            div x3,x1,x2
            rem x4,x1,x2
            div x5,x1,x0
            rem x6,x1,x0
            done: jal x0,done
        ''')
        _,_,regs,_=reference(words,labels['done'])
        self.assertEqual(regs[3:7],[0x80000000,0,0xffffffff,0x80000000])

    def test_machine_trap_return_known_answer(self):
        words,labels=assemble('''
            addi x1,x0,handler
            csrrw x0,mtvec,x1
            csrrwi x0,mstatus,8
            fault: ecall
            csrrs x6,mstatus,x0
            done: jal x0,done
            handler: csrrs x2,mcause,x0
            csrrs x3,mtval,x0
            csrrs x4,mepc,x0
            csrrs x5,mstatus,x0
            addi x4,x4,4
            csrrw x0,mepc,x4
            mret
        ''')
        trace,stores,regs,_=reference(words,labels['done'],machine=True)
        faults=[row for row in trace if row[4]]
        self.assertEqual(faults,[(labels['fault'],32,0,0x00000073,1,11,0)])
        self.assertEqual(regs[2:7],[11,0,labels['fault']+4,0x1880,0x1888])
        self.assertEqual(stores,[])

    def test_readonly_csr_write_intent_uses_register_index(self):
        words,labels=assemble('''
            addi x1,x0,handler
            csrrw x0,mtvec,x1
            csrrs x2,mhartid,x0
            csrrsi x3,mhartid,0
            addi x4,x0,0
            fault: csrrs x5,mhartid,x4
            done: jal x0,done
            handler: csrrs x6,mcause,x0
            csrrs x7,mtval,x0
            csrrs x8,mepc,x0
            addi x8,x8,4
            csrrw x0,mepc,x8
            mret
        ''')
        trace,_,regs,_=reference(words,labels['done'],machine=True)
        faults=[row for row in trace if row[4]]
        self.assertEqual(len(faults),1)
        self.assertEqual(faults[0][0],labels['fault'])
        self.assertEqual(faults[0][4:],(1,2,words[labels['fault']//4]))
        self.assertEqual(regs[2:7],[0,0,0,0,2])

    def test_misaligned_transfer_suppresses_link_write(self):
        words,labels=assemble('''
            addi x1,x0,handler
            csrrw x0,mtvec,x1
            addi x5,x0,77
            fault: jalr x5,x0,2
            done: jal x0,done
            handler: csrrs x6,mcause,x0
            csrrs x7,mtval,x0
            csrrs x8,mepc,x0
            addi x8,x8,4
            csrrw x0,mepc,x8
            mret
        ''')
        trace,_,regs,_=reference(words,labels['done'],machine=True)
        self.assertEqual([row[4:] for row in trace if row[4]],[(1,0,2)])
        self.assertEqual(regs[5:8],[77,0,2])

    def test_memory_fault_has_no_write_and_byte_access_is_allowed(self):
        words,labels=assemble('''
            addi x1,x0,handler
            csrrw x0,mtvec,x1
            lui x20,0x80
            addi x2,x0,127
            sw x2,2(x20)
            sb x2,1(x20)
            lw x0,1(x20)
            lbu x3,1(x20)
            done: jal x0,done
            handler: csrrs x8,mepc,x0
            addi x8,x8,4
            csrrw x0,mepc,x8
            mret
        ''')
        trace,stores,regs,memory=reference(words,labels['done'],machine=True)
        self.assertEqual([row[5:] for row in trace if row[4]],[(6,0x80002),(4,0x80001)])
        self.assertEqual(stores,[(0x80001,0x7f00,2)])
        self.assertEqual(regs[3],127)
        self.assertEqual(memory.get(0x80002,0),0)


if __name__=='__main__': unittest.main()

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


if __name__=='__main__': unittest.main()

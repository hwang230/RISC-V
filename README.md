# RISC-V

While I have already implemented a RISC-V processor in the context of my computer architecture (ECSE-425) class from McGill using VHDL, I wish to expand this project by implementing further features such as out-of-order execution or push towards superscalar execution by using Verilog. This will also serve as a very good opportunity for me to finally put myself to learning Verilog syntax. On the other hand, this brings us to also learn SystemVerilog, which is super helpful for verification flow by using UVM and SVA. 

Hope I get to commit daily to this project. It will go very slowly but one day surely!

# ALU Subsystem: Instruction Encoding & Control Logic

This document details the 5-bit control signal encoding for the Arithmetic Logic Unit (ALU). The design is fully compliant with the **RV32I** base integer instruction set and the **RV32M** standard extension, with additional custom support for **MAC (Multiply-Accumulate)** operations to accelerate AI and DSP workloads.

## 1. Control Signal Specification
The ALU is driven by a 5-bit signal (`alu_op_e`). This allows for up to 32 distinct operations, partitioned into arithmetic, logical, branch, and specialized math categories.

### 1.1 Base Integer Instructions (RV32I)
| Opcode [4:0] | Mnemonic | Category | Operation Description |
| :--- | :--- | :--- | :--- |
| `00000` | **ADD** | Arithmetic | $Result = A + B$ (Covers ADD, ADDI) |
| `00001` | **SUB** | Arithmetic | $Result = A - B$ |
| `00010` | **AND** | Logical | $Result = A \text{ AND } B$ (Covers AND, ANDI) |
| `00011` | **OR** | Logical | $Result = A \text{ OR } B$ (Covers OR, ORI) |
| `00100` | **XOR** | Logical | $Result = A \text{ XOR } B$ (Covers XOR, XORI) |
| `00101` | **SLL** | Shift | Logical Left Shift (A by B[4:0]) |
| `00110` | **SRL** | Shift | Logical Right Shift (A by B[4:0]) |
| `00111` | **SRA** | Shift | Arithmetic Right Shift (Sign-extended) |
| `01000` | **SLT** | Comparison | Set Less Than (Signed) |
| `01001` | **SLTU** | Comparison | Set Less Than (Unsigned) |

### 1.2 Branch Resolution Signals
These signals are utilized by the branch unit to evaluate jumping conditions.

| Opcode [4:0] | Mnemonic | Condition | Logic |
| :--- | :--- | :--- | :--- |
| `01010` | **BEQ** | Equal | $A == B$ |
| `01011` | **BNE** | Not Equal | $A \neq B$ |
| `01100` | **BLT** | Less Than | $A < B$ (Signed) |
| `01101` | **BGE** | Greater/Equal | $A \geq B$ (Signed) |
| `01110` | **BLTU** | Less Than (U) | $A < B$ (Unsigned) |
| `01111` | **BGEU** | Greater/Equal (U) | $A \geq B$ (Unsigned) |

### 1.3 Math Extension & AI Acceleration (RV32M + Custom)
The following encodings support multi-cycle operations for high-performance math and edge inference.

| Opcode [4:0] | Mnemonic | Category | Operation Description |
| :--- | :--- | :--- | :--- |
| `10000` | **MUL** | RV32M | Multiplication (Lower 32-bits) |
| `10001` | **MULH** | RV32M | Multiplication (Upper 32-bits, Signed) |
| `10011` | **MULHU** | RV32M | Multiplication (Upper 32-bits, Unsigned) |
| `10100` | **DIV** | RV32M | Division (Signed) |
| `10101` | **DIVU** | RV32M | Division (Unsigned) |
| `10110` | **REM** | RV32M | Remainder (Signed) |
| `11000` | **MAC** | **Custom** | **Multiply-Accumulate:** $(A \times B) + C$ |

## 2. Implementation Details

### 2.1 Multiply-Accumulate (MAC) Unit
To optimize for Neural Network inference (e.g., dot products), a specialized MAC unit is integrated. 
- **Accumulator Path:** The unit supports an external or internal 64-bit accumulator to maintain precision and prevent overflow during high-frequency additions.
- **Latency:** While standard ALU operations are single-cycle, the MAC and RV32M operations are decoupled to allow for pipelined execution without blocking the integer pipeline.

### 2.2 Status Flags
The ALU provides real-time status flags to the control unit:
- **Zero Flag:** Asserted when the output is zero (used for optimized BEQ/BNE).
- **Overflow/Carry:** Used for extended precision arithmetic and exception handling.

### 2.3 Integration with AXI-Lite
The ALU works in tandem with the Load-Store Unit (LSU) to calculate memory addresses. For `LB` (Load Byte) or `LH` (Load Half), the ALU provides the effective address while the LSU manages the byte-masking and AXI bus handshaking.
package cpu_pkg;

    // --- Global Parameters ---
    localparam int XLEN = 32;
    localparam logic [31:0] PC_RESET_VEC = 32'h0000_0000;

    // Common RV32 instruction field layout. The upper seven bits may be
    // funct7 or immediate bits depending on the instruction format.
    typedef struct packed {
        logic [6:0] funct7_or_imm_hi; // instr[31:25]
        logic [4:0] rs2;              // instr[24:20]
        logic [4:0] rs1;              // instr[19:15]
        logic [2:0] funct3;           // instr[14:12]
        logic [4:0] rd;               // instr[11:7]
        logic [6:0] opcode;           // instr[6:0]
    } instr_fields_t;

    // --- RV32I Base Opcodes (7-bit) ---
    typedef enum logic [6:0] {
        OP_LUI    = 7'b0110111, // Load Upper Immediate
        OP_AUIPC  = 7'b0010111, // Add Upper Immediate to PC
        OP_JAL    = 7'b1101111, // Jump and Link
        OP_JALR   = 7'b1100111, // Jump and Link Register
        OP_BRANCH = 7'b1100011, // Branch instructions (BEQ, BNE, etc.)
        OP_LOAD   = 7'b0000011, // Load instructions (LB, LW, etc.)
        OP_STORE  = 7'b0100011, // Store instructions (SB, SW, etc.)
        OP_ALU_I  = 7'b0010011, // Immediate Arithmetic/Logic
        OP_ALU_R  = 7'b0110011, // Register-Register Arithmetic/Logic
        OP_CUSTOM = 7'b0001011  // Reserved for your Custom MAC!
    } opcode_e;

    // --- ALU Operations (5-bit) ---
    // Includes RV32I, RV32M, and Custom MAC
    typedef enum logic [4:0] {
        // Arithmetic & Logic
        ALU_ADD    = 5'b00000,
        ALU_SUB    = 5'b00001,
        ALU_AND    = 5'b00010,
        ALU_OR     = 5'b00011,
        ALU_XOR    = 5'b00100,
        // Shifts
        ALU_SLL    = 5'b00101,
        ALU_SRL    = 5'b00110,
        ALU_SRA    = 5'b00111,
        // Comparisons
        ALU_SLT    = 5'b01000,
        ALU_SLTU   = 5'b01001,
        // Branching logic (passed to Branch Unit)
        ALU_BEQ    = 5'b01010,
        ALU_BNE    = 5'b01011,
        ALU_BLT    = 5'b01100,
        ALU_BGE    = 5'b01101,
        ALU_BLTU   = 5'b01110,
        ALU_BGEU   = 5'b01111,
        // RV32M Multiplication/Division
        ALU_MUL    = 5'b10000,
        ALU_MULH   = 5'b10001,
        ALU_MULHSU = 5'b10010,
        ALU_MULHU  = 5'b10011,
        ALU_DIV    = 5'b10100,
        ALU_DIVU   = 5'b10101,
        ALU_REM    = 5'b10110,
        ALU_REMU   = 5'b10111,
        // Custom Acceleration
        ALU_MAC    = 5'b11000
    } alu_op_e;

    // --- Immediate Formatting ---
    // Tells the Imm-Gen which bits to pull for sign-extension
    typedef enum logic [2:0] {
        IMM_I, // I-type: Addi, Loads, Jalr
        IMM_S, // S-type: Stores
        IMM_B, // B-type: Branches
        IMM_U, // U-type: Lui, Auipc
        IMM_J, // J-type: Jal
        IMM_R  // R-type: No immediate
    } imm_src_e;

endpackage : cpu_pkg

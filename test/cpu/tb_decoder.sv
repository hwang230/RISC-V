`timescale 1ns/1ps

module tb_decoder;
    import cpu_pkg::*;

    logic [31:0] instruction;
    instr_fields_t fields;
    logic [6:0] raw_opcode;
    opcode_e decoded_opcode;

    alu_op_e alu_op;
    logic mem_read;
    logic mem_write;
    logic reg_write;
    logic mem_to_reg_write;
    logic alu_src_imm;
    logic alu_src_pc;
    logic branch;
    logic jump;
    logic jalr;
    logic uses_rs1;
    logic uses_rs2;
    logic uses_rd_old;
    imm_src_e imm_type;
    logic [1:0] wb_sel;
    logic [1:0] mem_size;
    logic mem_unsigned;
    logic illegal_instr;

    int checks = 0;

    assign fields = instruction;
    assign raw_opcode = fields.opcode;
    assign decoded_opcode = opcode_e'(fields.opcode);

    decoder dut (
        .cur_opcode(decoded_opcode),
        .cur_funct3(fields.funct3),
        .cur_funct7(fields.funct7_or_imm_hi),
        .cur_id_alu_op(alu_op),
        .cur_id_mem_read(mem_read),
        .cur_id_mem_write(mem_write),
        .cur_id_reg_write(reg_write),
        .cur_id_mem_to_reg_write(mem_to_reg_write),
        .cur_id_alu_src_imm(alu_src_imm),
        .cur_id_alu_src_pc(alu_src_pc),
        .cur_id_branch(branch),
        .cur_id_jump(jump),
        .cur_id_jalr(jalr),
        .cur_id_uses_rs1(uses_rs1),
        .cur_id_uses_rs2(uses_rs2),
        .cur_id_uses_rd_old(uses_rd_old),
        .cur_id_imm_type(imm_type),
        .cur_id_wb_sel(wb_sel),
        .cur_id_mem_size(mem_size),
        .cur_id_mem_unsigned(mem_unsigned),
        .cur_id_illegal_instr(illegal_instr)
    );

    function automatic logic [31:0] encode_r(
        input logic [6:0] funct7,
        input logic [2:0] funct3,
        input logic [6:0] opcode
    );
        encode_r = {funct7, 5'd2, 5'd1, funct3, 5'd3, opcode};
    endfunction

    function automatic logic [31:0] encode_i(
        input logic [11:0] immediate,
        input logic [2:0] funct3,
        input logic [6:0] opcode
    );
        encode_i = {immediate, 5'd1, funct3, 5'd3, opcode};
    endfunction

    function automatic logic [31:0] encode_s(
        input logic [11:0] immediate,
        input logic [2:0] funct3,
        input logic [6:0] opcode
    );
        encode_s = {immediate[11:5], 5'd2, 5'd1, funct3,
                    immediate[4:0], opcode};
    endfunction

    function automatic logic [31:0] encode_b(
        input logic [2:0] funct3,
        input logic [6:0] opcode
    );
        encode_b = {1'b0, 6'b0, 5'd2, 5'd1, funct3, 4'b0, 1'b0, opcode};
    endfunction

    function automatic logic [31:0] encode_u(input logic [6:0] opcode);
        encode_u = {20'h12345, 5'd3, opcode};
    endfunction

    function automatic logic [31:0] encode_j(input logic [6:0] opcode);
        encode_j = {1'b0, 10'b0, 1'b0, 8'b0, 5'd3, opcode};
    endfunction

    task automatic check_instruction(
        input string test_name,
        input logic [31:0] encoded_instruction,
        input logic [6:0] expected_opcode,
        input alu_op_e expected_alu_op,
        input logic expected_illegal
    );
        instruction = encoded_instruction;
        #1;

        if (raw_opcode !== expected_opcode)
            $fatal(1, "%s: extracted opcode %07b, expected %07b",
                   test_name, raw_opcode, expected_opcode);
        if (alu_op !== expected_alu_op)
            $fatal(1, "%s: ALU op %0d, expected %0d",
                   test_name, alu_op, expected_alu_op);
        if (illegal_instr !== expected_illegal)
            $fatal(1, "%s: illegal=%0b, expected %0b",
                   test_name, illegal_instr, expected_illegal);

        checks++;
        $display("PASS: %-20s opcode=%07b alu_op=%0d illegal=%0b",
                 test_name, raw_opcode, alu_op, illegal_instr);
    endtask

    task automatic expect_bit(
        input string signal_name,
        input logic actual,
        input logic expected
    );
        if (actual !== expected)
            $fatal(1, "%s: got %0b, expected %0b", signal_name, actual, expected);
    endtask

    task automatic expect_pair(
        input string signal_name,
        input logic [1:0] actual,
        input logic [1:0] expected
    );
        if (actual !== expected)
            $fatal(1, "%s: got %02b, expected %02b", signal_name, actual, expected);
    endtask

    initial begin
        instruction = '0;

        // Register and immediate ALU classes, including funct-field checks.
        check_instruction("R-type ADD", encode_r(7'h00, 3'b000, OP_ALU_R),
                          OP_ALU_R, ALU_ADD, 1'b0);
        expect_bit("ADD reg_write", reg_write, 1'b1);
        check_instruction("R-type SUB", encode_r(7'h20, 3'b000, OP_ALU_R),
                          OP_ALU_R, ALU_SUB, 1'b0);
        check_instruction("R-type SLL", encode_r(7'h00, 3'b001, OP_ALU_R),
                          OP_ALU_R, ALU_SLL, 1'b0);
        check_instruction("R-type SLT", encode_r(7'h00, 3'b010, OP_ALU_R),
                          OP_ALU_R, ALU_SLT, 1'b0);
        check_instruction("R-type SLTU", encode_r(7'h00, 3'b011, OP_ALU_R),
                          OP_ALU_R, ALU_SLTU, 1'b0);
        check_instruction("R-type XOR", encode_r(7'h00, 3'b100, OP_ALU_R),
                          OP_ALU_R, ALU_XOR, 1'b0);
        check_instruction("R-type SRL", encode_r(7'h00, 3'b101, OP_ALU_R),
                          OP_ALU_R, ALU_SRL, 1'b0);
        check_instruction("R-type SRA", encode_r(7'h20, 3'b101, OP_ALU_R),
                          OP_ALU_R, ALU_SRA, 1'b0);
        check_instruction("R-type OR", encode_r(7'h00, 3'b110, OP_ALU_R),
                          OP_ALU_R, ALU_OR, 1'b0);
        check_instruction("R-type AND", encode_r(7'h00, 3'b111, OP_ALU_R),
                          OP_ALU_R, ALU_AND, 1'b0);
        check_instruction("MUL", encode_r(7'h01, 3'b000, OP_ALU_R),
                          OP_ALU_R, ALU_MUL, 1'b0);
        check_instruction("MULH", encode_r(7'h01, 3'b001, OP_ALU_R),
                          OP_ALU_R, ALU_MULH, 1'b0);
        check_instruction("MULHSU", encode_r(7'h01, 3'b010, OP_ALU_R),
                          OP_ALU_R, ALU_MULHSU, 1'b0);
        check_instruction("MULHU", encode_r(7'h01, 3'b011, OP_ALU_R),
                          OP_ALU_R, ALU_MULHU, 1'b0);
        check_instruction("DIV", encode_r(7'h01, 3'b100, OP_ALU_R),
                          OP_ALU_R, ALU_DIV, 1'b0);
        check_instruction("DIVU", encode_r(7'h01, 3'b101, OP_ALU_R),
                          OP_ALU_R, ALU_DIVU, 1'b0);
        check_instruction("REM", encode_r(7'h01, 3'b110, OP_ALU_R),
                          OP_ALU_R, ALU_REM, 1'b0);
        check_instruction("REMU", encode_r(7'h01, 3'b111, OP_ALU_R),
                          OP_ALU_R, ALU_REMU, 1'b0);
        check_instruction("bad R-type XOR", encode_r(7'h02, 3'b100, OP_ALU_R),
                          OP_ALU_R, ALU_ADD, 1'b1);
        check_instruction("I-type ADDI", encode_i(12'h800, 3'b000, OP_ALU_I),
                          OP_ALU_I, ALU_ADD, 1'b0);
        expect_bit("ADDI alu_src_imm", alu_src_imm, 1'b1);
        check_instruction("I-type SLTI", encode_i(12'hfff, 3'b010, OP_ALU_I),
                          OP_ALU_I, ALU_SLT, 1'b0);
        check_instruction("I-type SLTIU", encode_i(12'hfff, 3'b011, OP_ALU_I),
                          OP_ALU_I, ALU_SLTU, 1'b0);
        check_instruction("I-type XORI", encode_i(12'ha55, 3'b100, OP_ALU_I),
                          OP_ALU_I, ALU_XOR, 1'b0);
        check_instruction("I-type ORI", encode_i(12'h800, 3'b110, OP_ALU_I),
                          OP_ALU_I, ALU_OR, 1'b0);
        check_instruction("I-type ANDI", encode_i(12'h800, 3'b111, OP_ALU_I),
                          OP_ALU_I, ALU_AND, 1'b0);
        check_instruction("I-type SLLI", encode_i(12'h007, 3'b001, OP_ALU_I),
                          OP_ALU_I, ALU_SLL, 1'b0);
        check_instruction("I-type SRLI", encode_i(12'h005, 3'b101, OP_ALU_I),
                          OP_ALU_I, ALU_SRL, 1'b0);
        check_instruction("I-type SRAI", encode_i(12'h405, 3'b101, OP_ALU_I),
                          OP_ALU_I, ALU_SRA, 1'b0);
        check_instruction("bad I-type SLLI", encode_i(12'h020, 3'b001, OP_ALU_I),
                          OP_ALU_I, ALU_ADD, 1'b1);

        // Memory opcodes and their control outputs.
        check_instruction("load byte", encode_i(12'h100, 3'b000, OP_LOAD),
                          OP_LOAD, ALU_ADD, 1'b0);
        expect_pair("LB mem_size", mem_size, 2'b00);
        expect_bit("LB mem_unsigned", mem_unsigned, 1'b0);
        check_instruction("load half", encode_i(12'h100, 3'b001, OP_LOAD),
                          OP_LOAD, ALU_ADD, 1'b0);
        expect_pair("LH mem_size", mem_size, 2'b01);
        expect_bit("LH mem_unsigned", mem_unsigned, 1'b0);
        check_instruction("load word", encode_i(12'h100, 3'b010, OP_LOAD),
                          OP_LOAD, ALU_ADD, 1'b0);
        expect_bit("LW mem_read", mem_read, 1'b1);
        expect_bit("LW reg_write", reg_write, 1'b1);
        expect_bit("LW mem_to_reg", mem_to_reg_write, 1'b1);
        expect_pair("LW wb_sel", wb_sel, 2'b01);
        expect_pair("LW mem_size", mem_size, 2'b10);
        check_instruction("load byte unsigned", encode_i(12'h004, 3'b100, OP_LOAD),
                          OP_LOAD, ALU_ADD, 1'b0);
        expect_bit("LBU mem_unsigned", mem_unsigned, 1'b1);
        expect_pair("LBU mem_size", mem_size, 2'b00);
        check_instruction("load half unsigned", encode_i(12'h004, 3'b101, OP_LOAD),
                          OP_LOAD, ALU_ADD, 1'b0);
        expect_bit("LHU mem_unsigned", mem_unsigned, 1'b1);
        expect_pair("LHU mem_size", mem_size, 2'b01);
        check_instruction("store byte", encode_s(12'h024, 3'b000, OP_STORE),
                          OP_STORE, ALU_ADD, 1'b0);
        expect_bit("SB mem_write", mem_write, 1'b1);
        expect_pair("SB mem_size", mem_size, 2'b00);
        check_instruction("store half", encode_s(12'h024, 3'b001, OP_STORE),
                          OP_STORE, ALU_ADD, 1'b0);
        expect_bit("SH mem_write", mem_write, 1'b1);
        expect_pair("SH mem_size", mem_size, 2'b01);
        check_instruction("store word", encode_s(12'h024, 3'b010, OP_STORE),
                          OP_STORE, ALU_ADD, 1'b0);
        expect_bit("SW mem_write", mem_write, 1'b1);
        expect_pair("SW mem_size", mem_size, 2'b10);

        // Control-flow and upper-immediate opcode classes.
        check_instruction("branch equal", encode_b(3'b000, OP_BRANCH),
                          OP_BRANCH, ALU_BEQ, 1'b0);
        expect_bit("BEQ branch", branch, 1'b1);
        check_instruction("branch not equal", encode_b(3'b001, OP_BRANCH),
                          OP_BRANCH, ALU_BNE, 1'b0);
        check_instruction("branch less than", encode_b(3'b100, OP_BRANCH),
                          OP_BRANCH, ALU_BLT, 1'b0);
        check_instruction("branch greater equal", encode_b(3'b101, OP_BRANCH),
                          OP_BRANCH, ALU_BGE, 1'b0);
        check_instruction("branch less unsigned", encode_b(3'b110, OP_BRANCH),
                          OP_BRANCH, ALU_BLTU, 1'b0);
        check_instruction("branch ge unsigned", encode_b(3'b111, OP_BRANCH),
                          OP_BRANCH, ALU_BGEU, 1'b0);
        check_instruction("LUI", encode_u(OP_LUI), OP_LUI, ALU_ADD, 1'b0);
        expect_pair("LUI wb_sel", wb_sel, 2'b11);
        check_instruction("AUIPC", encode_u(OP_AUIPC), OP_AUIPC, ALU_ADD, 1'b0);
        expect_bit("AUIPC alu_src_pc", alu_src_pc, 1'b1);
        check_instruction("JAL", encode_j(OP_JAL), OP_JAL, ALU_ADD, 1'b0);
        expect_bit("JAL jump", jump, 1'b1);
        expect_pair("JAL wb_sel", wb_sel, 2'b10);
        check_instruction("JALR", encode_i(12'h008, 3'b000, OP_JALR),
                          OP_JALR, ALU_ADD, 1'b0);
        expect_bit("JALR jump", jump, 1'b1);
        expect_bit("JALR jalr", jalr, 1'b1);
        check_instruction("custom MAC", encode_r(7'h00, 3'b000, OP_CUSTOM),
                          OP_CUSTOM, ALU_MAC, 1'b0);

        // Unsupported opcode encodings must take the decoder default.
        check_instruction("unsupported opcode", encode_r(7'h00, 3'b000, 7'h7f),
                          7'h7f, ALU_ADD, 1'b1);

        $display("PASS: tb_decoder (%0d instruction cases)", checks);
        $finish;
    end
endmodule

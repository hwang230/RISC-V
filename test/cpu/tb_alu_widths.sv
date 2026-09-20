// Small widths allow exhaustive operand coverage against a wider integer model.
module tb_alu_small_width #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ADDR_WIDTH = DATA_WIDTH + 4
)(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    localparam int LIMIT = 1 << DATA_WIDTH;
    logic [DATA_WIDTH-1:0] rs1, rs2, old_value, immediate, result;
    logic [ADDR_WIDTH-1:0] address;
    logic use_imm;
    alu_op_e op;
    int checks;

    alu #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .rs1_val(rs1), .rs2_val(rs2), .rd_old_val(old_value), .imm_val(immediate),
        .cur_id_alu_op(op), .cur_id_alu_src_imm(use_imm),
        .alu_result(result), .alu_addr(address)
    );

    task automatic check(input alu_op_e operation, input int mathematical_result);
        logic [DATA_WIDTH-1:0] expected;
        expected = DATA_WIDTH'(mathematical_result);
        op = operation;
        #1;
        if (result !== expected || address !== ADDR_WIDTH'(expected))
            $fatal(1, "alu width=%0d op=%s a=%h b=%h old=%h: result=%h addr=%h expected=%h",
                   DATA_WIDTH, operation.name(), rs1, use_imm ? immediate : rs2,
                   old_value, result, address, expected);
        checks++;
    endtask

    initial begin
        int signed_a, signed_b;
        done = 1'b0;
        checks = 0;
        // The reference arithmetic uses 32-bit integers, wide enough to avoid
        // intermediate overflow for these 2-bit and 8-bit operand sweeps.
        for (int a = 0; a < LIMIT; a++) begin
            for (int b = 0; b < LIMIT; b++) begin
                signed_a = a < LIMIT / 2 ? a : a - LIMIT;
                signed_b = b < LIMIT / 2 ? b : b - LIMIT;
                rs1 = DATA_WIDTH'(a);
                old_value = DATA_WIDTH'(a ^ b);
                use_imm = 1'((a ^ b) & 1);
                // Give the unused source a different value to exercise the mux.
                rs2 = use_imm ? ~DATA_WIDTH'(b) : DATA_WIDTH'(b);
                immediate = use_imm ? DATA_WIDTH'(b) : ~DATA_WIDTH'(b);

                check(ALU_ADD, a + b);
                check(ALU_SUB, a - b);
                check(ALU_AND, a & b);
                check(ALU_OR, a | b);
                check(ALU_XOR, a ^ b);
                check(ALU_SLL, a << (b % DATA_WIDTH));
                check(ALU_SRL, a >> (b % DATA_WIDTH));
                check(ALU_SRA, signed_a >>> (b % DATA_WIDTH));
                check(ALU_SLT, int'(signed_a < signed_b));
                check(ALU_SLTU, int'(a < b));
                check(ALU_BEQ, int'(a == b));
                check(ALU_BNE, int'(a != b));
                check(ALU_BLT, int'(signed_a < signed_b));
                check(ALU_BGE, int'(signed_a >= signed_b));
                check(ALU_BLTU, int'(a < b));
                check(ALU_BGEU, int'(a >= b));
                check(ALU_MUL, a * b);
                check(ALU_MULH, (signed_a * signed_b) >>> DATA_WIDTH);
                check(ALU_MULHSU, (signed_a * b) >>> DATA_WIDTH);
                check(ALU_MULHU, (a * b) >> DATA_WIDTH);
                check(ALU_DIV, b == 0 ? -1 : signed_a / signed_b);
                check(ALU_DIVU, b == 0 ? LIMIT - 1 : a / b);
                check(ALU_REM, b == 0 ? a : signed_a % signed_b);
                check(ALU_REMU, b == 0 ? a : a % b);
                check(ALU_MAC, a * b + (a ^ b));
            end
        end
        for (int code = 25; code < 32; code++) check(alu_op_e'(code), 0);
        done = 1'b1;
        $display("PASS: tb_alu_small_width DATA_WIDTH=%0d ADDR_WIDTH=%0d (%0d checks)",
                 DATA_WIDTH, ADDR_WIDTH, checks);
    end
endmodule

module tb_alu_widths(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    localparam logic [63:0] MINIMUM = 64'h8000_0000_0000_0000;
    localparam logic [63:0] MAXIMUM = 64'h7fff_ffff_ffff_ffff;
    localparam logic [63:0] ONES = 64'hffff_ffff_ffff_ffff;
    logic done2, done8, done64;
    logic [63:0] rs1, rs2, old_value, immediate, result;
    logic [31:0] address;
    logic use_imm;
    alu_op_e op;
    int checks;

    tb_alu_small_width #(.DATA_WIDTH(2)) small_test(.done(done2));
    tb_alu_small_width #(.DATA_WIDTH(8)) exhaustive_test(.done(done8));
    alu #(.DATA_WIDTH(64), .ADDR_WIDTH(32)) dut (
        .rs1_val(rs1), .rs2_val(rs2), .rd_old_val(old_value), .imm_val(immediate),
        .cur_id_alu_op(op), .cur_id_alu_src_imm(use_imm),
        .alu_result(result), .alu_addr(address)
    );

    task automatic check(input string name, input alu_op_e operation,
                         input logic [63:0] a, b, expected,
                         input logic [63:0] accumulator = '0,
                         input logic immediate_select = 1'b0);
        op = operation;
        rs1 = a;
        rs2 = immediate_select ? ~b : b;
        immediate = immediate_select ? b : ~b;
        use_imm = immediate_select;
        old_value = accumulator;
        #1;
        if (result !== expected || address !== expected[31:0])
            $fatal(1, "alu width=64 %s: result=%h addr=%h expected=%h",
                   name, result, address, expected);
        checks++;
    endtask

    initial begin
        done64 = 1'b0;
        checks = 0;
        check("ADD carry above bit 31", ALU_ADD, 64'hffff_ffff, 1, 64'h1_0000_0000);
        check("ADD signed overflow", ALU_ADD, MAXIMUM, 1, MINIMUM);
        check("ADD unsigned wrap", ALU_ADD, ONES, 1, 0);
        check("ADD immediate", ALU_ADD, MINIMUM, 64'h1_0000_0000,
              64'h8000_0001_0000_0000, 0, 1'b1);
        check("SUB borrow", ALU_SUB, 64'h1_0000_0000, 1, 64'hffff_ffff);
        check("SUB wrap", ALU_SUB, 0, 1, ONES);
        check("AND upper bits", ALU_AND, 64'hff00_00ff_ff00_00ff,
              64'h0ff0_0ff0_0ff0_0ff0, 64'h0f00_00f0_0f00_00f0);
        check("OR upper bits", ALU_OR, MINIMUM, 64'h1_0000_0001, 64'h8000_0001_0000_0001);
        check("XOR upper bits", ALU_XOR, ONES, MAXIMUM, MINIMUM);
        check("SLL by zero", ALU_SLL, ONES, 0, ONES);
        check("SLL by 32", ALU_SLL, 1, 32, 64'h1_0000_0000);
        check("SLL by 63", ALU_SLL, 1, 63, MINIMUM);
        check("SLL masks 64", ALU_SLL, 1, 64, 1);
        check("SLL masks high bits", ALU_SLL, 1, ONES, MINIMUM, 0, 1'b1);
        check("SRL by 32", ALU_SRL, MINIMUM, 32, 64'h8000_0000);
        check("SRL by 63", ALU_SRL, ONES, 63, 1);
        check("SRL masks 64", ALU_SRL, MINIMUM, 64, MINIMUM);
        check("SRA by 32", ALU_SRA, MINIMUM, 32, 64'hffff_ffff_8000_0000);
        check("SRA by 63", ALU_SRA, MINIMUM, 63, ONES);
        check("SRA positive", ALU_SRA, MAXIMUM, 63, 0);
        check("SRA masks high bits", ALU_SRA, MINIMUM, 127, ONES);
        check("SLT sign at bit 63", ALU_SLT, MINIMUM, MAXIMUM, 1);
        check("SLTU unsigned high bit", ALU_SLTU, MINIMUM, MAXIMUM, 0);
        check("BEQ", ALU_BEQ, MINIMUM, MINIMUM, 1);
        check("BNE upper bit difference", ALU_BNE, MINIMUM, 0, 1);
        check("BLT upper bit difference", ALU_BLT, MINIMUM, 0, 1);
        check("BGE equal", ALU_BGE, MINIMUM, MINIMUM, 1);
        check("BLTU upper bit difference", ALU_BLTU, 0, MINIMUM, 1);
        check("BGEU upper bit difference", ALU_BGEU, MINIMUM, 0, 1);
        check("MUL bit 32 product", ALU_MUL, 64'h1_0000_0000, 2, 64'h2_0000_0000);
        check("MUL low wrap", ALU_MUL, ONES, ONES, 1);
        check("MULH negative times positive", ALU_MULH, MINIMUM, 2, ONES);
        check("MULH two minima", ALU_MULH, MINIMUM, MINIMUM, 64'h4000_0000_0000_0000);
        check("MULH two maxima", ALU_MULH, MAXIMUM, MAXIMUM, 64'h3fff_ffff_ffff_ffff);
        check("MULH minimum times minus one", ALU_MULH, MINIMUM, ONES, 0);
        check("MULHSU minimum times unsigned max", ALU_MULHSU, MINIMUM, ONES, MINIMUM);
        check("MULHSU minus one times unsigned max", ALU_MULHSU, ONES, ONES, ONES);
        check("MULHSU signed max times unsigned max", ALU_MULHSU, MAXIMUM, ONES,
              64'h7fff_ffff_ffff_fffe);
        check("MULHU max squared", ALU_MULHU, ONES, ONES, 64'hffff_ffff_ffff_fffe);
        check("MULHU bit 32 squared", ALU_MULHU, 64'h1_0000_0000, 64'h1_0000_0000, 1);
        check("DIV 64-bit dividend", ALU_DIV, MAXIMUM, 2, 64'h3fff_ffff_ffff_ffff);
        check("DIV signed minimum", ALU_DIV, MINIMUM, 2, 64'hc000_0000_0000_0000);
        check("DIV negative dividend", ALU_DIV, -64'd43, 5, -64'd8);
        check("DIV negative divisor", ALU_DIV, 43, -64'd5, -64'd8);
        check("DIV signed overflow", ALU_DIV, MINIMUM, ONES, MINIMUM);
        check("DIV zero", ALU_DIV, MINIMUM, 0, ONES);
        check("DIVU high bit", ALU_DIVU, ONES, 2, MAXIMUM);
        check("DIVU zero", ALU_DIVU, MAXIMUM, 0, ONES);
        check("REM negative dividend", ALU_REM, -64'd43, 5, -64'd3);
        check("REM negative divisor", ALU_REM, 43, -64'd5, 3);
        check("REM signed overflow", ALU_REM, MINIMUM, ONES, 0);
        check("REM zero", ALU_REM, MINIMUM, 0, MINIMUM);
        check("REMU unsigned high bit", ALU_REMU, ONES, MINIMUM, MAXIMUM);
        check("REMU zero", ALU_REMU, ONES, 0, ONES);
        check("MAC retains upper accumulator", ALU_MAC, 3, 4, 64'h1_0000_000c,
              64'h1_0000_0000);
        check("MAC product wraps", ALU_MAC, MINIMUM, 2, 7, 7);
        check("MAC accumulator wraps", ALU_MAC, ONES, 2, 1, 3);
        check("unknown op", alu_op_e'(5'b11111), ONES, ONES, 0, ONES);
        done64 = 1'b1;
        $display("PASS: tb_alu_widths DATA_WIDTH=64 ADDR_WIDTH=32 (%0d checks)", checks);
    end

    initial begin
        done = 1'b0;
        wait (done2 && done8 && done64);
        done = 1'b1;
        $display("PASS: tb_alu_widths (2/8/64-bit datapaths; address extension/truncation)");
    end
endmodule

module tb_alu_top(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, rd_old_val, imm_val, result, address;
    logic use_imm;
    alu_op_e alu_op;

    alu dut (
        .rs1_val(rs1_val),
        .rs2_val(rs2_val),
        .rd_old_val(rd_old_val),
        .imm_val(imm_val),
        .cur_id_alu_op(alu_op),
        .cur_id_alu_src_imm(use_imm),
        .alu_result(result),
        .alu_addr(address)
    );

    task automatic check(input string name, input alu_op_e op,
                         input logic [31:0] a, b, old_value, immediate,
                         input logic immediate_select, input logic [31:0] expected);
        alu_op = op;
        rs1_val = a;
        rs2_val = b;
        rd_old_val = old_value;
        imm_val = immediate;
        use_imm = immediate_select;
        #1;
        if (result !== expected)
            $fatal(1, "alu %s: got %08h expected %08h", name, result, expected);
        if (address !== expected)
            $fatal(1, "alu %s: address got %08h expected %08h", name, address, expected);
    endtask

    initial begin
        done = 1'b0;
        check("ADD register source", ALU_ADD, 32'd10, 32'd5, 32'd0, 32'd3, 1'b0, 32'd15);
        check("ADD immediate source", ALU_ADD, 32'd10, 32'd5, 32'd0, 32'd3, 1'b1, 32'd13);
        check("SUB immediate source", ALU_SUB, 32'd10, 32'd5, 32'd0, 32'd3, 1'b1, 32'd7);
        check("AND", ALU_AND, 32'hf0f0_00ff, 32'h0ff0_f00f, 32'd0, 32'd0, 1'b0,
              32'h00f0_000f);
        check("OR", ALU_OR, 32'hf0f0_00ff, 32'h0ff0_f00f, 32'd0, 32'd0, 1'b0,
              32'hfff0_f0ff);
        check("XOR", ALU_XOR, 32'hf0f0_00ff, 32'h0ff0_f00f, 32'd0, 32'd0, 1'b0,
              32'hff00_f0f0);
        check("SLL", ALU_SLL, 32'd1, 32'd4, 32'd0, 32'd0, 1'b0, 32'd16);
        check("SRL", ALU_SRL, 32'h8000_0000, 32'd1, 32'd0, 32'd0, 1'b0,
              32'h4000_0000);
        check("SRA", ALU_SRA, 32'hffff_fff8, 32'd2, 32'd0, 32'd0, 1'b0,
              32'hffff_fffe);
        check("SLT", ALU_SLT, 32'hffff_ffff, 32'd1, 32'd0, 32'd0, 1'b0, 32'd1);
        check("SLTU", ALU_SLTU, 32'hffff_ffff, 32'd1, 32'd0, 32'd0, 1'b0, 32'd0);
        check("BEQ true", ALU_BEQ, 32'd7, 32'd7, 32'd0, 32'd0, 1'b0, 32'd1);
        check("BNE true", ALU_BNE, 32'd7, 32'd8, 32'd0, 32'd0, 1'b0, 32'd1);
        check("BLT", ALU_BLT, 32'hffff_ffff, 32'd1, 32'd0, 32'd0, 1'b0, 32'd1);
        check("BGE", ALU_BGE, 32'd1, 32'hffff_ffff, 32'd0, 32'd0, 1'b0, 32'd1);
        check("BLTU", ALU_BLTU, 32'd1, 32'hffff_ffff, 32'd0, 32'd0, 1'b0, 32'd1);
        check("BGEU", ALU_BGEU, 32'hffff_ffff, 32'd1, 32'd0, 32'd0, 1'b0, 32'd1);
        check("MUL", ALU_MUL, 32'hffff_ffff, 32'd2, 32'd0, 32'd0, 1'b0, 32'hffff_fffe);
        check("MULH", ALU_MULH, 32'hffff_fffe, 32'd3, 32'd0, 32'd0, 1'b0, 32'hffff_ffff);
        check("MULHSU", ALU_MULHSU, 32'hffff_ffff, 32'hffff_ffff,
              32'd0, 32'd0, 1'b0, 32'hffff_ffff);
        check("MULHU", ALU_MULHU, 32'hffff_ffff, 32'hffff_ffff, 32'd0, 32'd0,
              1'b0, 32'hffff_fffe);
        check("DIV", ALU_DIV, 32'hffff_ffd6, 32'd5, 32'd0, 32'd0, 1'b0,
              32'hffff_fff8);
        check("DIVU", ALU_DIVU, 32'hffff_ffff, 32'd2, 32'd0, 32'd0, 1'b0,
              32'h7fff_ffff);
        check("REM", ALU_REM, 32'hffff_ffd6, 32'd5, 32'd0, 32'd0, 1'b0,
              32'hffff_fffe);
        check("REMU", ALU_REMU, 32'hffff_ffff, 32'd2, 32'd0, 32'd0, 1'b0,
              32'd1);
        check("MAC", ALU_MAC, 32'd3, 32'd4, 32'd5, 32'd0, 1'b0, 32'd17);
        check("unknown op", alu_op_e'(5'b11111), 32'd3, 32'd4, 32'd5, 32'd0,
              1'b0, 32'd0);

        done = 1'b1;
        $display("PASS: tb_alu_top (all ALU operations and source mux)");
    end
endmodule

module tb_alu_branch(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, result;
    alu_op_e alu_op;

    alu_branch dut(.*);

    task automatic check(input string name, input alu_op_e op,
                        input logic [31:0] a, b, input logic expected);
        alu_op = op;
        rs1_val = a;
        rs2_val = b;
        #1;
        if (result !== {31'b0, expected})
            $fatal(1, "alu_branch %s: got %08h expected %08h",
                   name, result, {31'b0, expected});
    endtask

    initial begin
        done = 1'b0;
        check("BEQ true", ALU_BEQ, 32'h1234, 32'h1234, 1'b1);
        check("BEQ false", ALU_BEQ, 32'h1234, 32'h1235, 1'b0);
        check("BNE true", ALU_BNE, 32'h1234, 32'h1235, 1'b1);
        check("BNE false", ALU_BNE, 32'h1234, 32'h1234, 1'b0);
        check("BLT negative", ALU_BLT, 32'hffff_ffff, 32'd1, 1'b1);
        check("BLT false", ALU_BLT, 32'd1, 32'hffff_ffff, 1'b0);
        check("BGE false", ALU_BGE, 32'hffff_ffff, 32'd1, 1'b0);
        check("BGE true", ALU_BGE, 32'd1, 32'hffff_ffff, 1'b1);
        check("BLTU true", ALU_BLTU, 32'd1, 32'hffff_ffff, 1'b1);
        check("BLTU false", ALU_BLTU, 32'hffff_ffff, 32'd1, 1'b0);
        check("BGEU true", ALU_BGEU, 32'hffff_ffff, 32'd1, 1'b1);
        check("BGEU false", ALU_BGEU, 32'd1, 32'hffff_ffff, 1'b0);
        check("SLT alias", ALU_SLT, 32'h8000_0000, 32'h7fff_ffff, 1'b1);
        check("SLTU alias", ALU_SLTU, 32'h8000_0000, 32'h7fff_ffff, 1'b0);
        check("unsupported op", ALU_ADD, 32'd1, 32'd1, 1'b0);
        done = 1'b1;
        $display("PASS: tb_alu_branch");
    end
endmodule

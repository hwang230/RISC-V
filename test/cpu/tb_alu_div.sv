module tb_alu_div(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, result;
    alu_op_e alu_op;

    alu_div dut(.*);

    task automatic check(input string name, input alu_op_e op,
                        input logic [31:0] a, b, expected);
        alu_op = op;
        rs1_val = a;
        rs2_val = b;
        #1;
        if (result !== expected)
            $fatal(1, "alu_div %s: got %08h expected %08h", name, result, expected);
    endtask

    initial begin
        done = 1'b0;
        check("DIV positive", ALU_DIV, 32'd42, 32'd5, 32'd8);
        check("DIV negative dividend", ALU_DIV, 32'hffff_ffd6, 32'd5, 32'hffff_fff8);
        check("DIV negative divisor", ALU_DIV, 32'd42, 32'hffff_fffb, 32'hffff_fff8);
        check("DIV both negative", ALU_DIV, 32'hffff_ffd6, 32'hffff_fffb, 32'd8);
        check("DIV by zero", ALU_DIV, 32'h1234_5678, 32'd0, 32'hffff_ffff);
        check("DIV overflow", ALU_DIV, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
        check("DIVU ordinary", ALU_DIVU, 32'hffff_ffff, 32'd2, 32'h7fff_ffff);
        check("DIVU high bit", ALU_DIVU, 32'h8000_0000, 32'd2, 32'h4000_0000);
        check("DIVU by zero", ALU_DIVU, 32'h1234_5678, 32'd0, 32'hffff_ffff);
        check("REM positive", ALU_REM, 32'd43, 32'd5, 32'd3);
        check("REM negative dividend", ALU_REM, 32'hffff_ffd6, 32'd5, 32'hffff_fffe);
        check("REM negative divisor", ALU_REM, 32'd43, 32'hffff_fffb, 32'd3);
        check("REM by zero", ALU_REM, 32'h8765_4321, 32'd0, 32'h8765_4321);
        check("REM overflow", ALU_REM, 32'h8000_0000, 32'hffff_ffff, 32'd0);
        check("REMU ordinary", ALU_REMU, 32'hffff_ffff, 32'd10, 32'd5);
        check("REMU high bit", ALU_REMU, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
        check("REMU by zero", ALU_REMU, 32'h8765_4321, 32'd0, 32'h8765_4321);
        check("unsupported op", ALU_ADD, 32'd42, 32'd5, 32'd0);
        done = 1'b1;
        $display("PASS: tb_alu_div");
    end
endmodule

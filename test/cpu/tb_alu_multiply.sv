module tb_alu_multiply(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, result;
    alu_op_e alu_op;

    alu_multiply dut(.*);

    task automatic check(input string name, input alu_op_e op,
                        input logic [31:0] a, b, expected);
        alu_op = op;
        rs1_val = a;
        rs2_val = b;
        #1;
        if (result !== expected)
            $fatal(1, "alu_multiply %s: got %08h expected %08h", name, result, expected);
    endtask

    initial begin
        done = 1'b0;
        check("MUL low", ALU_MUL, 32'hffff_ffff, 32'd2, 32'hffff_fffe);
        check("MUL wrap", ALU_MUL, 32'h1234_5678, 32'h10, 32'h2345_6780);
        check("MULH signed positive", ALU_MULH, 32'd3, 32'd7, 32'd0);
        check("MULH signed negative", ALU_MULH, 32'hffff_fffe, 32'd3, 32'hffff_ffff);
        check("MULH signed boundary", ALU_MULH, 32'h8000_0000, 32'hffff_ffff, 32'd0);
        check("MULHSU negative", ALU_MULHSU, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff);
        check("MULHSU min signed", ALU_MULHSU, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
        check("MULHSU max signed", ALU_MULHSU, 32'h7fff_ffff, 32'hffff_ffff, 32'h7fff_fffe);
        check("MULHU max unsigned", ALU_MULHU, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_fffe);
        check("unsupported op", ALU_MAC, 32'd3, 32'd4, 32'd0);
        done = 1'b1;
        $display("PASS: tb_alu_multiply");
    end
endmodule

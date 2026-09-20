module tb_alu_arithmetic(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, result;
    alu_op_e alu_op;

    alu_arithmetic dut(.*);

    task automatic check(input string name, input alu_op_e op,
                        input logic [31:0] a, b, expected);
        alu_op = op;
        rs1_val = a;
        rs2_val = b;
        #1;
        if (result !== expected)
            $fatal(1, "alu_arithmetic %s: got %08h expected %08h", name, result, expected);
    endtask

    initial begin
        done = 1'b0;
        check("ADD ordinary", ALU_ADD, 32'd17, 32'd25, 32'd42);
        check("ADD wrap", ALU_ADD, 32'hffff_ffff, 32'd1, 32'h0000_0000);
        check("ADD signed boundary", ALU_ADD, 32'h7fff_ffff, 32'd1, 32'h8000_0000);
        check("SUB ordinary", ALU_SUB, 32'd17, 32'd25, 32'hffff_fff8);
        check("SUB wrap", ALU_SUB, 32'd0, 32'd1, 32'hffff_ffff);
        check("SUB signed boundary", ALU_SUB, 32'h8000_0000, 32'd1, 32'h7fff_ffff);
        check("unsupported op", ALU_AND, 32'hffff_ffff, 32'h1234_5678, 32'd0);
        done = 1'b1;
        $display("PASS: tb_alu_arithmetic");
    end
endmodule

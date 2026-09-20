module tb_alu_shift(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, result;
    alu_op_e alu_op;

    alu_shift dut(.*);

    task automatic check(input string name, input alu_op_e op,
                        input logic [31:0] value, shamt, expected);
        alu_op = op;
        rs1_val = value;
        rs2_val = shamt;
        #1;
        if (result !== expected)
            $fatal(1, "alu_shift %s: got %08h expected %08h", name, result, expected);
    endtask

    initial begin
        done = 1'b0;
        check("SLL by zero", ALU_SLL, 32'h1234_5678, 32'd0, 32'h1234_5678);
        check("SLL by one", ALU_SLL, 32'h8000_0001, 32'd1, 32'h0000_0002);
        check("SLL masks shamt", ALU_SLL, 32'd1, 32'd33, 32'd2);
        check("SRL by one", ALU_SRL, 32'h8000_0000, 32'd1, 32'h4000_0000);
        check("SRL by 31", ALU_SRL, 32'hffff_ffff, 32'd31, 32'd1);
        check("SRA negative", ALU_SRA, 32'hffff_fff8, 32'd2, 32'hffff_fffe);
        check("SRA by 31", ALU_SRA, 32'h8000_0000, 32'd31, 32'hffff_ffff);
        check("SRA positive", ALU_SRA, 32'h7fff_ffff, 32'd31, 32'd0);
        check("unsupported op", ALU_ADD, 32'hffff_ffff, 32'd1, 32'd0);
        done = 1'b1;
        $display("PASS: tb_alu_shift");
    end
endmodule

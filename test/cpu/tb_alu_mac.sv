module tb_alu_mac(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, rd_old_val, result;
    alu_op_e alu_op;

    alu_mac dut(.*);

    task automatic check(input string name, input logic [31:0] a, b, old_value, expected);
        alu_op = ALU_MAC;
        rs1_val = a;
        rs2_val = b;
        rd_old_val = old_value;
        #1;
        if (result !== expected)
            $fatal(1, "alu_mac %s: got %08h expected %08h", name, result, expected);
    endtask

    initial begin
        done = 1'b0;
        check("ordinary", 32'd3, 32'd4, 32'd5, 32'd17);
        check("zero product", 32'd0, 32'hffff_ffff, 32'h1234_5678, 32'h1234_5678);
        check("low product wrap", 32'hffff_ffff, 32'd2, 32'd3, 32'd1);
        check("accumulator wrap", 32'h8000_0000, 32'd2, 32'd1, 32'd1);
        alu_op = ALU_ADD;
        #1;
        if (result !== 32'd0) $fatal(1, "alu_mac default mismatch: %08h", result);
        done = 1'b1;
        $display("PASS: tb_alu_mac");
    end
endmodule

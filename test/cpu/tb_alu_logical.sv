module tb_alu_logical(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] rs1_val, rs2_val, result;
    alu_op_e alu_op;

    alu_logical dut(.*);

    initial begin
        done = 1'b0;
        rs1_val = 32'hf0f0_00ff;
        rs2_val = 32'h0ff0_f00f;
        alu_op = ALU_AND;
        #1;
        if (result !== 32'h00f0_000f) $fatal(1, "alu_logical AND mismatch: %08h", result);
        alu_op = ALU_OR;
        #1;
        if (result !== 32'hfff0_f0ff) $fatal(1, "alu_logical OR mismatch: %08h", result);
        alu_op = ALU_XOR;
        #1;
        if (result !== 32'hff00_f0f0) $fatal(1, "alu_logical XOR mismatch: %08h", result);
        alu_op = ALU_ADD;
        #1;
        if (result !== 32'd0) $fatal(1, "alu_logical default mismatch: %08h", result);
        done = 1'b1;
        $display("PASS: tb_alu_logical");
    end
endmodule

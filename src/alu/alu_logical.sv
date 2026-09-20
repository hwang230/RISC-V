`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_logical #(
    parameter int unsigned DATA_WIDTH = 32
)(
    input alu_op_e alu_op,
    input logic [DATA_WIDTH-1:0] rs1_val,
    input logic [DATA_WIDTH-1:0] rs2_val,

    output logic [DATA_WIDTH-1:0] result
);
    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "alu_logical DATA_WIDTH must be positive");
    end
    always_comb begin
        case(alu_op)
            ALU_AND: result = rs1_val & rs2_val;
            ALU_OR: result = rs1_val | rs2_val;
            ALU_XOR: result = rs1_val ^ rs2_val;
            default: result = '0;
        endcase
    end
endmodule

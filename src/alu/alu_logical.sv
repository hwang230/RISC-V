`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_logical(
    input alu_op_e alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,

    output logic [31:0] result
);
    always_comb begin
        case(alu_op)
            ALU_AND: result = rs1_val & rs2_val;
            ALU_OR: result = rs1_val | rs2_val;
            ALU_XOR: result = rs1_val ^ rs2_val;
            default: result = '0;
        endcase
    end
endmodule

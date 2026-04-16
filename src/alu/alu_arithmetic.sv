`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_arithmetic(
    input logic [31:0] rs1_val, 
    input logic [31:0] rs2_val, 
    input alu_op_e alu_op, 
    output logic [31:0] result
);
    always_comb begin
        case(alu_op)
            ALU_ADD: result = rs1_val + rs2_val;
            ALU_SUB: result = rs1_val - rs2_val;
            default: result = '0;
        endcase
    end
endmodule

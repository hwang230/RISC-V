`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_shift(
    input alu_op_e alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,
    output logic [31:0] result
);
    always_comb begin
        case(alu_op)
            ALU_SLL: result = rs1_val << rs2_val[4:0];
            ALU_SRL: result = rs1_val >> rs2_val[4:0];
            ALU_SRA: result = $signed(rs1_val) >>> rs2_val[4:0];
            default: result = '0;
        endcase
    end
endmodule

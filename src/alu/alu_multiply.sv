`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_multiply(
    input alu_op_e alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,

    output logic [31:0] result
);
    logic [63:0] temp;
    always_comb begin
        case(alu_op) 
            ALU_MUL: begin
                temp = rs1_val * rs2_val;
                result = temp[31:0];
            end

            ALU_MULH: begin
                temp = $signed(rs1_val) * $signed(rs2_val);
                result = temp[63:32];
            end

            ALU_MULHU: begin
                temp = rs1_val * rs2_val;
                result = temp[63:32];
            end
            default: result = '0;
        endcase
    end
endmodule

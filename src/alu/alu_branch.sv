`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_branch(
    input alu_op_e alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,
    output logic [31:0] result
);
    logic temp;
    always_comb begin
        case (alu_op)
            ALU_BEQ:            temp = (rs1_val == rs2_val);
            ALU_BNE:            temp = (rs1_val != rs2_val);
            ALU_BLT, ALU_SLT:   temp = ($signed(rs1_val) < $signed(rs2_val));
            ALU_BGE:            temp = ($signed(rs1_val) >= $signed(rs2_val));
            ALU_BLTU, ALU_SLTU: temp = (rs1_val < rs2_val);
            ALU_BGEU:           temp = (rs1_val >= rs2_val);
            default:            temp = 1'b0;
        endcase
        result = {31'b0, temp};
    end
    
endmodule

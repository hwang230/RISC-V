`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_branch #(
    parameter int unsigned DATA_WIDTH = 32
)(
    input alu_op_e alu_op,
    input logic [DATA_WIDTH-1:0] rs1_val,
    input logic [DATA_WIDTH-1:0] rs2_val,
    output logic [DATA_WIDTH-1:0] result
);
    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "alu_branch DATA_WIDTH must be positive");
    end
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
        result = '0;
        result[0] = temp;
    end
    
endmodule

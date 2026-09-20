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
        temp = '0;
        result = '0;
        case(alu_op)
            ALU_MUL: begin
                temp = {32'b0, rs1_val} * {32'b0, rs2_val};
                result = temp[31:0];
            end

            ALU_MULH: begin
                temp = $signed({{32{rs1_val[31]}}, rs1_val}) *
                       $signed({{32{rs2_val[31]}}, rs2_val});
                result = temp[63:32];
            end

            ALU_MULHSU: begin
                temp = $signed({{32{rs1_val[31]}}, rs1_val}) *
                       $signed({32'b0, rs2_val});
                result = temp[63:32];
            end

            ALU_MULHU: begin
                temp = {32'b0, rs1_val} * {32'b0, rs2_val};
                result = temp[63:32];
            end
            default: begin
                result = '0;
            end
        endcase
    end
endmodule

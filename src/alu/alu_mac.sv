`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_mac(
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val, 
    input logic [31:0] rd_old_val, 
    input alu_op_e alu_op,
    output logic [31:0] result
);
    logic [63:0] temp;
    always_comb begin
        case(alu_op)
            ALU_MAC: begin
                temp = rs1_val * rs2_val;
                result = temp[31:0] + rd_old_val;
            end 
            default: result = '0;
        endcase
    end
endmodule

`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_mac(
    input logic [31:0] a,
    input logic [31:0] b, 
    input logic [31:0] c, 
    input alu_op_e alu_op,
    output logic [31:0] result
);
    logic [63:0] temp;
    always_comb begin
        case(alu_op)
            ALU_MAC: begin
                temp = a*b;
                result = temp[31:0] + c;
            end 
            default: result = '0;
        endcase
    end
endmodule

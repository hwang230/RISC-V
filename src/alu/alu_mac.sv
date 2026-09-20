`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_mac #(
    parameter int unsigned DATA_WIDTH = 32
)(
    input logic [DATA_WIDTH-1:0] rs1_val,
    input logic [DATA_WIDTH-1:0] rs2_val,
    input logic [DATA_WIDTH-1:0] rd_old_val,
    input alu_op_e alu_op,
    output logic [DATA_WIDTH-1:0] result
);
    logic [2*DATA_WIDTH-1:0] temp;

    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "alu_mac DATA_WIDTH must be positive");
    end

    always_comb begin
        temp = '0;
        case(alu_op)
            ALU_MAC: begin
                temp = {{DATA_WIDTH{1'b0}}, rs1_val} *
                       {{DATA_WIDTH{1'b0}}, rs2_val};
                result = temp[DATA_WIDTH-1:0] + rd_old_val;
            end 
            default: result = '0;
        endcase
    end
endmodule

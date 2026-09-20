`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_multiply #(
    parameter int unsigned DATA_WIDTH = 32
)(
    input alu_op_e alu_op,
    input logic [DATA_WIDTH-1:0] rs1_val,
    input logic [DATA_WIDTH-1:0] rs2_val,

    output logic [DATA_WIDTH-1:0] result
);
    logic [2*DATA_WIDTH-1:0] temp;

    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "alu_multiply DATA_WIDTH must be positive");
    end

    always_comb begin
        temp = '0;
        result = '0;
        case(alu_op)
            ALU_MUL: begin
                temp = {{DATA_WIDTH{1'b0}}, rs1_val} *
                       {{DATA_WIDTH{1'b0}}, rs2_val};
                result = temp[DATA_WIDTH-1:0];
            end

            ALU_MULH: begin
                temp = $signed({{DATA_WIDTH{rs1_val[DATA_WIDTH-1]}}, rs1_val}) *
                       $signed({{DATA_WIDTH{rs2_val[DATA_WIDTH-1]}}, rs2_val});
                result = temp[2*DATA_WIDTH-1:DATA_WIDTH];
            end

            ALU_MULHSU: begin
                temp = $signed({{DATA_WIDTH{rs1_val[DATA_WIDTH-1]}}, rs1_val}) *
                       $signed({{DATA_WIDTH{1'b0}}, rs2_val});
                result = temp[2*DATA_WIDTH-1:DATA_WIDTH];
            end

            ALU_MULHU: begin
                temp = {{DATA_WIDTH{1'b0}}, rs1_val} *
                       {{DATA_WIDTH{1'b0}}, rs2_val};
                result = temp[2*DATA_WIDTH-1:DATA_WIDTH];
            end
            default: begin
                result = '0;
            end
        endcase
    end
endmodule

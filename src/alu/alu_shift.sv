`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_shift #(
    parameter int unsigned DATA_WIDTH = 32
)(
    input alu_op_e alu_op,
    input logic [DATA_WIDTH-1:0] rs1_val,
    input logic [DATA_WIDTH-1:0] rs2_val,
    output logic [DATA_WIDTH-1:0] result
);
    localparam int unsigned SHAMT_WIDTH = (DATA_WIDTH > 1) ? $clog2(DATA_WIDTH) : 1;

    initial begin
        if (DATA_WIDTH < 2 || (DATA_WIDTH & (DATA_WIDTH - 1)) != 0)
            $fatal(1, "alu_shift DATA_WIDTH must be a power of two and at least 2");
    end

    always_comb begin
        case(alu_op)
            ALU_SLL: result = rs1_val << rs2_val[SHAMT_WIDTH-1:0];
            ALU_SRL: result = rs1_val >> rs2_val[SHAMT_WIDTH-1:0];
            ALU_SRA: result = $signed(rs1_val) >>> rs2_val[SHAMT_WIDTH-1:0];
            default: result = '0;
        endcase
    end
endmodule

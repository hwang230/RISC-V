`include "../cpu_pkg.sv"
import cpu_pkg::*;

module alu_div #(
    parameter int unsigned DATA_WIDTH = 32
)(
    input alu_op_e alu_op,
    input logic [DATA_WIDTH-1:0] rs1_val,
    input logic [DATA_WIDTH-1:0] rs2_val,
    output logic [DATA_WIDTH-1:0] result
);
    localparam logic [DATA_WIDTH-1:0] SIGNED_MIN = {1'b1, {(DATA_WIDTH-1){1'b0}}};
    localparam logic [DATA_WIDTH-1:0] ALL_ONES = '1;

    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "alu_div DATA_WIDTH must be positive");
    end

    always_comb begin
        // handle division by zero according to RISC-V rules
        case (alu_op)
            ALU_DIV: begin
                if (rs2_val == '0)
                    result = ALL_ONES;
                else if ((rs1_val == SIGNED_MIN) && (rs2_val == ALL_ONES))
                    result = SIGNED_MIN;
                else
                    result = $signed(rs1_val) / $signed(rs2_val);
            end

            ALU_DIVU: begin
                if (rs2_val == '0)
                    result = ALL_ONES;
                else
                    result = rs1_val / rs2_val;
            end

            ALU_REM: begin
                if (rs2_val == '0)
                    result = rs1_val;
                else if ((rs1_val == SIGNED_MIN) && (rs2_val == ALL_ONES))
                    result = '0;
                else
                    result = $signed(rs1_val) % $signed(rs2_val);
            end

            ALU_REMU: begin
                if (rs2_val == '0)
                    result = rs1_val;
                else
                    result = rs1_val % rs2_val;
            end

            default: result = '0;
        endcase
    end
endmodule

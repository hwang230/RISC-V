module alu_div(
    input logic [4:0] alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,
    output logic [31:0] result
);
    localparam logic [4:0] ALU_DIV  = 5'b10100;
    localparam logic [4:0] ALU_DIVU = 5'b10101;
    localparam logic [4:0] ALU_REM  = 5'b10110;

    always_comb begin
        // handle division by zero according to RISC-V rules
        case (alu_op)
            ALU_DIV: begin
                if (rs2_val == '0)
                    result = 32'hFFFF_FFFF;
                else if ((rs1_val == 32'h8000_0000) && (rs2_val == 32'hFFFF_FFFF))
                    result = 32'h8000_0000;
                else
                    result = $signed(rs1_val) / $signed(rs2_val);
            end

            ALU_DIVU: begin
                if (rs2_val == '0)
                    result = 32'hFFFF_FFFF;
                else
                    result = rs1_val / rs2_val;
            end

            ALU_REM: begin
                if (rs2_val == '0)
                    result = rs1_val;
                else if ((rs1_val == 32'h8000_0000) && (rs2_val == 32'hFFFF_FFFF))
                    result = 32'h0000_0000;
                else
                    result = $signed(rs1_val) % $signed(rs2_val);
            end

            default: result = '0;
        endcase
    end
endmodule

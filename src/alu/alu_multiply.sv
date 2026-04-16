module alu_multiply(
    input logic [4:0] alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,

    output logic [31:0] result
);
    logic [63:0] temp;
    localparam logic [4:0] ALU_MUL = 5'b10000;
    localparam logic [4:0] ALU_MULH = 5'b10001;
    localparam logic [4:0] ALU_MULHU = 5'b10011;
    always_comb begin
        case(alu_op) 
            ALU_MUL: begin
                temp = rs1_val * rs2_val;
                result = temp[31:0];
            end

            ALU_MULH: begin
                temp = $signed(rs1_val) * $signed(rs2_val);
                result = temp[63:32];
            end

            ALU_MULHU: begin
                temp = rs1_val * rs2_val;
                result = temp[63:32];
            end
            default: result = '0;
        endcase
    end
endmodule
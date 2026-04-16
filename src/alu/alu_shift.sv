module alu_shift(
    input logic [4:0] alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,
    output logic [31:0] result
);
    localparam logic [4:0] ALU_SLL = 5'b00101;
    localparam logic [4:0] ALU_SRL = 5'b00110;
    localparam logic [4:0] ALU_SRA = 5'b00111;

    always_comb begin
        case(alu_op)
            ALU_SLL: result = rs1_val << rs2_val[4:0];
            ALU_SRL: result = rs1_val >> rs2_val[4:0];
            ALU_SRA: result = $signed(rs1_val) >>> rs2_val[4:0];
            default: result = '0;
        endcase
    end
endmodule
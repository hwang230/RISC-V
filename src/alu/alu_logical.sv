module alu_logical(
    input logic [4:0] alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,

    output logic [31:0] result
);
    localparam logic [4:0] ALU_AND = 5'b00010;
    localparam logic [4:0] ALU_OR = 5'b00011;
    localparam logic [4:0] ALU_XOR = 5'b00100;

    always_comb begin
        case(alu_op)
            ALU_AND: result = rs1_val & rs2_val;
            ALU_OR: result = rs1_val | rs2_val;
            ALU_XOR: result = rs1_val ^ rs2_val;
            default: result = '0;
        endcase
    end
endmodule
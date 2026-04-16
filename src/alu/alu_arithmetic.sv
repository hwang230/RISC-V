module alu_arithmetic(
    input logic [31:0] rs1_val, 
    input logic [31:0] rs2_val, 
    input logic [4:0] alu_op, 
    output logic [31:0] result
);
    localparam logic [4:0] ALU_ADD = 5'b00000;
    localparam logic [4:0] ALU_SUB = 5'b00001;

    always_comb begin
        case(alu_op)
            ALU_ADD: result = rs1_val + rs2_val;
            ALU_SUB: result = rs1_val - rs2_val;
            default: result = '0;
        endcase
    end
endmodule

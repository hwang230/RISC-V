module alu_branch(
    input logic [4:0] alu_op,
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,
    output logic [31:0] result
);
    localparam logic [4:0] ALU_SLT = 5'b01000;
    localparam logic [4:0] ALU_SLTU = 5'b01001;
    localparam logic [4:0] ALU_BEQ = 5'b01010;
    localparam logic [4:0] ALU_BNE = 5'b01011;
    localparam logic [4:0] ALU_BLT = 5'b01100;
    localparam logic [4:0] ALU_BGE = 5'b01101;
    localparam logic [4:0] ALU_BLTU = 5'b01110;
    localparam logic [4:0] ALU_BGEU = 5'b01111;

    logic temp;
    always_comb begin
        case (alu_op)
            ALU_BEQ:            temp = (rs1_val == rs2_val);
            ALU_BNE:            temp = (rs1_val != rs2_val);
            ALU_BLT, ALU_SLT:   temp = ($signed(rs1_val) < $signed(rs2_val));
            ALU_BGE:            temp = ($signed(rs1_val) >= $signed(rs2_val));
            ALU_BLTU, ALU_SLTU: temp = (rs1_val < rs2_val);
            ALU_BGEU:           temp = (rs1_val >= rs2_val);
            default:            temp = 1'b0;
        endcase
        result = {31'b0, temp};
    end
    
endmodule

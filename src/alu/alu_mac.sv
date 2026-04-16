module alu_mac(
    input logic [31:0] a,
    input logic [31:0] b, 
    input logic [31:0] c, 
    input logic [4:0] alu_op,
    output logic [31:0] result
);
    localparam logic [4:0] ALU_MAC = 5'b11000;
    logic [63:0] temp;
    always_comb begin
        case(alu_op)
            ALU_MAC: begin
                temp = a*b;
                result = temp[31:0] + c;
            end 
            default: result = '0;
        endcase
    end
endmodule
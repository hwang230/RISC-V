module regfile(
    input logic clk,
    input logic we,
    input logic [4:0] rs1_addr,
    input logic [4:0] rs2_addr,
    input logic [4:0] rd_addr, 
    input logic [31:0] rd_data,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data
);
    // ignore x0 here
    logic [31:0] regs [31:1]
    assign rs1_data = (rs1_addr == 5'b0) ? 32'b0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'b0) ? 32'b0 : regs[rs2_addr];

    always_ff @(posedge clk) begin
        if (we && rd_addr != 5'b0) begin
            regs[rd_addr] <= rd_data;
        end

    end
endmodule
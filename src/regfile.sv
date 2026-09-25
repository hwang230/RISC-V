module regfile #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 5
)(
    input logic clk,
    input logic we,
    input logic  [ADDR_WIDTH-1:0] rs1_addr,
    input logic  [ADDR_WIDTH-1:0] rs2_addr,
    input logic  [ADDR_WIDTH-1:0] rd_old_addr,
    input logic  [ADDR_WIDTH-1:0] rd_addr, 
    input logic  [DATA_WIDTH-1:0] rd_data,
    output logic [DATA_WIDTH-1:0] rs1_data,
    output logic [DATA_WIDTH-1:0] rs2_data,
    output logic [DATA_WIDTH-1:0] rd_old_data
);
    localparam int NUM_REGS = 1 << ADDR_WIDTH;
    // ignore x0 here
    logic [DATA_WIDTH-1:0] regs [1:NUM_REGS-1];
    assign rs1_data = (rs1_addr == '0) ? '0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == '0) ? '0 : regs[rs2_addr];
    assign rd_old_data = (rd_old_addr == '0) ? '0 : regs[rd_old_addr];

    always_ff @(posedge clk) begin
        if (we && rd_addr != '0) begin
            regs[rd_addr] <= rd_data;
        end
    end

endmodule

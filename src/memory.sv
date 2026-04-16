`include "axi_interface.sv"

module memory #(
    parameter int MEM_DEPTH = 1024, 
    parameter int DATA_WIDTH = 32, 
    parameter int MEMORY_DELAY = 5, 
    parameter int ADDR_WIDTH = $clog2(MEM_DEPTH),
    parameter int MAX_MEM_SIZE = MEM_DEPTH * DATA_WIDTH/8
) (
    axi_lite_if.slave bus
);
    logic [31:0] mem [0:MEM_DEPTH-1]; // representing the storage 
    logic [ADDR_WIDTH-1:0] wr_idx;
    logic [ADDR_WIDTH-1:0] rd_idx;

    assign wr_idx = bus.awaddr[ADDR_WIDTH+1:2];
    assign rd_idx = bus.araddr[ADDR_WIDTH+1:2];

    always_ff @(posedge bus.clk) begin
        // synchronous reset
        if (bus.rst_n) begin
            bus.bresp  <= 2'b00;
            bus.bvalid <= 1'b0;
            bus.rdata  <= '0;
            bus.rvalid <= 1'b0;
        end else begin
            // store operation
            if (bus.awvalid && bus.awready && bus.wvalid && bus.wready) begin
                // select where to store the data based on wstrb signal
                if (bus.awaddr < MAX_MEM_SIZE) begin
                    bus.bresp <= 2'b00;
                    case (bus.wstrb)
                        4'b0001: mem[wr_idx][7:0] <= bus.wdata[7:0];
                        4'b0010: mem[wr_idx][15:8]  <= bus.wdata[15:8];
                        4'b0100: mem[wr_idx][23:16] <= bus.wdata[23:16];
                        4'b1000: mem[wr_idx][31:24] <= bus.wdata[31:24];
                        4'b0011: mem[wr_idx][15:0] <= bus.wdata[15:0];
                        4'b1100: mem[wr_idx][31:16] <= bus.wdata[31:16];
                        4'b1111: mem[wr_idx] <= bus.wdata;
                    endcase
                end else begin
                    bus.bresp <= 2'b10;
                end
                bus.bvalid <= 1'b1;
            end
            // load operation
            if (bus.arvalid && bus.arready) begin
                bus.rdata <= mem[rd_idx];
            end
        end
    end
endmodule

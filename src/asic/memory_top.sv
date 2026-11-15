// Synthesis wrapper for a compact cache hierarchy experiment. The functional
// memory_system remains the source of truth; only its capacity parameters are
// selected here for this Nangate45 flop-mapped run.
module asic_memory_top (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         i_read,
    input  logic [31:0]  i_addr,
    output logic [31:0]  i_data,
    output logic         i_waitrequest,
    input  logic         d_read,
    input  logic         d_write,
    input  logic [31:0]  d_addr,
    input  logic [31:0]  d_wdata,
    input  logic [3:0]   d_wstrb,
    output logic [31:0]  d_rdata,
    output logic         d_waitrequest
);
    memory_system #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(32),
        .L1_CACHE_SIZE(4096),
        .L2_CACHE_SIZE(16384),
        .L1_NUM_WAYS(4),
        .L2_NUM_WAYS(4),
        .L1_LATENCY(1),
        .L2_LATENCY(5),
        .DRAM_LATENCY(80),
        .DRAM_SIZE(1048576)
    ) u_memory_system (
        .clk(clk),
        .rst_n(rst_n),
        .i_read(i_read),
        .i_addr(i_addr),
        .i_data(i_data),
        .i_waitrequest(i_waitrequest),
        .d_read(d_read),
        .d_write(d_write),
        .d_addr(d_addr),
        .d_wdata(d_wdata),
        .d_wstrb(d_wstrb),
        .d_rdata(d_rdata),
        .d_waitrequest(d_waitrequest)
    );
endmodule

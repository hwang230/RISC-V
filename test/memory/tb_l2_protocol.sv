`timescale 1ns/1ps
module tb_l2_protocol #(
    parameter int CACHE_SIZE = 256 * 1024,
    parameter int L2_LATENCY = 3,
    parameter int DRAM_LATENCY = 4
);
    tb_l2 #(.USE_REAL_DRAM(0), .CACHE_SIZE(CACHE_SIZE),
            .L2_LATENCY(L2_LATENCY), .DRAM_LATENCY(DRAM_LATENCY)) testbench();
endmodule

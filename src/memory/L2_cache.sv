`include "axi_interface.sv"
// write-through to DRAM
module l2_cache #(
    // cache parameters
    parameter CACHE_SIZE = 256*1024, //256 kB
    parameter LINE_SIZE  = 64,
    parameter NUM_WAYS   = 4,
    parameter ADDR_WIDTH = 32
)(
    input logic clk, 
    input logic rst_n, 
    axi_lite_if.slave axi_slave,
    axi_lite_if.master axi_master
);  
    // internal signal
    logic busy; // 1 = occupied / 0 = free 
    logic owner; // 1/0 -> l1i/l1d
    
    // ACTUAL STORAGE AND METADATA
    localparam NUM_SETS = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam INDEX_BITS = $clog2(NUM_SETS);
    localparam OFFSET_BITS = $clog2(LINE_SIZE);
    localparam TAG_BITS = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    logic [LINE_SIZE*8-1:0] data_array  [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic [TAG_BITS-1:0]    tag_array   [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic                   valid_array [0:NUM_SETS-1][0:NUM_WAYS-1];

    // l2d logic

endmodule
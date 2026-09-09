`include "axi_interface.sv"
`include "l1_cache_if.sv"

// write-back on dirty
module l1d_cache #(
    // cache parameters
    parameter CACHE_SIZE = 64*1024, //64kB
    parameter LINE_SIZE  = 64,
    parameter NUM_WAYS   = 4,
    parameter ADDR_WIDTH = 32
)(
    input logic clk, 
    input logic rst_n, 
    l1_cache_if.l1d, 
    axi_lite_if.master axi

); 
    // internal signal
    localparam NUM_SETS = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam INDEX_BITS = $clog2(NUM_SETS);
    localparam OFFSET_BITS = $clog2(LINE_SIZE);
    localparam TAG_BITS = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    
    // ACTUAL STORAGE AND METADATA
    logic [LINE_SIZE*8-1:0] data_array  [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic [TAG_BITS-1:0]    tag_array   [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic                   valid_array [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic                   dirty_array [0:NUM_SETS-1][0:NUM_WAYS-1];

    // l1d logic

endmodule


module l1i_cache #(
     // cache parameters
    parameter CACHE_SIZE = 64*1024, // 64kB
    parameter LINE_SIZE  = 64,
    parameter NUM_WAYS   = 4,
    parameter ADDR_WIDTH = 32
)(
    input logic clk, 
    input logic rst_n,
    l1_cache_if.l1i, 
    axi_lite_if.master axi
); 
    // internal signal
    localparam NUM_SETS = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam INDEX_BITS = $clog2(NUM_SETS);
    localparam OFFSET_BITS = $clog2(LINE_SIZE);
    localparam TAG_BITS = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

    // ACTUAL STORAGE AND METADATA
    logic [LINE_SIZE*8-1:0] data_array  [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic [TAG_BITS-1:0]    tag_array   [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic                   valid_array [0:NUM_SETS-1][0:NUM_WAYS-1];

    // l1i logic

endmodule
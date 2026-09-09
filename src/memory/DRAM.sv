`include "axi_interface.sv"

module DRAM #(
    // cache parameters
    // direct-mapped
    parameter MEM_SIZE = 1024*1024, // 1MB
    parameter LINE_SIZE  = 64,
    parameter ADDR_WIDTH = 32
)(
    input logic clk, 
    input logic rst_n, 
    axi_lite_if.slave axi
); 
    // internal signal
    // ACTUAL STORAGE AND METADATA
    localparam NUM_WORDS = MEM_SIZE / (DATA_WIDTH / 8);
    logic [DATA_WIDTH-1:0] memory [0:NUM_WORDS-1];

    // DRAM logic 

endmodule
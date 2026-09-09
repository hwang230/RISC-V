`include "axi_interface.sv"
`include "l1_cache_if.sv"

module l1d_cache(
    input logic clk, 
    input logic rst_n, 
    l1_cache_if.l1d, 
    axi_lite_if.master axi

); 
    // internal signal
    
    // l1d logic
endmodule


module l1i_cache(
    input logic clk, 
    input logic rst_n,
    l1_cache_if.l1i, 
    axi_lite_if.master axi
); 
    // internal signal

    // l1i logic
endmodule
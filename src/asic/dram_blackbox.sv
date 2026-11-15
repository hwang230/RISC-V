// Flattened external DRAM boundary for synthesis of the cache hierarchy. The
// behavioral array in memory/DRAM.sv remains the simulation model and is not
// synthesized. The pin list mirrors axi_lite_if.master/slave.
(* blackbox *)
module DRAM_MACRO #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32
)(
    input logic clk,
    input logic rst_n,
    input  logic [ADDR_WIDTH-1:0] awaddr,
    input  logic                  awvalid,
    output logic                  awready,
    input  logic [DATA_WIDTH-1:0] wdata,
    input  logic                  wvalid,
    input  logic [DATA_WIDTH/8-1:0] wstrb,
    output logic                  wready,
    output logic [1:0]            bresp,
    output logic                  bvalid,
    input  logic                  bready,
    input  logic [ADDR_WIDTH-1:0] araddr,
    input  logic                  arvalid,
    output logic                  arready,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic                  rvalid,
    input  logic                  rready
);
endmodule

`include "axi_interface.sv"
`include "L1_cache_interface.sv"
`include "L1I_cache.sv"
`include "L1D_cache.sv"
`include "L2_cache.sv"
`ifndef ASIC_MEMORY_SYNTH
`include "DRAM.sv"
`endif

// CPU-facing memory hierarchy: L1I and L1D share one L2 and one DRAM.
module memory_system #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer LINE_SIZE = 64,
    // NUM_WAYS remains as a compatibility shorthand for equal associativity.
    parameter integer NUM_WAYS = 4,
    parameter integer L1_NUM_WAYS = NUM_WAYS,
    parameter integer L2_NUM_WAYS = NUM_WAYS,
    parameter integer L1_CACHE_SIZE = 64 * 1024,
    parameter integer L2_CACHE_SIZE = 256 * 1024,
    parameter integer L1_LATENCY = 1,
    parameter integer L2_LATENCY = 5,
    parameter integer DRAM_LATENCY = 80,
    parameter integer DRAM_SIZE = 1024 * 1024
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // Instruction fetch request and response.
    input  logic                  i_read,
    input  logic [ADDR_WIDTH-1:0] i_addr,
    output logic [DATA_WIDTH-1:0] i_data,
    output logic                  i_waitrequest,

    // Data load/store request and response.
    input  logic                  d_read,
    input  logic                  d_write,
    input  logic [ADDR_WIDTH-1:0] d_addr,
    input  logic [DATA_WIDTH-1:0] d_wdata,
    input  logic [DATA_WIDTH/8-1:0] d_wstrb,
    output logic [DATA_WIDTH-1:0] d_rdata,
    output logic                  d_waitrequest
);
    // The memory hierarchy supports RV32 instruction words on wider buses.
    // Cache geometry remains fixed for now; address and bus widths propagate
    // through each interface and hierarchy level.
    initial begin
        if (ADDR_WIDTH < 32)
            $fatal(1, "memory_system ADDR_WIDTH must be at least 32");
        if (DATA_WIDTH < 32 || (DATA_WIDTH % 32) != 0 ||
            (DATA_WIDTH & (DATA_WIDTH - 1)) != 0 || DATA_WIDTH > LINE_SIZE * 8)
            $fatal(1, "memory_system DATA_WIDTH must be a power-of-two multiple of 32 that fits in a cache line");
        if (LINE_SIZE != 64 || L1_NUM_WAYS < 1 ||
            (L1_NUM_WAYS & (L1_NUM_WAYS - 1)) != 0 ||
            L2_NUM_WAYS < 1 || (L2_NUM_WAYS & (L2_NUM_WAYS - 1)) != 0)
            $fatal(1, "memory_system requires 64-byte lines and power-of-two L1/L2 associativity");
    end

    l1_cache_if #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) cpu_if();
    axi_lite_if #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) axi_l1i_to_l2();
    axi_lite_if #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) axi_l1d_to_l2();
    axi_lite_if #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) axi_l2_to_dram();

    // Adapt the explicit CPU ports to the shared L1 interface. The L1
    // instruction and data modports drive separate fields of cpu_if.
    assign cpu_if.i_read = i_read;
    assign cpu_if.iaddr = i_addr;
    assign i_data = cpu_if.instr;
    assign i_waitrequest = cpu_if.i_waitrequest;

    assign cpu_if.d_read = d_read;
    assign cpu_if.d_write = d_write;
    assign cpu_if.daddr = d_addr;
    assign cpu_if.wdata = d_wdata;
    assign cpu_if.wstrb = d_wstrb;
    assign d_rdata = cpu_if.data;
    assign d_waitrequest = cpu_if.d_waitrequest;

    l1i_cache #(
        .CACHE_SIZE(L1_CACHE_SIZE),
        .LINE_SIZE(LINE_SIZE),
        .NUM_WAYS(L1_NUM_WAYS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LATENCY(L1_LATENCY)
    ) l1i (
        .clk(clk),
        .rst_n(rst_n),
        .l1i(cpu_if),
        .axi(axi_l1i_to_l2)
    );

    l1d_cache #(
        .CACHE_SIZE(L1_CACHE_SIZE),
        .LINE_SIZE(LINE_SIZE),
        .NUM_WAYS(L1_NUM_WAYS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LATENCY(L1_LATENCY)
    ) l1d (
        .clk(clk),
        .rst_n(rst_n),
        .l1d(cpu_if),
        .axi(axi_l1d_to_l2)
    );

    l2_cache #(
        .CACHE_SIZE(L2_CACHE_SIZE),
        .LINE_SIZE(LINE_SIZE),
        .NUM_WAYS(L2_NUM_WAYS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LATENCY(L2_LATENCY)
    ) l2 (
        .clk(clk),
        .rst_n(rst_n),
        .axi_slave_i(axi_l1i_to_l2),
        .axi_slave_d(axi_l1d_to_l2),
        .axi_master(axi_l2_to_dram)
    );

`ifdef ASIC_MEMORY_SYNTH
    DRAM_MACRO #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dram (
        .clk(clk),
        .rst_n(rst_n),
        .awaddr(axi_l2_to_dram.awaddr),
        .awvalid(axi_l2_to_dram.awvalid),
        .awready(axi_l2_to_dram.awready),
        .wdata(axi_l2_to_dram.wdata),
        .wvalid(axi_l2_to_dram.wvalid),
        .wready(axi_l2_to_dram.wready),
        .wstrb(axi_l2_to_dram.wstrb),
        .bresp(axi_l2_to_dram.bresp),
        .bvalid(axi_l2_to_dram.bvalid),
        .bready(axi_l2_to_dram.bready),
        .araddr(axi_l2_to_dram.araddr),
        .arvalid(axi_l2_to_dram.arvalid),
        .arready(axi_l2_to_dram.arready),
        .rdata(axi_l2_to_dram.rdata),
        .rvalid(axi_l2_to_dram.rvalid),
        .rready(axi_l2_to_dram.rready)
    );
`else
    DRAM #(
        .MEM_SIZE(DRAM_SIZE),
        .LINE_SIZE(LINE_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .LATENCY(DRAM_LATENCY)
    ) dram (
        .clk(clk),
        .rst_n(rst_n),
        .axi(axi_l2_to_dram)
    );
`endif
endmodule

// Standalone replacement for memory_system, compiled only with CORE_STANDALONE.
// One-cycle responses deliberately disappear after completion, just like L1.
module memory_system #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int LINE_SIZE = 64,
    parameter int NUM_WAYS = 4,
    parameter int L1_CACHE_SIZE = 64 * 1024,
    parameter int L2_CACHE_SIZE = 256 * 1024,
    parameter int L1_LATENCY = 5,
    parameter int L2_LATENCY = 20,
    parameter int DRAM_LATENCY = 100,
    parameter int DRAM_SIZE = 1024 * 1024
)(
    input logic clk, rst_n,
    input logic i_read,
    input logic [31:0] i_addr,
    output logic [31:0] i_data,
    output logic i_waitrequest,
    input logic d_read, d_write,
    input logic [31:0] d_addr, d_wdata,
    input logic [3:0] d_wstrb,
    output logic [31:0] d_rdata,
    output logic d_waitrequest
);
    logic [31:0] memory [0:262143];
    bit manual = 0;
    logic manual_i_wait = 0, manual_d_wait = 0;
    logic [31:0] manual_i_data = 0, manual_d_data = 0;
    int i_delay = 0, d_delay = 0, jitter = 0;
    int i_left = -1, d_left = -1;
    int i_count = 0, d_count = 0;
    logic [31:0] saved_i_addr, saved_d_addr;

    initial begin
        void'($value$plusargs("i_delay=%d", i_delay));
        void'($value$plusargs("d_delay=%d", d_delay));
        void'($value$plusargs("jitter=%d", jitter));
    end

    assign i_waitrequest = manual ? manual_i_wait :
        (i_left > 0) || (i_left < 0 && i_read && i_delay > 0);
    assign d_waitrequest = manual ? manual_d_wait :
        (d_left > 0) || (d_left < 0 && (d_read || d_write) && d_delay > 0);

    always_comb begin
        i_data = 0;
        if (!i_waitrequest && i_read)
            i_data = memory[(i_left == 0 ? saved_i_addr : i_addr) >> 2];
        if (manual) i_data = manual_i_data;
    end

    always_comb begin
        d_rdata = 0;
        if (!d_waitrequest && d_read)
            d_rdata = memory[(d_left == 0 ? saved_d_addr : d_addr) >> 2];
        if (manual) d_rdata = manual_d_data;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            i_left <= -1;
            d_left <= -1;
            i_count <= 0;
            d_count <= 0;
        end else if (!manual) begin
            if (i_read && i_addr >= 32'h100000) $fatal(1, "fetch outside memory");
            if ((d_read || d_write) && d_addr >= 32'h100000) $fatal(1, "data outside memory");
            if (i_left > 0) i_left <= i_left-1;
            else if (i_left == 0) i_left <= -1;
            else if (i_read && i_delay > 0) begin
                saved_i_addr <= i_addr;
                i_left <= i_delay + (jitter != 0 ? i_count % 4 : 0);
                i_count <= i_count+1;
            end
            if (d_left > 0) d_left <= d_left-1;
            else if (d_left == 0) d_left <= -1;
            else if ((d_read || d_write) && d_delay > 0) begin
                saved_d_addr <= d_addr;
                d_left <= d_delay + (jitter != 0 ? d_count % 5 : 0);
                d_count <= d_count+1;
            end
            if (d_write && !d_waitrequest)
                for (int lane=0; lane<4; lane++)
                    if (d_wstrb[lane]) memory[d_addr>>2][8*lane +: 8] <= d_wdata[8*lane +: 8];
        end
    end
endmodule

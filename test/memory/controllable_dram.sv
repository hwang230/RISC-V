`timescale 1ns/1ps

// Blocking, full-word AXI-Lite memory used by the L2 protocol tests.
// Compile after axi_interface.sv; the RTL compilation wrapper supplies it.
//
// Address/data delay N rejects the first N rising edges on which a new VALID
// is presented. The selected delay is latched at that first edge; changing
// a control subsequently only affects a later request. AW and W each have
// their own timer, starting when that channel first presents VALID.
// Response delay N inserts N complete cycles after AR acceptance, or after
// both AW and W have been accepted. A zero-delay response is visible directly
// after that acceptance edge, and can be consumed at the following edge.
//
// memory[] is indexed by word, initialized by the testbench, and preserved on
// reset. WSTRB is deliberately ignored: partial writes are outside the plan.
// ar_count/aw_count/w_count/r_count/b_count count channel handshakes.
// read_count counts accepted reads; write_count counts committed full writes.
// All counters reset with rst_n. No next transaction is accepted until the
// previous response handshake completes.
module controllable_dram #(
    parameter int unsigned MEM_SIZE = 1024 * 1024
) (
    input logic clk,
    input logic rst_n,
    axi_lite_if.slave axi,
    input int unsigned ar_delay,
    input int unsigned r_delay,
    input int unsigned aw_delay,
    input int unsigned w_delay,
    input int unsigned b_delay
);
    localparam int unsigned NUM_WORDS = MEM_SIZE / 4;
    logic [31:0] memory [0:NUM_WORDS-1];

    typedef enum logic [2:0] {
        IDLE, READ_ADDRESS, READ_RESPONSE, WRITE_CAPTURE, WRITE_RESPONSE
    } state_t;
    state_t state;

    logic ar_waiting, aw_waiting, w_waiting;
    logic aw_captured, w_captured;
    logic [31:0] saved_awaddr, saved_wdata, saved_rdata;
    logic read_valid, write_valid;
    int unsigned ar_remaining, aw_remaining, w_remaining;
    int unsigned r_remaining, b_remaining;

    int unsigned ar_count, aw_count, w_count, r_count, b_count;
    int unsigned read_count, write_count;

    logic allow_read_capture, allow_write_capture;
    logic ar_fire, aw_fire, w_fire;

    initial begin
        if (MEM_SIZE == 0 || (MEM_SIZE % 4) != 0)
            $fatal(1, "controllable_dram: MEM_SIZE must be a positive multiple of 4");
    end

    task automatic check_address(input logic [31:0] address);
        if ($isunknown(address) || address[1:0] != 2'b00 ||
            $unsigned(address) >= MEM_SIZE)
            $fatal(1, "controllable_dram: unaligned/out-of-range/unknown address %h", address);
    endtask

    always_comb begin
        // A presented write has priority while idle, including a lone AW or W.
        allow_write_capture = (state == WRITE_CAPTURE) ||
            ((state == IDLE) && (axi.awvalid || axi.wvalid));
        allow_read_capture = (state == READ_ADDRESS) ||
            ((state == IDLE) && !axi.awvalid && !axi.wvalid);

        axi.arready = rst_n && allow_read_capture &&
            (ar_waiting ? (ar_remaining == 0) : (ar_delay == 0));
        axi.awready = rst_n && allow_write_capture && !aw_captured &&
            (aw_waiting ? (aw_remaining == 0) : (aw_delay == 0));
        axi.wready = rst_n && allow_write_capture && !w_captured &&
            (w_waiting ? (w_remaining == 0) : (w_delay == 0));
        axi.rvalid = rst_n && read_valid;
        axi.rdata = saved_rdata;
        axi.bvalid = rst_n && write_valid;
        axi.bresp = 2'b00;

        ar_fire = axi.arvalid && axi.arready;
        aw_fire = axi.awvalid && axi.awready;
        w_fire = axi.wvalid && axi.wready;
    end

    // Use a plain procedural clocked block: memory[] is also preloaded by the
    // testbench, so it intentionally does not have always_ff single ownership.
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            ar_waiting <= 1'b0;
            aw_waiting <= 1'b0;
            w_waiting <= 1'b0;
            aw_captured <= 1'b0;
            w_captured <= 1'b0;
            saved_awaddr <= '0;
            saved_wdata <= '0;
            saved_rdata <= '0;
            read_valid <= 1'b0;
            write_valid <= 1'b0;
            ar_remaining <= 0;
            aw_remaining <= 0;
            w_remaining <= 0;
            r_remaining <= 0;
            b_remaining <= 0;
            ar_count <= 0;
            aw_count <= 0;
            w_count <= 0;
            r_count <= 0;
            b_count <= 0;
            read_count <= 0;
            write_count <= 0;
        end else begin
            if (allow_read_capture) begin
                if (ar_fire) begin
                    check_address(axi.araddr);
                    saved_rdata <= memory[axi.araddr >> 2];
                    ar_count <= ar_count + 1;
                    read_count <= read_count + 1;
                    ar_waiting <= 1'b0;
                    ar_remaining <= 0;
                    r_remaining <= r_delay;
                    read_valid <= (r_delay == 0);
                    state <= READ_RESPONSE;
                end else if (!ar_waiting && axi.arvalid) begin
                    ar_waiting <= 1'b1;
                    ar_remaining <= ar_delay - 1;
                    state <= READ_ADDRESS;
                end else if (ar_waiting && ar_remaining != 0) begin
                    ar_remaining <= ar_remaining - 1;
                end
            end

            if (allow_write_capture) begin
                state <= WRITE_CAPTURE;
                if (aw_fire) begin
                    check_address(axi.awaddr);
                    saved_awaddr <= axi.awaddr;
                    aw_captured <= 1'b1;
                    aw_count <= aw_count + 1;
                end else if (!aw_captured && !aw_waiting && axi.awvalid) begin
                    aw_waiting <= 1'b1;
                    aw_remaining <= aw_delay - 1;
                end else if (aw_waiting && aw_remaining != 0) begin
                    aw_remaining <= aw_remaining - 1;
                end

                if (w_fire) begin
                    saved_wdata <= axi.wdata;
                    w_captured <= 1'b1;
                    w_count <= w_count + 1;
                end else if (!w_captured && !w_waiting && axi.wvalid) begin
                    w_waiting <= 1'b1;
                    w_remaining <= w_delay - 1;
                end else if (w_waiting && w_remaining != 0) begin
                    w_remaining <= w_remaining - 1;
                end

                if ((aw_captured || aw_fire) && (w_captured || w_fire)) begin
                    memory[(aw_fire ? axi.awaddr : saved_awaddr) >> 2] <=
                        w_fire ? axi.wdata : saved_wdata;
                    write_count <= write_count + 1;
                    b_remaining <= b_delay;
                    write_valid <= (b_delay == 0);
                    state <= WRITE_RESPONSE;
                end
            end

            if (state == READ_RESPONSE) begin
                if (read_valid && axi.rready) begin
                    read_valid <= 1'b0;
                    r_count <= r_count + 1;
                    state <= IDLE;
                end else if (!read_valid && r_remaining != 0) begin
                    r_remaining <= r_remaining - 1;
                    if (r_remaining == 1)
                        read_valid <= 1'b1;
                end
            end

            if (state == WRITE_RESPONSE) begin
                if (write_valid && axi.bready) begin
                    write_valid <= 1'b0;
                    b_count <= b_count + 1;
                    aw_captured <= 1'b0;
                    w_captured <= 1'b0;
                    aw_waiting <= 1'b0;
                    w_waiting <= 1'b0;
                    aw_remaining <= 0;
                    w_remaining <= 0;
                    state <= IDLE;
                end else if (!write_valid && b_remaining != 0) begin
                    b_remaining <= b_remaining - 1;
                    if (b_remaining == 1)
                        write_valid <= 1'b1;
                end
            end
        end
    end
endmodule

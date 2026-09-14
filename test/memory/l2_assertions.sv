`timescale 1ns/1ps
// Procedural assertions work with Verilator --assert and event-driven simulators.
// Samples at the same rising edge as the RTL, before nonblocking assignments.
module l2_assertions #(
    parameter int L2_LATENCY = 3
)(
    input logic clk, rst_n,
    axi_lite_if axi_i,
    axi_lite_if axi_d,
    axi_lite_if axi_mem,
    input logic [2:0] state,
    input logic [1:0] owner,
    input logic [3:0] refill_count,
    input logic [31:0] readaddr, writeaddr,
    input logic ar_sent, aw_sent, w_sent
);
    localparam logic [2:0] IDLE=0, READ_MISS=2, READ_RESP=3,
                           WRITE_MISS=5, WRITE_THROUGH=6, WRITE_RESP=7;
    localparam logic [1:0] OWNER_I=1, OWNER_D=2;
    bit prev_valid;
    bit stalled_ar, stalled_aw, stalled_w, stalled_i_r, stalled_d_r, stalled_d_b;
    bit stalled_mem_r, stalled_mem_b;
    logic [31:0] saved_ar, saved_aw, saved_w, saved_i_r, saved_d_r, saved_mem_r;
    logic [2:0] prev_state;
    logic [3:0] prev_refill;
    bit prev_refill_response;
    int unsigned pending_reads, pending_aw, pending_w;
    int unsigned dram_write_responses, l1_write_responses;
    logic [31:0] expected_base;

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_valid = 0;
            stalled_ar = 0; stalled_aw = 0; stalled_w = 0;
            stalled_i_r = 0; stalled_d_r = 0; stalled_d_b = 0;
            stalled_mem_r = 0; stalled_mem_b = 0;
            pending_reads = 0; pending_aw = 0; pending_w = 0;
            dram_write_responses = 0; l1_write_responses = 0;
        end else begin
            assert (int'(refill_count) < 16) else $fatal(1, "refill_count out of range");
            if (axi_i.rvalid)
                assert (state == READ_RESP && owner == OWNER_I && !axi_d.rvalid)
                    else $fatal(1, "instruction response has wrong state/owner");
            if (axi_d.rvalid)
                assert (state == READ_RESP && owner == OWNER_D && !axi_i.rvalid)
                    else $fatal(1, "data response has wrong state/owner");
            if (axi_d.bvalid) begin
                assert (state == WRITE_RESP && owner == OWNER_D)
                    else $fatal(1, "write response has wrong state/owner");
                assert (dram_write_responses > l1_write_responses)
                    else $fatal(1, "L1 write response precedes DRAM completion");
            end

            // AW and W together are one logical write, not two requests.
            assert ((int'(axi_i.arvalid && axi_i.arready) +
                     int'(axi_d.arvalid && axi_d.arready) +
                     int'((axi_d.awvalid && axi_d.awready) ||
                          (axi_d.wvalid && axi_d.wready))) <= 1)
                else $fatal(1, "multiple L1 requests accepted in one cycle");
            if (state != IDLE)
                assert (!axi_i.arready && !axi_d.arready && !axi_d.awready && !axi_d.wready)
                    else $fatal(1, "L2 accepted a request while busy");

            if (stalled_ar)
                assert (axi_mem.arvalid && axi_mem.araddr === saved_ar)
                    else $fatal(1, "AR request changed under backpressure");
            if (stalled_aw)
                assert (axi_mem.awvalid && axi_mem.awaddr === saved_aw)
                    else $fatal(1, "AW request changed under backpressure");
            if (stalled_w)
                assert (axi_mem.wvalid && axi_mem.wdata === saved_w)
                    else $fatal(1, "W request changed under backpressure");
            if (stalled_i_r)
                assert (axi_i.rvalid && axi_i.rdata === saved_i_r)
                    else $fatal(1, "L1I response changed under backpressure");
            if (stalled_d_r)
                assert (axi_d.rvalid && axi_d.rdata === saved_d_r)
                    else $fatal(1, "L1D response changed under backpressure");
            if (stalled_d_b)
                assert (axi_d.bvalid) else $fatal(1, "L1D BVALID dropped before handshake");
            if (stalled_mem_r)
                assert (axi_mem.rvalid && axi_mem.rdata === saved_mem_r)
                    else $fatal(1, "backend read response changed under backpressure");
            if (stalled_mem_b)
                assert (axi_mem.bvalid) else $fatal(1, "backend BVALID dropped before handshake");

            if (axi_mem.arvalid) begin
                expected_base = ((state == WRITE_MISS) ? writeaddr : readaddr) & 32'hffff_ffc0;
                assert ((state == READ_MISS || state == WRITE_MISS) && !ar_sent)
                    else $fatal(1, "refill request in incorrect state or duplicated");
                assert (axi_mem.araddr[1:0] == 0 &&
                        axi_mem.araddr == expected_base + int'(refill_count)*4)
                    else $fatal(1, "incorrect refill address: %08x", axi_mem.araddr);
            end
            if (prev_valid && (prev_state == READ_MISS || prev_state == WRITE_MISS)) begin
                if (!prev_refill_response)
                    assert (refill_count == prev_refill)
                        else $fatal(1, "refill counter advanced without data handshake");
                else
                    assert (refill_count == ((prev_refill == 15) ? 0 : prev_refill+1))
                        else $fatal(1, "refill counter did not advance exactly once");
            end
            if (axi_mem.arvalid && axi_mem.arready) begin
                assert (pending_reads == 0) else $fatal(1, "duplicate outstanding DRAM read");
                pending_reads++;
            end
            if (axi_mem.rvalid && axi_mem.rready) begin
                assert (pending_reads == 1) else $fatal(1, "DRAM response without request");
                pending_reads--;
            end
            if (axi_mem.awvalid) begin
                assert (state == WRITE_THROUGH && !aw_sent)
                    else $fatal(1, "AW repeated after acceptance");
            end
            if (axi_mem.wvalid) begin
                assert (state == WRITE_THROUGH && !w_sent)
                    else $fatal(1, "W repeated after acceptance");
            end
            if (axi_mem.awvalid && axi_mem.awready) begin
                assert (pending_aw == 0) else $fatal(1, "duplicate DRAM AW");
                pending_aw++;
            end
            if (axi_mem.wvalid && axi_mem.wready) begin
                assert (pending_w == 0) else $fatal(1, "duplicate DRAM W");
                pending_w++;
            end
            if (axi_mem.bvalid && axi_mem.bready) begin
                assert (pending_aw == 1 && pending_w == 1)
                    else $fatal(1, "DRAM write response before both AW and W");
                pending_aw = 0; pending_w = 0;
                dram_write_responses++;
            end
            if (axi_d.bvalid && axi_d.bready) l1_write_responses++;

            stalled_ar = axi_mem.arvalid && !axi_mem.arready; saved_ar = axi_mem.araddr;
            stalled_aw = axi_mem.awvalid && !axi_mem.awready; saved_aw = axi_mem.awaddr;
            stalled_w = axi_mem.wvalid && !axi_mem.wready; saved_w = axi_mem.wdata;
            stalled_i_r = axi_i.rvalid && !axi_i.rready; saved_i_r = axi_i.rdata;
            stalled_d_r = axi_d.rvalid && !axi_d.rready; saved_d_r = axi_d.rdata;
            stalled_d_b = axi_d.bvalid && !axi_d.bready;
            stalled_mem_r = axi_mem.rvalid && !axi_mem.rready; saved_mem_r = axi_mem.rdata;
            stalled_mem_b = axi_mem.bvalid && !axi_mem.bready;
            prev_state = state; prev_refill = refill_count;
            prev_refill_response = axi_mem.rvalid && axi_mem.rready;
            prev_valid = 1;
        end
    end
endmodule

`include "cpu_pkg.sv"
import cpu_pkg::*;

module fetch #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
)(
    input logic clk,
    input logic rst_n, 
    input logic stall,

    // to enable jumps
    input logic jump_en,
    input logic [ADDR_WIDTH-1:0] jump_target,

    // CPU-side L1I request/response interface. Keep i_read asserted while
    // i_waitrequest is high; the instruction is returned when it goes low.
    output logic i_read,
    output logic [ADDR_WIDTH-1:0] i_addr,
    input logic [DATA_WIDTH-1:0] i_data,
    input logic i_waitrequest,

    // output what decoder needs -- let decode figure out what goes where
    output logic [31:0] instr, 
    output logic instr_valid,
    // PC associated with the instruction currently held in instr.
    output logic [ADDR_WIDTH-1:0] instr_pc
); 
    localparam int BYTE_OFFSET_BITS = $clog2(DATA_WIDTH / 8);
    localparam int INSTR_LANE_BITS = (DATA_WIDTH > 32) ? $clog2(DATA_WIDTH / 32) : 1;

    logic [ADDR_WIDTH-1:0] pc;
    logic [31:0] fetched_instr;
    logic [INSTR_LANE_BITS-1:0] instr_lane;
    // A redirect can occur while the instruction cache is still returning
    // the sequential fetch. That response belongs to the flushed path.
    logic discard_response;

    initial begin
        if (ADDR_WIDTH < 32)
            $fatal(1, "fetch ADDR_WIDTH must be at least 32");
        if (DATA_WIDTH < 32 || (DATA_WIDTH % 32) != 0 ||
            (DATA_WIDTH & (DATA_WIDTH - 1)) != 0)
            $fatal(1, "fetch DATA_WIDTH must be a power-of-two multiple of 32");
    end

    generate
        if (DATA_WIDTH == 32) begin : gen_single_instruction_lane
            assign fetched_instr = i_data;
        end else begin : gen_multiple_instruction_lanes
            assign instr_lane = pc[BYTE_OFFSET_BITS-1:2];
            assign fetched_instr = i_data[instr_lane * 32 +: 32];
        end
    endgenerate

    assign i_addr = pc;
    // Do not issue or consume an instruction while an older data access
    // stalls the in-order pipeline.
    // Do not request another instruction while the current one is still
    // waiting for decode. This turns instr/instr_valid into a one-entry
    // fetch/decode buffer and prevents stalls from dropping instructions.
    assign i_read = rst_n && !stall && !instr_valid;
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc <= ADDR_WIDTH'(PC_RESET_VEC);
            instr <= '0;
            instr_valid <= 1'b0;
            instr_pc <= '0;
            discard_response <= 1'b0;
        end 

        else begin
            // Hold a valid fetch/decode instruction while an older data
            // access or a load-use hazard stalls the front of the pipeline.
            if (!stall) begin
                // A redirect has priority over the sequential response. The
                // current instruction is younger than the instruction
                // resolving the redirect, so invalidate it and restart from
                // the target.
                if (jump_en) begin
                    pc <= jump_target;
                    instr_valid <= 1'b0;
                    discard_response <= i_waitrequest;
                end

                // Decode consumes the held instruction on this edge.  The
                // next request can be issued after the valid bit clears.
                else if (instr_valid) begin
                    instr_valid <= 1'b0;
                end

                // L1I holds i_waitrequest high until its instruction response
                // is ready. The request address stays stable because PC
                // advances only when that response is consumed.
                else if (!i_waitrequest) begin
                    if (discard_response) begin
                        // Retire the outstanding sequential response without
                        // exposing it to decode. PC already points at target.
                        discard_response <= 1'b0;
                    end else begin
                        instr <= fetched_instr;
                        instr_pc <= pc;
                        instr_valid <= 1'b1;
                        pc <= pc + ADDR_WIDTH'(4);
                    end
                end
            end
        end

    end
endmodule

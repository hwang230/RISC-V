`include "cpu_pkg.sv"
import cpu_pkg::*;

module fetch #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int BHT_ENTRIES = 256,
    parameter int INSTR_QUEUE_DEPTH = 4
)(
    input logic clk,
    input logic rst_n, 
    input logic stall,

    // to enable jumps
    input logic jump_en,
    input logic [ADDR_WIDTH-1:0] jump_target,

    // Branch resolution feedback. The predictor is updated only when a
    // conditional branch advances out of execute.
    input logic branch_update_valid,
    input logic [ADDR_WIDTH-1:0] branch_update_pc,
    input logic branch_update_taken,

    // Decode consumes the queue head on this edge.
    input logic consume,

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
    output logic [ADDR_WIDTH-1:0] instr_pc,
    // Direction predicted when the instruction response was accepted.
    output logic instr_pred_taken
); 
    localparam int BYTE_OFFSET_BITS = $clog2(DATA_WIDTH / 8);
    localparam int INSTR_LANE_BITS = (DATA_WIDTH > 32) ? $clog2(DATA_WIDTH / 32) : 1;
    localparam int BHT_INDEX_BITS = (BHT_ENTRIES > 1) ? $clog2(BHT_ENTRIES) : 1;
    localparam int QUEUE_PTR_BITS = (INSTR_QUEUE_DEPTH > 1) ? $clog2(INSTR_QUEUE_DEPTH) : 1;
    localparam int QUEUE_COUNT_BITS = $clog2(INSTR_QUEUE_DEPTH + 1);

    logic [ADDR_WIDTH-1:0] pc;
    logic [31:0] fetched_instr;
    logic [INSTR_LANE_BITS-1:0] instr_lane;
    logic [31:0] instr_queue [0:INSTR_QUEUE_DEPTH-1];
    logic [ADDR_WIDTH-1:0] pc_queue [0:INSTR_QUEUE_DEPTH-1];
    logic pred_queue [0:INSTR_QUEUE_DEPTH-1];
    logic [QUEUE_PTR_BITS-1:0] queue_head;
    logic [QUEUE_PTR_BITS-1:0] queue_tail;
    logic [QUEUE_COUNT_BITS-1:0] queue_count;
    logic queue_full;
    logic queue_empty;
    logic request_pending;
    logic enqueue_response;
    logic dequeue_instruction;
    logic [1:0] bht [0:BHT_ENTRIES-1];
    logic [BHT_INDEX_BITS-1:0] bht_index;
    logic [BHT_INDEX_BITS-1:0] branch_update_index;
    logic [31:0] branch_imm32;
    logic [ADDR_WIDTH-1:0] branch_imm;
    logic [ADDR_WIDTH-1:0] predicted_target;
    logic fetched_is_branch;
    logic predicted_taken;
    // A redirect can occur while the instruction cache is still returning
    // the sequential fetch. That response belongs to the flushed path.
    logic discard_response;

    initial begin
        if (ADDR_WIDTH < 32)
            $fatal(1, "fetch ADDR_WIDTH must be at least 32");
        if (DATA_WIDTH < 32 || (DATA_WIDTH % 32) != 0 ||
            (DATA_WIDTH & (DATA_WIDTH - 1)) != 0)
            $fatal(1, "fetch DATA_WIDTH must be a power-of-two multiple of 32");
        if (BHT_ENTRIES < 2 || (BHT_ENTRIES & (BHT_ENTRIES - 1)) != 0)
            $fatal(1, "fetch BHT_ENTRIES must be a power of two >= 2");
        if (INSTR_QUEUE_DEPTH < 2 || (INSTR_QUEUE_DEPTH & (INSTR_QUEUE_DEPTH - 1)) != 0)
            $fatal(1, "fetch INSTR_QUEUE_DEPTH must be a power of two >= 2");
    end

    generate
        if (DATA_WIDTH == 32) begin : gen_single_instruction_lane
            assign fetched_instr = i_data;
        end else begin : gen_multiple_instruction_lanes
            assign instr_lane = pc[BYTE_OFFSET_BITS-1:2];
            assign fetched_instr = i_data[instr_lane * 32 +: 32];
        end
    endgenerate

    function automatic logic [QUEUE_PTR_BITS-1:0] next_queue_ptr(
        input logic [QUEUE_PTR_BITS-1:0] current_ptr
    );
        if (current_ptr == QUEUE_PTR_BITS'(INSTR_QUEUE_DEPTH - 1))
            next_queue_ptr = '0;
        else
            next_queue_ptr = current_ptr + 1'b1;
    endfunction

    assign bht_index = pc[BHT_INDEX_BITS+1:2];
    assign branch_update_index = branch_update_pc[BHT_INDEX_BITS+1:2];

    assign queue_empty = (queue_count == '0);
    assign queue_full = (queue_count == QUEUE_COUNT_BITS'(INSTR_QUEUE_DEPTH));
    assign instr_valid = !queue_empty;
    assign instr = queue_empty ? '0 : instr_queue[queue_head];
    assign instr_pc = queue_empty ? '0 : pc_queue[queue_head];
    assign instr_pred_taken = queue_empty ? 1'b0 : pred_queue[queue_head];

    // Keep an issued request asserted until its response is available. A
    // response may be accepted immediately for zero-latency memories, or
    // after request_pending has tracked a delayed transaction.
    assign i_read = rst_n &&
                    (request_pending || (!stall && !queue_full));
    assign enqueue_response = i_read && !i_waitrequest && !discard_response && !jump_en;
    assign dequeue_instruction = consume && !queue_empty && !jump_en;

    // Decode only valid B-type branch encodings in fetch. The branch target
    // is available directly from the instruction, so a BTB is not needed for
    // this direction-only predictor.
    always_comb begin
        branch_imm32 = { {19{fetched_instr[31]}}, fetched_instr[31],
                         fetched_instr[7], fetched_instr[30:25],
                         fetched_instr[11:8], 1'b0 };
        branch_imm = {{(ADDR_WIDTH-32){branch_imm32[31]}}, branch_imm32};
        predicted_target = pc + branch_imm;

        fetched_is_branch = 1'b0;
        if (fetched_instr[6:0] == OP_BRANCH) begin
            case (fetched_instr[14:12])
                3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111:
                    fetched_is_branch = 1'b1;
                default:
                    fetched_is_branch = 1'b0;
            endcase
        end

        predicted_taken = fetched_is_branch && bht[bht_index][1];
    end

    assign i_addr = pc;

    // Separate fixed-index processes keep synchronous initialization portable
    // to Verilator 5.020, whose runtime loops cannot reset unpacked arrays
    // with nonblocking assignments (BLKLOOPINIT).
    for (genvar entry = 0; entry < BHT_ENTRIES; entry++) begin : gen_bht
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                bht[entry] <= 2'b00; // strongly not taken
            end else if (branch_update_valid &&
                         branch_update_index == BHT_INDEX_BITS'(entry)) begin
                if (branch_update_taken) begin
                    if (bht[entry] != 2'b11)
                        bht[entry] <= bht[entry] + 2'b01;
                end else if (bht[entry] != 2'b00) begin
                    bht[entry] <= bht[entry] - 2'b01;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc <= ADDR_WIDTH'(PC_RESET_VEC);
            queue_head <= '0;
            queue_tail <= '0;
            queue_count <= '0;
            request_pending <= 1'b0;
            discard_response <= 1'b0;
        end 

        else begin
            // A redirect has priority over queue movement. All buffered
            // instructions are younger than the resolving control-flow
            // instruction and must be discarded.
            if (jump_en) begin
                pc <= jump_target;
                queue_head <= '0;
                queue_tail <= '0;
                queue_count <= '0;

                // If the cache is still holding the old request, consume its
                // eventual response without exposing it to decode. If the
                // response is already ready, discard it immediately.
                if (i_read && i_waitrequest) begin
                    request_pending <= 1'b1;
                    discard_response <= 1'b1;
                end else begin
                    request_pending <= 1'b0;
                    discard_response <= 1'b0;
                end
            end else begin
                // Track a delayed request. For zero-latency memories, the
                // response is accepted in the same cycle the request is seen.
                if (i_read && i_waitrequest) begin
                    request_pending <= 1'b1;
                end else if (request_pending && !i_waitrequest) begin
                    request_pending <= 1'b0;
                    discard_response <= 1'b0;
                end

                if (enqueue_response) begin
                    instr_queue[queue_tail] <= fetched_instr;
                    pc_queue[queue_tail] <= pc;
                    pred_queue[queue_tail] <= predicted_taken;
                    pc <= predicted_taken ? predicted_target :
                          pc + ADDR_WIDTH'(4);
                    queue_tail <= next_queue_ptr(queue_tail);
                end

                if (dequeue_instruction)
                    queue_head <= next_queue_ptr(queue_head);

                case ({enqueue_response, dequeue_instruction})
                    2'b10: queue_count <= queue_count + 1'b1;
                    2'b01: queue_count <= queue_count - 1'b1;
                    default: begin end
                endcase
            end
        end

    end
endmodule

module tb_fetch #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32
)(output logic done);
    timeunit 1ns;
    timeprecision 1ps;

    localparam integer LANES = DATA_WIDTH / 32;
    localparam integer BUS_BYTES = DATA_WIDTH / 8;
    localparam logic [31:0] TEST_BRANCH = 32'h0000_0463; // beq x0,x0,+8

    logic clk, rst_n;
    logic stall;
    logic jump_en;
    logic [ADDR_WIDTH-1:0] jump_target;
    logic branch_update_valid;
    logic [ADDR_WIDTH-1:0] branch_update_pc;
    logic branch_update_taken;
    logic consume;
    logic i_read;
    logic [ADDR_WIDTH-1:0] i_addr;
    logic [DATA_WIDTH-1:0] i_data;
    logic i_waitrequest;
    logic [31:0] instr;
    logic instr_valid;
    logic [ADDR_WIDTH-1:0] instr_pc;
    logic instr_pred_taken;
    logic [ADDR_WIDTH-1:0] expected_pc;
    logic [31:0] expected_instruction;

    fetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    function automatic logic [DATA_WIDTH-1:0] response_for_pc(
        input logic [ADDR_WIDTH-1:0] byte_addr,
        input logic [31:0] selected_instruction
    );
        logic [DATA_WIDTH-1:0] response;
        integer lane;
        integer lane_index;
        begin
            response = '0;
            for (lane_index = 0; lane_index < LANES; lane_index = lane_index + 1)
                response[lane_index*32 +: 32] = 32'hA500_0000 | lane_index;

            // The memory response is the DATA_WIDTH-aligned word containing
            // byte_addr. Each lane holds one 32-bit RV32 instruction.
            // Only the low address bits participate in a power-of-two bus
            // alignment, so the 32-bit cast preserves the needed modulus.
            lane = (int'(byte_addr) % BUS_BYTES) / 4;
            response[lane*32 +: 32] = selected_instruction;
            response_for_pc = response;
        end
    endfunction

    task automatic check_response(
        input logic [ADDR_WIDTH-1:0] response_pc,
        input logic [31:0] selected_instruction,
        input logic [ADDR_WIDTH-1:0] next_pc
    );
        begin
            i_data = response_for_pc(response_pc, selected_instruction);
            i_waitrequest = 1'b0;
            tick();
            if (instr !== selected_instruction || !instr_valid ||
                instr_pc !== response_pc || i_addr !== next_pc)
                $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: response at %h got instr=%h valid=%b instr_pc=%h next_addr=%h expected instr=%h instr_pc=%h next_addr=%h",
                       ADDR_WIDTH, DATA_WIDTH, response_pc, instr, instr_valid,
                       instr_pc, i_addr, selected_instruction, response_pc, next_pc);

            // Model decode consuming the queue head, then hold the next
            // request until the following response check.
            consume = 1'b1;
            i_waitrequest = 1'b1;
            tick();
            consume = 1'b0;
            if (!i_read || instr_valid)
                $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: queue head did not drain valid=%b addr=%h",
                       ADDR_WIDTH, DATA_WIDTH, instr_valid, i_addr);
        end
    endtask

    task automatic check_branch_response(
        input logic expected_prediction,
        input logic [ADDR_WIDTH-1:0] expected_next_pc
    );
        begin
            i_data = response_for_pc('0, TEST_BRANCH);
            i_waitrequest = 1'b0;
            tick();
            if (instr !== TEST_BRANCH || !instr_valid ||
                instr_pc !== '0 || instr_pred_taken !== expected_prediction ||
                i_addr !== expected_next_pc)
                $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: prediction=%b instr=%h valid=%b instr_pc=%h next_addr=%h expected prediction=%b next_addr=%h",
                       ADDR_WIDTH, DATA_WIDTH, instr_pred_taken, instr, instr_valid,
                       instr_pc, i_addr, expected_prediction, expected_next_pc);
            i_waitrequest = 1'b1;
        end
    endtask

    task automatic resolve_test_branch(input logic actual_taken);
        begin
            // Use the existing redirect input to restart the same test branch
            // after applying one execute-stage outcome update.
            branch_update_valid = 1'b1;
            branch_update_pc = '0;
            branch_update_taken = actual_taken;
            jump_target = '0;
            jump_en = 1'b1;
            i_waitrequest = 1'b0;
            tick();

            branch_update_valid = 1'b0;
            branch_update_taken = 1'b0;
            jump_en = 1'b0;
            i_waitrequest = 1'b1;
            tick();
            if (!i_read || instr_valid || i_addr !== '0)
                $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: predictor test restart failed addr=%h valid=%b",
                       ADDR_WIDTH, DATA_WIDTH, i_addr, instr_valid);
        end
    endtask

    initial begin
        done = 1'b0;
        clk = 1'b0;
        rst_n = 1'b0;
        stall = 1'b0;
        jump_en = 1'b0;
        jump_target = '0;
        branch_update_valid = 1'b0;
        branch_update_pc = '0;
        branch_update_taken = 1'b0;
        consume = 1'b0;
        i_data = '0;
        i_waitrequest = 1'b1;
        expected_pc = '0;

        tick();
        if (i_read || i_addr !== '0 || instr !== 32'd0 || instr_pc !== '0 || instr_valid)
            $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: reset state mismatch", ADDR_WIDTH, DATA_WIDTH);

        rst_n = 1'b1;
        tick();
        tick();
        if (!i_read || i_addr !== expected_pc || instr_valid)
            $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: request/address not held under waitrequest", ADDR_WIDTH, DATA_WIDTH);

        // Exercise the complete two-bit state machine. Reset initializes the
        // entry to strongly not-taken (00), and prediction uses the state MSB.
        check_branch_response(1'b0, ADDR_WIDTH'(4));
        resolve_test_branch(1'b1); // 00 -> 01, still predicts not taken
        check_branch_response(1'b0, ADDR_WIDTH'(4));
        resolve_test_branch(1'b1); // 01 -> 10, now predicts taken
        check_branch_response(1'b1, ADDR_WIDTH'(8));
        resolve_test_branch(1'b1); // 10 -> 11, remains taken
        check_branch_response(1'b1, ADDR_WIDTH'(8));
        resolve_test_branch(1'b0); // 11 -> 10, remains taken
        check_branch_response(1'b1, ADDR_WIDTH'(8));
        resolve_test_branch(1'b0); // 10 -> 01, now predicts not taken
        check_branch_response(1'b0, ADDR_WIDTH'(4));
        resolve_test_branch(1'b0); // 01 -> 00, remains not taken
        check_branch_response(1'b0, ADDR_WIDTH'(4));

        // Reset clears both the fetch buffer and predictor state before the
        // existing width/lane and redirect checks.
        rst_n = 1'b0;
        i_waitrequest = 1'b1;
        tick();
        if (i_read || i_addr !== '0 || instr !== 32'd0 || instr_pc !== '0 || instr_valid)
            $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: predictor reset failed", ADDR_WIDTH, DATA_WIDTH);
        rst_n = 1'b1;
        tick();
        tick();
        if (!i_read || i_addr !== '0 || instr_valid)
            $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: request after predictor reset failed", ADDR_WIDTH, DATA_WIDTH);

        // Walk two complete DATA_WIDTH words. This checks lane zero and every
        // upper instruction lane, as well as normal PC increments.
        for (integer instruction_index = 0;
             instruction_index < 2 * LANES;
             instruction_index = instruction_index + 1) begin
            expected_instruction = 32'h1357_0000 | instruction_index;
            check_response(expected_pc, expected_instruction, expected_pc + 4);
            expected_pc = expected_pc + 4;

            i_waitrequest = 1'b1;
            tick();
            if (!i_read || i_addr !== expected_pc || instr_valid)
                $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: stalled request/address or instr_valid pulse mismatch", ADDR_WIDTH, DATA_WIDTH);
        end

        // Redirect to an upper lane at a high address when ADDR_WIDTH allows
        // it. The sequential response is flushed; the following request must
        // use the full-width target address.
        jump_target = '0;
        for (integer bit_index = 32; bit_index < ADDR_WIDTH; bit_index = bit_index + 1)
            jump_target[bit_index] = (bit_index == 32);
        jump_target[7:0] = 8'(8'h80 + ((LANES - 1) * 4));
        jump_en = 1'b1;
        expected_instruction = 32'h0000_006f;
        i_data = response_for_pc(expected_pc, expected_instruction);
        i_waitrequest = 1'b0;
        tick();
        if (!i_read || instr_valid || i_addr !== jump_target)
            $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: redirect did not flush sequential response",
                   ADDR_WIDTH, DATA_WIDTH);

        jump_en = 1'b0;
        i_waitrequest = 1'b1;
        tick();
        if (!i_read || i_addr !== jump_target || instr_valid)
            $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: redirect address was not held", ADDR_WIDTH, DATA_WIDTH);

        expected_instruction = 32'h00c0_0113;
        check_response(jump_target, expected_instruction, jump_target + 4);

        // Reset with a request pending to verify the PC returns to the reset
        // vector and no stale instruction remains valid.
        rst_n = 1'b0;
        i_waitrequest = 1'b1;
        tick();
        if (i_read || i_addr !== '0 || instr !== 32'd0 || instr_pc !== '0 || instr_valid)
            $fatal(1, "fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d: reset during request failed", ADDR_WIDTH, DATA_WIDTH);

        done = 1'b1;
        $display("PASS: tb_fetch ADDR_WIDTH=%0d DATA_WIDTH=%0d (%0d instruction lanes)",
                 ADDR_WIDTH, DATA_WIDTH, LANES);
    end
endmodule

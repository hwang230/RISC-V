module tb_fetch(output logic done);
    timeunit 1ns;
    timeprecision 1ps;

    logic clk, rst_n;
    logic jump_en;
    logic [31:0] jump_target;
    logic i_read;
    logic [31:0] i_addr;
    logic [31:0] i_data;
    logic i_waitrequest;
    logic [31:0] instr;
    logic instr_valid;

    fetch dut(.*);

    always #5 clk = ~clk;

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    initial begin
        done = 1'b0;
        clk = 1'b0;
        rst_n = 1'b0;
        jump_en = 1'b0;
        jump_target = '0;
        i_data = '0;
        i_waitrequest = 1'b1;

        tick();
        if (i_read || i_addr !== 32'd0 || instr !== 32'd0 || instr_valid)
            $fatal(1, "fetch reset state mismatch");

        // L1I stalls the request until its instruction is ready. Fetch must
        // keep both the request and address stable for the whole stall.
        rst_n = 1'b1;
        tick();
        tick();
        if (!i_read || i_addr !== 32'd0 || instr_valid)
            $fatal(1, "fetch did not hold its request while i_waitrequest was high");

        // The falling waitrequest marks the response cycle for the L1I port.
        i_data = 32'h0050_0093;
        i_waitrequest = 1'b0;
        tick();
        if (!i_read || instr !== 32'h0050_0093 || !instr_valid || i_addr !== 32'd4)
            $fatal(1, "fetch failed to capture the first instruction or increment PC");

        // Keep the next request stalled and check instr_valid is a pulse.
        i_waitrequest = 1'b1;
        tick();
        if (!i_read || instr_valid || i_addr !== 32'd4)
            $fatal(1, "fetch changed address during stall or held instr_valid high");

        // A jump takes effect with the current response, so the next L1I
        // request uses the target address.
        jump_en = 1'b1;
        jump_target = 32'h0000_0080;
        i_data = 32'h0000_8067;
        i_waitrequest = 1'b0;
        tick();
        if (!i_read || instr !== 32'h0000_8067 || !instr_valid ||
            i_addr !== 32'h0000_0080)
            $fatal(1, "fetch failed to apply jump target on response");

        // Reset an in-flight request and verify the interface returns to reset.
        jump_en = 1'b0;
        i_waitrequest = 1'b1;
        rst_n = 1'b0;
        tick();
        if (i_read || i_addr !== 32'd0 || instr !== 32'd0 || instr_valid)
            $fatal(1, "fetch reset failed while request was pending");

        done = 1'b1;
        $display("PASS: tb_fetch (L1I waitrequest stalls, response capture, PC increment, jump, reset)");
    end
endmodule

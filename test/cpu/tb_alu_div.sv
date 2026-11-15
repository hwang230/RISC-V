module tb_alu_div_width #(parameter int unsigned DATA_WIDTH = 32)(output logic done);
    timeunit 1ns;
    timeprecision 1ps;

    localparam int TAG_WIDTH = 8;
    localparam int STREAM_COUNT = 96;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #0.5 clk = ~clk;

    logic req_valid, req_ready, req_signed, req_remainder;
    logic [DATA_WIDTH-1:0] req_dividend, req_divisor;
    logic [TAG_WIDTH-1:0] req_tag;
    logic resp_valid, resp_ready;
    logic [DATA_WIDTH-1:0] resp_result;
    logic [TAG_WIDTH-1:0] resp_tag;
    logic [DATA_WIDTH-1:0] expected [0:STREAM_COUNT-1];
    logic [TAG_WIDTH-1:0] expected_tag [0:STREAM_COUNT-1];
    logic [DATA_WIDTH-1:0] stream_dividend [0:STREAM_COUNT-1];
    logic [DATA_WIDTH-1:0] stream_divisor [0:STREAM_COUNT-1];
    logic stream_signed [0:STREAM_COUNT-1];
    logic stream_remainder [0:STREAM_COUNT-1];

    alu_div #(.DATA_WIDTH(DATA_WIDTH), .TAG_WIDTH(TAG_WIDTH)) dut (.*);

    function automatic logic [DATA_WIDTH-1:0] reference_result(
        input logic [DATA_WIDTH-1:0] dividend,
        input logic [DATA_WIDTH-1:0] divisor,
        input logic signed_mode,
        input logic remainder_mode
    );
        longint signed signed_dividend, signed_divisor, signed_value;
        longint unsigned unsigned_dividend, unsigned_divisor, unsigned_value;
        logic [DATA_WIDTH-1:0] minimum_value;
        minimum_value = {1'b1, {(DATA_WIDTH-1){1'b0}}};
        if (divisor == '0) begin
            reference_result = remainder_mode ? dividend : '1;
        end else if (signed_mode && dividend == minimum_value && divisor == '1) begin
            reference_result = remainder_mode ? '0 : dividend;
        end else if (signed_mode) begin
            signed_dividend = $signed(dividend);
            signed_divisor = $signed(divisor);
            signed_value = remainder_mode ? (signed_dividend % signed_divisor) :
                                             (signed_dividend / signed_divisor);
            reference_result = DATA_WIDTH'(signed_value);
        end else begin
            unsigned_dividend = dividend;
            unsigned_divisor = divisor;
            unsigned_value = remainder_mode ? (unsigned_dividend % unsigned_divisor) :
                                               (unsigned_dividend / unsigned_divisor);
            reference_result = DATA_WIDTH'(unsigned_value);
        end
    endfunction

    task automatic send_and_check(
        input logic [DATA_WIDTH-1:0] dividend,
        input logic [DATA_WIDTH-1:0] divisor,
        input logic signed_mode,
        input logic remainder_mode,
        input logic [TAG_WIDTH-1:0] tag_value
    );
        logic [DATA_WIDTH-1:0] wanted;
        wanted = reference_result(dividend, divisor, signed_mode, remainder_mode);
        @(negedge clk);
        req_valid = 1'b1;
        req_dividend = dividend;
        req_divisor = divisor;
        req_signed = signed_mode;
        req_remainder = remainder_mode;
        req_tag = tag_value;
        do @(posedge clk); while (!req_ready);
        @(negedge clk);
        req_valid = 1'b0;
        while (!resp_valid) @(negedge clk);
        if (resp_result !== wanted || resp_tag !== tag_value)
            $fatal(1, "divider width=%0d a=%h b=%h signed=%b rem=%b got=%h tag=%h expected=%h tag=%h",
                   DATA_WIDTH, dividend, divisor, signed_mode, remainder_mode,
                   resp_result, resp_tag, wanted, tag_value);
        @(posedge clk);
    endtask

    initial begin : run_tests
        int sent, pushed, popped, cycle;
        logic [DATA_WIDTH-1:0] random_a, random_b;
        done = 1'b0;
        req_valid = 1'b0;
        req_dividend = '0;
        req_divisor = '0;
        req_signed = 1'b0;
        req_remainder = 1'b0;
        req_tag = '0;
        resp_ready = 1'b1;
        for (int i = 0; i < STREAM_COUNT; i++) begin
            stream_dividend[i] = DATA_WIDTH'({$urandom, $urandom});
            stream_divisor[i] = DATA_WIDTH'({$urandom, $urandom});
            stream_signed[i] = 1'(i & 1);
            stream_remainder[i] = 1'((i >> 1) & 1);
        end
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        if (DATA_WIDTH == 32) begin
            send_and_check(DATA_WIDTH'(32'd42), DATA_WIDTH'(32'd5), 1'b1, 1'b0, 8'h01);
            send_and_check(DATA_WIDTH'(32'hffff_ffd6), DATA_WIDTH'(32'd5), 1'b1, 1'b0, 8'h02);
            send_and_check(DATA_WIDTH'(32'd42), DATA_WIDTH'(32'hffff_fffb), 1'b1, 1'b0, 8'h03);
            send_and_check(DATA_WIDTH'(32'hffff_ffd6), DATA_WIDTH'(32'hffff_fffb), 1'b1, 1'b0, 8'h04);
            send_and_check(DATA_WIDTH'(32'h1234_5678), DATA_WIDTH'(32'd0), 1'b1, 1'b0, 8'h05);
            send_and_check(DATA_WIDTH'(32'h8000_0000), DATA_WIDTH'(32'hffff_ffff), 1'b1, 1'b0, 8'h06);
            send_and_check(DATA_WIDTH'(32'hffff_ffff), DATA_WIDTH'(32'd2), 1'b0, 1'b0, 8'h07);
            send_and_check(DATA_WIDTH'(32'd43), DATA_WIDTH'(32'd5), 1'b1, 1'b1, 8'h08);
            send_and_check(DATA_WIDTH'(32'hffff_ffd6), DATA_WIDTH'(32'd5), 1'b1, 1'b1, 8'h09);
            send_and_check(DATA_WIDTH'(32'd43), DATA_WIDTH'(32'hffff_fffb), 1'b1, 1'b1, 8'h0a);
            send_and_check(DATA_WIDTH'(32'h8765_4321), DATA_WIDTH'(32'd0), 1'b1, 1'b1, 8'h0b);
            send_and_check(DATA_WIDTH'(32'h8000_0000), DATA_WIDTH'(32'hffff_ffff), 1'b1, 1'b1, 8'h0c);
            send_and_check(DATA_WIDTH'(32'hffff_ffff), DATA_WIDTH'(32'd10), 1'b0, 1'b1, 8'h0d);
        end

        // Sustain one request per cycle. A short response pause checks that
        // backpressure propagates through the elastic pipeline without
        // changing response data or tags.
        sent = 0;
        pushed = 0;
        popped = 0;
        cycle = 0;
        while (popped < STREAM_COUNT) begin
            @(negedge clk);
            req_valid = sent < STREAM_COUNT;
            req_dividend = req_valid ? stream_dividend[sent] : '0;
            req_divisor = req_valid ? stream_divisor[sent] : '0;
            req_signed = req_valid ? stream_signed[sent] : 1'b0;
            req_remainder = req_valid ? stream_remainder[sent] : 1'b0;
            req_tag = TAG_WIDTH'(sent);
            resp_ready = !((cycle >= 48) && (cycle < 54));
            random_a = req_dividend;
            random_b = req_divisor;

            @(posedge clk);
            if (resp_valid && resp_ready) begin
                if (resp_tag !== expected_tag[popped] ||
                    resp_result !== expected[popped])
                    $fatal(1, "divider stream width=%0d response=%0d tag=%h got=%h expected tag=%h value=%h",
                           DATA_WIDTH, popped, resp_tag, resp_result,
                           expected_tag[popped], expected[popped]);
                popped++;
            end
            if (req_valid && req_ready) begin
                expected[pushed] = reference_result(random_a, random_b,
                                                    req_signed, req_remainder);
                expected_tag[pushed] = req_tag;
                pushed++;
                sent++;
            end
            cycle++;
        end
        @(negedge clk);
        req_valid = 1'b0;
        resp_ready = 1'b1;

        // A reset flushes in-flight valid bits, then the unit accepts work again.
        @(negedge clk);
        req_valid = 1'b1;
        req_dividend = DATA_WIDTH'(17);
        req_divisor = DATA_WIDTH'(3);
        req_signed = 1'b0;
        req_remainder = 1'b0;
        req_tag = 8'he1;
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (DATA_WIDTH+1) @(negedge clk);
        if (resp_valid)
            $fatal(1, "divider width=%0d reset failed to flush response", DATA_WIDTH);
        send_and_check(DATA_WIDTH'(22), DATA_WIDTH'(7), 1'b0, 1'b1, 8'he2);

        done = 1'b1;
        $display("PASS: tb_alu_div width=%0d (%0d streamed requests)", DATA_WIDTH, STREAM_COUNT);
    end
endmodule

module tb_alu_div(output logic done);
    logic done2, done8, done32, done64;
    tb_alu_div_width #(.DATA_WIDTH(2)) width2(.done(done2));
    tb_alu_div_width #(.DATA_WIDTH(8)) width8(.done(done8));
    tb_alu_div_width #(.DATA_WIDTH(32)) width32(.done(done32));
    tb_alu_div_width #(.DATA_WIDTH(64)) width64(.done(done64));
    initial begin
        done = 1'b0;
        wait (done2 && done8 && done32 && done64);
        done = 1'b1;
        $display("PASS: tb_alu_div (2/8/32/64-bit pipelined dividers)");
    end
endmodule

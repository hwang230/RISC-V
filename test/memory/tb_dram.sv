`timescale 1ns/1ps

// Standalone coverage for DRAM tests 0-9 plus the memory-range boundary case.
// Compile axi_lite_if and DRAM before this file. The testbench never includes RTL.
// bresp is deliberately not checked: the present DRAM does not drive it.
// Only aligned, full-word accesses are supported; partial writes are out of scope.
module tb_dram #(
    parameter integer DRAM_LATENCY = 4,
    parameter integer MEM_SIZE = 65536
);
    localparam integer NUM_WORDS = MEM_SIZE / 4;
    localparam integer TIMEOUT_CYCLES = DRAM_LATENCY + 128;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    axi_lite_if axi();
    DRAM #(.MEM_SIZE(MEM_SIZE), .LATENCY(DRAM_LATENCY)) dut (
        .clk(clk), .rst_n(rst_n), .axi(axi)
    );

    always #5 clk = ~clk;

    initial begin : optional_waves
        string wave_file;
        if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_dram);
        end
    end

    logic [31:0] reference_memory [0:NUM_WORDS-1];
    integer cycle_count = 0;
    integer ar_count = 0, r_count = 0;
    integer aw_count = 0, w_count = 0, b_count = 0;
    integer tests_passed = 0;
    integer random_transactions = 200;
    integer random_seed = 1;
    logic [31:0] random_state;
    bit read_pending = 0, address_pending = 0, data_pending = 0;
    bit write_pending = 0;
    integer read_cycle = 0, write_cycle = 0;
    logic [31:0] expected_read_data, pending_write_address, pending_write_data;
    bit stalled_ar = 0, stalled_aw = 0, stalled_w = 0;
    bit stalled_r = 0, stalled_b = 0;
    logic [31:0] held_araddr, held_awaddr, held_wdata, held_rdata;
    logic [3:0] held_wstrb;

    function automatic bit address_in_range(input logic [31:0] address);
        return !$isunknown(address) && address[1:0] == 2'b00 && address < MEM_SIZE;
    endfunction

    task automatic check_address(input logic [31:0] address);
        if (!address_in_range(address))
            $fatal(1, "DRAM testbench: invalid address %h", address);
    endtask

    task automatic preload(input logic [31:0] address, input logic [31:0] value);
        check_address(address);
        reference_memory[address >> 2] = value;
        dut.memory[address >> 2] = value;
    endtask

    // An explicit PRNG makes +SEED reproducible across simulators.
    function automatic logic [31:0] next_random();
        random_state = random_state ^ (random_state << 13);
        random_state = random_state ^ (random_state >> 17);
        random_state = random_state ^ (random_state << 5);
        return random_state;
    endfunction

    // Handshakes are sampled before NBA, as the DUT samples them. Checks after
    // #1 see registered state and combinational outputs after that same edge.
    // Thus LATENCY=1 means RVALID/BVALID first rises one edge after acceptance.
    always @(posedge clk) begin : protocol_monitor
        cycle_count = cycle_count + 1;
        if (!rst_n) begin
            ar_count = 0;
            r_count = 0;
            aw_count = 0;
            w_count = 0;
            b_count = 0;
            read_pending = 0;
            address_pending = 0;
            data_pending = 0;
            write_pending = 0;
            stalled_ar = 0;
            stalled_aw = 0;
            stalled_w = 0;
            stalled_r = 0;
            stalled_b = 0;
            #1;
            if (dut.state !== 3'd0 || dut.latency_count !== '0 ||
                dut.aw_received !== 1'b0 || dut.w_received !== 1'b0 ||
                axi.rvalid !== 1'b0 || axi.bvalid !== 1'b0)
                $fatal(1, "DRAM Test 0: reset did not clear state/handshakes/counter");
        end else begin
            if ($isunknown({axi.arready, axi.awready, axi.wready,
                            axi.rvalid, axi.bvalid}))
                $fatal(1, "DRAM unknown handshake signal at cycle %0d", cycle_count);
            if (stalled_ar && (axi.arvalid !== 1'b1 || axi.araddr !== held_araddr))
                $fatal(1, "DRAM AR request changed while stalled");
            if (stalled_aw && (axi.awvalid !== 1'b1 || axi.awaddr !== held_awaddr))
                $fatal(1, "DRAM AW request changed while stalled");
            if (stalled_w && (axi.wvalid !== 1'b1 || axi.wdata !== held_wdata ||
                              axi.wstrb !== held_wstrb))
                $fatal(1, "DRAM W request changed while stalled");
            if (stalled_r && (axi.rvalid !== 1'b1 || axi.rdata !== held_rdata))
                $fatal(1, "DRAM R response changed while stalled");
            if (stalled_b && axi.bvalid !== 1'b1)
                $fatal(1, "DRAM B response disappeared while stalled");

            if (axi.arvalid && axi.arready) begin
                check_address(axi.araddr);
                if (read_pending || address_pending || data_pending || write_pending)
                    $fatal(1, "DRAM accepted a read while another transaction is pending");
                read_pending = 1;
                read_cycle = cycle_count;
                expected_read_data = reference_memory[axi.araddr >> 2];
                ar_count = ar_count + 1;
            end
            if (axi.awvalid && axi.awready) begin
                check_address(axi.awaddr);
                if (address_pending || read_pending || write_pending)
                    $fatal(1, "DRAM duplicated AW or accepted AW while busy");
                address_pending = 1;
                pending_write_address = axi.awaddr;
                aw_count = aw_count + 1;
            end
            if (axi.wvalid && axi.wready) begin
                if (data_pending || read_pending || write_pending)
                    $fatal(1, "DRAM duplicated W or accepted W while busy");
                if (axi.wstrb !== 4'hf || $isunknown(axi.wdata))
                    $fatal(1, "DRAM received an unsupported/unknown write payload");
                data_pending = 1;
                pending_write_data = axi.wdata;
                w_count = w_count + 1;
            end
            if (!write_pending && address_pending && data_pending) begin
                write_pending = 1;
                write_cycle = cycle_count;
            end

            if (axi.rvalid) begin
                if (!read_pending || cycle_count - read_cycle < DRAM_LATENCY)
                    $fatal(1, "DRAM unexpected or early RVALID");
                if (axi.rdata !== expected_read_data)
                    $fatal(1, "DRAM read mismatch: expected %h got %h", expected_read_data, axi.rdata);
                if (axi.rready) begin
                    r_count = r_count + 1;
                    read_pending = 0;
                end
            end
            if (axi.bvalid) begin
                if (!write_pending || cycle_count - write_cycle < DRAM_LATENCY)
                    $fatal(1, "DRAM unexpected or early BVALID; AW and W must precede B");
                if (dut.memory[pending_write_address >> 2] !== pending_write_data)
                    $fatal(1, "DRAM write did not update memory[%h]", pending_write_address);
                if (axi.bready) begin
                    reference_memory[pending_write_address >> 2] = pending_write_data;
                    b_count = b_count + 1;
                    write_pending = 0;
                    address_pending = 0;
                    data_pending = 0;
                end
            end

            stalled_ar = axi.arvalid && !axi.arready;
            stalled_aw = axi.awvalid && !axi.awready;
            stalled_w = axi.wvalid && !axi.wready;
            stalled_r = axi.rvalid && !axi.rready;
            stalled_b = axi.bvalid && !axi.bready;
            held_araddr = axi.araddr;
            held_awaddr = axi.awaddr;
            held_wdata = axi.wdata;
            held_wstrb = axi.wstrb;
            held_rdata = axi.rdata;

            #1;
            if (read_pending) begin
                if (cycle_count - read_cycle < DRAM_LATENCY) begin
                    if (axi.rvalid !== 1'b0)
                        $fatal(1, "DRAM RVALID before configured latency");
                    if (dut.latency_count !== cycle_count - read_cycle)
                        $fatal(1, "DRAM read latency counter mismatch");
                end else if (axi.rvalid !== 1'b1 || axi.rdata !== expected_read_data ||
                             dut.latency_count !== '0)
                    $fatal(1, "DRAM read response/counter incorrect at configured latency %0d", DRAM_LATENCY);
            end else if (axi.rvalid !== 1'b0)
                $fatal(1, "DRAM RVALID without outstanding read");

            if (write_pending) begin
                if (cycle_count - write_cycle < DRAM_LATENCY) begin
                    if (axi.bvalid !== 1'b0)
                        $fatal(1, "DRAM BVALID before configured latency");
                    if (dut.latency_count !== cycle_count - write_cycle)
                        $fatal(1, "DRAM write latency counter mismatch");
                end else if (axi.bvalid !== 1'b1 || dut.latency_count !== '0 ||
                             dut.memory[pending_write_address >> 2] !== pending_write_data)
                    $fatal(1, "DRAM write response/counter incorrect at configured latency %0d", DRAM_LATENCY);
            end else if (axi.bvalid !== 1'b0)
                $fatal(1, "DRAM BVALID without a complete outstanding write");
            if (!read_pending && !write_pending && dut.latency_count !== '0)
                $fatal(1, "DRAM idle/partial-write latency counter must remain zero");
        end
    end

    // Scenario code calls these tasks on falling edges, and both tasks return
    // on falling edges. Consecutive calls can therefore launch the next request
    // immediately after the preceding response, without an idle rising edge.
    task automatic write_word(
        input logic [31:0] address,
        input logic [31:0] value,
        input integer aw_delay = 0,
        input integer w_delay = 0,
        input integer bready_delay = 0
    );
        integer elapsed, before_aw, before_w, before_b;
        bit aw_done, w_done;
        logic [31:0] old_value;
        check_address(address);
        before_aw = aw_count;
        before_w = w_count;
        before_b = b_count;
        old_value = reference_memory[address >> 2];
        aw_done = 0;
        w_done = 0;
        elapsed = 0;
        if (clk !== 1'b0) $fatal(1, "write_word must be called in the falling-edge drive phase");
        axi.awaddr = address;
        axi.wdata = value;
        axi.wstrb = 4'hf;
        axi.awvalid = (aw_delay == 0);
        axi.wvalid = (w_delay == 0);
        axi.bready = 0;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (axi.awvalid && axi.awready) aw_done = 1;
            if (axi.wvalid && axi.wready) w_done = 1;
            @(negedge clk);
            elapsed = elapsed + 1;
            if (elapsed > TIMEOUT_CYCLES)
                $fatal(1, "DRAM write address/data handshake timeout at %h", address);
            if ((!aw_done || !w_done) &&
                (axi.bvalid !== 1'b0 || dut.memory[address >> 2] !== old_value))
                $fatal(1, "DRAM committed a write before both AW and W were accepted");
            axi.awvalid = !aw_done && elapsed >= aw_delay;
            axi.wvalid = !w_done && elapsed >= w_delay;
        end
        elapsed = 0;
        while (axi.bvalid !== 1'b1) begin
            @(negedge clk);
            elapsed = elapsed + 1;
            if (elapsed > TIMEOUT_CYCLES)
                $fatal(1, "DRAM B response timeout at %h", address);
        end
        repeat (bready_delay) begin
            @(negedge clk);
            if (axi.bvalid !== 1'b1)
                $fatal(1, "DRAM Test 8: BVALID dropped while BREADY was low");
        end
        axi.bready = 1;
        @(posedge clk);
        if (axi.bvalid !== 1'b1) $fatal(1, "DRAM write response handshake missing");
        @(negedge clk);
        axi.bready = 0;
        if (aw_count != before_aw + 1 || w_count != before_w + 1 || b_count != before_b + 1)
            $fatal(1, "DRAM write must have exactly one AW, W and B handshake");
        if (reference_memory[address >> 2] !== value || dut.memory[address >> 2] !== value)
            $fatal(1, "DRAM/reference memory mismatch after write at %h", address);
    endtask

    task automatic read_word(
        input logic [31:0] address,
        input integer rready_delay = 0
    );
        integer elapsed, before_ar, before_r;
        bit accepted;
        logic [31:0] expected_value;
        check_address(address);
        expected_value = reference_memory[address >> 2];
        before_ar = ar_count;
        before_r = r_count;
        elapsed = 0;
        accepted = 0;
        if (clk !== 1'b0) $fatal(1, "read_word must be called in the falling-edge drive phase");
        axi.araddr = address;
        axi.arvalid = 1;
        axi.rready = 0;
        while (!accepted) begin
            @(posedge clk);
            accepted = axi.arvalid && axi.arready;
            @(negedge clk);
            elapsed = elapsed + 1;
            if (elapsed > TIMEOUT_CYCLES)
                $fatal(1, "DRAM read address handshake timeout at %h", address);
        end
        axi.arvalid = 0;
        elapsed = 0;
        while (axi.rvalid !== 1'b1) begin
            @(negedge clk);
            elapsed = elapsed + 1;
            if (elapsed > TIMEOUT_CYCLES)
                $fatal(1, "DRAM R response timeout at %h", address);
        end
        if (axi.rdata !== expected_value)
            $fatal(1, "DRAM read %h expected %h got %h", address, expected_value, axi.rdata);
        repeat (rready_delay) begin
            @(negedge clk);
            if (axi.rvalid !== 1'b1 || axi.rdata !== expected_value)
                $fatal(1, "DRAM Test 7: read response changed while RREADY was low");
        end
        axi.rready = 1;
        @(posedge clk);
        if (axi.rvalid !== 1'b1 || axi.rdata !== expected_value)
            $fatal(1, "DRAM read response handshake missing/incorrect");
        @(negedge clk);
        axi.rready = 0;
        if (ar_count != before_ar + 1 || r_count != before_r + 1)
            $fatal(1, "DRAM read must have exactly one AR and R handshake");
    endtask

    task automatic test_pass(input integer test_number, input string description);
        tests_passed = tests_passed + 1;
        $display("DRAM Test %0d PASS: %s", test_number, description);
    endtask

    // Independent watchdog bounds even an accidental unbounded testbench wait.
    initial begin
        #100000000;
        $fatal(1, "tb_dram global watchdog expired");
    end

    initial begin : run_tests
        logic [31:0] addresses [0:4];
        logic [31:0] random_address, random_value, selection;
        integer aw_delay, w_delay, response_delay;
        if (DRAM_LATENCY < 1 || MEM_SIZE < 'h4004 || MEM_SIZE % 4 != 0)
            $fatal(1, "tb_dram requires DRAM_LATENCY >= 1 and word-aligned MEM_SIZE >= 0x4004");
        if (!address_in_range(MEM_SIZE - 4) || address_in_range(MEM_SIZE))
            $fatal(1, "DRAM testbench address-range check does not distinguish the last valid word from the first invalid address");
        if ($value$plusargs("SEED=%d", random_seed)) begin end
        if ($value$plusargs("RANDOM_ITERS=%d", random_transactions)) begin end
        if (random_transactions < 0 || random_transactions > 100000)
            $fatal(1, "RANDOM_ITERS must be in 0..100000");
        random_state = (random_seed == 0) ? 32'h1 : random_seed;
        $display("tb_dram: LATENCY=%0d MEM_SIZE=%0d SEED=%0d RANDOM_ITERS=%0d",
                 DRAM_LATENCY, MEM_SIZE, random_seed, random_transactions);
        axi.awaddr = 0;
        axi.awvalid = 0;
        axi.wdata = 0;
        axi.wvalid = 0;
        axi.wstrb = 4'hf;
        axi.bready = 0;
        axi.araddr = 0;
        axi.arvalid = 0;
        axi.rready = 0;
        for (integer word_index = 0; word_index < NUM_WORDS; word_index = word_index + 1) begin
            reference_memory[word_index] = 32'ha5000000 ^ (32'h9e3779b9 * word_index);
            dut.memory[word_index] = reference_memory[word_index];
        end

        // Test 0: reset state is checked on every reset edge by the monitor.
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        if (dut.state !== 3'd0 || dut.latency_count !== '0 ||
            dut.aw_received !== 1'b0 || dut.w_received !== 1'b0 ||
            ar_count != 0 || aw_count != 0 || w_count != 0 || r_count != 0 || b_count != 0)
            $fatal(1, "DRAM Test 0: unexpected activity following reset");
        test_pass(0, "reset");

        write_word(32'h1000, 32'hdeadbeef);
        test_pass(1, "basic write and physical memory update");

        preload(32'h1000, 32'h12345678);
        read_word(32'h1000);
        test_pass(2, "basic read and exact latency");

        write_word(32'h1000, 32'hdeadbeef);
        read_word(32'h1000);
        test_pass(3, "write then read back");

        addresses[0] = 32'h1000;
        addresses[1] = 32'h1004;
        addresses[2] = 32'h1008;
        addresses[3] = 32'h2000;
        addresses[4] = 32'h4000;
        for (integer i = 0; i < 5; i = i + 1)
            write_word(addresses[i], 32'h10203040 ^ (i * 32'h11111111));
        for (integer i = 4; i >= 0; i = i - 1) read_word(addresses[i]);
        test_pass(4, "multiple addresses retain independent values");

        write_word(32'h1010, 32'haaaabbbb, 0, DRAM_LATENCY + 3);
        read_word(32'h1010);
        test_pass(5, "AW accepted before delayed W");

        write_word(32'h1014, 32'hccccdddd, DRAM_LATENCY + 3, 0);
        read_word(32'h1014);
        test_pass(6, "W accepted before delayed AW");

        read_word(32'h1000, DRAM_LATENCY + 5);
        test_pass(7, "RVALID and RDATA survive RREADY backpressure");

        write_word(32'h1018, 32'h89abcdef, 0, 0, DRAM_LATENCY + 5);
        read_word(32'h1018);
        test_pass(8, "BVALID survives BREADY backpressure");

        for (integer i = 0; i < 16; i = i + 1) begin
            write_word(32'h3000 + i * 4, 32'h01234567 ^ i);
            read_word(32'h3000 + i * 4);
        end
        test_pass(9, "consecutive transactions return correctly to idle");

        write_word(MEM_SIZE - 4, 32'hb0adf00d);
        read_word(MEM_SIZE - 4);
        test_pass(10, "last valid word works and first out-of-range address is rejected by the testbench guard");

        // Random traffic follows all directed tests, with bounded independent
        // AW/W delays and response backpressure against the same scoreboard.
        for (integer i = 0; i < random_transactions; i = i + 1) begin
            random_address = (next_random() % NUM_WORDS) * 4;
            random_value = next_random();
            selection = next_random();
            aw_delay = int'(next_random() % 6);
            w_delay = int'(next_random() % 6);
            response_delay = int'(next_random() % 8);
            if (selection[0]) begin
                write_word(random_address, random_value, aw_delay, w_delay, response_delay);
                read_word(random_address, response_delay);
            end else begin
                read_word(random_address, response_delay);
            end
        end
        repeat (3) @(negedge clk);
        if (tests_passed != 11 || ar_count != r_count || aw_count != w_count ||
            aw_count != b_count || read_pending || write_pending || address_pending || data_pending ||
            axi.rvalid !== 1'b0 || axi.bvalid !== 1'b0 || dut.state !== 3'd0)
            $fatal(1, "tb_dram: transactions lost/duplicated or DUT failed to return to idle");
        for (integer i = 0; i < NUM_WORDS; i = i + 1)
            if (dut.memory[i] !== reference_memory[i])
                $fatal(1, "tb_dram: final memory mismatch at byte address %h", i * 4);
        $display("DRAM coverage: directed=%0d reads=%0d writes=%0d random=%0d",
                 tests_passed, r_count, b_count, random_transactions);
        $display("PASS: tb_dram");
        $finish;
    end
endmodule

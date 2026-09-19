`timescale 1ns/1ps

// Standalone verification of the separate L1I_cache.sv implementation.
// Compile the real l1i_cache, its interfaces, and controllable_dram first.
// This test intentionally targets l1_cache_if.i_read and does not supply a
// replacement interface or silently repair incomplete production RTL.
// A normal CPU request is pulsed across one IDLE rising edge, then deasserted
// on the following falling edge while the cache finishes its latched request.
module tb_l1i #(
    parameter integer L1_CACHE_SIZE = 65536,
    parameter integer L1_LATENCY = 2
);
    localparam integer MEM_SIZE = 1024 * 1024;
    localparam integer NUM_WORDS = MEM_SIZE / 4;
    localparam integer NUM_WAYS = 4;
    localparam integer LINE_SIZE = 64;
    localparam integer WORDS_PER_LINE = 16;
    localparam integer NUM_SETS = L1_CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam integer SET_STRIDE = NUM_SETS * LINE_SIZE;
    localparam longint unsigned REQUEST_TIMEOUT = 64'(L1_LATENCY) + 64'd4096;

    logic clk = 0;
    logic rst_n = 0;
    l1_cache_if cpu();
    axi_lite_if axi();
    int unsigned ar_delay = 0, r_delay = 0;

    l1i_cache #(.CACHE_SIZE(L1_CACHE_SIZE), .LATENCY(L1_LATENCY)) dut (
        .clk(clk), .rst_n(rst_n), .l1i(cpu), .axi(axi)
    );
    controllable_dram #(.MEM_SIZE(MEM_SIZE)) memory_backend (
        .clk(clk), .rst_n(rst_n), .axi(axi),
        .ar_delay(ar_delay), .r_delay(r_delay),
        .aw_delay(0), .w_delay(0), .b_delay(0)
    );

    always #5 clk = ~clk;

    initial begin : optional_waves
        string wave_file;
        if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_l1i);
        end
    end

    logic [31:0] reference_memory [0:NUM_WORDS-1];
    bit reference_valid [0:NUM_SETS-1][0:NUM_WAYS-1];
    integer reference_tag [0:NUM_SETS-1][0:NUM_WAYS-1];
    // Reference replacement uses timestamps, independently of RTL rank updates.
    longint unsigned reference_used [0:NUM_SETS-1][0:NUM_WAYS-1];
    longint unsigned reference_clock = 0;
    longint unsigned cycle_count = 0;
    integer read_requests = 0, read_responses = 0;
    integer fetch_count = 0, hit_count = 0, miss_count = 0;
    integer invalid_allocations = 0, evictions = 0;
    integer ar_stall_cycles = 0, r_delay_cycles = 0;
    integer tests_passed = 0;
    integer random_seed = 1, random_iters = 200;
    logic [31:0] random_state;

    bit active_fetch = 0, active_hit = 0;
    logic [31:0] active_address, active_line;
    integer active_way = 0;
    integer transaction_ar = 0, transaction_r = 0;
    bit response_pending = 0;
    logic [31:0] pending_address;
    bit stalled_ar = 0, stalled_r = 0;
    logic [31:0] held_araddr, held_rdata;
    integer held_refill_count;

    function automatic logic [31:0] initial_word(input integer index);
        return 32'h6a09e667 ^ (32'h9e3779b9 * index) ^ (index << 7);
    endfunction

    function automatic logic [31:0] next_random();
        random_state = random_state ^ (random_state << 13);
        random_state = random_state ^ (random_state >> 17);
        random_state = random_state ^ (random_state << 5);
        return random_state;
    endfunction

    function automatic integer address_set(input logic [31:0] address);
        return int'((address / LINE_SIZE) % NUM_SETS);
    endfunction

    function automatic integer address_tag(input logic [31:0] address);
        return int'(address / SET_STRIDE);
    endfunction

    task automatic check_address(input logic [31:0] address);
        if ($isunknown(address) || address[1:0] != 0 || address >= MEM_SIZE)
            $fatal(1, "tb_l1i: invalid test address %h", address);
    endtask

    task automatic check_set(input integer set_index);
        integer expected_rank, stored_address;
        for (integer way = 0; way < NUM_WAYS; way = way + 1) begin
            if (dut.valid_array[set_index][way] !== reference_valid[set_index][way])
                $fatal(1, "L1I valid mismatch set=%0d way=%0d", set_index, way);
            if (reference_valid[set_index][way]) begin
                if (int'(dut.tag_array[set_index][way]) != reference_tag[set_index][way])
                    $fatal(1, "L1I tag mismatch set=%0d way=%0d", set_index, way);
                expected_rank = 0;
                for (integer other = 0; other < NUM_WAYS; other = other + 1)
                    if (reference_valid[set_index][other] &&
                        reference_used[set_index][other] > reference_used[set_index][way])
                        expected_rank = expected_rank + 1;
                stored_address = (reference_tag[set_index][way] * NUM_SETS + set_index) * LINE_SIZE;
                for (integer word_index = 0; word_index < WORDS_PER_LINE; word_index = word_index + 1)
                    if (dut.data_array[set_index][way][word_index * 32 +: 32] !==
                        reference_memory[(stored_address >> 2) + word_index])
                        $fatal(1, "L1I cache data mismatch set=%0d way=%0d word=%0d",
                               set_index, way, word_index);
            end else begin
                // Unused ways retain their deterministic reset rank.
                expected_rank = way;
            end
            if (int'(dut.lru_rank[set_index][way]) != expected_rank)
                $fatal(1, "L1I LRU mismatch set=%0d way=%0d expected=%0d got=%0d",
                       set_index, way, expected_rank, dut.lru_rank[set_index][way]);
        end
    endtask

    // Drivers only change CPU inputs on falling edges. This monitor samples
    // handshakes on rising edges, before registered DUT/backend updates.
    always @(posedge clk) begin : protocol_monitor
        cycle_count = cycle_count + 1;
        if (!rst_n) begin
            read_requests = 0;
            read_responses = 0;
            response_pending = 0;
            stalled_ar = 0;
            stalled_r = 0;
        end else begin
            if ($isunknown({axi.arvalid, axi.rready, axi.awvalid, axi.wvalid,
                            axi.bready, cpu.i_waitrequest}))
                $fatal(1, "L1I unknown output control signal");
            if (axi.awvalid !== 1'b0 || axi.wvalid !== 1'b0 || axi.bready !== 1'b0)
                $fatal(1, "L1I must never issue writes");
            if (!active_fetch && (axi.arvalid || axi.rready))
                $fatal(1, "L1I generated backend traffic without an active CPU fetch");
            if (stalled_ar && (axi.arvalid !== 1'b1 || axi.araddr !== held_araddr ||
                               int'(dut.refill_count) != held_refill_count))
                $fatal(1, "L1I refill request/address/count changed during AR backpressure");
            if (stalled_r && (axi.rvalid !== 1'b1 || axi.rdata !== held_rdata))
                $fatal(1, "L1I backend read response changed during backpressure");
            if (active_fetch && dut.state != 0 && dut.readaddr !== active_address)
                $fatal(1, "L1I failed to retain the accepted CPU address while busy");
            if (dut.state == 2 && int'(dut.refill_count) >= WORDS_PER_LINE)
                $fatal(1, "L1I refill counter is out of range");

            if (response_pending && !axi.rvalid) begin
                r_delay_cycles = r_delay_cycles + 1;
                if (dut.ar_sent !== 1'b1 || axi.arvalid !== 1'b0 ||
                    int'(dut.refill_count) != transaction_r)
                    $fatal(1, "L1I did not preserve pending read state while waiting for RVALID");
            end
            if (axi.arvalid && !axi.arready)
                ar_stall_cycles = ar_stall_cycles + 1;

            if (axi.arvalid && axi.arready) begin
                if (!active_fetch || active_hit || response_pending || transaction_ar >= WORDS_PER_LINE)
                    $fatal(1, "L1I duplicate or unexpected refill request");
                if (axi.araddr !== active_line + transaction_ar * 4 || axi.araddr[1:0] != 0)
                    $fatal(1, "L1I refill address %h expected %h", axi.araddr,
                           active_line + transaction_ar * 4);
                if (dut.state != 2 || int'(dut.refill_count) != transaction_ar ||
                    int'(dut.miss_way) != active_way || dut.miss_way_selected !== 1'b1)
                    $fatal(1, "L1I refill state/count/victim disagrees with reference model");
                pending_address = axi.araddr;
                response_pending = 1;
                transaction_ar = transaction_ar + 1;
                read_requests = read_requests + 1;
            end
            if (axi.rvalid && axi.rready) begin
                if (!response_pending || !active_fetch || transaction_r >= WORDS_PER_LINE)
                    $fatal(1, "L1I duplicate or unsolicited refill response");
                if (axi.rdata !== reference_memory[pending_address >> 2])
                    $fatal(1, "L1I backend data mismatch at %h", pending_address);
                if (int'(dut.refill_count) != transaction_r)
                    $fatal(1, "L1I refill response was not stored exactly once");
                response_pending = 0;
                transaction_r = transaction_r + 1;
                read_responses = read_responses + 1;
            end
            stalled_ar = axi.arvalid && !axi.arready;
            stalled_r = axi.rvalid && !axi.rready;
            held_araddr = axi.araddr;
            held_rdata = axi.rdata;
            held_refill_count = int'(dut.refill_count);
        end
    end

    task automatic reset_cache;
        @(negedge clk);
        rst_n = 0;
        cpu.i_read = 0;
        cpu.iaddr = 0;
        active_fetch = 0;
        ar_delay = 0;
        r_delay = 0;
        repeat (4) @(negedge clk);
        if (dut.state !== 2'd0 || dut.latency_count !== '0 ||
            dut.refill_count !== '0 || dut.ar_sent !== 1'b0 ||
            dut.miss_way_selected !== 1'b0 || dut.miss_way !== '0 ||
            dut.readaddr !== '0 || dut.readdata !== '0 ||
            axi.arvalid !== 1'b0 || axi.rready !== 1'b0 ||
            axi.awvalid !== 1'b0 || axi.wvalid !== 1'b0 ||
            cpu.i_waitrequest !== 1'b0 || cpu.instr !== '0)
            $fatal(1, "L1I reset did not clear controller/handshake state");
        reference_clock = 0;
        for (integer set_index = 0; set_index < NUM_SETS; set_index = set_index + 1)
            for (integer way = 0; way < NUM_WAYS; way = way + 1) begin
                reference_valid[set_index][way] = 0;
                reference_tag[set_index][way] = 0;
                reference_used[set_index][way] = 0;
                if (dut.valid_array[set_index][way] !== 1'b0 ||
                    int'(dut.lru_rank[set_index][way]) != way)
                    $fatal(1, "L1I reset metadata mismatch set=%0d way=%0d", set_index, way);
            end
        rst_n = 1;
        @(negedge clk);
    endtask

    // expected_hit: -1 lets the independent model decide, 0/1 additionally
    // asserts that the directed test really exercised its intended condition.
    task automatic fetch_word(
        input logic [31:0] address,
        input integer expected_hit = -1,
        input bit disturb_cpu_inputs = 0
    );
        integer set_index, tag_value, way;
        longint unsigned start_cycle, elapsed;
        integer before_ar, before_r;
        bit was_hit, was_invalid;
        check_address(address);
        if (clk !== 1'b0 || active_fetch || dut.state != 0)
            $fatal(1, "L1I driver requires falling-edge idle phase");
        set_index = address_set(address);
        tag_value = address_tag(address);
        way = -1;
        for (integer candidate = 0; candidate < NUM_WAYS; candidate = candidate + 1)
            if (reference_valid[set_index][candidate] && reference_tag[set_index][candidate] == tag_value)
                way = candidate;
        was_hit = (way >= 0);
        if (expected_hit >= 0 && int'(was_hit) != expected_hit)
            $fatal(1, "L1I directed scenario failed to create its intended hit/miss at %h", address);
        if (!was_hit) begin
            for (integer candidate = 0; candidate < NUM_WAYS; candidate = candidate + 1)
                if (way < 0 && !reference_valid[set_index][candidate]) way = candidate;
            if (way < 0) begin
                way = 0;
                for (integer candidate = 1; candidate < NUM_WAYS; candidate = candidate + 1)
                    if (reference_used[set_index][candidate] < reference_used[set_index][way]) way = candidate;
            end
        end
        was_invalid = !reference_valid[set_index][way];
        before_ar = read_requests;
        before_r = read_responses;
        transaction_ar = 0;
        transaction_r = 0;
        active_fetch = 1;
        active_hit = was_hit;
        active_address = address;
        active_line = address & 32'hffffffc0;
        active_way = way;
        cpu.iaddr = address;
        cpu.i_read = 1;
        @(posedge clk);
        @(negedge clk);
        start_cycle = cycle_count;
        if (dut.state !== 2'd1 || dut.readaddr !== address || cpu.i_waitrequest !== 1'b1)
            $fatal(1, "L1I did not latch a fetch into READ_WAIT");
        cpu.i_read = 0;
        while (cpu.i_waitrequest !== 1'b0) begin
            elapsed = cycle_count - start_cycle;
            if (elapsed >= REQUEST_TIMEOUT)
                $fatal(1, "L1I fetch timed out address=%h state=%0d", address, dut.state);
            if (dut.readaddr !== address)
                $fatal(1, "L1I request address changed while busy");
            if (elapsed < L1_LATENCY) begin
                if (dut.state !== 2'd1 || int'(dut.latency_count) != elapsed)
                    $fatal(1, "L1I lookup latency counter/state mismatch at age %0d", elapsed);
            end else if (was_hit)
                $fatal(1, "L1I hit response missed configured latency %0d", L1_LATENCY);
            if (disturb_cpu_inputs) begin
                cpu.iaddr = (address ^ 32'h0003ffc0) & (MEM_SIZE - 4);
                cpu.i_read = (elapsed % 2 == 0);
            end
            @(negedge clk);
        end
        elapsed = cycle_count - start_cycle;
        if (dut.state !== 2'd3 || cpu.instr !== reference_memory[address >> 2])
            $fatal(1, "L1I response mismatch at %h expected=%h got=%h state=%0d",
                   address, reference_memory[address >> 2], cpu.instr, dut.state);
        if (was_hit && elapsed != L1_LATENCY)
            $fatal(1, "L1I hit latency expected=%0d got=%0d", L1_LATENCY, elapsed);
        if (transaction_ar != (was_hit ? 0 : WORDS_PER_LINE) ||
            transaction_r != (was_hit ? 0 : WORDS_PER_LINE) ||
            read_requests - before_ar != transaction_ar || read_responses - before_r != transaction_r)
            $fatal(1, "L1I fetch has incorrect number of backend transactions");
        if (response_pending || memory_backend.ar_count != read_requests ||
            memory_backend.r_count != read_responses)
            $fatal(1, "L1I/backend handshake accounting disagrees");

        reference_clock = reference_clock + 1;
        reference_valid[set_index][way] = 1;
        reference_tag[set_index][way] = tag_value;
        reference_used[set_index][way] = reference_clock;
        check_set(set_index);
        fetch_count = fetch_count + 1;
        if (was_hit) hit_count = hit_count + 1;
        else begin
            miss_count = miss_count + 1;
            if (was_invalid) invalid_allocations = invalid_allocations + 1;
            else evictions = evictions + 1;
        end
        cpu.i_read = 0;
        cpu.iaddr = 0;
        @(negedge clk);
        if (dut.state !== 2'd0 || dut.ar_sent !== 1'b0 ||
            dut.miss_way_selected !== 1'b0 || dut.refill_count !== '0 ||
            dut.latency_count !== '0 || cpu.i_waitrequest !== 1'b0 || cpu.instr !== '0)
            $fatal(1, "L1I did not return to a clean idle state after its response");
        active_fetch = 0;
    endtask

    task automatic idle_cycles(input integer count);
        integer before_ar, before_r;
        before_ar = read_requests;
        before_r = read_responses;
        cpu.i_read = 0;
        repeat (count) begin
            cpu.iaddr = next_random() & (MEM_SIZE - 4);
            @(negedge clk);
            if (dut.state !== 2'd0 || cpu.i_waitrequest !== 1'b0 || cpu.instr !== '0 ||
                axi.arvalid !== 1'b0 || axi.rready !== 1'b0 ||
                read_requests != before_ar || read_responses != before_r)
                $fatal(1, "L1I generated activity without i_read");
        end
    endtask

    task automatic test_pass(input string description);
        tests_passed = tests_passed + 1;
        $display("L1I directed %0d PASS: %s", tests_passed, description);
    endtask

    initial begin : global_watchdog
        longint unsigned maximum_cycles;
        // Wait for plusarg initialization, then budget every random fetch and
        // ample directed/reset overhead at the per-request timeout. Explicit
        // 64-bit arithmetic prevents overflow at the supported iteration cap.
        #1;
        maximum_cycles = (64'(random_iters) + 64'd256) *
                         (64'(REQUEST_TIMEOUT) + 64'd8) + 64'd1024;
        repeat (maximum_cycles) @(posedge clk);
        $fatal(1, "tb_l1i global watchdog expired SEED=%0d RANDOM_ITERS=%0d", random_seed, random_iters);
    end

    initial begin : run_tests
        logic [31:0] base, random_address, choice;
        integer stalls_before, delays_before;
        if (L1_LATENCY < 1 || L1_CACHE_SIZE % 256 != 0 || NUM_SETS < 2 ||
            (NUM_SETS & (NUM_SETS - 1)) != 0 || 6 * SET_STRIDE >= MEM_SIZE)
            $fatal(1, "tb_l1i requires positive latency, power-of-two sets >=2, and room for six tags in 1MB");
        if ($value$plusargs("SEED=%d", random_seed)) begin end
        if ($value$plusargs("RANDOM_ITERS=%d", random_iters)) begin end
        if (random_iters < 0 || random_iters > 100000)
            $fatal(1, "RANDOM_ITERS must be in 0..100000");
        random_state = (random_seed == 0) ? 32'h1 : random_seed;
        $display("tb_l1i: L1_CACHE_SIZE=%0d L1_LATENCY=%0d SEED=%0d RANDOM_ITERS=%0d",
                 L1_CACHE_SIZE, L1_LATENCY, random_seed, random_iters);
        cpu.iaddr = 0;
        cpu.i_read = 0;
        cpu.daddr = 0;
        cpu.wdata = 0;
        cpu.d_read = 0;
        cpu.d_write = 0;
        for (integer index = 0; index < NUM_WORDS; index = index + 1) begin
            reference_memory[index] = initial_word(index);
            memory_backend.memory[index] = reference_memory[index];
        end

        reset_cache();
        idle_cycles(8);
        test_pass("reset valid/LRU/controller state and idle without requests");

        fetch_word(32'h100c, 0);
        test_pass("cold miss with sixteen ordered refill addresses and complete line data");
        fetch_word(32'h100c, 1);
        test_pass("read hit with exact lookup latency and zero backend traffic");
        for (integer word_index = 0; word_index < WORDS_PER_LINE; word_index = word_index + 1)
            fetch_word(32'h1000 + word_index * 4, 1);
        test_pass("all sixteen word offsets in one line");
        fetch_word(32'h103c, 1);
        fetch_word(32'h1040, 0);
        fetch_word(32'h103c, 1);
        test_pass("line boundary and adjacent sets do not interfere");

        reset_cache();
        base = 32'h40;
        for (integer tag_index = 0; tag_index < NUM_WAYS; tag_index = tag_index + 1)
            fetch_word(base + tag_index * SET_STRIDE, 0);
        test_pass("four same-set tags allocate invalid ways before any eviction");
        fetch_word(base, 1);
        test_pass("LRU hit update makes the oldest line most recently used");
        fetch_word(base + 4 * SET_STRIDE, 0);
        fetch_word(base, 1);
        fetch_word(base + 2 * SET_STRIDE, 1);
        fetch_word(base + 3 * SET_STRIDE, 1);
        fetch_word(base + SET_STRIDE, 0);
        test_pass("fifth same-set line evicts the timestamp model's least recently used way");

        reset_cache();
        fetch_word(base, 0);
        fetch_word(base + SET_STRIDE, 0);
        fetch_word(base, 1);
        fetch_word(base + 2 * SET_STRIDE, 0);
        fetch_word(base, 1);
        fetch_word(base + SET_STRIDE, 1);
        test_pass("partial set retains valid lines when another invalid way exists");

        ar_delay = 5;
        r_delay = 0;
        stalls_before = ar_stall_cycles;
        fetch_word(32'h2000, 0);
        if (ar_stall_cycles - stalls_before != WORDS_PER_LINE * 5)
            $fatal(1, "L1I AR backpressure test did not observe five stalled edges per refill word");
        test_pass("ARREADY delay preserves each request and refill index");

        ar_delay = 0;
        r_delay = 7;
        delays_before = r_delay_cycles;
        fetch_word(32'h2040, 0);
        if (r_delay_cycles - delays_before != WORDS_PER_LINE * 7)
            $fatal(1, "L1I RVALID delay test did not observe seven pending edges per word");
        test_pass("RVALID delay retains ar_sent and prevents duplicate requests");

        ar_delay = 3;
        r_delay = 4;
        fetch_word(32'h30b4, 0, 1);
        fetch_word(32'h30b4, 1, 1);
        idle_cycles(8);
        test_pass("accepted CPU address/request remain latched while busy");

        // Small working-set traffic ensures random tests include hits and
        // same-set conflicts, with occasional addresses across the full memory.
        for (integer iteration = 0; iteration < random_iters; iteration = iteration + 1) begin
            choice = next_random();
            if (choice[1:0] != 0)
                random_address = (next_random() % 6) * SET_STRIDE +
                                 (next_random() % 2) * LINE_SIZE + (next_random() % 16) * 4;
            else
                random_address = (next_random() % NUM_WORDS) * 4;
            ar_delay = next_random() % 5;
            r_delay = next_random() % 6;
            fetch_word(random_address, -1, choice[2]);
        end
        idle_cycles(8);
        for (integer set_index = 0; set_index < NUM_SETS; set_index = set_index + 1)
            check_set(set_index);
        for (integer index = 0; index < NUM_WORDS; index = index + 1)
            if (memory_backend.memory[index] !== reference_memory[index])
                $fatal(1, "L1I unexpectedly modified backing memory at %h", index * 4);
        if (tests_passed != 12 || hit_count == 0 || miss_count == 0 ||
            invalid_allocations == 0 || evictions == 0 || ar_stall_cycles == 0 || r_delay_cycles == 0 ||
            read_requests != read_responses || response_pending ||
            memory_backend.aw_count != 0 || memory_backend.w_count != 0 || memory_backend.b_count != 0)
            $fatal(1, "L1I coverage/accounting incomplete");
        $display("L1I coverage: directed=%0d fetches=%0d hits=%0d misses=%0d invalid=%0d evictions=%0d AR_stalls=%0d R_delays=%0d random=%0d",
                 tests_passed, fetch_count, hit_count, miss_count, invalid_allocations,
                 evictions, ar_stall_cycles, r_delay_cycles, random_iters);
        $display("PASS: tb_l1i");
        $finish;
    end
endmodule

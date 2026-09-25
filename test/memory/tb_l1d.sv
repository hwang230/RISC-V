`timescale 1ns/1ps

// Standalone write-back/write-allocate L1D contract tests. The DUT is always
// the real l1d_cache RTL; only its downstream memory is modeled. These checks
// intentionally fail while the L1D implementation does not meet this contract.
// CPU requests are latched at an IDLE rising edge. d_waitrequest stays asserted
// through lookup/miss service and drops for the completion cycle.
module tb_l1d #(
    parameter int L1_CACHE_SIZE = 64 * 1024,
    parameter int L1_LATENCY = 2
);
    localparam int MEM_SIZE = 1024 * 1024;
    localparam int NUM_WORDS = MEM_SIZE / 4;
    localparam int NUM_SETS = L1_CACHE_SIZE / 256;
    bit clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;
    l1_cache_if cpu();
    axi_lite_if axi();
    int unsigned ar_delay = 0, r_delay = 0, aw_delay = 0, w_delay = 0, b_delay = 0;
    l1d_cache #(.CACHE_SIZE(L1_CACHE_SIZE), .LATENCY(L1_LATENCY)) dut (
        .clk(clk), .rst_n(rst_n), .l1d(cpu), .axi(axi)
    );
    controllable_dram #(.MEM_SIZE(MEM_SIZE)) backend (
        .clk(clk), .rst_n(rst_n), .axi(axi), .ar_delay(ar_delay), .r_delay(r_delay),
        .aw_delay(aw_delay), .w_delay(w_delay), .b_delay(b_delay)
    );

    // Architectural memory changes on CPU writes. Backing memory changes only
    // after dirty eviction; those two references must remain distinct.
    logic [31:0] architectural [0:NUM_WORDS-1];
    logic [31:0] backing [0:NUM_WORDS-1];
    bit expected_valid [0:NUM_SETS-1][0:3];
    bit expected_dirty [0:NUM_SETS-1][0:3];
    int unsigned expected_tag [0:NUM_SETS-1][0:3];
    int expected_rank [0:NUM_SETS-1][0:3];
    bit active = 0, active_write, active_hit, dirty_victim;
    logic [31:0] active_address, active_data, victim_base;
    int active_set, active_way;
    int unsigned cycle = 0, started, completed = 0;
    int unsigned txn_ar, txn_r, txn_aw, txn_w, txn_b;
    int unsigned read_hits = 0, read_misses = 0, write_hits = 0, write_misses = 0;
    int unsigned clean_evictions = 0, dirty_read_evictions = 0, dirty_write_evictions = 0, invalid_fills = 0;
    int unsigned dram_reads = 0, dram_writes = 0, aw_first = 0, w_first = 0;
    int unsigned ar_stalls = 0, r_waits = 0, aw_stalls = 0, w_stalls = 0, b_waits = 0;
    bit stalled_ar = 0, stalled_aw = 0, stalled_w = 0, stalled_r = 0, stalled_b = 0;
    logic [31:0] saved_ar, saved_aw, saved_w, saved_r;
    int unsigned seed = 1, random_iters = 200, rng;
    string wave_file;

    function automatic logic [31:0] initial_word(input int unsigned index);
        return 32'h91827364 ^ (index * 32'h01020305) ^ (index << 11);
    endfunction

    function automatic logic [31:0] address_for(input int set_number, input int tag_number);
        return (tag_number * NUM_SETS + set_number % NUM_SETS) * 64;
    endfunction

    function automatic int lookup(input logic [31:0] address);
        int set_number;
        set_number = (address / 64) % NUM_SETS;
        for (int way = 0; way < 4; way++)
            if (expected_valid[set_number][way] && expected_tag[set_number][way] == address / (NUM_SETS * 64))
                return way;
        return -1;
    endfunction

    function automatic int unsigned next_random();
        rng = rng ^ (rng << 13);
        rng = rng ^ (rng >> 17);
        rng = rng ^ (rng << 5);
        return rng;
    endfunction

    task automatic check_set(input int set_number);
        int unsigned word_index;
        for (int way = 0; way < 4; way++) begin
            if (dut.valid_array[set_number][way] !== expected_valid[set_number][way] ||
                dut.dirty_array[set_number][way] !== expected_dirty[set_number][way])
                $fatal(1, "L1D valid/dirty mismatch set=%0d way=%0d", set_number, way);
            if (int'(dut.lru_rank[set_number][way]) != expected_rank[set_number][way])
                $fatal(1, "L1D LRU mismatch set=%0d way=%0d got=%0d expected=%0d", set_number,
                       way, dut.lru_rank[set_number][way], expected_rank[set_number][way]);
            if (expected_valid[set_number][way]) begin
                if (int'(dut.tag_array[set_number][way]) != expected_tag[set_number][way])
                    $fatal(1, "L1D tag mismatch set=%0d way=%0d", set_number, way);
                for (int word_number = 0; word_number < 16; word_number++) begin
                    word_index = (expected_tag[set_number][way] * NUM_SETS + set_number) * 16 + word_number;
                    if (dut.data_array[set_number][way][word_number*32 +: 32] !== architectural[word_index])
                        $fatal(1, "L1D cached data mismatch address=%08x got=%08x expected=%08x", word_index * 4,
                               dut.data_array[set_number][way][word_number*32 +: 32], architectural[word_index]);
                    if (backend.memory[word_index] !== backing[word_index])
                        $fatal(1, "L1D unintended backing write at %08x", word_index * 4);
                    if (!expected_dirty[set_number][way] && backing[word_index] !== architectural[word_index])
                        $fatal(1, "L1D clean line diverged from backing at %08x", word_index * 4);
                end
            end
        end
    endtask

    task automatic begin_request();
        if (active) $fatal(1, "L1D accepted CPU request while busy");
        if (cpu.daddr[1:0] != 0 || cpu.daddr >= MEM_SIZE) $fatal(1, "L1D test address invalid");
        active = 1;
        active_write = cpu.d_write; // A simultaneous read/write selects write.
        active_address = cpu.daddr;
        active_data = cpu.wdata;
        active_set = (cpu.daddr / 64) % NUM_SETS;
        active_way = lookup(cpu.daddr);
        active_hit = active_way >= 0;
        started = cycle;
        dirty_victim = 0;
        if (!active_hit) begin
            for (int way = 0; way < 4; way++)
                if (active_way < 0 && !expected_valid[active_set][way]) active_way = way;
            if (active_way >= 0) invalid_fills++;
            else begin
                for (int way = 0; way < 4; way++)
                    if (expected_rank[active_set][way] == 3) active_way = way;
                if (active_way < 0) $fatal(1, "L1D reference has no LRU victim");
                dirty_victim = expected_dirty[active_set][active_way];
                if (dirty_victim) begin
                    if (active_write) dirty_write_evictions++; else dirty_read_evictions++;
                end else clean_evictions++;
            end
            victim_base = address_for(active_set, expected_tag[active_set][active_way]);
        end
        if (active_write) begin
            if (active_hit) write_hits++; else write_misses++;
        end else begin
            if (active_hit) read_hits++; else read_misses++;
        end
        txn_ar = 0; txn_r = 0; txn_aw = 0; txn_w = 0; txn_b = 0;
    endtask

    task automatic complete_request();
        int old_rank;
        if (txn_ar != (active_hit ? 0 : 16) || txn_r != txn_ar)
            $fatal(1, "L1D refill count mismatch at %08x AR=%0d R=%0d hit=%0d", active_address, txn_ar, txn_r, active_hit);
        if (txn_aw != (dirty_victim ? 16 : 0) || txn_w != txn_aw || txn_b != txn_aw)
            $fatal(1, "L1D write-back count mismatch AW/W/B=%0d/%0d/%0d dirty-victim=%0d", txn_aw, txn_w, txn_b, dirty_victim);
        if (active_write) begin
            if (cpu.resp !== 2'b00) $fatal(1, "L1D store returned non-OKAY response");
            architectural[active_address / 4] = active_data;
        end else if (cpu.data !== architectural[active_address / 4])
            $fatal(1, "L1D CPU read mismatch at %08x got=%08x expected=%08x", active_address, cpu.data, architectural[active_address / 4]);
        old_rank = expected_rank[active_set][active_way];
        for (int way = 0; way < 4; way++)
            if (way != active_way) begin
                if (active_hit && expected_rank[active_set][way] < old_rank) expected_rank[active_set][way]++;
                if (!active_hit && expected_valid[active_set][way] && expected_rank[active_set][way] < 3)
                    expected_rank[active_set][way]++;
            end
        expected_rank[active_set][active_way] = 0;
        if (!active_hit) expected_dirty[active_set][active_way] = 0;
        expected_valid[active_set][active_way] = 1;
        expected_tag[active_set][active_way] = active_address / (NUM_SETS * 64);
        if (active_write) expected_dirty[active_set][active_way] = 1;
        check_set(active_set);
        active = 0;
        completed++;
    endtask

    always @(posedge clk) begin
        cycle++;
        if (!rst_n) begin
            active = 0;
            stalled_ar = 0; stalled_aw = 0; stalled_w = 0; stalled_r = 0; stalled_b = 0;
            for (int set_number = 0; set_number < NUM_SETS; set_number++)
                for (int way = 0; way < 4; way++) begin
                    expected_valid[set_number][way] = 0;
                    expected_dirty[set_number][way] = 0;
                    expected_tag[set_number][way] = 0;
                    expected_rank[set_number][way] = way;
                end
        end else begin
            if (int'(dut.state) == 0 && (cpu.d_read || cpu.d_write)) begin_request();
            if (stalled_ar && (!axi.arvalid || axi.araddr !== saved_ar)) $fatal(1, "L1D AR changed under backpressure");
            if (stalled_aw && (!axi.awvalid || axi.awaddr !== saved_aw)) $fatal(1, "L1D AW changed under backpressure");
            if (stalled_w && (!axi.wvalid || axi.wdata !== saved_w)) $fatal(1, "L1D W changed under backpressure");
            if (stalled_r && (!axi.rvalid || axi.rdata !== saved_r)) $fatal(1, "backend R changed under backpressure");
            if (stalled_b && !axi.bvalid) $fatal(1, "backend B dropped before handshake");

            if (axi.arvalid && axi.arready) begin
                if (!active || active_hit || txn_ar >= 16 || txn_ar != txn_r || (dirty_victim && txn_b != 16))
                    $fatal(1, "L1D duplicate/premature/unexpected refill request");
                if (axi.araddr !== ((active_address & 32'hffffffc0) + txn_ar * 4))
                    $fatal(1, "L1D wrong refill address got=%08x", axi.araddr);
                txn_ar++; dram_reads++;
            end
            if (axi.rvalid && axi.rready) begin
                if (!active || txn_r >= txn_ar) $fatal(1, "L1D unsolicited refill data");
                if (axi.rdata !== backing[(active_address & 32'hffffffc0) / 4 + txn_r])
                    $fatal(1, "L1D incorrect refill data");
                txn_r++;
            end
            if (axi.awvalid && axi.awready) begin
                if (!active || !dirty_victim || txn_aw >= 16 || txn_aw != txn_b || txn_ar != 0)
                    $fatal(1, "L1D unexpected/duplicate write-back AW");
                if (axi.awaddr !== victim_base + txn_aw * 4)
                    $fatal(1, "L1D write-back must address evicted tag, got=%08x expected=%08x", axi.awaddr, victim_base + txn_aw * 4);
                if (txn_w == txn_aw && !(axi.wvalid && axi.wready)) aw_first++;
                txn_aw++;
            end
            if (axi.wvalid && axi.wready) begin
                if (!active || !dirty_victim || txn_w >= 16 || txn_w != txn_b || txn_ar != 0)
                    $fatal(1, "L1D unexpected/duplicate write-back W");
                if (axi.wdata !== architectural[victim_base / 4 + txn_w])
                    $fatal(1, "L1D wrong write-back data at %08x", victim_base + txn_w * 4);
                if (txn_aw == txn_w) w_first++;
                txn_w++;
            end
            if (axi.bvalid && axi.bready) begin
                if (!active || !dirty_victim || txn_aw != txn_b + 1 || txn_w != txn_b + 1 || axi.bresp !== 2'b00)
                    $fatal(1, "L1D write-back B before paired AW/W or response error");
                backing[victim_base / 4 + txn_b] = architectural[victim_base / 4 + txn_b];
                if (backend.memory[victim_base / 4 + txn_b] !== backing[victim_base / 4 + txn_b])
                    $fatal(1, "L1D backing memory failed to commit eviction word");
                txn_b++; dram_writes++;
            end
            if (axi.arvalid && !axi.arready) ar_stalls++;
            if (active && txn_ar > txn_r && !axi.rvalid) r_waits++;
            if (axi.awvalid && !axi.awready) aw_stalls++;
            if (axi.wvalid && !axi.wready) w_stalls++;
            if (active && txn_aw > txn_b && txn_w > txn_b && !axi.bvalid) b_waits++;
            if (active && cycle > started) begin
                if (cycle - started <= L1_LATENCY && !cpu.d_waitrequest)
                    $fatal(1, "L1D completed before configured lookup latency");
                if (active_hit && cycle - started == L1_LATENCY + 1 && cpu.d_waitrequest)
                    $fatal(1, "L1D hit exceeded configured lookup latency");
                if (!cpu.d_waitrequest) complete_request();
                else if (cycle - started > 5000 + L1_LATENCY)
                    $fatal(1, "L1D transaction watchdog: state=%0d addr=%08x", dut.state, active_address);
            end
            stalled_ar = axi.arvalid && !axi.arready; saved_ar = axi.araddr;
            stalled_aw = axi.awvalid && !axi.awready; saved_aw = axi.awaddr;
            stalled_w = axi.wvalid && !axi.wready; saved_w = axi.wdata;
            stalled_r = axi.rvalid && !axi.rready; saved_r = axi.rdata;
            stalled_b = axi.bvalid && !axi.bready;
        end
    end

    task automatic access_word(input bit is_write, input logic [31:0] address,
                               input logic [31:0] data = 0, input int expect_hit = -1,
                               input bit poison_busy_inputs = 0, input bit both_requests = 0);
        int unsigned before_completed;
        if (expect_hit >= 0 && (lookup(address) >= 0) != (expect_hit != 0))
            $fatal(1, "L1D directed setup expected hit=%0d address=%08x", expect_hit, address);
        // Calls return in a falling-edge idle phase, allowing the next CPU
        // request at the very next rising edge without an idle-cycle bubble.
        if (clk !== 1'b0) @(negedge clk);
        if (int'(dut.state) != 0 || active) $fatal(1, "L1D failed to return idle");
        before_completed = completed;
        cpu.daddr = address; cpu.wdata = data; cpu.wstrb = '1;
        cpu.d_write = is_write; cpu.d_read = !is_write || both_requests;
        @(posedge clk);
        @(negedge clk);
        cpu.d_write = 0; cpu.d_read = 0;
        if (poison_busy_inputs) begin
            if (!cpu.d_waitrequest) $fatal(1, "L1D blocking test did not become busy");
            // Pulse a competing CPU command during a delayed miss. The original
            // request must use its latched address/data and finish exactly once.
            cpu.daddr = address_for(3, 7); cpu.wdata = ~data;
            cpu.d_write = 1; cpu.d_read = 1;
            repeat (2) begin
                @(posedge clk);
                if (!cpu.d_waitrequest) $fatal(1, "L1D unblocked while original miss was outstanding");
                @(negedge clk);
            end
            cpu.d_write = 0; cpu.d_read = 0;
        end
        while (completed == before_completed) @(negedge clk);
        if (completed != before_completed + 1 || int'(dut.state) != 0)
            $fatal(1, "L1D request duplicated or response failed to return idle");
    endtask

    task automatic prepare_dirty_line(input int set_number);
        for (int word_number = 0; word_number < 16; word_number++)
            access_word(1, address_for(set_number, 0) + word_number * 4,
                        32'hcafe0000 ^ (set_number << 12) ^ (word_number * 32'h1020304), word_number == 0 ? 0 : 1);
        for (int tag_number = 1; tag_number < 4; tag_number++)
            access_word(0, address_for(set_number, tag_number), 0, 0);
    endtask

    task automatic directed_tests();
        int unsigned before_count, before_b_waits;
        $display("L1D Test 0 - Reset valid, dirty, LRU and handshake state");
        repeat (4) @(negedge clk);
        if (int'(dut.state) != 0 || dut.latency_count != 0 || dut.refill_count != 0 ||
            dut.ar_sent || dut.aw_sent || dut.w_sent)
            $fatal(1, "L1D reset state is incorrect");
        for (int set_number = 0; set_number < NUM_SETS; set_number++) check_set(set_number);
        rst_n = 1;
        $display("L1D Test 1 - Read miss refills exactly 16 ordered words");
        access_word(0, address_for(0, 0) + 20, 0, 0);
        $display("L1D Test 2 - Read hit and same-line word selection");
        access_word(0, address_for(0, 0) + 20, 0, 1);
        access_word(0, address_for(0, 0) + 60, 0, 1);
        $display("L1D Test 3 - Write hit stays local, sets dirty, reads latest data");
        access_word(1, address_for(0, 0) + 20, 32'hdeadbeef, 1);
        access_word(0, address_for(0, 0) + 20, 0, 1);
        $display("L1D Test 4 - Write miss allocates, merges one word, sets dirty without write-through");
        access_word(1, address_for(0, 1) + 28, 32'h12345678, 0);
        access_word(0, address_for(0, 1) + 28, 0, 1);
        $display("L1D Test 5 - Invalid preference, four ways, LRU hit update and clean eviction");
        for (int tag_number = 0; tag_number < 4; tag_number++) access_word(0, address_for(3, tag_number), 0, 0);
        access_word(0, address_for(3, 0), 0, 1);
        access_word(0, address_for(3, 4), 0, 0);
        if (lookup(address_for(3, 1)) >= 0) $fatal(1, "L1D clean eviction selected wrong LRU tag");
        $display("L1D Test 6 - Read-triggered dirty eviction: 16 writes before 16 reads, AW before W");
        prepare_dirty_line(1);
        before_count = aw_first;
        w_delay = 7;
        access_word(0, address_for(1, 4), 0, 0);
        w_delay = 0;
        if (aw_first - before_count != 16) $fatal(1, "L1D did not exercise AW before W on every eviction word");
        $display("L1D Test 7 - Write-triggered dirty eviction, W before AW and delayed B");
        prepare_dirty_line(2);
        before_count = w_first;
        before_b_waits = b_waits;
        aw_delay = 8; b_delay = 9;
        access_word(1, address_for(2, 4) + 60, 32'hfacefeed, 0);
        aw_delay = 0; b_delay = 0;
        if (w_first - before_count != 16) $fatal(1, "L1D did not exercise W before AW on every eviction word");
        // b_waits includes the second AW/W acceptance edge plus delayed edges.
        if (b_waits - before_b_waits != 16 * 10)
            $fatal(1, "L1D did not delay every dirty-eviction B response nine cycles");
        access_word(0, address_for(2, 4) + 60, 0, 1);
        $display("L1D Test 8 - Delayed ARREADY for every refill word");
        before_count = ar_stalls;
        ar_delay = 6;
        access_word(0, address_for(0, 3), 0, 0);
        ar_delay = 0;
        if (ar_stalls - before_count != 16 * 6) $fatal(1, "L1D AR delay coverage mismatch");
        $display("L1D Test 9 - Delayed RVALID for every refill word");
        before_count = r_waits;
        r_delay = 8;
        access_word(0, address_for(0, 4), 0, 0);
        r_delay = 0;
        if (r_waits - before_count != 16 * 9) $fatal(1, "L1D R delay coverage mismatch");
        $display("L1D Test 10 - CPU request latching and blocking during read/write miss");
        r_delay = 5;
        access_word(0, address_for(0, 5), 0, 0, 1);
        access_word(1, address_for(0, 6), 32'hf00dcafe, 0, 1);
        r_delay = 0;
        $display("L1D Test 11 - Simultaneous CPU write/read selects write");
        access_word(1, address_for(0, 6), 32'h01020304, 1, 0, 1);
        access_word(0, address_for(0, 6), 0, 1);
        $display("L1D Test 12 - Cache-line boundary and consecutive operations");
        access_word(0, address_for(0, 6) + 60, 0, 1);
        access_word(0, address_for(0, 6) + 64);
        for (int word_number = 0; word_number < 16; word_number++) begin
            access_word(1, address_for(0, 6) + word_number * 4, 32'h11220000 + word_number, 1);
            access_word(0, address_for(0, 6) + word_number * 4, 0, 1);
        end
    endtask

    task automatic random_regression();
        logic [31:0] address, previous_address, data;
        int set_number, tag_number, word_number;
        bit is_write;
        previous_address = address_for(0, 6);
        $display("L1D randomized regression SEED=%0d RANDOM_ITERS=%0d", seed, random_iters);
        for (int iteration = 0; iteration < random_iters; iteration++) begin
            is_write = (next_random() % 3) == 0;
            set_number = next_random() % (NUM_SETS < 16 ? NUM_SETS : 16);
            tag_number = next_random() % 7;
            word_number = next_random() % 16;
            address = address_for(set_number, tag_number) + word_number * 4;
            if (next_random() % 4 == 0) address = (previous_address & 32'hffffffc0) + word_number * 4;
            data = next_random();
            ar_delay = next_random() % 4; r_delay = next_random() % 5;
            aw_delay = next_random() % 5; w_delay = next_random() % 5; b_delay = next_random() % 6;
            access_word(is_write, address, data);
            previous_address = address;
        end
    endtask

    task automatic flush_dirty_by_eviction();
        bit has_dirty;
        ar_delay = 0; r_delay = 0; aw_delay = 0; w_delay = 0; b_delay = 0;
        $display("L1D final consistency - conflict-read every dirty set to write back all architectural stores");
        for (int set_number = 0; set_number < NUM_SETS; set_number++) begin
            has_dirty = 0;
            for (int way = 0; way < 4; way++) if (expected_dirty[set_number][way]) has_dirty = 1;
            if (has_dirty)
                // Tags 12..15 are reserved for flushing, disjoint from all
                // directed/random traffic. Four clean allocations evict all
                // previous contents without an implementation-specific flush.
                for (int tag_number = 12; tag_number < 16; tag_number++)
                    access_word(0, address_for(set_number, tag_number), 0, 0);
        end
    endtask

    task automatic warm_reset_discards_dirty();
        int unsigned writes_before;
        logic [31:0] address;
        $display("L1D Test 13 - Warm reset discards dirty cache contents without flushing");
        address = address_for(0, 0);
        writes_before = dram_writes;
        // The previous flush leaves only clean lines. Make a value different
        // from backing dirty, so a missing dirty-bit reset is observable even
        // in a two-state simulator.
        access_word(1, address, backing[address / 4] ^ 32'hffffffff);
        if (architectural[address / 4] === backing[address / 4])
            $fatal(1, "L1D warm-reset setup did not create dirty divergence");
        @(negedge clk);
        rst_n = 0;
        cpu.d_read = 0; cpu.d_write = 0;
        repeat (4) @(negedge clk);
        if (int'(dut.state) != 0 || dut.latency_count != 0 || dut.refill_count != 0 ||
            dut.ar_sent || dut.aw_sent || dut.w_sent)
            $fatal(1, "L1D warm reset did not clear controller tracking");
        for (int set_number = 0; set_number < NUM_SETS; set_number++) check_set(set_number);
        for (int word_index = 0; word_index < NUM_WORDS; word_index++) begin
            if (backend.memory[word_index] !== backing[word_index])
                $fatal(1, "L1D warm reset unexpectedly modified backing memory");
            // Reset is explicitly defined to discard unflushed CPU stores.
            architectural[word_index] = backing[word_index];
        end
        rst_n = 1;
        access_word(0, address, 0, 0);
        if (dram_writes != writes_before)
            $fatal(1, "L1D warm reset or post-reset read issued a spurious write-back");
    endtask

    initial begin
        if (L1_CACHE_SIZE < 1024 || L1_CACHE_SIZE > 256*1024 ||
            (L1_CACHE_SIZE & (L1_CACHE_SIZE - 1)) != 0 || L1_LATENCY < 1)
            $fatal(1, "L1D tests require power-of-two L1_CACHE_SIZE 1024..262144 and L1_LATENCY >= 1");
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("RANDOM_ITERS=%d", random_iters)) begin end
        if (random_iters > 100000) $fatal(1, "RANDOM_ITERS must be 0..100000");
        rng = seed == 0 ? 32'h6d2b79f5 : seed;
        if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_l1d);
        end
        cpu.daddr = 0; cpu.wdata = 0; cpu.wstrb = '1; cpu.d_read = 0; cpu.d_write = 0;
        cpu.iaddr = 0; cpu.i_read = 0;
        for (int word_index = 0; word_index < NUM_WORDS; word_index++) begin
            architectural[word_index] = initial_word(word_index);
            backing[word_index] = initial_word(word_index);
            backend.memory[word_index] = initial_word(word_index);
        end
        directed_tests();
        $display("L1D directed tests passed; starting random traffic");
        random_regression();
        flush_dirty_by_eviction();
        repeat (3) @(negedge clk);
        if (active || int'(dut.state) != 0) $fatal(1, "L1D pending request at end of test");
        for (int set_number = 0; set_number < NUM_SETS; set_number++) check_set(set_number);
        for (int word_index = 0; word_index < NUM_WORDS; word_index++)
            if (backend.memory[word_index] !== backing[word_index] || backing[word_index] !== architectural[word_index])
                $fatal(1, "L1D final flushed architectural/backing mismatch address=%08x", word_index * 4);
        warm_reset_discards_dirty();
        if (read_hits == 0 || read_misses == 0 || write_hits == 0 || write_misses == 0 ||
            dirty_read_evictions == 0 || dirty_write_evictions == 0 || clean_evictions == 0 || invalid_fills == 0 ||
            aw_first == 0 || w_first == 0 || ar_stalls == 0 || r_waits == 0 || aw_stalls == 0 || w_stalls == 0 || b_waits == 0)
            $fatal(1, "L1D required directed coverage missing");
        $display("L1D coverage completed=%0d read_hit/miss=%0d/%0d write_hit/miss=%0d/%0d invalid=%0d clean_evict=%0d dirty_read/write_evict=%0d/%0d",
                 completed, read_hits, read_misses, write_hits, write_misses, invalid_fills,
                 clean_evictions, dirty_read_evictions, dirty_write_evictions);
        $display("L1D AXI reads/writes=%0d/%0d AW_first=%0d W_first=%0d AR/R/AW/W/B delay_cycles=%0d/%0d/%0d/%0d/%0d",
                 dram_reads, dram_writes, aw_first, w_first, ar_stalls, r_waits, aw_stalls, w_stalls, b_waits);
        $display("PASS: tb_l1d");
        $finish;
    end

    initial begin
        #1;
        repeat (64'd10000 + (64'd5000 + random_iters) * (64'd5000 + L1_LATENCY)) @(posedge clk);
        $fatal(1, "L1D global watchdog expired state=%0d SEED=%0d", dut.state, seed);
    end
endmodule

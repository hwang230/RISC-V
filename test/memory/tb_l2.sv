`timescale 1ns/1ps

// Shared stimulus and independent architectural/cache scoreboard for both layers.
// All drivers change inputs at negedge; monitors sample handshakes before NBA.
module tb_l2 #(
    parameter bit USE_REAL_DRAM = 0,
    parameter int CACHE_SIZE = 256 * 1024,
    parameter int L2_LATENCY = 3,
    parameter int DRAM_LATENCY = 4
);
    localparam int MEM_SIZE = 1024 * 1024;
    localparam int NUM_SETS = CACHE_SIZE / 256;
    localparam int NUM_WORDS = MEM_SIZE / 4;
    localparam int IDLE = 0, READ_WAIT = 1, READ_MISS = 2, READ_RESP = 3;
    localparam int WRITE_WAIT = 4, WRITE_MISS = 5, WRITE_THROUGH = 6, WRITE_RESP = 7;

    bit clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;
    axi_lite_if axi_i();
    axi_lite_if axi_d();
    axi_lite_if axi_mem();
    int unsigned ar_delay = 0, r_delay = 0, aw_delay = 0, w_delay = 0, b_delay = 0;

    l2_cache #(.CACHE_SIZE(CACHE_SIZE), .LATENCY(L2_LATENCY)) dut (
        .clk(clk), .rst_n(rst_n), .axi_slave_i(axi_i),
        .axi_slave_d(axi_d), .axi_master(axi_mem)
    );
    generate
        if (USE_REAL_DRAM) begin : g_backend
            DRAM #(.MEM_SIZE(MEM_SIZE), .LATENCY(DRAM_LATENCY)) backend (
                .clk(clk), .rst_n(rst_n), .axi(axi_mem)
            );
        end else begin : g_backend
            controllable_dram #(.MEM_SIZE(MEM_SIZE)) backend (
                .clk(clk), .rst_n(rst_n), .axi(axi_mem),
                .ar_delay(ar_delay), .r_delay(r_delay), .aw_delay(aw_delay),
                .w_delay(w_delay), .b_delay(b_delay)
            );
        end
    endgenerate

    l2_assertions #(.L2_LATENCY(L2_LATENCY)) protocol_checks (
        .clk(clk), .rst_n(rst_n), .axi_i(axi_i), .axi_d(axi_d), .axi_mem(axi_mem),
        .state(dut.state), .owner(dut.owner), .refill_count(dut.refill_count),
        .readaddr(dut.readaddr), .writeaddr(dut.writeaddr),
        .ar_sent(dut.ar_sent), .aw_sent(dut.aw_sent), .w_sent(dut.w_sent)
    );

    logic [31:0] reference_memory [0:NUM_WORDS-1];
    bit expected_valid [0:NUM_SETS-1][0:3];
    int unsigned expected_tag [0:NUM_SETS-1][0:3];
    int expected_rank [0:NUM_SETS-1][0:3];
    int unsigned cycle = 0;
    int unsigned completed = 0, dram_reads = 0, dram_writes = 0;
    int unsigned read_hits = 0, read_misses = 0, write_hits = 0, write_misses = 0;
    int unsigned i_reads = 0, d_reads = 0, d_writes = 0;
    int unsigned invalid_fills = 0, evictions = 0;
    int unsigned aw_first = 0, w_first = 0;
    int unsigned ar_stalls = 0, r_waits = 0, aw_stalls = 0, w_stalls = 0, b_waits = 0;
    int unsigned l1_r_stalls = 0, l1_b_stalls = 0;
    // Portable coverage crosses: request kind 0=I read, 1=D read, 2=D write;
    // hit/miss second index 0=miss, 1=hit; replacement 0=invalid, 1=LRU.
    int unsigned request_hit_cross [0:2][0:1];
    int unsigned replacement_cross [0:2][0:1];
    bit active = 0, active_write, active_i, active_hit, response_seen;
    bit pending_aw = 0, pending_w = 0;
    logic [31:0] pending_addr, pending_data;
    logic [31:0] active_addr, active_data;
    int active_set, active_way, active_age, active_start;
    int txn_ar, txn_r, txn_aw, txn_w, txn_b;
    logic [31:0] last_refill_addr;
    int unsigned seed = 1, random_iters = 200, rng;
    string wave_file;

    function automatic logic [31:0] initial_word(input int unsigned index);
        return 32'h9e3779b9 ^ (index * 32'h01010101) ^ (index << 7);
    endfunction

    function automatic logic [31:0] line_address(input int set_number, input int tag_number);
        return ((tag_number * NUM_SETS) + (set_number % NUM_SETS)) * 64;
    endfunction

    function automatic int lookup_way(input logic [31:0] address);
        int set_number;
        int unsigned tag_number;
        set_number = (address / 64) % NUM_SETS;
        tag_number = address / (NUM_SETS * 64);
        for (int way = 0; way < 4; way++)
            if (expected_valid[set_number][way] && expected_tag[set_number][way] == tag_number)
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
            if (dut.valid_array[set_number][way] !== expected_valid[set_number][way])
                $fatal(1, "valid mismatch set=%0d way=%0d", set_number, way);
            if (int'(dut.lru_rank[set_number][way]) != expected_rank[set_number][way])
                $fatal(1, "LRU mismatch set=%0d way=%0d got=%0d expected=%0d", set_number,
                       way, dut.lru_rank[set_number][way], expected_rank[set_number][way]);
            if (expected_valid[set_number][way]) begin
                if (int'(dut.tag_array[set_number][way]) != expected_tag[set_number][way])
                    $fatal(1, "tag mismatch set=%0d way=%0d", set_number, way);
                for (int word_number = 0; word_number < 16; word_number++) begin
                    word_index = (expected_tag[set_number][way] * NUM_SETS + set_number) * 16 + word_number;
                    if (dut.data_array[set_number][way][word_number*32 +: 32] !== reference_memory[word_index])
                        $fatal(1, "cache data mismatch address=%08x got=%08x expected=%08x",
                               word_index * 4, dut.data_array[set_number][way][word_number*32 +: 32],
                               reference_memory[word_index]);
                    if (g_backend.backend.memory[word_index] !== reference_memory[word_index])
                        $fatal(1, "backing data mismatch address=%08x", word_index * 4);
                end
            end
        end
    endtask

    task automatic begin_transaction(input bit is_write, input bit is_i,
                                     input logic [31:0] address, input logic [31:0] data);
        int request_kind;
        if (active) $fatal(1, "L2 accepted a new request while another request was active");
        if (address[1:0] != 0 || address >= MEM_SIZE) $fatal(1, "invalid test address %08x", address);
        active = 1;
        active_write = is_write;
        active_i = is_i;
        active_addr = address;
        active_data = data;
        active_start = cycle;
        response_seen = 0;
        active_set = (address / 64) % NUM_SETS;
        active_way = lookup_way(address);
        active_hit = active_way >= 0;
        request_kind = is_write ? 2 : (is_i ? 0 : 1);
        request_hit_cross[request_kind][int'(active_hit)]++;
        if (!active_hit) begin
            // Reference replacement chooses the first invalid entry, then rank 3.
            for (int way = 0; way < 4; way++)
                if (active_way < 0 && !expected_valid[active_set][way]) active_way = way;
            if (active_way >= 0) begin
                invalid_fills++;
                replacement_cross[request_kind][0]++;
            end
            else begin
                evictions++;
                replacement_cross[request_kind][1]++;
                for (int way = 0; way < 4; way++)
                    if (expected_rank[active_set][way] == 3) active_way = way;
            end
            if (active_way < 0) $fatal(1, "reference LRU has no victim");
        end
        if (is_write) begin
            d_writes++;
            if (active_hit) write_hits++; else write_misses++;
        end else begin
            if (is_i) i_reads++; else d_reads++;
            if (active_hit) read_hits++; else read_misses++;
        end
        txn_ar = 0; txn_r = 0; txn_aw = 0; txn_w = 0; txn_b = 0;
    endtask

    task automatic finish_transaction();
        int old_rank;
        if (!active) $fatal(1, "response without an active request");
        if (txn_ar != (active_hit ? 0 : 16) || txn_r != txn_ar)
            $fatal(1, "refill count at %08x: AR=%0d R=%0d expected=%0d", active_addr,
                   txn_ar, txn_r, active_hit ? 0 : 16);
        if (txn_aw != int'(active_write) || txn_w != int'(active_write) || txn_b != int'(active_write))
            $fatal(1, "write count at %08x: AW=%0d W=%0d B=%0d", active_addr, txn_aw, txn_w, txn_b);
        if (active_write) begin
            reference_memory[active_addr / 4] = active_data;
            if (g_backend.backend.memory[active_addr / 4] !== active_data)
                $fatal(1, "write-through failed at %08x", active_addr);
        end
        old_rank = expected_rank[active_set][active_way];
        for (int way = 0; way < 4; way++) begin
            if (way != active_way) begin
                if (active_hit && expected_rank[active_set][way] < old_rank)
                    expected_rank[active_set][way]++;
                if (!active_hit && expected_valid[active_set][way] && expected_rank[active_set][way] < 3)
                    expected_rank[active_set][way]++;
            end
        end
        expected_rank[active_set][active_way] = 0;
        expected_valid[active_set][active_way] = 1;
        expected_tag[active_set][active_way] = active_addr / (NUM_SETS * 64);
        check_set(active_set);
        completed++;
        active = 0;
    endtask

    // This scoreboard observes actual handshakes, including concurrent driver tests.
    // It never uses DUT hit/victim signals to predict expected behavior.
    always @(posedge clk) begin
        cycle++;
        if (!rst_n) begin
            active = 0;
            pending_aw = 0;
            pending_w = 0;
            for (int set_number = 0; set_number < NUM_SETS; set_number++)
                for (int way = 0; way < 4; way++) begin
                    expected_valid[set_number][way] = 0;
                    expected_tag[set_number][way] = 0;
                    expected_rank[set_number][way] = way;
                end
        end else begin
            if (axi_d.awvalid && axi_d.awready) begin
                if (pending_aw) $fatal(1, "duplicate L1 AW acceptance");
                pending_aw = 1;
                pending_addr = axi_d.awaddr;
            end
            if (axi_d.wvalid && axi_d.wready) begin
                if (pending_w) $fatal(1, "duplicate L1 W acceptance");
                pending_w = 1;
                pending_data = axi_d.wdata;
            end
            if (pending_aw && pending_w && !active)
                begin_transaction(1, 0, pending_addr, pending_data);
            if (axi_d.arvalid && axi_d.arready) begin_transaction(0, 0, axi_d.araddr, 0);
            if (axi_i.arvalid && axi_i.arready) begin_transaction(0, 1, axi_i.araddr, 0);

            if (active && cycle > active_start) begin
                active_age = cycle - active_start;
                if (int'(dut.owner) != (active_i ? 1 : 2)) $fatal(1, "request owner changed");
                if (active_age <= L2_LATENCY && int'(dut.state) != (active_write ? WRITE_WAIT : READ_WAIT))
                    $fatal(1, "lookup did not preserve configured latency age=%0d state=%0d", active_age, dut.state);
                if (active_age == L2_LATENCY + 1) begin
                    if (int'(dut.state) != (active_write ? (active_hit ? WRITE_THROUGH : WRITE_MISS)
                                                                      : (active_hit ? READ_RESP : READ_MISS)))
                        $fatal(1, "wrong lookup result/latency state=%0d hit=%0d write=%0d", dut.state, active_hit, active_write);
                end
                if ((int'(dut.state) == READ_MISS || int'(dut.state) == WRITE_MISS) && dut.miss_way_selected)
                    if (int'(dut.miss_way) != active_way) $fatal(1, "wrong refill way");
            end
            if (axi_mem.arvalid && axi_mem.arready) begin
                if (!active || active_hit || txn_ar != txn_r || txn_ar >= 16)
                    $fatal(1, "unexpected/duplicate DRAM read");
                if (axi_mem.araddr !== ((active_addr & 32'hffffffc0) + txn_ar * 4))
                    $fatal(1, "wrong refill address got=%08x word=%0d request=%08x", axi_mem.araddr, txn_ar, active_addr);
                last_refill_addr = axi_mem.araddr;
                txn_ar++;
                dram_reads++;
            end
            if (axi_mem.rvalid && axi_mem.rready) begin
                if (!active || txn_r >= txn_ar) $fatal(1, "unsolicited DRAM R response");
                if (axi_mem.rdata !== reference_memory[last_refill_addr / 4])
                    $fatal(1, "wrong backend refill data at %08x", last_refill_addr);
                txn_r++;
            end
            if (axi_mem.awvalid && axi_mem.awready) begin
                if (!active || !active_write || txn_aw != 0 || axi_mem.awaddr !== active_addr)
                    $fatal(1, "unexpected/duplicate/misaddressed DRAM AW");
                if (txn_w == 0 && !(axi_mem.wvalid && axi_mem.wready)) aw_first++;
                txn_aw++;
            end
            if (axi_mem.wvalid && axi_mem.wready) begin
                if (!active || !active_write || txn_w != 0 || axi_mem.wdata !== active_data)
                    $fatal(1, "unexpected/duplicate/incorrect DRAM W");
                if (txn_aw == 0) w_first++;
                txn_w++;
            end
            if (axi_mem.bvalid && axi_mem.bready) begin
                if (!active || !active_write || txn_aw != 1 || txn_w != 1 || txn_b != 0)
                    $fatal(1, "DRAM B response before unique AW and W");
                txn_b++;
                dram_writes++;
            end
            if (axi_mem.arvalid && !axi_mem.arready) ar_stalls++;
            if (active && txn_ar > txn_r && !axi_mem.rvalid) r_waits++;
            if (axi_mem.awvalid && !axi_mem.awready) aw_stalls++;
            if (axi_mem.wvalid && !axi_mem.wready) w_stalls++;
            if (active && active_write && txn_aw == 1 && txn_w == 1 && txn_b == 0 && !axi_mem.bvalid) b_waits++;
            if ((axi_i.rvalid && !axi_i.rready) || (axi_d.rvalid && !axi_d.rready)) l1_r_stalls++;
            if (axi_d.bvalid && !axi_d.bready) l1_b_stalls++;

            if (axi_i.rvalid || axi_d.rvalid) begin
                if (!active || active_write || (active_i ? !axi_i.rvalid || axi_d.rvalid : !axi_d.rvalid || axi_i.rvalid))
                    $fatal(1, "read response delivered to wrong owner");
                if ((active_i ? axi_i.rdata : axi_d.rdata) !== reference_memory[active_addr / 4])
                    $fatal(1, "L1 read mismatch addr=%08x got=%08x expected=%08x", active_addr,
                           active_i ? axi_i.rdata : axi_d.rdata, reference_memory[active_addr / 4]);
                if (!response_seen && active_hit && cycle - active_start != L2_LATENCY + 1)
                    $fatal(1, "wrong read hit response latency");
                response_seen = 1;
                if (active_i ? axi_i.rready : axi_d.rready) finish_transaction();
            end
            if (axi_d.bvalid) begin
                if (!active || !active_write || txn_b != 1) $fatal(1, "early L1 B response");
                // Real DRAM currently leaves BRESP unspecified. Its handshake and data
                // are verified; the controlled backend has a defined OKAY response.
                if (!USE_REAL_DRAM && axi_d.bresp !== 2'b00) $fatal(1, "non-OKAY model write response");
                if (axi_d.bready) begin
                    finish_transaction();
                    pending_aw = 0;
                    pending_w = 0;
                end
            end
        end
    end

    task automatic reset_cache();
        @(negedge clk);
        rst_n = 0;
        axi_i.arvalid = 0; axi_i.rready = 0;
        axi_d.arvalid = 0; axi_d.rready = 0;
        axi_d.awvalid = 0; axi_d.wvalid = 0; axi_d.bready = 0;
        repeat (4) @(negedge clk);
        if (int'(dut.state) != IDLE || int'(dut.owner) != 0 || dut.latency_count != 0 || dut.refill_count != 0 ||
            dut.ar_sent || dut.aw_sent || dut.w_sent || dut.aw_received || dut.w_received || dut.miss_way_selected)
            $fatal(1, "L2 reset state or handshake tracking is incorrect");
        if (axi_i.rvalid || axi_d.rvalid || axi_d.bvalid) $fatal(1, "unexpected reset response");
        for (int set_number = 0; set_number < NUM_SETS; set_number++) check_set(set_number);
        rst_n = 1;
        @(negedge clk);
    endtask

    task automatic launch_read(input bit instruction, input logic [31:0] address);
        @(negedge clk);
        if (instruction) begin axi_i.araddr = address; axi_i.arvalid = 1; end
        else begin axi_d.araddr = address; axi_d.arvalid = 1; end
        do @(posedge clk); while (!(instruction ? axi_i.arready : axi_d.arready));
        @(negedge clk);
        if (instruction) axi_i.arvalid = 0; else axi_d.arvalid = 0;
    endtask

    task automatic receive_read(input bit instruction, input int stall_cycles = 0);
        while (!(instruction ? axi_i.rvalid : axi_d.rvalid)) @(negedge clk);
        repeat (stall_cycles) @(negedge clk);
        if (instruction) axi_i.rready = 1; else axi_d.rready = 1;
        @(posedge clk);
        if (!(instruction ? axi_i.rvalid : axi_d.rvalid)) $fatal(1, "read response disappeared");
        @(negedge clk);
        if (instruction) axi_i.rready = 0; else axi_d.rready = 0;
        if (int'(dut.state) != IDLE || int'(dut.owner) != 0 || dut.miss_way_selected || dut.ar_sent)
            $fatal(1, "read completion did not clear state, owner, or refill tracking");
    endtask

    task automatic read_word(input bit instruction, input logic [31:0] address,
                             input int expected_hit = -1, input int stall_cycles = 0);
        if (expected_hit >= 0 && (lookup_way(address) >= 0) != (expected_hit != 0))
            $fatal(1, "directed test setup expected hit=%0d at %08x", expected_hit, address);
        launch_read(instruction, address);
        receive_read(instruction, stall_cycles);
    endtask

    task automatic launch_write(input logic [31:0] address, input logic [31:0] data);
        bit aw_done, w_done;
        aw_done = 0; w_done = 0;
        @(negedge clk);
        axi_d.awaddr = address; axi_d.wdata = data;
        axi_d.awvalid = 1; axi_d.wvalid = 1;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (axi_d.awvalid && axi_d.awready) aw_done = 1;
            if (axi_d.wvalid && axi_d.wready) w_done = 1;
            @(negedge clk);
            if (aw_done) axi_d.awvalid = 0;
            if (w_done) axi_d.wvalid = 0;
        end
    endtask

    task automatic receive_write(input int stall_cycles = 0);
        while (!axi_d.bvalid) @(negedge clk);
        repeat (stall_cycles) @(negedge clk);
        axi_d.bready = 1;
        @(posedge clk);
        if (!axi_d.bvalid) $fatal(1, "write response disappeared");
        @(negedge clk);
        axi_d.bready = 0;
        if (int'(dut.state) != IDLE || int'(dut.owner) != 0 || dut.aw_received || dut.w_received ||
            dut.aw_sent || dut.w_sent || dut.miss_way_selected)
            $fatal(1, "write completion did not clear state, owner, or handshake tracking");
    endtask

    task automatic write_word(input logic [31:0] address, input logic [31:0] data,
                              input int expected_hit = -1, input int stall_cycles = 0);
        if (expected_hit >= 0 && (lookup_way(address) >= 0) != (expected_hit != 0))
            $fatal(1, "directed write setup expected hit=%0d at %08x", expected_hit, address);
        launch_write(address, data);
        receive_write(stall_cycles);
    endtask

    task automatic accept_pending_read(input bit instruction);
        do @(posedge clk); while (!(instruction ? axi_i.arready : axi_d.arready));
        @(negedge clk);
        if (instruction) axi_i.arvalid = 0; else axi_d.arvalid = 0;
        receive_read(instruction);
    endtask

    // mode 0: D read beats I; mode 1: D write beats D read; mode 2: D write beats I.
    task automatic arbitration(input int mode);
        bit instruction;
        instruction = mode != 1;
        @(negedge clk);
        if (instruction) begin axi_i.araddr = line_address(2, 1); axi_i.arvalid = 1; end
        else begin axi_d.araddr = line_address(1, 0); axi_d.arvalid = 1; end
        if (mode == 0) begin
            axi_d.araddr = line_address(0, 1); axi_d.arvalid = 1;
        end else begin
            axi_d.awaddr = line_address(0, 1) + 4; axi_d.wdata = 32'habc00000 + mode;
            axi_d.awvalid = 1; axi_d.wvalid = 1;
        end
        @(posedge clk);
        if ((instruction ? axi_i.arready : axi_d.arready)) $fatal(1, "lower-priority request accepted first");
        if (mode == 0 ? !axi_d.arready : (!axi_d.awready || !axi_d.wready))
            $fatal(1, "higher-priority request not accepted");
        @(negedge clk);
        if (mode == 0) begin
            axi_d.arvalid = 0;
            receive_read(0);
        end else begin
            axi_d.awvalid = 0; axi_d.wvalid = 0;
            receive_write();
        end
        accept_pending_read(instruction);
    endtask

    task automatic blocking_miss(input bit is_write);
        if (is_write) launch_write(line_address(1, 2), 32'hba5eba11);
        else launch_read(0, line_address(0, 2));
        while (int'(dut.state) != (is_write ? WRITE_MISS : READ_MISS)) @(negedge clk);
        axi_i.araddr = line_address(is_write ? 3 : 2, 2);
        axi_i.arvalid = 1;
        if (is_write) begin
            while (int'(dut.state) != WRITE_THROUGH) begin
                @(posedge clk);
                if (axi_i.arready) $fatal(1, "request accepted during write miss");
                @(negedge clk);
            end
            @(posedge clk);
            if (axi_i.arready) $fatal(1, "request accepted during write-through");
            @(negedge clk);
            receive_write();
        end else receive_read(0);
        accept_pending_read(1);
    endtask

    task automatic protocol_directed();
        int before_count;
        $display("L2 Test 0 - Reset");
        reset_cache();
        $display("L2 Test 1 - L1D read miss, complete ordered refill");
        read_word(0, line_address(0, 0) + 20, 0);
        $display("L2 Test 2 - L1D read hit and exact lookup latency");
        read_word(0, line_address(0, 0) + 20, 1);
        $display("L2 Test 3 - Different word in the same line");
        read_word(0, line_address(0, 0) + 44, 1);
        $display("L2 Test 4 - L1I read miss and ownership");
        read_word(1, line_address(1, 0) + 12, 0);
        $display("L2 Test 5 - L1I read hit");
        read_word(1, line_address(1, 0) + 12, 1);
        $display("L2 Test 6 - Write hit and write-through consistency");
        write_word(line_address(0, 0) + 20, 32'hdeadbeef, 1);
        $display("L2 Test 7 - AW accepted before W");
        before_count = aw_first;
        w_delay = 8;
        write_word(line_address(0, 0) + 24, 32'h12345678, 1);
        w_delay = 0;
        if (aw_first == before_count) $fatal(1, "AW-before-W timing was not exercised");
        $display("L2 Test 8 - W accepted before AW");
        before_count = w_first;
        aw_delay = 8;
        write_word(line_address(0, 0) + 28, 32'h87654321, 1);
        aw_delay = 0;
        if (w_first == before_count) $fatal(1, "W-before-AW timing was not exercised");
        $display("L2 Test 9 - Write miss, allocate all words, write through");
        write_word(line_address(2, 0) + 28, 32'hcafe1234, 0);
        $display("L2 Test 10 - Read after write hit and write miss");
        read_word(0, line_address(0, 0) + 20, 1);
        read_word(0, line_address(2, 0) + 28, 1);
        $display("L2 Test 11 - Four ways filled without early eviction");
        for (int tag_number = 0; tag_number < 4; tag_number++) read_word(0, line_address(3, tag_number), 0);
        $display("L2 Test 12 - Hit changes independent LRU ordering");
        read_word(0, line_address(3, 0), 1);
        $display("L2 Test 13 - Fifth tag evicts current LRU only");
        read_word(0, line_address(3, 4), 0);
        if (lookup_way(line_address(3, 1)) >= 0) $fatal(1, "expected B to be evicted");
        $display("L2 Test 14 - Invalid ways preferred after reset");
        reset_cache();
        read_word(0, line_address(1, 0), 0);
        read_word(0, line_address(1, 1), 0);
        read_word(0, line_address(1, 0), 1);
        $display("L2 Test 15 - Simultaneous L1D and L1I reads");
        arbitration(0);
        $display("L2 Test 16 - L1D write versus L1D read");
        arbitration(1);
        $display("L2 Test 17 - L1D write versus L1I read");
        arbitration(2);
        $display("L2 Test 18 - Pending request blocked during read miss");
        blocking_miss(0);
        $display("L2 Test 19 - Pending request blocked during write miss and write-through");
        blocking_miss(1);
        $display("L2 Test 20 - Delayed ARREADY");
        before_count = ar_stalls;
        ar_delay = 7;
        read_word(0, line_address(0, 3), 0);
        ar_delay = 0;
        if (ar_stalls - before_count != 16 * 7)
            $fatal(1, "each of the 16 AR requests must stall exactly seven cycles");
        $display("L2 Test 21 - Delayed RVALID");
        before_count = r_waits;
        r_delay = 9;
        read_word(1, line_address(1, 3), 0);
        r_delay = 0;
        // r_waits includes the AR acceptance edge plus nine delayed edges.
        if (r_waits - before_count != 16 * (9 + 1))
            $fatal(1, "each of the 16 R responses must be delayed nine cycles");
        $display("L2 Test 22 - Delayed L1D and L1I RREADY");
        read_word(0, line_address(0, 3), 1, 9);
        read_word(1, line_address(1, 3), 1, 7);
        $display("L2 Test 23 - Delayed L1 BREADY");
        write_word(line_address(0, 3), 32'h13579bdf, 1, 11);
        $display("L2 extension - Delayed backend BVALID");
        before_count = b_waits;
        b_delay = 12;
        write_word(line_address(0, 3) + 4, 32'h2468ace0, 1);
        b_delay = 0;
        if (b_waits - before_count != 12 + 1)
            $fatal(1, "backend B response must be delayed twelve cycles");
        $display("L2 Test 24 - Last word and first word of adjacent lines");
        read_word(0, line_address(2, 3) + 60, 0);
        read_word(0, line_address(2, 3) + 64, 0);
        $display("L2 Test 25 - Same set, different tags");
        read_word(0, line_address(0, 4), 0);
        read_word(1, line_address(0, 5), 0);
        read_word(0, line_address(0, 4), 1);
        $display("L2 Test 26 - Different sets do not interfere");
        for (int set_number = 0; set_number < 3; set_number++) read_word(0, line_address(set_number, 6), 0);
        for (int set_number = 0; set_number < 3; set_number++) read_word(1, line_address(set_number, 6), 1);
    endtask

    task automatic integration_directed();
        reset_cache();
        $display("Integration Test 1 - Real DRAM read miss and complete refill");
        read_word(0, line_address(0, 0) + 20, 0);
        $display("Integration Test 2 - Read hit after refill");
        read_word(0, line_address(0, 0) + 20, 1);
        $display("Integration Test 3 - Write hit, real memory consistency, read back");
        write_word(line_address(0, 0) + 20, 32'hdeadbeef, 1);
        read_word(0, line_address(0, 0) + 20, 1);
        $display("Integration Test 4 - Write miss, refill, allocation and real write-through");
        write_word(line_address(1, 0) + 44, 32'hc001cafe, 0);
        read_word(0, line_address(1, 0) + 44, 1);
        $display("Integration Test 5 - Fill four ways and evict without a DRAM write");
        for (int tag_number = 0; tag_number < 4; tag_number++) read_word(0, line_address(3, tag_number), 0);
        read_word(0, line_address(3, 0), 1);
        read_word(0, line_address(3, 4), 0);
        $display("Integration Test 6 - L1I read miss and hit");
        read_word(1, line_address(2, 0) + 8, 0);
        read_word(1, line_address(2, 0) + 8, 1);
        $display("Integration Test 7 - Mixed L1I and L1D traffic with arbitration");
        read_word(1, line_address(0, 0));
        read_word(0, line_address(1, 0));
        write_word(line_address(2, 1), 32'hf00dcafe);
        read_word(1, line_address(3, 1));
        read_word(0, line_address(2, 1));
        read_word(1, line_address(0, 0));
        arbitration(0); arbitration(1); arbitration(2);
        $display("Integration Test 8 - Sequential words across six cache lines");
        for (int word_number = 0; word_number < 96; word_number++)
            read_word(word_number % 2, line_address(0, 6) + word_number * 4);
        $display("Integration Test 9 - Mixed reads/writes and architectural memory scoreboard");
        read_word(0, line_address(0, 2));
        read_word(0, line_address(1, 2));
        write_word(line_address(0, 2), 32'haabbccdd);
        read_word(0, line_address(0, 2));
        write_word(line_address(2, 2), 32'h11223344);
        read_word(1, line_address(2, 2));
        read_word(0, line_address(1, 2));
        write_word(line_address(3, 2), 32'h55667788, -1, 8);
        read_word(0, line_address(3, 2), 1, 8);
    endtask

    task automatic randomized_regression();
        logic [31:0] address, previous_address, data;
        int kind, set_number, tag_number, word_number, response_delay;
        previous_address = line_address(0, 0);
        $display("Random regression: backend=%s SEED=%0d RANDOM_ITERS=%0d", USE_REAL_DRAM ? "RTL" : "model", seed, random_iters);
        for (int iteration = 0; iteration < random_iters; iteration++) begin
            kind = next_random() % 3;
            set_number = next_random() % (NUM_SETS < 16 ? NUM_SETS : 16);
            tag_number = next_random() % 7;
            word_number = next_random() % 16;
            address = line_address(set_number, tag_number) + word_number * 4;
            if (next_random() % 4 == 0) address = (previous_address & 32'hffffffc0) + word_number * 4;
            data = next_random();
            response_delay = next_random() % 5;
            if (!USE_REAL_DRAM) begin
                ar_delay = next_random() % 5; r_delay = next_random() % 7;
                aw_delay = next_random() % 6; w_delay = next_random() % 6;
                b_delay = next_random() % 8;
            end
            case (kind)
                0: read_word(0, address, -1, response_delay);
                1: read_word(1, address, -1, response_delay);
                2: write_word(address, data, -1, response_delay);
            endcase
            previous_address = address;
        end
    endtask

    initial begin
        if (NUM_SETS < 4 || (NUM_SETS & (NUM_SETS - 1)) != 0 || CACHE_SIZE > 256*1024 ||
            CACHE_SIZE % 256 != 0 || L2_LATENCY < 1 || DRAM_LATENCY < 1)
            $fatal(1, "Use a power-of-two CACHE_SIZE from 1024 to 262144 and positive latencies");
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("RANDOM_ITERS=%d", random_iters)) begin end
        if (random_iters > 100000) $fatal(1, "RANDOM_ITERS must be from 0 to 100000");
        rng = seed == 0 ? 32'h6d2b79f5 : seed;
        for (int request_kind = 0; request_kind < 3; request_kind++)
            for (int outcome = 0; outcome < 2; outcome++) begin
                request_hit_cross[request_kind][outcome] = 0;
                replacement_cross[request_kind][outcome] = 0;
            end
        if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_l2);
        end
        axi_i.awaddr = 0; axi_i.awvalid = 0; axi_i.wdata = 0; axi_i.wvalid = 0;
        axi_i.wstrb = 4'hf; axi_i.bready = 0; axi_i.araddr = 0; axi_i.arvalid = 0; axi_i.rready = 0;
        axi_d.awaddr = 0; axi_d.awvalid = 0; axi_d.wdata = 0; axi_d.wvalid = 0;
        axi_d.wstrb = 4'hf; axi_d.bready = 0; axi_d.araddr = 0; axi_d.arvalid = 0; axi_d.rready = 0;
        for (int word_index = 0; word_index < NUM_WORDS; word_index++) begin
            reference_memory[word_index] = initial_word(word_index);
            g_backend.backend.memory[word_index] = initial_word(word_index);
        end
        if (USE_REAL_DRAM) integration_directed(); else protocol_directed();
        $display("Directed tests passed; starting seeded random traffic");
        randomized_regression();
        repeat (3) @(negedge clk);
        if (active || pending_aw || pending_w || int'(dut.state) != IDLE || int'(dut.owner) != 0)
            $fatal(1, "unfinished request at end of regression");
        for (int set_number = 0; set_number < NUM_SETS; set_number++) check_set(set_number);
        for (int word_index = 0; word_index < NUM_WORDS; word_index++)
            if (g_backend.backend.memory[word_index] !== reference_memory[word_index])
                $fatal(1, "unintended backing-memory modification address=%08x", word_index * 4);
        if (i_reads == 0 || d_reads == 0 || d_writes == 0 || read_hits == 0 || read_misses == 0 ||
            write_hits == 0 || write_misses == 0 || invalid_fills == 0 || evictions == 0 || l1_r_stalls == 0 || l1_b_stalls == 0)
            $fatal(1, "required transaction/replacement/response-stall coverage missing");
        if (!USE_REAL_DRAM && (aw_first == 0 || w_first == 0 || ar_stalls == 0 || r_waits == 0 ||
                              aw_stalls == 0 || w_stalls == 0 || b_waits == 0))
            $fatal(1, "required controlled-backend timing coverage missing");
        $display("Coverage: completed=%0d I_read=%0d D_read=%0d D_write=%0d read_hit/miss=%0d/%0d write_hit/miss=%0d/%0d",
                 completed, i_reads, d_reads, d_writes, read_hits, read_misses, write_hits, write_misses);
        $display("Coverage: DRAM_read/write=%0d/%0d invalid/LRU=%0d/%0d AW_before_W=%0d W_before_AW=%0d",
                 dram_reads, dram_writes, invalid_fills, evictions, aw_first, w_first);
        $display("Coverage cycles: AR_stall=%0d R_wait=%0d AW_stall=%0d W_stall=%0d B_wait=%0d L1_R_stall=%0d L1_B_stall=%0d",
                 ar_stalls, r_waits, aw_stalls, w_stalls, b_waits, l1_r_stalls, l1_b_stalls);
        for (int request_kind = 0; request_kind < 3; request_kind++)
            $display("Coverage cross kind=%s hit/miss=%0d/%0d invalid/LRU=%0d/%0d",
                     request_kind == 0 ? "I_read" : (request_kind == 1 ? "D_read" : "D_write"),
                     request_hit_cross[request_kind][1], request_hit_cross[request_kind][0],
                     replacement_cross[request_kind][0], replacement_cross[request_kind][1]);
        if (USE_REAL_DRAM) $display("PASS: tb_l2_integration");
        else $display("PASS: tb_l2_protocol");
        $finish;
    end

    initial begin
        // Cycle bound scales with user-selected latencies and random workload.
        // A stalled handshake therefore ends as a failure instead of hanging Tcl.
        #1;
        repeat (10000 + (random_iters + 300) * (16 * (DRAM_LATENCY + 32) + L2_LATENCY + 100)) @(posedge clk);
        $fatal(1, "L2 watchdog expired: state=%0d owner=%0d active_addr=%08x SEED=%0d", dut.state, dut.owner, active_addr, seed);
    end
endmodule

`timescale 1ns/1ps

// Drive the complete hierarchy through memory_system's CPU-facing ports. The
// testbench observes internal cache and AXI state only for protocol checking
// and scoreboarding; no replacement cache or interface is supplied.
//
// CPU contract: pulse i_read, d_read, or d_write for one clock while that L1 is
// IDLE; waitrequest must assert while busy and deassert with the CPU response.
// Instruction and data addresses occupy disjoint halves of memory. These tests
// do not assume coherence between L1I and dirty, write-back L1D lines.
module tb_memory_subsystem #(
    parameter int L1_CACHE_SIZE = 65536,
    parameter int L2_CACHE_SIZE = 262144,
    parameter int L1_LATENCY = 2,
    parameter int L2_LATENCY = 3,
    parameter int DRAM_LATENCY = 4
);
    localparam int MEM_SIZE = 1024 * 1024;
    localparam int WORDS = MEM_SIZE / 4;
    localparam int L1_SETS = L1_CACHE_SIZE / 256;
    localparam int L2_SETS = L2_CACHE_SIZE / 256;
    localparam int L1_STRIDE = L1_CACHE_SIZE / 4;
    localparam logic [31:0] DATA_BASE = 32'h0008_0000;
    localparam int LAST_DATA_TAG =
        (MEM_SIZE - 64 - DATA_BASE - (L1_SETS - 1) * 64) / L1_STRIDE;
    localparam longint REQUEST_TIMEOUT =
        1024 + 64 * (L1_LATENCY + L2_LATENCY + 16 * (DRAM_LATENCY + 16));

    logic clk = 0, rst_n = 0;
    logic i_read = 0, i_waitrequest;
    logic [31:0] i_addr = 0, i_data;
    logic d_read = 0, d_write = 0, d_waitrequest;
    logic [31:0] d_addr = DATA_BASE, d_wdata = 0, d_rdata;
    logic [3:0] d_wstrb = '1;
    always #5 clk = ~clk;

    memory_system #(
        .L1_CACHE_SIZE(L1_CACHE_SIZE),
        .L2_CACHE_SIZE(L2_CACHE_SIZE),
        .L1_LATENCY(L1_LATENCY),
        .L2_LATENCY(L2_LATENCY),
        .DRAM_LATENCY(DRAM_LATENCY),
        .DRAM_SIZE(MEM_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .i_read(i_read),
        .i_addr(i_addr),
        .i_data(i_data),
        .i_waitrequest(i_waitrequest),
        .d_read(d_read),
        .d_write(d_write),
        .d_addr(d_addr),
        .d_wdata(d_wdata),
        .d_wstrb(d_wstrb),
        .d_rdata(d_rdata),
        .d_waitrequest(d_waitrequest)
    );

    memory_subsystem_axi_monitor #(.READ_ONLY(1)) i_protocol (
        .clk(clk), .rst_n(rst_n), .axi(dut.axi_l1i_to_l2)
    );
    memory_subsystem_axi_monitor d_protocol (
        .clk(clk), .rst_n(rst_n), .axi(dut.axi_l1d_to_l2)
    );
    memory_subsystem_axi_monitor mem_protocol (
        .clk(clk), .rst_n(rst_n), .axi(dut.axi_l2_to_dram)
    );

    // Architectural memory changes at CPU store completion. Backing memory
    // changes only at a real DRAM write response; divergence while L1D is dirty
    // is expected. Neither scoreboard learns expected data from a DUT read.
    logic [31:0] architectural [0:WORDS-1];
    logic [31:0] backing [0:WORDS-1];
    bit written_set [0:L1_SETS-1];
    int unsigned seed = 1, random_iters = 200, rng;
    int unsigned cpu_i_reads = 0, cpu_d_reads = 0, cpu_d_writes = 0;
    int unsigned i_ar = 0, i_r = 0, d_ar = 0, d_r = 0;
    int unsigned d_aw = 0, d_w = 0, d_b = 0;
    int unsigned mem_ar = 0, mem_r = 0, mem_aw = 0, mem_w = 0, mem_b = 0;
    int unsigned contention = 0, directed_passed = 0;
    int unsigned address_range_checks = 0;
    int unsigned i_refill_word = 0, d_refill_word = 0, wb_word = 0;
    logic [31:0] i_line, d_line, wb_line, i_read_address, d_read_address, mem_read_address;
    logic [31:0] wb_address, wb_data, mem_write_address, mem_write_data;
    bit wb_aw_pending = 0, wb_w_pending = 0, wb_checked = 0, wb_committed = 0;
    bit mem_aw_pending = 0, mem_w_pending = 0;

    function automatic logic [31:0] initial_word(input int unsigned word_index);
        return 32'h6a09e667 ^ (word_index * 32'h9e3779b9) ^ (word_index << 9);
    endfunction

    function automatic logic [31:0] line_address(
        input bit data_region, input int set_number, input int tag_number
    );
        return (data_region ? DATA_BASE : 0) +
            tag_number * L1_STRIDE + (set_number % L1_SETS) * 64;
    endfunction

    function automatic int unsigned next_random();
        rng = rng ^ (rng << 13);
        rng = rng ^ (rng >> 17);
        rng = rng ^ (rng << 5);
        return rng;
    endfunction

    function automatic bit address_in_range(input logic [31:0] address);
        return !$isunknown(address) && address[1:0] == 2'b00 && address < MEM_SIZE;
    endfunction

    task automatic valid_address(input logic [31:0] address);
        if (!address_in_range(address))
            $fatal(1, "subsystem invalid address %08x", address);
    endtask

    task automatic check_address_range(input logic [31:0] address, input bit expected_valid);
        if (address_in_range(address) !== expected_valid)
            $fatal(1, "address range guard classified %08x incorrectly", address);
        address_range_checks++;
    endtask

    task automatic check_l1_set(input bit instruction, input int set_number);
        int unsigned word_index, tag_number;
        for (int way = 0; way < 4; way++) begin
            if (instruction ? dut.l1i.valid_array[set_number][way] : dut.l1d.valid_array[set_number][way]) begin
                tag_number = instruction ? int'(dut.l1i.tag_array[set_number][way]) :
                                           int'(dut.l1d.tag_array[set_number][way]);
                for (int word_number = 0; word_number < 16; word_number++) begin
                    word_index = (tag_number * L1_SETS + set_number) * 16 + word_number;
                    if (word_index >= WORDS) $fatal(1, "L1 installed an out-of-range tag");
                    if (instruction) begin
                        if (dut.l1i.data_array[set_number][way][word_number*32 +: 32] !== architectural[word_index])
                            $fatal(1, "L1I line mismatch address=%08x", word_index * 4);
                    end else if (dut.l1d.data_array[set_number][way][word_number*32 +: 32] !== architectural[word_index])
                        $fatal(1, "L1D line mismatch address=%08x", word_index * 4);
                end
            end
        end
    endtask

    // Sample bus handshakes before NBA, just as the actual RTL does. CPU
    // reference writes and driver inputs change on falling edges.
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.axi_l1i_to_l2.arvalid && dut.axi_l1i_to_l2.arready) begin
                valid_address(dut.axi_l1i_to_l2.araddr);
                if (dut.axi_l1i_to_l2.araddr >= DATA_BASE) $fatal(1, "instruction traffic entered data region");
                if (i_refill_word == 0) i_line = dut.axi_l1i_to_l2.araddr & 32'hffff_ffc0;
                if (dut.axi_l1i_to_l2.araddr !== i_line + i_refill_word * 4)
                    $fatal(1, "L1I refill must request all 16 words in order");
                i_refill_word = (i_refill_word + 1) % 16;
                i_read_address = dut.axi_l1i_to_l2.araddr;
                i_ar++;
            end
            if (dut.axi_l1i_to_l2.rvalid && dut.axi_l1i_to_l2.rready) begin
                if (dut.axi_l1i_to_l2.rdata !== architectural[i_read_address / 4])
                    $fatal(1, "L1I refill data mismatch at %08x", i_read_address);
                i_r++;
            end
            if (dut.axi_l1d_to_l2.arvalid && dut.axi_l1d_to_l2.arready) begin
                valid_address(dut.axi_l1d_to_l2.araddr);
                if (dut.axi_l1d_to_l2.araddr < DATA_BASE) $fatal(1, "data traffic entered instruction region");
                if (d_refill_word == 0) d_line = dut.axi_l1d_to_l2.araddr & 32'hffff_ffc0;
                if (dut.axi_l1d_to_l2.araddr !== d_line + d_refill_word * 4)
                    $fatal(1, "L1D refill must request all 16 words in order");
                d_refill_word = (d_refill_word + 1) % 16;
                d_read_address = dut.axi_l1d_to_l2.araddr;
                d_ar++;
            end
            if (dut.axi_l1d_to_l2.rvalid && dut.axi_l1d_to_l2.rready) begin
                if (dut.axi_l1d_to_l2.rdata !== architectural[d_read_address / 4])
                    $fatal(1, "L1D refill data mismatch at %08x", d_read_address);
                d_r++;
            end
            if (dut.axi_l1d_to_l2.awvalid && dut.axi_l1d_to_l2.awready) begin
                valid_address(dut.axi_l1d_to_l2.awaddr);
                if (dut.axi_l1d_to_l2.awaddr < DATA_BASE) $fatal(1, "writeback entered instruction region");
                if (wb_word == 0) wb_line = dut.axi_l1d_to_l2.awaddr & 32'hffff_ffc0;
                if (dut.axi_l1d_to_l2.awaddr !== wb_line + wb_word * 4)
                    $fatal(1, "dirty victim writeback must transfer all 16 words in order");
                wb_word = (wb_word + 1) % 16;
                wb_address = dut.axi_l1d_to_l2.awaddr;
                wb_aw_pending = 1;
                d_aw++;
            end
            if (dut.axi_l1d_to_l2.wvalid && dut.axi_l1d_to_l2.wready) begin
                wb_data = dut.axi_l1d_to_l2.wdata;
                wb_w_pending = 1;
                d_w++;
            end
            if (wb_aw_pending && wb_w_pending && !wb_checked) begin
                if (wb_data !== architectural[wb_address / 4])
                    $fatal(1, "dirty writeback mismatch at %08x got=%08x expected=%08x",
                           wb_address, wb_data, architectural[wb_address / 4]);
                wb_checked = 1;
                wb_committed = 0;
            end

            if (dut.axi_l2_to_dram.arvalid && dut.axi_l2_to_dram.arready) begin
                valid_address(dut.axi_l2_to_dram.araddr);
                if (int'(dut.l2.state) != 2 && int'(dut.l2.state) != 5)
                    $fatal(1, "DRAM read outside L2 refill");
                if (dut.axi_l2_to_dram.araddr !==
                    (((int'(dut.l2.state) == 5 ? dut.l2.writeaddr : dut.l2.readaddr) & 32'hffff_ffc0) +
                     int'(dut.l2.refill_count) * 4))
                    $fatal(1, "L2 refill address sequence mismatch");
                mem_read_address = dut.axi_l2_to_dram.araddr;
                mem_ar++;
            end
            if (dut.axi_l2_to_dram.rvalid && dut.axi_l2_to_dram.rready) begin
                if (dut.axi_l2_to_dram.rdata !== backing[mem_read_address / 4])
                    $fatal(1, "real DRAM read mismatch at %08x", mem_read_address);
                mem_r++;
            end
            if (dut.axi_l2_to_dram.awvalid && dut.axi_l2_to_dram.awready) begin
                valid_address(dut.axi_l2_to_dram.awaddr);
                mem_write_address = dut.axi_l2_to_dram.awaddr;
                mem_aw_pending = 1;
                mem_aw++;
            end
            if (dut.axi_l2_to_dram.wvalid && dut.axi_l2_to_dram.wready) begin
                mem_write_data = dut.axi_l2_to_dram.wdata;
                mem_w_pending = 1;
                mem_w++;
            end
            if (dut.axi_l2_to_dram.bvalid && dut.axi_l2_to_dram.bready) begin
                if (!mem_aw_pending || !mem_w_pending || !wb_checked || wb_committed ||
                    mem_write_address !== wb_address || mem_write_data !== wb_data)
                    $fatal(1, "L2 write-through does not match one pending L1D writeback");
                if (dut.dram.memory[mem_write_address / 4] !== mem_write_data)
                    $fatal(1, "real DRAM failed to commit writeback at %08x", mem_write_address);
                backing[mem_write_address / 4] = mem_write_data;
                wb_committed = 1;
                mem_aw_pending = 0;
                mem_w_pending = 0;
                mem_b++;
            end
            if (dut.axi_l1d_to_l2.bvalid && dut.axi_l1d_to_l2.bready) begin
                if (!wb_checked || !wb_committed)
                    $fatal(1, "L1D writeback acknowledged before real DRAM completion");
                wb_aw_pending = 0;
                wb_w_pending = 0;
                wb_checked = 0;
                wb_committed = 0;
                d_b++;
            end

            if (int'(dut.l2.state) != 0 &&
                (dut.axi_l1i_to_l2.arready || dut.axi_l1d_to_l2.arready || dut.axi_l1d_to_l2.awready || dut.axi_l1d_to_l2.wready))
                $fatal(1, "blocking L2 accepted a request while busy");
            if (int'(dut.l2.state) == 0 && dut.axi_l1i_to_l2.arvalid && dut.axi_l1d_to_l2.arvalid &&
                !dut.axi_l1d_to_l2.awvalid && !dut.axi_l1d_to_l2.wvalid && !dut.l2.aw_received && !dut.l2.w_received) begin
                if (dut.axi_l1i_to_l2.arready || !dut.axi_l1d_to_l2.arready)
                    $fatal(1, "simultaneous L1 misses did not give L1D priority");
                contention++;
            end
        end
    end

    task automatic fetch(input logic [31:0] address);
        longint elapsed;
        int unsigned before_reads;
        valid_address(address);
        if (address >= DATA_BASE) $fatal(1, "fetch must use instruction region");
        @(negedge clk);
        if (int'(dut.l1i.state) != 0) $fatal(1, "fetch launched while L1I was busy");
        before_reads = i_ar;
        i_addr = address;
        i_read = 1;
        @(posedge clk);
        #1;
        if (i_waitrequest !== 1'b1) $fatal(1, "L1I failed to assert waitrequest after request");
        @(negedge clk);
        i_read = 0;
        elapsed = 0;
        while (i_waitrequest !== 1'b0) begin
            if ($isunknown(i_waitrequest)) $fatal(1, "unknown L1I waitrequest");
            if (elapsed++ >= REQUEST_TIMEOUT) $fatal(1, "L1I completion timeout at %08x", address);
            @(negedge clk);
        end
        if (i_data !== architectural[address / 4])
            $fatal(1, "CPU instruction mismatch at %08x got=%08x expected=%08x",
                   address, i_data, architectural[address / 4]);
        if (i_ar - before_reads != 0 && i_ar - before_reads != 16)
            $fatal(1, "CPU fetch produced an incomplete or duplicate L1I refill");
        check_l1_set(1, (address / 64) % L1_SETS);
        cpu_i_reads++;
        @(negedge clk);
        if (int'(dut.l1i.state) != 0) $fatal(1, "L1I did not return to IDLE after CPU response");
    endtask

    task automatic data_access(input bit is_write, input logic [31:0] address,
                               input logic [31:0] value = 0);
        longint elapsed;
        int unsigned before_reads, before_writes;
        valid_address(address);
        if (address < DATA_BASE) $fatal(1, "data access must use data region");
        @(negedge clk);
        if (int'(dut.l1d.state) != 0) $fatal(1, "data access launched while L1D was busy");
        before_reads = d_ar;
        before_writes = d_b;
        d_addr = address;
        d_wdata = value;
        d_write = is_write;
        d_read = !is_write;
        @(posedge clk);
        #1;
        if (d_waitrequest !== 1'b1) $fatal(1, "L1D failed to assert waitrequest after request");
        @(negedge clk);
        d_write = 0;
        d_read = 0;
        elapsed = 0;
        while (d_waitrequest !== 1'b0) begin
            if ($isunknown(d_waitrequest)) $fatal(1, "unknown L1D waitrequest");
            if (elapsed++ >= REQUEST_TIMEOUT) $fatal(1, "L1D completion timeout at %08x", address);
            @(negedge clk);
        end
        if (is_write) begin
            architectural[address / 4] = value;
            written_set[(address / 64) % L1_SETS] = 1;
            cpu_d_writes++;
        end else begin
            if (d_rdata !== architectural[address / 4])
                $fatal(1, "CPU data mismatch at %08x got=%08x expected=%08x",
                       address, d_rdata, architectural[address / 4]);
            cpu_d_reads++;
        end
        if (d_ar - before_reads != 0 && d_ar - before_reads != 16)
            $fatal(1, "CPU data access produced an incomplete or duplicate L1D refill");
        if (d_b - before_writes != 0 && d_b - before_writes != 16)
            $fatal(1, "CPU data access must write back zero or exactly 16 victim words");
        check_l1_set(0, (address / 64) % L1_SETS);
        @(negedge clk);
        if (int'(dut.l1d.state) != 0) $fatal(1, "L1D did not return to IDLE after CPU response");
    endtask

    task automatic passed(input string description);
        directed_passed++;
        $display("Subsystem Test %0d PASS: %s", directed_passed, description);
    endtask

    task automatic directed_tests();
        int unsigned before_i, before_d, before_mem, before_writes, before_contention;
        logic [31:0] address, old_value;
        before_i = i_ar; before_mem = mem_ar;
        fetch(line_address(0, 0, 0) + 20);
        if (i_ar - before_i != 16 || mem_ar - before_mem != 16)
            $fatal(1, "cold instruction miss must generate 16 L2 reads and 16 DRAM reads");
        passed("cold L1I/L2 miss and full line refills");

        before_d = d_ar; before_mem = mem_ar;
        data_access(0, line_address(1, 1, 0) + 28);
        if (d_ar - before_d != 16 || mem_ar - before_mem != 16)
            $fatal(1, "cold data miss must generate 16 L2 reads and 16 DRAM reads");
        passed("cold L1D/L2 miss and full line refills");

        before_i = i_ar; before_d = d_ar; before_mem = mem_ar;
        fetch(line_address(0, 0, 0) + 60);
        data_access(0, line_address(1, 1, 0) + 4);
        if (i_ar != before_i || d_ar != before_d || mem_ar != before_mem)
            $fatal(1, "L1 read hit unexpectedly accessed L2/DRAM");
        passed("L1 instruction/data hits and same-line word selection");

        for (int tag_number = 0; tag_number < 5; tag_number++)
            fetch(line_address(0, 2, tag_number));
        before_i = i_ar; before_mem = mem_ar;
        fetch(line_address(0, 2, 0));
        if (i_ar - before_i != 16 || mem_ar != before_mem)
            $fatal(1, "clean L1 eviction should retain its line in L2");
        passed("L1 eviction followed by an L2 hit");

        address = line_address(1, 1, 0) + 28;
        old_value = dut.dram.memory[address / 4];
        before_d = d_ar; before_writes = mem_b;
        data_access(1, address, 32'hdeadbeef);
        data_access(0, address);
        if (d_ar != before_d || mem_b != before_writes || dut.dram.memory[address / 4] !== old_value)
            $fatal(1, "L1D write hit must remain local until dirty eviction");
        passed("write-back hit remains local and CPU read sees latest store");

        before_writes = mem_b;
        for (int tag_number = 1; tag_number <= 4; tag_number++)
            data_access(0, line_address(1, 1, tag_number));
        if (mem_b - before_writes != 16 || dut.dram.memory[address / 4] !== 32'hdeadbeef)
            $fatal(1, "dirty victim must write back 16 words through L2 to real DRAM");
        data_access(0, address);
        passed("dirty eviction, real write-through, and read after eviction");

        address = line_address(1, 3, 0) + 44;
        old_value = dut.dram.memory[address / 4];
        before_d = d_ar; before_writes = mem_b;
        data_access(1, address, 32'hc001cafe);
        data_access(0, address);
        if (d_ar - before_d != 16 || mem_b != before_writes || dut.dram.memory[address / 4] !== old_value)
            $fatal(1, "write allocation must refill then retain dirty data locally");
        for (int tag_number = 1; tag_number <= 4; tag_number++)
            data_access(0, line_address(1, 3, tag_number));
        if (mem_b - before_writes != 16 || dut.dram.memory[address / 4] !== 32'hc001cafe)
            $fatal(1, "write-allocated dirty line did not survive eviction");
        data_access(0, address);
        passed("write allocate, dirty refill replacement, and read-back");

        before_i = i_ar; before_d = d_ar; before_contention = contention;
        fork
            fetch(line_address(0, 0, 7) + 12);
            data_access(0, line_address(1, 1, 7) + 36);
        join
        if (i_ar - before_i != 16 || d_ar - before_d != 16 || contention == before_contention)
            $fatal(1, "simultaneous instruction/data misses did not exercise L2 arbitration");
        passed("concurrent L1I/L1D misses, ownership, and arbitration");

        data_access(0, line_address(1, 2, 7) + 60);
        data_access(0, line_address(1, 2, 7) + 64);
        passed("adjacent cache-line boundary");

        address = MEM_SIZE - 4;
        before_d = d_ar; before_mem = mem_ar; before_writes = mem_b;
        old_value = dut.dram.memory[address / 4];
        data_access(0, address);
        if (d_ar - before_d != 16 || mem_ar - before_mem != 16)
            $fatal(1, "last valid word must refill only its in-range cache line");
        data_access(1, address, 32'hb0adf00d);
        data_access(0, address);
        if (dut.dram.memory[address / 4] !== old_value || mem_b != before_writes)
            $fatal(1, "last-word store must remain dirty in L1D before eviction");
        for (int tag_number = LAST_DATA_TAG - 4; tag_number < LAST_DATA_TAG; tag_number++)
            data_access(0, line_address(1, L1_SETS - 1, tag_number));
        if (mem_b - before_writes != 16 || dut.dram.memory[address / 4] !== 32'hb0adf00d)
            $fatal(1, "last valid line did not write back through L2 to DRAM");
        data_access(0, address);
        passed("last valid word, testbench first-invalid guard, and in-range dirty write-back");
    endtask

    task automatic random_tests();
        logic [31:0] address, value;
        int kind, set_number, tag_number, word_number;
        for (int iteration = 0; iteration < random_iters; iteration++) begin
            kind = next_random() % 3;
            set_number = next_random() % (L1_SETS < 8 ? L1_SETS : 8);
            tag_number = next_random() % 8;
            word_number = next_random() % 16;
            address = line_address(kind != 0, set_number, tag_number) + word_number * 4;
            value = next_random();
            case (kind)
                0: fetch(address);
                1: data_access(0, address);
                2: begin
                    data_access(1, address, value);
                    data_access(0, address);
                end
            endcase
        end
    endtask

    task automatic drain_dirty_lines();
        // Four previously unused tags displace every original way in each
        // written set using normal CPU loads. Reset must not be used to flush.
        for (int set_number = 0; set_number < L1_SETS; set_number++)
            if (written_set[set_number])
                for (int tag_number = 24; tag_number < 28; tag_number++)
                    data_access(0, line_address(1, set_number, tag_number));
        for (int set_number = 0; set_number < L1_SETS; set_number++) begin
            check_l1_set(1, set_number);
            check_l1_set(0, set_number);
            for (int way = 0; way < 4; way++)
                if (dut.l1d.valid_array[set_number][way] && dut.l1d.dirty_array[set_number][way] !== 1'b0)
                    $fatal(1, "dirty line remains after conflict-read drain");
        end
        for (int word_index = 0; word_index < WORDS; word_index++)
            if (backing[word_index] !== architectural[word_index] ||
                dut.dram.memory[word_index] !== architectural[word_index])
                $fatal(1, "final architectural/backing/DRAM mismatch at %08x", word_index * 4);
        for (int set_number = 0; set_number < L2_SETS; set_number++)
            for (int way = 0; way < 4; way++)
                if (dut.l2.valid_array[set_number][way])
                    for (int word_number = 0; word_number < 16; word_number++) begin
                        int unsigned word_index;
                        word_index = (int'(dut.l2.tag_array[set_number][way]) * L2_SETS + set_number) * 16 + word_number;
                        if (word_index >= WORDS ||
                            dut.l2.data_array[set_number][way][word_number*32 +: 32] !== architectural[word_index])
                            $fatal(1, "L2 differs from architectural memory after dirty drain");
                    end
    endtask

    initial begin : regression
        string wave_file;
        if (L1_CACHE_SIZE < 1024 || L1_CACHE_SIZE > 65536 ||
            (L1_CACHE_SIZE & (L1_CACHE_SIZE - 1)) != 0 ||
            L2_CACHE_SIZE < 4 * L1_CACHE_SIZE || L2_CACHE_SIZE > 262144 ||
            (L2_CACHE_SIZE & (L2_CACHE_SIZE - 1)) != 0 ||
            L1_LATENCY < 1 || L2_LATENCY < 1 || DRAM_LATENCY < 1)
            $fatal(1, "subsystem requires power-of-two L1 1024..65536, L2 4*L1..262144, positive latencies");
        check_address_range(MEM_SIZE - 4, 1'b1);
        check_address_range(MEM_SIZE, 1'b0);
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("RANDOM_ITERS=%d", random_iters)) begin end
        if (random_iters > 100000) $fatal(1, "RANDOM_ITERS must be in 0..100000");
        rng = seed == 0 ? 32'h1 : seed;
        if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0, tb_memory_subsystem);
        end
        i_addr = 0; i_read = 0;
        d_addr = DATA_BASE; d_wdata = 0; d_read = 0; d_write = 0;
        for (int word_index = 0; word_index < WORDS; word_index++) begin
            architectural[word_index] = initial_word(word_index);
            backing[word_index] = initial_word(word_index);
            dut.dram.memory[word_index] = initial_word(word_index);
        end
        for (int set_number = 0; set_number < L1_SETS; set_number++) written_set[set_number] = 0;
        repeat (5) @(negedge clk);
        if (int'(dut.l1i.state) != 0 || int'(dut.l1d.state) != 0 || int'(dut.l2.state) != 0 ||
            int'(dut.dram.state) != 0 || i_waitrequest !== 1'b0 || d_waitrequest !== 1'b0)
            $fatal(1, "subsystem failed reset/idle checks");
        for (int set_number = 0; set_number < L1_SETS; set_number++)
            for (int way = 0; way < 4; way++)
                if (dut.l1i.valid_array[set_number][way] !== 1'b0 ||
                    dut.l1d.valid_array[set_number][way] !== 1'b0 ||
                    dut.l1d.dirty_array[set_number][way] !== 1'b0 ||
                    int'(dut.l1i.lru_rank[set_number][way]) != way ||
                    int'(dut.l1d.lru_rank[set_number][way]) != way)
                    $fatal(1, "L1 reset valid/dirty/LRU state is incorrect");
        rst_n = 1;
        $display("tb_memory_subsystem: L1=%0d L2=%0d latencies=%0d/%0d/%0d SEED=%0d RANDOM_ITERS=%0d",
                 L1_CACHE_SIZE, L2_CACHE_SIZE, L1_LATENCY, L2_LATENCY, DRAM_LATENCY, seed, random_iters);
        directed_tests();
        $display("Subsystem directed tests passed; starting random CPU traffic");
        random_tests();
        drain_dirty_lines();
        repeat (3) @(negedge clk);
        if (directed_passed != 10 || address_range_checks != 2 ||
            cpu_i_reads == 0 || cpu_d_reads == 0 || cpu_d_writes == 0 ||
            i_ar != i_r || d_ar != d_r || mem_ar != mem_r || d_aw != d_w || d_aw != d_b ||
            mem_aw != mem_w || mem_aw != mem_b || mem_b != d_b || mem_b == 0 ||
            i_refill_word != 0 || d_refill_word != 0 || wb_word != 0 || wb_aw_pending || wb_w_pending ||
            mem_aw_pending || mem_w_pending || int'(dut.l1i.state) != 0 || int'(dut.l1d.state) != 0 ||
            int'(dut.l2.state) != 0 || int'(dut.dram.state) != 0)
            $fatal(1, "subsystem unfinished/duplicate transactions or mandatory coverage missing");
        $display("Subsystem coverage: CPU I_read/D_read/D_write=%0d/%0d/%0d L1I/L1D_refill_words=%0d/%0d writeback_words=%0d DRAM_read/write=%0d/%0d contention=%0d address_range_checks=%0d",
                 cpu_i_reads, cpu_d_reads, cpu_d_writes, i_ar, d_ar, d_b, mem_ar, mem_b,
                 contention, address_range_checks);
        $display("PASS: tb_memory_subsystem");
        $finish;
    end

    initial begin
        #1;
        repeat ((longint'(random_iters) * 2 + L1_SETS * 4 + 512) * REQUEST_TIMEOUT) @(posedge clk);
        $fatal(1, "subsystem global watchdog: L1I=%0d L1D=%0d L2=%0d DRAM=%0d seed=%0d",
               dut.l1i.state, dut.l1d.state, dut.l2.state, dut.dram.state, seed);
    end
endmodule

// Common blocking AXI checks. BRESP and WSTRB are intentionally outside these
// checks: real DRAM currently leaves BRESP undriven, and writes are full words.
module memory_subsystem_axi_monitor #(
    parameter bit READ_ONLY = 0
)(
    input logic clk, rst_n,
    axi_lite_if axi
);
    bit read_pending = 0, aw_pending = 0, w_pending = 0;
    bit stall_ar = 0, stall_aw = 0, stall_w = 0, stall_r = 0, stall_b = 0;
    logic [31:0] held_ar, held_aw, held_w, held_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            read_pending = 0; aw_pending = 0; w_pending = 0;
            stall_ar = 0; stall_aw = 0; stall_w = 0; stall_r = 0; stall_b = 0;
        end else begin
            if (READ_ONLY && (axi.awvalid || axi.wvalid)) $fatal(1, "%m instruction path attempted a write");
            if (stall_ar && (axi.arvalid !== 1'b1 || axi.araddr !== held_ar))
                $fatal(1, "%m AR changed under backpressure");
            if (stall_aw && (axi.awvalid !== 1'b1 || axi.awaddr !== held_aw))
                $fatal(1, "%m AW changed under backpressure");
            if (stall_w && (axi.wvalid !== 1'b1 || axi.wdata !== held_w))
                $fatal(1, "%m W changed under backpressure");
            if (stall_r && (axi.rvalid !== 1'b1 || axi.rdata !== held_r))
                $fatal(1, "%m R changed under backpressure");
            if (stall_b && axi.bvalid !== 1'b1) $fatal(1, "%m B disappeared under backpressure");
            if (axi.arvalid && axi.arready) begin
                if (read_pending || aw_pending || w_pending) $fatal(1, "%m duplicate/overlapping AR");
                read_pending = 1;
            end
            if (axi.awvalid && axi.awready) begin
                if (read_pending || aw_pending) $fatal(1, "%m duplicate/overlapping AW");
                aw_pending = 1;
            end
            if (axi.wvalid && axi.wready) begin
                if (read_pending || w_pending) $fatal(1, "%m duplicate/overlapping W");
                w_pending = 1;
            end
            if (axi.rvalid) begin
                if (!read_pending) $fatal(1, "%m R response without AR");
                if (axi.rready) read_pending = 0;
            end
            if (!READ_ONLY && axi.bvalid) begin
                if (!aw_pending || !w_pending) $fatal(1, "%m B response before both AW and W");
                if (axi.bready) begin aw_pending = 0; w_pending = 0; end
            end
            stall_ar = axi.arvalid && !axi.arready; held_ar = axi.araddr;
            stall_aw = axi.awvalid && !axi.awready; held_aw = axi.awaddr;
            stall_w = axi.wvalid && !axi.wready; held_w = axi.wdata;
            stall_r = axi.rvalid && !axi.rready; held_r = axi.rdata;
            stall_b = !READ_ONLY && axi.bvalid && !axi.bready;
        end
    end
endmodule

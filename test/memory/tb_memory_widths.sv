`timescale 1ns/1ps

// Focused L1D -> L2 -> DRAM check at the default and widened bus widths.
// The testbench is built twice by run_memory_widths.tcl. With LINE_SIZE kept
// at 64 bytes, a wider DATA_WIDTH must reduce the refill beat count while
// preserving byte-addressed word selection and dirty writeback.
module tb_memory_widths #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
);
    localparam int LINE_SIZE = 64;
    localparam int MEM_SIZE = 1024 * 1024;
    localparam int WORD_BYTES = DATA_WIDTH / 8;
    localparam int BYTE_OFFSET_BITS = $clog2(WORD_BYTES);
    localparam int WORDS_PER_LINE = LINE_SIZE / WORD_BYTES;
    localparam int STORE_BYTE_OFFSET = (WORDS_PER_LINE / 2) * WORD_BYTES;
    localparam int L1_CACHE_SIZE = 1024;
    localparam int L2_CACHE_SIZE = 4096;
    localparam int L1_STRIDE = L1_CACHE_SIZE / 4;
    localparam int TIMEOUT_CYCLES = 5000;
    localparam logic [ADDR_WIDTH-1:0] BASE = ADDR_WIDTH'(32'h0000_1000);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic d_read = 1'b0;
    logic d_write = 1'b0;
    logic [ADDR_WIDTH-1:0] d_addr = '0;
    logic [DATA_WIDTH-1:0] d_wdata = '0;
    logic [DATA_WIDTH/8-1:0] d_wstrb = '1;
    logic [DATA_WIDTH-1:0] d_rdata;
    logic d_waitrequest;

    always #5 clk = ~clk;

    memory_system #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_SIZE(LINE_SIZE),
        .NUM_WAYS(4),
        .L1_CACHE_SIZE(L1_CACHE_SIZE),
        .L2_CACHE_SIZE(L2_CACHE_SIZE),
        .L1_LATENCY(1),
        .L2_LATENCY(1),
        .DRAM_LATENCY(1),
        .DRAM_SIZE(MEM_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .i_read(1'b0),
        .i_addr('0),
        .i_data(),
        .i_waitrequest(),
        .d_read(d_read),
        .d_write(d_write),
        .d_addr(d_addr),
        .d_wdata(d_wdata),
        .d_wstrb(d_wstrb),
        .d_rdata(d_rdata),
        .d_waitrequest(d_waitrequest)
    );

    function automatic logic [DATA_WIDTH-1:0] initial_word(input int unsigned word_index);
        logic [63:0] value;
        value = 64'hd1b5_4a32_d192_ed03 ^
                (64'(word_index) * 64'h9e37_79b9_7f4a_7c15);
        return DATA_WIDTH'(value);
    endfunction

    task automatic read_word(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [DATA_WIDTH-1:0] expected
    );
        int elapsed;
        @(negedge clk);
        if (d_waitrequest !== 1'b0)
            $fatal(1, "data port was busy before read at %h", address);
        d_addr = address;
        d_read = 1'b1;
        @(posedge clk);
        #1;
        if (d_waitrequest !== 1'b1)
            $fatal(1, "L1D did not assert waitrequest after read at %h", address);
        @(negedge clk);
        d_read = 1'b0;
        elapsed = 0;
        while (d_waitrequest !== 1'b0) begin
            if (elapsed++ >= TIMEOUT_CYCLES)
                $fatal(1, "read timed out at %h", address);
            @(negedge clk);
        end
        if (d_rdata !== expected)
            $fatal(1, "read mismatch addr=%h got=%h expected=%h",
                   address, d_rdata, expected);
        @(negedge clk);
    endtask

    task automatic write_word(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [DATA_WIDTH-1:0] value
    );
        int elapsed;
        @(negedge clk);
        if (d_waitrequest !== 1'b0)
            $fatal(1, "data port was busy before write at %h", address);
        d_addr = address;
        d_wdata = value;
        d_write = 1'b1;
        @(posedge clk);
        #1;
        if (d_waitrequest !== 1'b1)
            $fatal(1, "L1D did not assert waitrequest after write at %h", address);
        @(negedge clk);
        d_write = 1'b0;
        elapsed = 0;
        while (d_waitrequest !== 1'b0) begin
            if (elapsed++ >= TIMEOUT_CYCLES)
                $fatal(1, "write timed out at %h", address);
            @(negedge clk);
        end
        @(negedge clk);
    endtask

    initial begin : run_test
        logic [ADDR_WIDTH-1:0] address;
        logic [DATA_WIDTH-1:0] replacement;
        logic [DATA_WIDTH-1:0] old_backing;
        int unsigned word_index;

        if (ADDR_WIDTH < 32 || DATA_WIDTH < 32 || DATA_WIDTH % 8 != 0 ||
            (DATA_WIDTH & (DATA_WIDTH - 1)) != 0 || WORDS_PER_LINE < 1)
            $fatal(1, "unsupported width pair ADDR_WIDTH=%0d DATA_WIDTH=%0d",
                   ADDR_WIDTH, DATA_WIDTH);

        // Seed real DRAM contents independently of returned cache data.
        for (int index = 0; index < MEM_SIZE / WORD_BYTES; index++)
            dut.dram.memory[index] = initial_word(index);

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Read every data beat in one cache line to verify widened word offset
        // decode, refill ordering, and the CPU-facing result width.
        for (int word = 0; word < WORDS_PER_LINE; word++) begin
            address = BASE + word * WORD_BYTES;
            word_index = int'(address >> BYTE_OFFSET_BITS);
            read_word(address, initial_word(word_index));
        end

        // A store updates the dirty L1D line. It must be visible to a later
        // load immediately and reach DRAM when the line is evicted.
        address = BASE + ADDR_WIDTH'(STORE_BYTE_OFFSET);
        word_index = int'(address >> BYTE_OFFSET_BITS);
        old_backing = dut.dram.memory[word_index];
        replacement = DATA_WIDTH'(64'hface_cafe_1234_5678);
        write_word(address, replacement);
        if (dut.dram.memory[word_index] !== old_backing)
            $fatal(1, "dirty L1D store reached DRAM before eviction");
        read_word(address, replacement);

        // Addresses separated by one L1 set stride map to the same set.
        // Four fills evict the dirty base line from this four-way cache.
        for (int tag = 1; tag <= 4; tag++) begin
            logic [ADDR_WIDTH-1:0] conflict_address;
            conflict_address = BASE + tag * L1_STRIDE;
            word_index = int'(conflict_address >> BYTE_OFFSET_BITS);
            read_word(conflict_address, initial_word(word_index));
        end
        if (dut.dram.memory[int'(address >> BYTE_OFFSET_BITS)] !== replacement)
            $fatal(1, "dirty L1D value did not reach DRAM after eviction");

        read_word(address, replacement);

        // A high address outside DRAM must not truncate to a valid backing
        // word when ADDR_WIDTH is wider than the physical memory range.
        read_word(ADDR_WIDTH'(MEM_SIZE), '0);
        if (dut.dram.memory[0] !== initial_word(0))
            $fatal(1, "out-of-range address aliased the first DRAM word");

        $display("PASS: tb_memory_widths ADDR_WIDTH=%0d DATA_WIDTH=%0d WORDS_PER_LINE=%0d",
                 ADDR_WIDTH, DATA_WIDTH, WORDS_PER_LINE);
        $finish;
    end
endmodule

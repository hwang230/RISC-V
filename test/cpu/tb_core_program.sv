`timescale 1ns/1ps
// Same core/program scoreboard with either controlled memory or the real caches.
module tb_core_program #(
    parameter int L1_CACHE_SIZE = 64 * 1024,
    parameter int L2_CACHE_SIZE = 256 * 1024,
    parameter int L1_LATENCY = 1,
    parameter int L2_LATENCY = 5,
    parameter int DRAM_LATENCY = 80,
    parameter int DRAM_SIZE = 1024 * 1024
);
    localparam int L1_SETS = L1_CACHE_SIZE / (64 * 4);
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    core #(
        .L1_CACHE_SIZE(L1_CACHE_SIZE),
        .L2_CACHE_SIZE(L2_CACHE_SIZE),
        .L1_LATENCY(L1_LATENCY),
        .L2_LATENCY(L2_LATENCY),
        .DRAM_LATENCY(DRAM_LATENCY),
        .DRAM_SIZE(DRAM_SIZE)
    ) dut(.clk(clk), .rst_n(rst_n));

    logic [127:0] expected [0:9999]; // PC, destination (32 = no write), value, instruction
    logic [95:0] expected_stores [0:9999]; // byte address, lane-positioned data, byte enables
    logic [31:0] architectural_regs [0:31];
    logic [31:0] architectural_memory [0:262143];
    bit dirty_word [0:262143];
    string image, trace_file, stores_file, wave_file;
    int trace_count, store_count, stop_pc, retired=0, stores=0;
    int cycles=0, max_cycles=2000000, i_stalls=0, d_stalls=0;
    int hazards=0, redirects=0, wb_during_wait=0;
    real ipc;

    function automatic logic [31:0] memory_word(input int word_index);
`ifdef CORE_STANDALONE
        return dut.u_memory_system.memory[word_index];
`else
        // L1D is write-back: dirty data need not have reached DRAM yet.
        for (int way=0; way<4; way++)
            if (dut.u_memory_system.l1d.valid_array[(word_index/16)%L1_SETS][way] &&
                int'(dut.u_memory_system.l1d.tag_array[(word_index/16)%L1_SETS][way]) == word_index/(16*L1_SETS))
                return dut.u_memory_system.l1d.data_array[(word_index/16)%L1_SETS][way][(word_index%16)*32 +: 32];
        return dut.u_memory_system.dram.memory[word_index];
`endif
    endfunction

    initial begin
        if (!$value$plusargs("image=%s",image) || !$value$plusargs("trace=%s",trace_file) ||
            !$value$plusargs("stores=%s",stores_file) || !$value$plusargs("trace_count=%d",trace_count) ||
            !$value$plusargs("store_count=%d",store_count) || !$value$plusargs("stop_pc=%d",stop_pc))
            $fatal(1,"missing program/scoreboard plusargs; use run_core.py");
        void'($value$plusargs("max_cycles=%d",max_cycles));
        if ($value$plusargs("waves=%s",wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0,tb_core_program);
        end
        // Explicit simulation initialization, not a hardware reset guarantee.
        for (int r=0;r<32;r++) architectural_regs[r]=0;
        for (int r=1;r<32;r++) dut.u_regfile.regs[r]=0;
        for (int w=0;w<262144;w++) begin
            architectural_memory[w]=0;
            dirty_word[w]=0;
`ifdef CORE_STANDALONE
            dut.u_memory_system.memory[w]=0;
`else
            dut.u_memory_system.dram.memory[w]=0;
`endif
        end
`ifdef CORE_STANDALONE
        $readmemh(image,dut.u_memory_system.memory);
`else
        $readmemh(image,dut.u_memory_system.dram.memory);
`endif
        $readmemh(image,architectural_memory);
        $readmemh(trace_file,expected,0,trace_count-1);
        if (store_count>0) $readmemh(stores_file,expected_stores,0,store_count-1);
        repeat (3) @(negedge clk);
        if (dut.id_ex_valid || dut.ex_mem_valid || dut.mem_wb_valid || dut.u_fetch.pc!=0)
            $fatal(1,"reset failed");
        rst_n=1;
    end

    // Compare architectural behavior at retirement, independently of pipeline timing.
    always @(posedge clk) begin : scoreboard
        int dest;
        logic [31:0] word;
        if (rst_n) begin
            cycles++;
            if (cycles>max_cycles) $fatal(1,"timeout pc=%08x retired=%0d/%0d",dut.i_addr,retired,trace_count);
            if (dut.i_waitrequest) i_stalls++;
            if (dut.d_waitrequest) d_stalls++;
            if (dut.hazard_stall) hazards++;
            if (dut.jump_en && !dut.pipeline_stall) redirects++;
            if (dut.mem_wb_valid && dut.d_waitrequest) wb_during_wait++;
            if (dut.d_read && dut.d_write) $fatal(1,"simultaneous data read/write");
            if (dut.d_write && !dut.d_waitrequest) begin
                if (stores>=store_count) $fatal(1,"unexpected store address=%08x",dut.d_addr);
                if ({dut.d_addr,dut.d_wdata,28'b0,dut.d_wstrb} !== expected_stores[stores])
                    $fatal(1,"store %0d mismatch got=%08x/%08x/%x expected=%024x",stores,dut.d_addr,dut.d_wdata,dut.d_wstrb,expected_stores[stores]);
                word=architectural_memory[dut.d_addr>>2];
                for (int lane=0;lane<4;lane++)
                    if (dut.d_wstrb[lane]) word[8*lane +: 8]=dut.d_wdata[8*lane +: 8];
                architectural_memory[dut.d_addr>>2]=word;
                dirty_word[dut.d_addr>>2]=1;
                stores++;
            end
            if (dut.mem_wb_valid) begin
                if (retired == trace_count) begin
                    if (dut.mem_wb_instr_pc != 32'(stop_pc)) $fatal(1,"incorrect stop PC %08x",dut.mem_wb_instr_pc);
                    if (stores != store_count) $fatal(1,"missing stores");
                    for (int r=1;r<32;r++)
                        if (dut.u_regfile.regs[r] !== architectural_regs[r])
                            $fatal(1,"final x%0d mismatch got=%08x expected=%08x",r,dut.u_regfile.regs[r],architectural_regs[r]);
                    for (int w=0;w<262144;w++)
                        if (dirty_word[w] && memory_word(w) !== architectural_memory[w])
                            $fatal(1,"final memory mismatch at %08x",w*4);
                    ipc = (cycles == 0) ? 0.0 : $itor(retired) / $itor(cycles);
                    $display("PASS: tb_core_program retired=%0d stores=%0d cycles=%0d IPC=%0.4f I-wait=%0d D-wait=%0d hazards=%0d redirects=%0d WB-during-wait=%0d",retired,stores,cycles,ipc,i_stalls,d_stalls,hazards,redirects,wb_during_wait);
                    $finish;
                end else begin
                    dest=(dut.mem_wb_reg_write && dut.mem_wb_rd!=0) ? int'(dut.mem_wb_rd) : 32;
                    if (dut.mem_wb_instr_pc !== expected[retired][127:96] || dest != int'(expected[retired][95:64]) ||
                        (dest!=32 && dut.wb_data !== expected[retired][63:32]))
                        $fatal(1,"retire %0d instr=%08x got PC=%08x rd=%0d data=%08x expected PC=%08x rd=%0d data=%08x",
                               retired,expected[retired][31:0],dut.mem_wb_instr_pc,dest,dut.wb_data,
                               expected[retired][127:96],expected[retired][95:64],expected[retired][63:32]);
                    if (dest!=32) architectural_regs[dest]=dut.wb_data;
                    retired++;
                end
            end
        end
    end

    // Hold the complete memory transaction throughout backpressure.
    property hold_memory_request;
        @(posedge clk) disable iff (!rst_n)
        dut.d_waitrequest |=> !rst_n || $stable({dut.ex_mem_valid,dut.d_read,dut.d_write,dut.d_addr,dut.d_wdata,dut.d_wstrb});
    endproperty
    assert property (hold_memory_request);
endmodule

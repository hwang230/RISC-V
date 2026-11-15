`timescale 1ns/1ps
// Same core/program scoreboard with either controlled memory or the real caches.
module tb_core_program #(
    parameter int L1_CACHE_SIZE = 64 * 1024,
    parameter int L2_CACHE_SIZE = 256 * 1024,
    parameter int L1_NUM_WAYS = 4,
    parameter int L2_NUM_WAYS = 4,
    parameter int L1_LATENCY = 1,
    parameter int L2_LATENCY = 5,
    parameter int DRAM_LATENCY = 80,
    parameter int DRAM_SIZE = 1024 * 1024
);
    localparam int L1_SETS = L1_CACHE_SIZE / (64 * L1_NUM_WAYS);
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    core #(
        .L1_CACHE_SIZE(L1_CACHE_SIZE),
        .L2_CACHE_SIZE(L2_CACHE_SIZE),
        .L1_NUM_WAYS(L1_NUM_WAYS),
        .L2_NUM_WAYS(L2_NUM_WAYS),
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
    int load_use_stalls=0, fifo_empty_cycles=0, fifo_full_cycles=0;
    int branch_flush_cycles=0, execute_busy_cycles=0;
    int redirects=0, wb_during_wait=0;
    int branch_predictions=0, branch_taken=0, branch_mispredictions=0;
    real ipc;

    function automatic logic [31:0] memory_word(input int word_index);
`ifdef CORE_STANDALONE
        return dut.u_memory_system.memory[word_index];
`else
        // L1D is write-back: dirty data need not have reached DRAM yet.
        for (int way=0; way<L1_NUM_WAYS; way++)
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
            // Cache wait cycles are counted only while the corresponding
            // request is active, so idle waitrequest values are not charged
            // to the program.
            if (dut.i_read && dut.i_waitrequest) i_stalls++;
            if ((dut.d_read || dut.d_write) && dut.d_waitrequest) d_stalls++;

            // FIFO-empty means decode could otherwise advance but fetch has
            // no instruction ready. FIFO-full exposes how often a backend
            // stall lets fetch reach its buffering limit.
            if (!dut.pipeline_stall && !dut.jump_en && !dut.instr_valid)
                fifo_empty_cycles++;
            if (dut.u_fetch.queue_full)
                fifo_full_cycles++;

            // A load-use stall is an actual unhidden dependency bubble.
            // With data-cache-to-EX forwarding this should remain zero for
            // one-cycle L1D hits.
            if (dut.hazard_stall) load_use_stalls++;

            // Conditional redirects flush the speculative FIFO contents.
            // This is a cycle count of the resolving flush event, distinct
            // from the longer refill delay that may follow it.
            if (dut.jump_en && dut.id_ex_valid && dut.id_ex_branch &&
                !dut.id_ex_illegal_instr)
                branch_flush_cycles++;

            // Count cycles in which a valid instruction actually advances
            // through EX; a held ID/EX entry during a data wait is not work.
            if (dut.id_ex_valid && dut.memory_advance)
                execute_busy_cycles++;
            if (dut.jump_en && !dut.pipeline_stall) redirects++;
            // Count a branch when it advances out of EX so a held instruction
            // during a data-side wait is not counted more than once.
            if (dut.memory_advance && dut.id_ex_valid && dut.id_ex_branch &&
                !dut.id_ex_illegal_instr) begin
                branch_predictions++;
                if (dut.alu_result[0]) begin
                    branch_taken++;
                end
                if (dut.id_ex_pred_taken != dut.alu_result[0])
                    branch_mispredictions++;
            end
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
                    $display("PASS: tb_core_program retired=%0d stores=%0d cycles=%0d IPC=%0.4f I-wait=%0d D-wait=%0d load-use-stalls=%0d FIFO-empty=%0d FIFO-full=%0d branch-flush=%0d EX-busy=%0d branches=%0d branch-taken=%0d branch-predictions=%0d branch-mispredictions=%0d redirects=%0d WB-during-wait=%0d",retired,stores,cycles,ipc,i_stalls,d_stalls,load_use_stalls,fifo_empty_cycles,fifo_full_cycles,branch_flush_cycles,execute_busy_cycles,branch_predictions,branch_taken,branch_predictions,branch_mispredictions,redirects,wb_during_wait);
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

`timescale 1ns/1ps
// Both backends use this retirement scoreboard; only initialization and
// performance instrumentation depend on implementation details.
module tb_core_program #(
    parameter int L1_CACHE_SIZE = 64 * 1024,
    parameter int L2_CACHE_SIZE = 256 * 1024,
    parameter int L1_NUM_WAYS = 4,
    parameter int L2_NUM_WAYS = 4,
    parameter int L1_LATENCY = 1,
    parameter int L2_LATENCY = 5,
    parameter int DRAM_LATENCY = 80,
    parameter int DRAM_SIZE = 1024 * 1024,
    parameter int ROB_ENTRIES = 32,
    parameter int PHYS_REGS = 64,
    parameter int INT_ENTRIES = 8,
    parameter int MUL_ENTRIES = 4,
    parameter int DIV_ENTRIES = 2,
    parameter int MEM_ENTRIES = 4
);
    localparam int L1_SETS = L1_CACHE_SIZE / (64 * L1_NUM_WAYS);
    localparam int IQ_ENTRIES = INT_ENTRIES+MUL_ENTRIES+DIV_ENTRIES+MEM_ENTRIES;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic retire_valid, retire_rd_we, retire_mem_we, retire_trap;
    logic [31:0] retire_pc, retire_instr, retire_rd_data;
    logic [31:0] retire_mem_addr, retire_mem_data, retire_cause, retire_tval;
    logic [4:0] retire_rd;
    logic [3:0] retire_mem_strb;
`ifdef OOO_BACKEND
    ooo_core #(
        .ROB_ENTRIES(ROB_ENTRIES), .PHYS_REGS(PHYS_REGS),
        .INT_ENTRIES(INT_ENTRIES), .MUL_ENTRIES(MUL_ENTRIES),
        .DIV_ENTRIES(DIV_ENTRIES), .MEM_ENTRIES(MEM_ENTRIES),
`else
    core #(
`endif
        .L1_CACHE_SIZE(L1_CACHE_SIZE), .L2_CACHE_SIZE(L2_CACHE_SIZE),
        .L1_NUM_WAYS(L1_NUM_WAYS), .L2_NUM_WAYS(L2_NUM_WAYS),
        .L1_LATENCY(L1_LATENCY), .L2_LATENCY(L2_LATENCY),
        .DRAM_LATENCY(DRAM_LATENCY), .DRAM_SIZE(DRAM_SIZE)
    ) dut(.clk(clk), .rst_n(rst_n), .retire_valid(retire_valid),
        .retire_pc(retire_pc), .retire_instr(retire_instr),
        .retire_rd_we(retire_rd_we), .retire_rd(retire_rd), .retire_rd_data(retire_rd_data),
        .retire_mem_we(retire_mem_we), .retire_mem_addr(retire_mem_addr),
        .retire_mem_data(retire_mem_data), .retire_mem_strb(retire_mem_strb),
        .retire_trap(retire_trap), .retire_cause(retire_cause), .retire_tval(retire_tval));

    // PC, destination (32 means no write), value, instruction, trap, cause, tval.
    logic [223:0] expected [0:99999];
    logic [95:0] expected_stores [0:99999];
    logic [31:0] architectural_regs [0:31];
    logic [31:0] architectural_memory [0:262143];
    bit dirty_word [0:262143];
    string image, trace_file, stores_file, wave_file, metrics_file;
    int trace_count, store_count, stop_pc, events=0, retired=0, stores=0, retired_stores=0, traps=0;
    int cycles=0, max_cycles=2000000, i_stalls=0, d_stalls=0;
    int fifo_empty_cycles=0, fifo_full_cycles=0, load_use_stalls=0;
    int branch_predictions=0, branch_taken=0, branch_mispredictions=0, redirects=0;
    int dispatches=0, dispatch_stalls=0, issues=0, wb_contention=0, recovery_cycles=0;
    int rob_full_cycles=0, physical_full_cycles=0, max_rob=0;
    int queue_hist [0:3][0:255];
    int rob_hist [0:255];
    int queue_full [0:3], operand_wait [0:3], unit_wait [0:3], queue_issues [0:3];
    int overlap_div_pc=-1, overlap_add_pc=-1, overlap_dep_pc=-1, check_overlap=0;
    int div_complete=-1, add_complete=-1, dep_complete=-1, div_retire=-1, add_retire=-1;
    real ipc;

    function automatic logic [31:0] memory_word(input int word_index);
`ifdef CORE_STANDALONE
        return dut.u_memory_system.memory[word_index];
`else
        for (int way=0; way<L1_NUM_WAYS; way++)
            if (dut.u_memory_system.l1d.valid_array[(word_index/16)%L1_SETS][way] &&
                int'(dut.u_memory_system.l1d.tag_array[(word_index/16)%L1_SETS][way]) == word_index/(16*L1_SETS))
                return dut.u_memory_system.l1d.data_array[(word_index/16)%L1_SETS][way][(word_index%16)*32 +: 32];
        return dut.u_memory_system.dram.memory[word_index];
`endif
    endfunction

    task automatic write_metrics;
        int file_handle;
        file_handle=$fopen(metrics_file,"w");
        if (!file_handle) $fatal(1,"cannot open metrics output %s",metrics_file);
        $fwrite(file_handle,"{\"cycles\":%0d,\"retired\":%0d,\"events\":%0d,\"traps\":%0d,\"ipc\":%0.9f,",cycles,retired,events,traps,ipc);
        $fwrite(file_handle,"\"i_wait\":%0d,\"d_wait\":%0d,\"fifo_empty_cycles\":%0d,\"fifo_full_cycles\":%0d,",i_stalls,d_stalls,fifo_empty_cycles,fifo_full_cycles);
        $fwrite(file_handle,"\"load_use_stalls\":%0d,\"branches\":%0d,\"branch_taken\":%0d,\"branch_mispredictions\":%0d,\"redirects\":%0d,",load_use_stalls,branch_predictions,branch_taken,branch_mispredictions,redirects);
        $fwrite(file_handle,"\"dispatches\":%0d,\"dispatch_stalls\":%0d,\"issues\":%0d,\"writeback_contention\":%0d,\"recovery_cycles\":%0d,",dispatches,dispatch_stalls,issues,wb_contention,recovery_cycles);
        $fwrite(file_handle,"\"rob_full_cycles\":%0d,\"physical_full_cycles\":%0d,\"max_rob\":%0d,",rob_full_cycles,physical_full_cycles,max_rob);
        $fwrite(file_handle,"\"overlap\":{\"div_complete\":%0d,\"add_complete\":%0d,\"dependent_complete\":%0d,\"div_retire\":%0d,\"add_retire\":%0d},",div_complete,add_complete,dep_complete,div_retire,add_retire);
        $fwrite(file_handle,"\"rob_occupancy_histogram\":[");
        for (int n=0;n<=ROB_ENTRIES;n++) $fwrite(file_handle,"%s%0d",n ? "," : "",rob_hist[n]);
        $fwrite(file_handle,"],\"queues\":[");
        for (int q=0;q<4;q++) begin
            $fwrite(file_handle,"%s{\"full_cycles\":%0d,\"operand_wait_cycles\":%0d,\"unit_wait_cycles\":%0d,\"issues\":%0d,\"occupancy_histogram\":[",q ? "," : "",queue_full[q],operand_wait[q],unit_wait[q],queue_issues[q]);
            for (int n=0;n<=(q==0 ? INT_ENTRIES : q==1 ? MUL_ENTRIES : q==2 ? DIV_ENTRIES : MEM_ENTRIES);n++)
                $fwrite(file_handle,"%s%0d",n ? "," : "",queue_hist[q][n]);
            $fwrite(file_handle,"]}");
        end
        $fwrite(file_handle,"]}\n");
        $fclose(file_handle);
    endtask

    initial begin
        if (!$value$plusargs("image=%s",image) || !$value$plusargs("trace=%s",trace_file) ||
            !$value$plusargs("stores=%s",stores_file) || !$value$plusargs("trace_count=%d",trace_count) ||
            !$value$plusargs("store_count=%d",store_count) || !$value$plusargs("stop_pc=%d",stop_pc) ||
            !$value$plusargs("metrics=%s",metrics_file))
            $fatal(1,"missing program/scoreboard plusargs; use run_core.py");
        if (trace_count>100000 || store_count>100000 || ROB_ENTRIES>255)
            $fatal(1,"testbench trace/capacity bound exceeded");
        void'($value$plusargs("max_cycles=%d",max_cycles));
        void'($value$plusargs("overlap_div_pc=%d",overlap_div_pc));
        void'($value$plusargs("overlap_add_pc=%d",overlap_add_pc));
        void'($value$plusargs("overlap_dep_pc=%d",overlap_dep_pc));
        void'($value$plusargs("check_overlap=%d",check_overlap));
        if ($value$plusargs("waves=%s",wave_file)) begin
            $dumpfile(wave_file);
            $dumpvars(0,tb_core_program);
        end
        for (int r=0;r<32;r++) architectural_regs[r]=0;
`ifndef OOO_BACKEND
        for (int r=1;r<32;r++) dut.u_regfile.regs[r]=0;
`endif
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
        if (retire_valid || dut.u_fetch.pc!=0) $fatal(1,"reset failed");
        rst_n=1;
    end

    always @(posedge clk) begin : scoreboard
        int dest;
        logic [31:0] word;
        int occupied [0:3];
        bit waiting [0:3];
        bit blocked [0:3];
        if (rst_n) begin
            cycles++;
            if (cycles>max_cycles) $fatal(1,"timeout pc=%08x events=%0d/%0d",dut.i_addr,events,trace_count);
            if (dut.i_read && dut.i_waitrequest) i_stalls++;
            if ((dut.d_read || dut.d_write) && dut.d_waitrequest) d_stalls++;
            if (dut.u_fetch.queue_full) fifo_full_cycles++;
`ifdef OOO_BACKEND
            if (!dut.instr_valid && !dut.recovering) fifo_empty_cycles++;
            if (dut.dispatch_fire) dispatches++;
            if (dut.instr_valid && !dut.dispatch_fire && !dut.recovering) dispatch_stalls++;
            if (dut.recovering) recovery_cycles++;
            if (dut.recover_event) begin branch_mispredictions++; redirects++; end
            if (dut.flush_backend && !dut.recovering) redirects++;
            if (dut.rob_count==ROB_ENTRIES) rob_full_cycles++;
            if (dut.free_bitmap=='0) physical_full_cycles++;
            if (int'(dut.rob_count)>max_rob) max_rob=int'(dut.rob_count);
            rob_hist[int'(dut.rob_count)]++;
            for (int q=0;q<4;q++) begin occupied[q]=0; waiting[q]=0; blocked[q]=0; end
            for (int n=0;n<IQ_ENTRIES;n++) begin
                int q;
                bit ready_now;
                q=n<INT_ENTRIES ? 0 : n<INT_ENTRIES+MUL_ENTRIES ? 1 : n<INT_ENTRIES+MUL_ENTRIES+DIV_ENTRIES ? 2 : 3;
                if (dut.iq[n].valid) begin
                    occupied[q]++;
                    ready_now = (dut.iq[n].ready1 || (dut.wb_valid && dut.wb_packet.pdst!=0 &&
                                   !dut.wb_packet.exception && dut.iq[n].src1==dut.wb_packet.pdst)) &&
                                 (dut.iq[n].ready2 || (dut.wb_valid && dut.wb_packet.pdst!=0 &&
                                   !dut.wb_packet.exception && dut.iq[n].src2==dut.wb_packet.pdst)) &&
                                 (dut.iq[n].ready3 || (dut.wb_valid && dut.wb_packet.pdst!=0 &&
                                   !dut.wb_packet.exception && dut.iq[n].src3==dut.wb_packet.pdst));
                    if (!ready_now) waiting[q]=1;
                    else if (!dut.unit_ready[q]) blocked[q]=1;
                end
            end
            for (int q=0;q<4;q++) begin
                queue_hist[q][occupied[q]]++;
                if (occupied[q]==(q==0 ? INT_ENTRIES : q==1 ? MUL_ENTRIES : q==2 ? DIV_ENTRIES : MEM_ENTRIES)) queue_full[q]++;
                if (waiting[q]) operand_wait[q]++;
                if (blocked[q]) unit_wait[q]++;
            end
            if (dut.issue_fire) begin issues++; queue_issues[int'(dut.issue_unit)]++; end
            if ($countones(dut.completion_live)>1) wb_contention++;
            if (dut.wb_valid) begin
                if (int'(dut.rob[dut.wb_rob].pc)==overlap_div_pc && div_complete<0) div_complete=cycles;
                if (int'(dut.rob[dut.wb_rob].pc)==overlap_add_pc && add_complete<0) add_complete=cycles;
                if (int'(dut.rob[dut.wb_rob].pc)==overlap_dep_pc && dep_complete<0) dep_complete=cycles;
            end
`else
            if (!dut.pipeline_stall && !dut.jump_en && !dut.instr_valid) fifo_empty_cycles++;
            if (dut.hazard_stall) load_use_stalls++;
            if (dut.jump_en && !dut.pipeline_stall) redirects++;
            if (dut.memory_advance && dut.id_ex_valid && dut.id_ex_branch && !dut.id_ex_illegal_instr) begin
                if (dut.id_ex_pred_taken != dut.alu_result[0]) branch_mispredictions++;
            end
`endif
            if (dut.d_read && dut.d_write) $fatal(1,"simultaneous data read/write");
            // Bus-side checking also catches stores that never retire (wrong paths).
            if (dut.d_write && !dut.d_waitrequest) begin
                if (stores>=store_count) $fatal(1,"unexpected store address=%08x",dut.d_addr);
                if ({dut.d_addr,dut.d_wdata,28'b0,dut.d_wstrb} !== expected_stores[stores])
                    $fatal(1,"store %0d mismatch got=%08x/%08x/%x expected=%024x",stores,dut.d_addr,dut.d_wdata,dut.d_wstrb,expected_stores[stores]);
                word=architectural_memory[dut.d_addr>>2];
                for (int lane=0;lane<4;lane++) if (dut.d_wstrb[lane]) word[8*lane +: 8]=dut.d_wdata[8*lane +: 8];
                architectural_memory[dut.d_addr>>2]=word;
                dirty_word[dut.d_addr>>2]=1;
                stores++;
            end
            if (retire_valid) begin
                if (events == trace_count) begin
                    if (retire_pc != 32'(stop_pc)) $fatal(1,"incorrect stop PC %08x",retire_pc);
                    if (stores != store_count || retired_stores != store_count) $fatal(1,"missing stores bus=%0d trace=%0d expected=%0d",stores,retired_stores,store_count);
                    for (int r=1;r<32;r++) begin
`ifdef OOO_BACKEND
                        if (dut.physical_regs[dut.committed_map[r]] !== architectural_regs[r])
                            $fatal(1,"final x%0d mismatch got=%08x expected=%08x",r,dut.physical_regs[dut.committed_map[r]],architectural_regs[r]);
`else
                        if (dut.u_regfile.regs[r] !== architectural_regs[r])
                            $fatal(1,"final x%0d mismatch got=%08x expected=%08x",r,dut.u_regfile.regs[r],architectural_regs[r]);
`endif
                    end
                    for (int w=0;w<262144;w++) if (dirty_word[w] && memory_word(w) !== architectural_memory[w]) $fatal(1,"final memory mismatch at %08x",w*4);
                    if (check_overlap && !(add_complete>0 && div_complete>add_complete && dep_complete>div_complete && add_retire>div_retire && div_retire>=div_complete))
                        $fatal(1,"DIV overlap failed: addWB=%0d divWB=%0d depWB=%0d divRet=%0d addRet=%0d",add_complete,div_complete,dep_complete,div_retire,add_retire);
                    ipc=$itor(retired)/$itor(cycles);
                    write_metrics();
                    $display("PASS: tb_core_program retired=%0d stores=%0d cycles=%0d IPC=%0.6f traps=%0d I-wait=%0d D-wait=%0d",retired,stores,cycles,ipc,traps,i_stalls,d_stalls);
                    $finish;
                end else begin
                    dest=(retire_rd_we && retire_rd!=0) ? int'(retire_rd) : 32;
                    if (retire_rd_we && retire_rd==0) $fatal(1,"trace writes x0");
                    if ({retire_pc,32'(dest),dest!=32 ? retire_rd_data : 32'b0,retire_instr,31'b0,retire_trap,retire_trap ? retire_cause : 32'b0,retire_trap ? retire_tval : 32'b0} !== expected[events])
                        $fatal(1,"retire %0d mismatch got pc=%08x instr=%08x rd=%0d data=%08x trap=%0d cause=%0d tval=%08x expected=%056x",events,retire_pc,retire_instr,dest,retire_rd_data,retire_trap,retire_cause,retire_tval,expected[events]);
                    if (retire_trap && (retire_rd_we || retire_mem_we)) $fatal(1,"faulting instruction has side effects");
                    if (dest!=32) architectural_regs[dest]=retire_rd_data;
                    if (retire_mem_we) begin
                        if (retired_stores>=store_count || {retire_mem_addr,retire_mem_data,28'b0,retire_mem_strb} !== expected_stores[retired_stores]) $fatal(1,"retirement store mismatch");
                        retired_stores++;
                    end
                    if (retire_instr[6:0]==7'h63 && !retire_trap) begin
                        branch_predictions++;
                        case (retire_instr[14:12])
                            0: if (architectural_regs[retire_instr[19:15]]==architectural_regs[retire_instr[24:20]]) branch_taken++;
                            1: if (architectural_regs[retire_instr[19:15]]!=architectural_regs[retire_instr[24:20]]) branch_taken++;
                            4: if ($signed(architectural_regs[retire_instr[19:15]])<$signed(architectural_regs[retire_instr[24:20]])) branch_taken++;
                            5: if ($signed(architectural_regs[retire_instr[19:15]])>=$signed(architectural_regs[retire_instr[24:20]])) branch_taken++;
                            6: if (architectural_regs[retire_instr[19:15]]<architectural_regs[retire_instr[24:20]]) branch_taken++;
                            7: if (architectural_regs[retire_instr[19:15]]>=architectural_regs[retire_instr[24:20]]) branch_taken++;
                            default: $fatal(1,"invalid branch retired");
                        endcase
                    end
                    if (int'(retire_pc)==overlap_div_pc && div_retire<0) div_retire=cycles;
                    if (int'(retire_pc)==overlap_add_pc && add_retire<0) add_retire=cycles;
                    if (retire_trap) traps++; else retired++;
                    events++;
                end
            end
        end
    end

    property hold_memory_request;
        @(posedge clk) disable iff (!rst_n)
        (dut.d_read || dut.d_write) && dut.d_waitrequest |=> !rst_n ||
            $stable({dut.d_read,dut.d_write,dut.d_addr,dut.d_wdata,dut.d_wstrb});
    endproperty
    assert property (hold_memory_request);
endmodule

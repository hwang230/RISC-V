`include "cpu_pkg.sv"
`include "decoder.sv"
`include "imm_gen.sv"
`include "fetch.sv"
`include "alu/alu_div.sv"
`include "ooo/ooo_multiply.sv"
`include "ooo/ooo_csr.sv"
`ifndef CORE_ASIC_SYNTH
`ifndef CORE_STANDALONE
`include "memory/memory_system.sv"
`endif
`endif

// Single-dispatch, single-issue, single-retirement RV32IM/Zicsr backend.
// Execution is out of order; all irreversible effects occur at the ROB head.
module ooo_core #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 32,
    parameter int ROB_ENTRIES = 32,
    parameter int PHYS_REGS = 64,
    parameter int INT_ENTRIES = 8,
    parameter int MUL_ENTRIES = 4,
    parameter int DIV_ENTRIES = 2,
    parameter int MEM_ENTRIES = 4,
    parameter int L1_CACHE_SIZE = 64 * 1024,
    parameter int L2_CACHE_SIZE = 256 * 1024,
    parameter int L1_NUM_WAYS = 4,
    parameter int L2_NUM_WAYS = 4,
    parameter int L1_LATENCY = 1,
    parameter int L2_LATENCY = 5,
    parameter int DRAM_LATENCY = 80,
    parameter int DRAM_SIZE = 1024 * 1024
)(
    input logic clk,
    input logic rst_n,
    output logic retire_valid,
    output logic [31:0] retire_pc,
    output logic [31:0] retire_instr,
    output logic retire_rd_we,
    output logic [4:0] retire_rd,
    output logic [31:0] retire_rd_data,
    output logic retire_mem_we,
    output logic [31:0] retire_mem_addr,
    output logic [31:0] retire_mem_data,
    output logic [3:0] retire_mem_strb,
    output logic retire_trap,
    output logic [31:0] retire_cause,
    output logic [31:0] retire_tval
`ifdef CORE_ASIC_SYNTH
    , output logic i_read
    , output logic [ADDR_WIDTH-1:0] i_addr
    , input logic [DATA_WIDTH-1:0] i_data
    , input logic i_waitrequest
    , output logic d_read
    , output logic d_write
    , output logic [ADDR_WIDTH-1:0] d_addr
    , output logic [DATA_WIDTH-1:0] d_wdata
    , output logic [DATA_WIDTH/8-1:0] d_wstrb
    , input logic [DATA_WIDTH-1:0] d_rdata
    , input logic d_waitrequest
`endif
);
    import cpu_pkg::*;
    localparam int RW = (ROB_ENTRIES > 1) ? $clog2(ROB_ENTRIES) : 1;
    localparam int PW = $clog2(PHYS_REGS);
    localparam int CW = $clog2(ROB_ENTRIES+1);
    localparam int IQ_ENTRIES = INT_ENTRIES+MUL_ENTRIES+DIV_ENTRIES+MEM_ENTRIES;
    localparam int IQ_SLOT_WIDTH = (IQ_ENTRIES > 1) ? $clog2(IQ_ENTRIES) : 1;
    localparam int IQ_TREE_LEAVES = 1 << $clog2(IQ_ENTRIES);
    localparam int IQ_TREE_NODES = 2*IQ_TREE_LEAVES;
    localparam int MUL_BASE = INT_ENTRIES;
    localparam int DIV_BASE = MUL_BASE+MUL_ENTRIES;
    localparam int MEM_BASE = DIV_BASE+DIV_ENTRIES;
    localparam int TAG_WIDTH = RW+PW;

`ifndef CORE_ASIC_SYNTH
    logic i_read, i_waitrequest, d_read, d_write, d_waitrequest;
    logic [ADDR_WIDTH-1:0] i_addr, d_addr;
    logic [DATA_WIDTH-1:0] i_data, d_wdata, d_rdata;
    logic [DATA_WIDTH/8-1:0] d_wstrb;
    memory_system #(
        .L1_CACHE_SIZE(L1_CACHE_SIZE), .L2_CACHE_SIZE(L2_CACHE_SIZE),
`ifdef CORE_STANDALONE
        .NUM_WAYS(L1_NUM_WAYS),
`else
        .L1_NUM_WAYS(L1_NUM_WAYS), .L2_NUM_WAYS(L2_NUM_WAYS),
`endif
        .L1_LATENCY(L1_LATENCY), .L2_LATENCY(L2_LATENCY),
        .DRAM_LATENCY(DRAM_LATENCY), .DRAM_SIZE(DRAM_SIZE)
    ) u_memory_system (.*);
`endif

    typedef struct packed {
        logic valid, done;
        logic [31:0] pc, instr;
        logic [4:0] rd;
        logic [PW-1:0] pdst, old_pdst;
        logic writes_rd;
        alu_op_e op;
        logic [31:0] imm;
        logic src_imm, src_pc;
        logic branch, jump, jalr, pred_taken, taken;
        logic load, store;
        logic [1:0] mem_size;
        logic mem_unsigned;
        logic csr, mret, serial;
        logic exception;
        logic [31:0] cause, tval;
        logic [31:0] result;
    } rob_entry_t;
    typedef struct packed {
        logic valid;
        logic [RW-1:0] rob_tag;
        logic [PW-1:0] src1, src2, src3;
        logic ready1, ready2, ready3;
    } issue_entry_t;
    typedef struct packed {
        logic [RW-1:0] rob_tag;
        logic [PW-1:0] pdst;
        logic [31:0] data;
        logic exception;
        logic [31:0] cause, tval;
        logic taken;
    } completion_t;

    rob_entry_t rob [0:ROB_ENTRIES-1];
    issue_entry_t iq [0:IQ_ENTRIES-1];
    logic [31:0] physical_regs [0:PHYS_REGS-1];
    logic [PW-1:0] speculative_map [0:31];
    logic [PW-1:0] committed_map [0:31];
    logic [PHYS_REGS-1:0] free_bitmap, physical_ready;
    logic [RW-1:0] rob_head, rob_tail;
    logic [CW-1:0] rob_count;

    function automatic logic [RW-1:0] next_rob(input logic [RW-1:0] tag);
        return (tag == RW'(ROB_ENTRIES-1)) ? '0 : tag+1'b1;
    endfunction
    function automatic logic [CW-1:0] age(input logic [RW-1:0] tag);
        logic [RW-1:0] wrapped_distance;
        // ROB age is bounded by the ROB capacity. Keep the wrap-aware
        // distance narrow so scheduler comparisons do not build 32-bit
        // add/subtract paths from the small ROB tags.
        if ((ROB_ENTRIES & (ROB_ENTRIES-1)) == 0) begin
            wrapped_distance = tag-rob_head;
            return CW'(wrapped_distance);
        end else begin
            return (tag >= rob_head) ? CW'(tag)-CW'(rob_head) :
                   CW'(tag)+CW'(ROB_ENTRIES)-CW'(rob_head);
        end
    endfunction
    function automatic int queue_unit(input int slot);
        if (slot < MUL_BASE) return 0;
        if (slot < DIV_BASE) return 1;
        if (slot < MEM_BASE) return 2;
        return 3;
    endfunction

    logic [31:0] instr, instr_pc;
    logic instr_valid, instr_pred_taken;
    logic dispatch_fire, issue_fire, wb_valid;
    logic [RW-1:0] issue_rob, wb_rob;
    logic [1:0] issue_unit;
    logic recovering, recover_event, flush_backend;
    logic [RW-1:0] recovery_rob;
    logic [31:0] recovery_target;
    logic jump_en;
    logic [31:0] jump_target;
    logic branch_update_valid;
    fetch #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) u_fetch (
        // Dispatch stops on recover_event above. Let fetch complete any
        // in-flight request; recovery redirect flushes wrong-path responses.
        // Keeping the scheduler's branch compare off i_read shortens the
        // external request path without allowing wrong-path dispatch.
        .clk(clk), .rst_n(rst_n), .stall(recovering),
        .jump_en(jump_en), .jump_target(jump_target),
        .branch_update_valid(branch_update_valid), .branch_update_pc(retire_pc),
        .branch_update_taken(rob[rob_head].taken), .consume(dispatch_fire),
        .i_read(i_read), .i_addr(i_addr), .i_data(i_data),
        .i_waitrequest(i_waitrequest), .instr(instr), .instr_valid(instr_valid),
        .instr_pc(instr_pc), .instr_pred_taken(instr_pred_taken)
    );

    alu_op_e dec_op;
    imm_src_e dec_imm_type;
    logic dec_load, dec_store, dec_write, dec_src_imm, dec_src_pc;
    logic dec_branch, dec_jump, dec_jalr, dec_rs1, dec_rs2, dec_rs3;
    logic dec_unsigned, dec_illegal;
    logic [1:0] dec_size;
    logic [31:0] dec_imm;
    decoder u_decoder (
        .cur_opcode(opcode_e'(instr[6:0])), .cur_funct3(instr[14:12]),
        .cur_funct7(instr[31:25]), .cur_id_alu_op(dec_op),
        .cur_id_mem_read(dec_load), .cur_id_mem_write(dec_store),
        .cur_id_reg_write(dec_write), .cur_id_mem_to_reg_write(),
        .cur_id_alu_src_imm(dec_src_imm), .cur_id_alu_src_pc(dec_src_pc),
        .cur_id_branch(dec_branch), .cur_id_jump(dec_jump), .cur_id_jalr(dec_jalr),
        .cur_id_uses_rs1(dec_rs1), .cur_id_uses_rs2(dec_rs2),
        .cur_id_uses_rd_old(dec_rs3), .cur_id_imm_type(dec_imm_type),
        .cur_id_wb_sel(), .cur_id_mem_size(dec_size),
        .cur_id_mem_unsigned(dec_unsigned), .cur_id_illegal_instr(dec_illegal)
    );
    imm_gen u_imm_gen (.instr(instr), .imm_type(dec_imm_type), .imm_out(dec_imm));

    logic decoded_exception, decoded_write, decoded_rs1, decoded_csr;
    logic decoded_mret, decoded_serial;
    logic [31:0] decoded_cause, decoded_tval;
    logic [1:0] decoded_unit;
    always_comb begin
        decoded_exception = dec_illegal;
        decoded_cause = 32'd2;
        decoded_tval = instr;
        decoded_write = dec_write;
        decoded_rs1 = dec_rs1;
        decoded_csr = 1'b0;
        decoded_mret = 1'b0;
        decoded_serial = 1'b0;
        decoded_unit = 0;
        if (dec_op inside {ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU, ALU_MAC})
            decoded_unit = 1;
        if (dec_op inside {ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU})
            decoded_unit = 2;
        if (dec_load || dec_store) decoded_unit = 3;
        // SYSTEM decode is confined to this backend; the baseline is unchanged.
        if (instr[6:0] == 7'h73) begin
            decoded_write = 0;
            decoded_rs1 = 0;
            decoded_serial = 1;
            if (instr[14:12] inside {3'b001,3'b010,3'b011,3'b101,3'b110,3'b111}) begin
                decoded_exception = 0;
                decoded_csr = 1;
                decoded_write = 1;
                decoded_rs1 = !instr[14];
            end else if (instr == 32'h30200073) begin
                decoded_exception = 0;
                decoded_mret = 1;
            end else if (instr == 32'h00000073 || instr == 32'h00100073) begin
                decoded_exception = 1;
                decoded_cause = instr[20] ? 32'd3 : 32'd11;
                decoded_tval = instr[20] ? instr_pc : 32'b0;
            end
        end
        // Memory is ordered at the head, so FENCE needs no additional action.
        if (instr[6:0] == 7'h0f && instr[14:12] == 0) begin
            decoded_exception = 0;
            decoded_write = 0;
            decoded_serial = 1;
        end
        if (dec_jalr && instr[14:12] != 0) decoded_exception = 1;
        if (instr_pc[1:0] != 0) begin
            decoded_exception = 1;
            decoded_cause = 0;
            decoded_tval = instr_pc;
        end
        if (decoded_exception) decoded_write = 0;
    end

    logic [PW-1:0] allocated_phys, dispatch_src1, dispatch_src2, dispatch_src3;
    logic free_found;
    integer dispatch_slot;
    always_comb begin
        allocated_phys = 0;
        free_found = 0;
        for (int p=1; p<PHYS_REGS; p++)
            if (free_bitmap[p] && !free_found) begin
                allocated_phys = PW'(p);
                free_found = 1;
            end
        dispatch_slot = -1;
        for (int q=0; q<IQ_ENTRIES; q++)
            if (queue_unit(q) == int'(decoded_unit) && !iq[q].valid && dispatch_slot < 0)
                dispatch_slot = q;
        // Capture every source, including MAC's old destination, before rename.
        dispatch_src1 = decoded_rs1 ? speculative_map[instr[19:15]] : PW'(0);
        dispatch_src2 = dec_rs2 ? speculative_map[instr[24:20]] : PW'(0);
        dispatch_src3 = dec_rs3 ? speculative_map[instr[11:7]] : PW'(0);
        dispatch_fire = rst_n && instr_valid && !recovering && !recover_event && !flush_backend &&
            rob_count < CW'(ROB_ENTRIES) &&
            (!(decoded_write && instr[11:7] != 0) || free_found) &&
            (decoded_exception || dispatch_slot >= 0);
    end

    completion_t int_packet, mem_packet;
    logic int_valid, mem_valid;
    logic mul_req_ready, mul_valid, mul_resp_ready;
    logic div_req_ready, div_valid, div_resp_ready;
    logic [TAG_WIDTH-1:0] mul_tag, div_tag;
    logic [31:0] mul_data, div_data;
    completion_t completion [0:3];
    logic [3:0] completion_valid, completion_live, completion_accept;
    logic [3:0] candidate_valid;
    integer wb_unit;
    completion_t wb_packet;
    always_comb begin
        completion[0] = int_packet;
        completion[1] = '0;
        completion[1].rob_tag = mul_tag[TAG_WIDTH-1:PW];
        completion[1].pdst = mul_tag[PW-1:0];
        completion[1].data = mul_data;
        completion[2] = '0;
        completion[2].rob_tag = div_tag[TAG_WIDTH-1:PW];
        completion[2].pdst = div_tag[PW-1:0];
        completion[2].data = div_data;
        completion[3] = mem_packet;
        completion_valid = {mem_valid, div_valid, mul_valid, int_valid};
        completion_live = '0;
        candidate_valid = '0;
        wb_unit = -1;
        for (int u=0; u<4; u++) begin
            completion_live[u] = completion_valid[u] && rob[completion[u].rob_tag].valid &&
                rob[completion[u].rob_tag].pdst == completion[u].pdst;
            candidate_valid[u] = completion_live[u];
            if (completion_live[u]) begin
                if (wb_unit < 0) wb_unit = u;
                else if (age(completion[u].rob_tag) < age(completion[wb_unit].rob_tag)) wb_unit = u;
            end
        end
        wb_packet = '0;
        if (wb_unit >= 0) wb_packet = completion[wb_unit];
        wb_valid = rst_n && wb_unit >= 0 && !flush_backend;
        wb_rob = wb_packet.rob_tag;
        for (int u=0; u<4; u++)
            completion_accept[u] = !completion_live[u] || (wb_valid && wb_unit == u);
        mul_resp_ready = completion_accept[1];
        div_resp_ready = completion_accept[2];
    end

    logic mem_busy;
    logic [3:0] unit_ready;
    integer selected_slot;
    logic [IQ_ENTRIES-1:0] issue_eligible;
    logic [IQ_TREE_NODES-1:1] issue_tree_valid;
    logic [CW-1:0] issue_tree_age [1:IQ_TREE_NODES-1];
    logic [IQ_SLOT_WIDTH-1:0] issue_tree_slot [1:IQ_TREE_NODES-1];
    rob_entry_t selected;
    logic [31:0] operand1, operand2, operand3;
    logic selected_ready1, selected_ready2, selected_ready3;
    always_comb begin
        unit_ready[0] = !int_valid || completion_accept[0];
        unit_ready[1] = mul_req_ready;
        unit_ready[2] = div_req_ready;
        unit_ready[3] = !mem_busy && (!mem_valid || completion_accept[3]);
        issue_eligible = '0;
        for (int node=1; node<IQ_TREE_NODES; node++) begin
            issue_tree_valid[node] = 0;
            issue_tree_age[node] = '0;
            issue_tree_slot[node] = '0;
        end
        for (int q=0; q<IQ_ENTRIES; q++) begin
            issue_eligible[q] = iq[q].valid && rob[iq[q].rob_tag].valid &&
                (iq[q].ready1 || (wb_valid && wb_packet.pdst != 0 &&
                                  !wb_packet.exception && iq[q].src1 == wb_packet.pdst)) &&
                (iq[q].ready2 || (wb_valid && wb_packet.pdst != 0 &&
                                  !wb_packet.exception && iq[q].src2 == wb_packet.pdst)) &&
                (iq[q].ready3 || (wb_valid && wb_packet.pdst != 0 &&
                                  !wb_packet.exception && iq[q].src3 == wb_packet.pdst)) &&
                unit_ready[queue_unit(q)] &&
                (!(queue_unit(q) == 3 || rob[iq[q].rob_tag].serial) || iq[q].rob_tag == rob_head);
            issue_tree_valid[IQ_TREE_LEAVES+q] = issue_eligible[q];
            issue_tree_age[IQ_TREE_LEAVES+q] = age(iq[q].rob_tag);
            issue_tree_slot[IQ_TREE_LEAVES+q] = IQ_SLOT_WIDTH'(q);
        end
        // A balanced tournament keeps oldest-ready selection logarithmic in
        // queue depth while preserving global ROB-age priority.
        for (int node=IQ_TREE_LEAVES-1; node>0; node--) begin
            if (issue_tree_valid[2*node] && issue_tree_valid[2*node+1]) begin
                if (issue_tree_age[2*node] <= issue_tree_age[2*node+1]) begin
                    issue_tree_valid[node] = 1;
                    issue_tree_age[node] = issue_tree_age[2*node];
                    issue_tree_slot[node] = issue_tree_slot[2*node];
                end else begin
                    issue_tree_valid[node] = 1;
                    issue_tree_age[node] = issue_tree_age[2*node+1];
                    issue_tree_slot[node] = issue_tree_slot[2*node+1];
                end
            end else if (issue_tree_valid[2*node]) begin
                issue_tree_valid[node] = 1;
                issue_tree_age[node] = issue_tree_age[2*node];
                issue_tree_slot[node] = issue_tree_slot[2*node];
            end else if (issue_tree_valid[2*node+1]) begin
                issue_tree_valid[node] = 1;
                issue_tree_age[node] = issue_tree_age[2*node+1];
                issue_tree_slot[node] = issue_tree_slot[2*node+1];
            end
        end
        selected_slot = issue_tree_valid[1] ? int'(issue_tree_slot[1]) : -1;
        selected = '0;
        issue_rob = '0;
        issue_unit = 0;
        operand1 = 0;
        operand2 = 0;
        operand3 = 0;
        selected_ready1 = 1;
        selected_ready2 = 1;
        selected_ready3 = 1;
        if (selected_slot >= 0) begin
            issue_rob = iq[selected_slot].rob_tag;
            issue_unit = 2'(queue_unit(selected_slot));
            selected = rob[issue_rob];
            selected_ready1 = iq[selected_slot].ready1;
            selected_ready2 = iq[selected_slot].ready2;
            selected_ready3 = iq[selected_slot].ready3;
            operand1 = (!selected_ready1 && wb_valid && wb_packet.pdst != 0 &&
                        !wb_packet.exception && iq[selected_slot].src1 == wb_packet.pdst) ?
                       wb_packet.data : physical_regs[iq[selected_slot].src1];
            operand2 = (!selected_ready2 && wb_valid && wb_packet.pdst != 0 &&
                        !wb_packet.exception && iq[selected_slot].src2 == wb_packet.pdst) ?
                       wb_packet.data : physical_regs[iq[selected_slot].src2];
            operand3 = (!selected_ready3 && wb_valid && wb_packet.pdst != 0 &&
                        !wb_packet.exception && iq[selected_slot].src3 == wb_packet.pdst) ?
                       wb_packet.data : physical_regs[iq[selected_slot].src3];
        end
        issue_fire = rst_n && selected_slot >= 0 && !flush_backend;
    end

    logic units_rst_n;
    assign units_rst_n = rst_n && !flush_backend;
    ooo_multiply #(.TAG_WIDTH(TAG_WIDTH)) u_multiply (
        .clk(clk), .rst_n(units_rst_n), .req_valid(issue_fire && issue_unit == 1),
        .req_ready(mul_req_ready), .req_a(operand1), .req_b(operand2), .req_c(operand3),
        .req_op(selected.op), .req_tag({issue_rob,selected.pdst}),
        .resp_valid(mul_valid), .resp_ready(mul_resp_ready), .resp_result(mul_data), .resp_tag(mul_tag)
    );
    alu_div #(.DATA_WIDTH(32), .TAG_WIDTH(TAG_WIDTH)) u_divider (
        .clk(clk), .rst_n(units_rst_n), .req_valid(issue_fire && issue_unit == 2),
        .req_ready(div_req_ready), .req_dividend(operand1), .req_divisor(operand2),
        .req_signed(selected.op == ALU_DIV || selected.op == ALU_REM),
        .req_remainder(selected.op == ALU_REM || selected.op == ALU_REMU),
        .req_tag({issue_rob,selected.pdst}), .resp_valid(div_valid),
        .resp_ready(div_resp_ready), .resp_result(div_data), .resp_tag(div_tag)
    );

    logic [31:0] csr_read_data, csr_mtvec, csr_mepc, csr_mstatus;
    logic [31:0] csr_mcause, csr_mtval, csr_mscratch;
    logic csr_illegal;
    logic mret_retire, branch_recovery_retire;
    ooo_csr u_csr (
        .clk(clk), .rst_n(rst_n), .access_valid(issue_fire && issue_unit == 0 && selected.csr),
        .addr(selected.instr[31:20]), .funct3(selected.instr[14:12]),
        .source(selected.instr[14] ? {27'b0,selected.instr[19:15]} : operand1),
        .source_nonzero(selected.instr[19:15] != 0), .read_data(csr_read_data), .illegal(csr_illegal),
        .trap_valid(retire_trap), .trap_pc(retire_pc), .trap_cause(retire_cause), .trap_tval(retire_tval),
        .mret_valid(mret_retire), .mtvec(csr_mtvec), .mepc(csr_mepc), .mstatus(csr_mstatus),
        .mcause(csr_mcause), .mtval(csr_mtval), .mscratch(csr_mscratch)
    );

    logic [31:0] alu_a, alu_b, alu_value, resolved_pc;
    logic branch_taken;
    completion_t int_result;
    always_comb begin
        alu_a = selected.src_pc ? selected.pc : operand1;
        alu_b = selected.src_imm ? selected.imm : operand2;
        alu_value = 0;
        branch_taken = 0;
        case (selected.op)
            ALU_ADD: alu_value = alu_a+alu_b;
            ALU_SUB: alu_value = alu_a-alu_b;
            ALU_AND: alu_value = alu_a & alu_b;
            ALU_OR: alu_value = alu_a | alu_b;
            ALU_XOR: alu_value = alu_a ^ alu_b;
            ALU_SLL: alu_value = alu_a << alu_b[4:0];
            ALU_SRL: alu_value = alu_a >> alu_b[4:0];
            ALU_SRA: alu_value = $signed(alu_a) >>> alu_b[4:0];
            ALU_SLT: alu_value = {31'b0,$signed(alu_a) < $signed(alu_b)};
            ALU_SLTU: alu_value = {31'b0,alu_a < alu_b};
            ALU_BEQ: branch_taken = operand1 == operand2;
            ALU_BNE: branch_taken = operand1 != operand2;
            ALU_BLT: branch_taken = $signed(operand1) < $signed(operand2);
            ALU_BGE: branch_taken = $signed(operand1) >= $signed(operand2);
            ALU_BLTU: branch_taken = operand1 < operand2;
            ALU_BGEU: branch_taken = operand1 >= operand2;
            default: begin end
        endcase
        resolved_pc = selected.pc+32'd4;
        if (selected.jump || (selected.branch && branch_taken))
            resolved_pc = selected.jalr ? ((operand1+selected.imm) & 32'hfffffffe) : selected.pc+selected.imm;
        if (selected.mret) resolved_pc = csr_mepc;
        int_result = '0;
        int_result.rob_tag = issue_rob;
        int_result.pdst = selected.pdst;
        int_result.data = alu_value;
        int_result.taken = branch_taken;
        if (selected.instr[6:0] == 7'h37) int_result.data = selected.imm;
        if (selected.jump) int_result.data = selected.pc+32'd4;
        if (selected.csr) begin
            int_result.data = csr_read_data;
            if (csr_illegal) begin
                int_result.exception = 1;
                int_result.cause = 2;
                int_result.tval = selected.instr;
            end
        end
        if ((selected.jump || (selected.branch && branch_taken)) && resolved_pc[1:0] != 0) begin
            int_result.exception = 1;
            int_result.cause = 0;
            int_result.tval = resolved_pc;
        end
        recover_event = issue_fire && issue_unit == 0 && !int_result.exception &&
            ((selected.jump && resolved_pc != selected.pc+32'd4) ||
             (selected.branch && branch_taken != selected.pred_taken));
    end

    logic [RW-1:0] memory_rob;
    logic [PW-1:0] memory_pdst;
    logic memory_load, memory_unsigned;
    logic [1:0] memory_size;
    logic [31:0] memory_address, memory_wdata, memory_load_value;
    logic [3:0] memory_strobes;
    logic [31:0] effective_address, issue_store_data;
    logic [3:0] issue_store_strobes;
    logic memory_misaligned;
    always_comb begin
        effective_address = operand1+selected.imm;
        memory_misaligned = (selected.mem_size == 1 && effective_address[0]) ||
                            (selected.mem_size == 2 && effective_address[1:0] != 0);
        issue_store_data = operand2 << (8*effective_address[1:0]);
        case (selected.mem_size)
            0: begin
                issue_store_strobes = 4'b0001 << effective_address[1:0];
                issue_store_data = {24'b0,operand2[7:0]} << (8*effective_address[1:0]);
            end
            1: begin
                issue_store_strobes = 4'b0011 << effective_address[1:0];
                issue_store_data = {16'b0,operand2[15:0]} << (8*effective_address[1:0]);
            end
            default: issue_store_strobes = 4'b1111;
        endcase
        memory_load_value = d_rdata >> (8*memory_address[1:0]);
        case (memory_size)
            0: memory_load_value = memory_unsigned ? {24'b0,memory_load_value[7:0]} :
                                                     {{24{memory_load_value[7]}},memory_load_value[7:0]};
            1: memory_load_value = memory_unsigned ? {16'b0,memory_load_value[15:0]} :
                                                     {{16{memory_load_value[15]}},memory_load_value[15:0]};
            default: begin end
        endcase
    end
    assign d_read = rst_n && mem_busy && memory_load;
    assign d_write = rst_n && mem_busy && !memory_load;
    assign d_addr = memory_address;
    assign d_wdata = memory_wdata;
    assign d_wstrb = memory_strobes;

    // The common retirement interface is sampled on the committing edge.
    always_comb begin
        retire_valid = rst_n && rob_count != 0 && rob[rob_head].valid && rob[rob_head].done;
        retire_pc = rob[rob_head].pc;
        retire_instr = rob[rob_head].instr;
        retire_trap = retire_valid && rob[rob_head].exception;
        retire_rd_we = retire_valid && !retire_trap && rob[rob_head].writes_rd;
        retire_rd = rob[rob_head].rd;
        retire_rd_data = rob[rob_head].result;
        retire_mem_we = retire_valid && !retire_trap && rob[rob_head].store;
        // The sole outstanding head transaction remains stable until this
        // entry retires, so its trace fields need only one shared register.
        retire_mem_addr = memory_address;
        retire_mem_data = memory_wdata;
        retire_mem_strb = memory_strobes;
        retire_cause = rob[rob_head].cause;
        retire_tval = rob[rob_head].tval;
        mret_retire = retire_valid && !retire_trap && rob[rob_head].mret;
        branch_recovery_retire = retire_valid && recovering && rob_head == recovery_rob;
        flush_backend = retire_trap || mret_retire || branch_recovery_retire;
        branch_update_valid = retire_valid && !retire_trap && rob[rob_head].branch;
        jump_en = flush_backend;
        jump_target = retire_trap ? csr_mtvec : mret_retire ? csr_mepc : recovery_target;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rob_head <= 0;
            rob_tail <= 0;
            rob_count <= 0;
            recovering <= 0;
            recovery_rob <= 0;
            recovery_target <= 0;
            int_valid <= 0;
            mem_valid <= 0;
            mem_busy <= 0;
            int_packet <= '0;
            mem_packet <= '0;
            memory_address <= 0;
            memory_wdata <= 0;
            memory_strobes <= 0;
            memory_rob <= 0;
            memory_pdst <= 0;
            memory_load <= 0;
            memory_size <= 0;
            memory_unsigned <= 0;
            for (int p=0; p<PHYS_REGS; p++) begin
                physical_regs[p] <= 0;
                physical_ready[p] <= 1;
                free_bitmap[p] <= (p >= 32);
            end
            for (int a=0; a<32; a++) begin
                speculative_map[a] <= PW'(a);
                committed_map[a] <= PW'(a);
            end
            for (int r=0; r<ROB_ENTRIES; r++) rob[r] <= '0;
            for (int q=0; q<IQ_ENTRIES; q++) iq[q] <= '0;
        end else begin
            if (int_valid && completion_accept[0]) int_valid <= 0;
            if (mem_valid && completion_accept[3]) mem_valid <= 0;
            if (wb_valid) begin
                rob[wb_rob].done <= 1;
                rob[wb_rob].result <= wb_packet.data;
                rob[wb_rob].exception <= wb_packet.exception;
                rob[wb_rob].cause <= wb_packet.cause;
                rob[wb_rob].tval <= wb_packet.tval;
                rob[wb_rob].taken <= wb_packet.taken;
                if (wb_packet.pdst != 0 && !wb_packet.exception) begin
                    physical_regs[wb_packet.pdst] <= wb_packet.data;
                    physical_ready[wb_packet.pdst] <= 1;
                end
                for (int q=0; q<IQ_ENTRIES; q++) begin
                    if (iq[q].src1 == wb_packet.pdst && !wb_packet.exception) iq[q].ready1 <= 1;
                    if (iq[q].src2 == wb_packet.pdst && !wb_packet.exception) iq[q].ready2 <= 1;
                    if (iq[q].src3 == wb_packet.pdst && !wb_packet.exception) iq[q].ready3 <= 1;
                end
            end
            if (retire_valid) begin
                rob[rob_head].valid <= 0;
                rob_head <= next_rob(rob_head);
                if (retire_rd_we) begin
                    committed_map[rob[rob_head].rd] <= rob[rob_head].pdst;
                    free_bitmap[rob[rob_head].old_pdst] <= 1;
                end
            end
            case ({dispatch_fire,retire_valid})
                2'b10: rob_count <= rob_count+1'b1;
                2'b01: rob_count <= rob_count-1'b1;
                default: begin end
            endcase
            if (dispatch_fire) begin
                rob[rob_tail] <= '0;
                rob[rob_tail].valid <= 1;
                rob[rob_tail].done <= decoded_exception;
                rob[rob_tail].pc <= instr_pc;
                rob[rob_tail].instr <= instr;
                rob[rob_tail].rd <= instr[11:7];
                rob[rob_tail].writes_rd <= decoded_write && instr[11:7] != 0;
                rob[rob_tail].pdst <= (decoded_write && instr[11:7] != 0) ? allocated_phys : PW'(0);
                rob[rob_tail].old_pdst <= speculative_map[instr[11:7]];
                rob[rob_tail].op <= dec_op;
                rob[rob_tail].imm <= dec_imm;
                rob[rob_tail].src_imm <= dec_src_imm;
                rob[rob_tail].src_pc <= dec_src_pc;
                rob[rob_tail].branch <= dec_branch;
                rob[rob_tail].jump <= dec_jump;
                rob[rob_tail].jalr <= dec_jalr;
                rob[rob_tail].pred_taken <= instr_pred_taken;
                rob[rob_tail].load <= dec_load;
                rob[rob_tail].store <= dec_store;
                rob[rob_tail].mem_size <= dec_size;
                rob[rob_tail].mem_unsigned <= dec_unsigned;
                rob[rob_tail].csr <= decoded_csr;
                rob[rob_tail].mret <= decoded_mret;
                rob[rob_tail].serial <= decoded_serial;
                rob[rob_tail].exception <= decoded_exception;
                rob[rob_tail].cause <= decoded_cause;
                rob[rob_tail].tval <= decoded_tval;
                rob_tail <= next_rob(rob_tail);
                if (decoded_write && instr[11:7] != 0) begin
                    speculative_map[instr[11:7]] <= allocated_phys;
                    free_bitmap[allocated_phys] <= 0;
                    physical_ready[allocated_phys] <= 0;
                end
                if (!decoded_exception) begin
                    iq[dispatch_slot].valid <= 1;
                    iq[dispatch_slot].rob_tag <= rob_tail;
                    iq[dispatch_slot].src1 <= dispatch_src1;
                    iq[dispatch_slot].src2 <= dispatch_src2;
                    iq[dispatch_slot].src3 <= dispatch_src3;
                    iq[dispatch_slot].ready1 <= physical_ready[dispatch_src1] ||
                        (wb_valid && !wb_packet.exception && wb_packet.pdst == dispatch_src1);
                    iq[dispatch_slot].ready2 <= physical_ready[dispatch_src2] ||
                        (wb_valid && !wb_packet.exception && wb_packet.pdst == dispatch_src2);
                    iq[dispatch_slot].ready3 <= physical_ready[dispatch_src3] ||
                        (wb_valid && !wb_packet.exception && wb_packet.pdst == dispatch_src3);
                end
            end
            if (issue_fire) begin
                iq[selected_slot].valid <= 0;
                if (issue_unit == 0) begin
                    int_valid <= 1;
                    int_packet <= int_result;
                end
                if (issue_unit == 3) begin
                    if (memory_misaligned) begin
                        mem_valid <= 1;
                        mem_packet <= '0;
                        mem_packet.rob_tag <= issue_rob;
                        mem_packet.pdst <= selected.pdst;
                        mem_packet.exception <= 1;
                        mem_packet.cause <= selected.store ? 32'd6 : 32'd4;
                        mem_packet.tval <= effective_address;
                    end else begin
                        mem_busy <= 1;
                        memory_rob <= issue_rob;
                        memory_pdst <= selected.pdst;
                        memory_load <= selected.load;
                        memory_unsigned <= selected.mem_unsigned;
                        memory_size <= selected.mem_size;
                        memory_address <= effective_address;
                        memory_wdata <= issue_store_data;
                        memory_strobes <= issue_store_strobes;
                    end
                end
            end
            if (mem_busy && !d_waitrequest) begin
                mem_busy <= 0;
                mem_valid <= 1;
                mem_packet <= '0;
                mem_packet.rob_tag <= memory_rob;
                mem_packet.pdst <= memory_pdst;
                mem_packet.data <= memory_load ? memory_load_value : 32'b0;
            end
            // An older branch may supersede an already pending younger one.
            // No allocation or slot reuse is possible until the boundary.
            if (recover_event) begin
                recovering <= 1;
                recovery_rob <= issue_rob;
                recovery_target <= resolved_pc;
                rob_count <= age(issue_rob) + CW'(1) - CW'(retire_valid);
                for (int r=0; r<ROB_ENTRIES; r++)
                    if (age(RW'(r)) > age(issue_rob)) rob[r].valid <= 0;
                for (int q=0; q<IQ_ENTRIES; q++)
                    if (age(iq[q].rob_tag) > age(issue_rob)) iq[q].valid <= 0;
            end
            if (flush_backend) begin
                // All pre-boundary completions are synchronously invalidated,
                // including all 32 divider stages, before any tag can be reused.
                int_valid <= 0;
                mem_valid <= 0;
                mem_busy <= 0;
                rob_head <= 0;
                rob_tail <= 0;
                rob_count <= 0;
                recovering <= 0;
                for (int r=0; r<ROB_ENTRIES; r++) rob[r].valid <= 0;
                for (int q=0; q<IQ_ENTRIES; q++) iq[q].valid <= 0;
                for (int a=0; a<32; a++)
                    speculative_map[a] <= (retire_rd_we && rob[rob_head].rd == 5'(a)) ?
                                           rob[rob_head].pdst : committed_map[a];
                for (int p=0; p<PHYS_REGS; p++) begin : rebuild_free
                    logic occupied;
                    occupied = (p == 0);
                    for (int a=1; a<32; a++)
                        if (((retire_rd_we && rob[rob_head].rd == 5'(a)) ?
                              rob[rob_head].pdst : committed_map[a]) == PW'(p)) occupied = 1;
                    free_bitmap[p] <= !occupied;
                    physical_ready[p] <= 1;
                end
            end
        end
    end

    initial begin
        if (DATA_WIDTH != 32 || ADDR_WIDTH != 32)
            $fatal(1,"ooo_core implements RV32 with 32-bit memory lanes");
        if (ROB_ENTRIES < 2 || PHYS_REGS < 33 || INT_ENTRIES < 1 ||
            MUL_ENTRIES < 1 || DIV_ENTRIES < 1 || MEM_ENTRIES < 1)
            $fatal(1,"invalid OOO capacity");
    end

`ifndef SYNTHESIS
    // Ownership is checked against both architectural and in-flight mappings.
    always @(posedge clk) if (rst_n) begin
        assert (!free_bitmap[0] && physical_ready[0] && physical_regs[0] == 0);
        assert (speculative_map[0] == 0 && committed_map[0] == 0);
        assert (int'(rob_count) <= ROB_ENTRIES);
        assert (!(d_read && d_write));
        if (d_read || d_write) begin
            assert (memory_rob == rob_head && rob[rob_head].valid);
            assert (!rob[rob_head].exception);
        end
        for (int a=1; a<32; a++) begin
            assert (committed_map[a] != 0 && !free_bitmap[committed_map[a]]);
            for (int b=a+1; b<32; b++) assert (committed_map[a] != committed_map[b]);
        end
        for (int r=0; r<ROB_ENTRIES; r++) if (rob[r].valid && rob[r].writes_rd) begin
            assert (rob[r].pdst != 0 && !free_bitmap[rob[r].pdst]);
            for (int s=r+1; s<ROB_ENTRIES; s++)
                if (rob[s].valid && rob[s].writes_rd) assert (rob[r].pdst != rob[s].pdst);
        end
        if (retire_rd_we) assert (rob[rob_head].old_pdst != 0 && !free_bitmap[rob[rob_head].old_pdst]);
    end
    assert property (@(posedge clk) disable iff (!rst_n)
        (d_read || d_write) && d_waitrequest |=> $stable({d_read,d_write,d_addr,d_wdata,d_wstrb}));
`endif
endmodule

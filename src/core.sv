`include "cpu_pkg.sv"
`include "./alu/alu.sv"
`ifndef CORE_ASIC_SYNTH
`ifndef CORE_STANDALONE
`include "./memory/memory_system.sv"
`endif
`endif
`include "decoder.sv"
`include "fetch.sv"
`include "regfile.sv"
`include "imm_gen.sv"

import cpu_pkg::*;

module core #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 32,
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
    input logic rst_n
`ifdef CORE_ASIC_SYNTH
    , output logic                   i_read
    , output logic [ADDR_WIDTH-1:0]   i_addr
    , input  logic [DATA_WIDTH-1:0]   i_data
    , input  logic                   i_waitrequest
    , output logic                   d_read
    , output logic                   d_write
    , output logic [ADDR_WIDTH-1:0]   d_addr
    , output logic [DATA_WIDTH-1:0]   d_wdata
    , output logic [DATA_WIDTH/8-1:0] d_wstrb
    , input  logic [DATA_WIDTH-1:0]   d_rdata
    , input  logic                   d_waitrequest
`endif
);

`ifndef CORE_ASIC_SYNTH
    logic                    i_read;
    logic [ADDR_WIDTH-1:0]    i_addr;
    logic [DATA_WIDTH-1:0]    i_data;
    logic                    i_waitrequest;
    logic                    d_read;
    logic                    d_write;
    logic [ADDR_WIDTH-1:0]    d_addr;
    logic [DATA_WIDTH-1:0]    d_wdata;
    logic [DATA_WIDTH/8-1:0]  d_wstrb;
    logic [DATA_WIDTH-1:0]    d_rdata;
    logic                    d_waitrequest;
`endif

    localparam int BYTE_LANES        = DATA_WIDTH / 8;
    localparam int BYTE_OFFSET_BITS  = $clog2(BYTE_LANES);

    localparam logic [1:0] WB_ALU    = 2'b00;
    localparam logic [1:0] WB_LOAD   = 2'b01;
    localparam logic [1:0] WB_PC4    = 2'b10;
    localparam logic [1:0] WB_IMM    = 2'b11;

    localparam logic [1:0] MEM_BYTE  = 2'b00;
    localparam logic [1:0] MEM_HALF  = 2'b01;
    localparam logic [1:0] MEM_WORD  = 2'b10;

    localparam logic [1:0] FWD_REG   = 2'b00;
    localparam logic [1:0] FWD_MEMWB = 2'b01;
    localparam logic [1:0] FWD_EXMEM = 2'b10;
    localparam logic [1:0] FWD_DMEM  = 2'b11;

    // ------------------------------------------------------------------------
    // Fetch stage
    // ------------------------------------------------------------------------
    logic                  jump_en;
    logic [ADDR_WIDTH-1:0] jump_target;
    logic                  branch_update_valid;
    logic [ADDR_WIDTH-1:0] branch_update_pc;
    logic                  branch_update_taken;
    logic [DATA_WIDTH-1:0] instr;
    logic                  instr_valid;
    logic [ADDR_WIDTH-1:0] instr_pc;
    logic                  instr_pred_taken;
    logic                  pipeline_stall;
    logic                  hazard_stall;
    logic                  front_stall;

    fetch u_fetch (
        .clk(clk),
        .rst_n(rst_n),
        // Fetch may continue filling its FIFO while the in-order backend is
        // blocked by a data-side wait. The FIFO and redirect logic provide
        // the required backpressure/flush behavior.
        .stall(1'b0),
        .jump_en(jump_en),
        .jump_target(jump_target),
        .branch_update_valid(branch_update_valid),
        .branch_update_pc(branch_update_pc),
        .branch_update_taken(branch_update_taken),
        .consume(decode_enable),
        .i_read(i_read),
        .i_addr(i_addr),
        .i_data(i_data),
        .i_waitrequest(i_waitrequest),
        .instr(instr),
        .instr_valid(instr_valid),
        .instr_pc(instr_pc),
        .instr_pred_taken(instr_pred_taken)
    );

    // ------------------------------------------------------------------------
    // Decode stage
    // ------------------------------------------------------------------------
    opcode_e cur_opcode;
    logic [2:0] cur_funct3;
    logic [6:0] cur_funct7;

    assign cur_opcode = opcode_e'(instr[6:0]);
    assign cur_funct3 = instr[14:12];
    assign cur_funct7 = instr[31:25];

    alu_op_e    cur_id_alu_op;
    logic       cur_id_mem_read;
    logic       cur_id_mem_write;
    logic       cur_id_reg_write;
    logic       cur_id_mem_to_reg_write;
    logic       cur_id_alu_src_imm;
    logic       cur_id_alu_src_pc;
    logic       cur_id_branch;
    logic       cur_id_jump;
    logic       cur_id_jalr;
    logic       cur_id_uses_rs1;
    logic       cur_id_uses_rs2;
    logic       cur_id_uses_rd_old;
    imm_src_e   cur_id_imm_type;
    logic [1:0] cur_id_wb_sel;
    logic [1:0] cur_id_mem_size;
    logic       cur_id_mem_unsigned;
    logic       cur_id_illegal_instr;

    decoder u_decoder (
        .cur_opcode(cur_opcode),
        .cur_funct3(cur_funct3),
        .cur_funct7(cur_funct7),
        .cur_id_alu_op(cur_id_alu_op),
        .cur_id_mem_read(cur_id_mem_read),
        .cur_id_mem_write(cur_id_mem_write),
        .cur_id_reg_write(cur_id_reg_write),
        .cur_id_mem_to_reg_write(cur_id_mem_to_reg_write),
        .cur_id_alu_src_imm(cur_id_alu_src_imm),
        .cur_id_alu_src_pc(cur_id_alu_src_pc),
        .cur_id_branch(cur_id_branch),
        .cur_id_jump(cur_id_jump),
        .cur_id_jalr(cur_id_jalr),
        .cur_id_uses_rs1(cur_id_uses_rs1),
        .cur_id_uses_rs2(cur_id_uses_rs2),
        .cur_id_uses_rd_old(cur_id_uses_rd_old),
        .cur_id_imm_type(cur_id_imm_type),
        .cur_id_wb_sel(cur_id_wb_sel),
        .cur_id_mem_size(cur_id_mem_size),
        .cur_id_mem_unsigned(cur_id_mem_unsigned),
        .cur_id_illegal_instr(cur_id_illegal_instr)
    );

    logic [DATA_WIDTH-1:0] imm_out;

    imm_gen u_imm_gen (
        .instr(instr),
        .imm_type(cur_id_imm_type),
        .imm_out(imm_out)
    );

    // Register-file read values are captured into ID/EX below.
    logic [DATA_WIDTH-1:0] rs1_val;
    logic [DATA_WIDTH-1:0] rs2_val;
    logic [DATA_WIDTH-1:0] rd_old_val;

    // ------------------------------------------------------------------------
    // Register file
    // ------------------------------------------------------------------------
    regfile #(
        .ADDR_WIDTH(5),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_regfile (
        .clk(clk),
        .we(mem_wb_valid && mem_wb_reg_write),
        .rs1_addr(instr[19:15]),
        .rs2_addr(instr[24:20]),
        .rd_old_addr(instr[11:7]),
        .rd_addr(mem_wb_rd),
        .rd_data(wb_data),
        .rs1_data(rs1_val),
        .rs2_data(rs2_val),
        .rd_old_data(rd_old_val)
    );

    // ------------------------------------------------------------------------
    // Execute stage
    // ------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] alu_result;
    logic [ADDR_WIDTH-1:0] alu_addr;

    alu #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_alu (
        .rs1_val(execute_rs1_val),
        .rs2_val(execute_rs2_val),
        .rd_old_val(execute_rd_old_val),
        .pc_val(DATA_WIDTH'(id_ex_instr_pc)),
        .imm_val(id_ex_imm_out),
        .cur_id_alu_op(id_ex_alu_op),
        .cur_id_alu_src_imm(id_ex_alu_src_imm),
        .cur_id_alu_src_pc(id_ex_alu_src_pc),
        .alu_result(alu_result),
        .alu_addr(alu_addr)
    );

    // ------------------------------------------------------------------------
    // Memory stage
    // ------------------------------------------------------------------------
`ifndef CORE_ASIC_SYNTH
    memory_system #(
        .L1_CACHE_SIZE(L1_CACHE_SIZE),
        .L2_CACHE_SIZE(L2_CACHE_SIZE),
`ifdef CORE_STANDALONE
        .NUM_WAYS(L1_NUM_WAYS),
`else
        .L1_NUM_WAYS(L1_NUM_WAYS),
        .L2_NUM_WAYS(L2_NUM_WAYS),
`endif
        .L1_LATENCY(L1_LATENCY),
        .L2_LATENCY(L2_LATENCY),
        .DRAM_LATENCY(DRAM_LATENCY),
        .DRAM_SIZE(DRAM_SIZE)
    ) u_memory_system (
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
`endif

    // ------------------------------------------------------------------------
    // Pipeline registers
    // ------------------------------------------------------------------------

    // ID/EX: decoded instruction and operands consumed by execute.
    logic                  id_ex_valid;
    logic [4:0]            id_ex_rd;
    logic [4:0]            id_ex_rs1_addr;
    logic [4:0]            id_ex_rs2_addr;
    logic [DATA_WIDTH-1:0] id_ex_rs1_val;
    logic [DATA_WIDTH-1:0] id_ex_rs2_val;
    logic [DATA_WIDTH-1:0] id_ex_rd_old_val;
    logic [DATA_WIDTH-1:0] id_ex_imm_out;
    logic [ADDR_WIDTH-1:0] id_ex_instr_pc;
    alu_op_e               id_ex_alu_op;
    logic                  id_ex_alu_src_imm;
    logic                  id_ex_alu_src_pc;
    logic                  id_ex_branch;
    logic                  id_ex_pred_taken;
    logic                  id_ex_jump;
    logic                  id_ex_jalr;
    logic                  id_ex_mem_read;
    logic                  id_ex_mem_write;
    logic                  id_ex_mem_to_reg_write;
    logic [1:0]            id_ex_mem_size;
    logic                  id_ex_mem_unsigned;
    logic                  id_ex_reg_write;
    logic [1:0]            id_ex_wb_sel;
    logic                  id_ex_illegal_instr;

    // Forwarding and hazard controls.
    logic [DATA_WIDTH-1:0] execute_rs1_val;
    logic [DATA_WIDTH-1:0] execute_rs2_val;
    logic [DATA_WIDTH-1:0] execute_rd_old_val;
    logic [DATA_WIDTH-1:0] ex_mem_forward_data;
    logic [DATA_WIDTH-1:0] ex_mem_load_forward_data;
    logic [DATA_WIDTH-1:0] decode_rs1_capture;
    logic [DATA_WIDTH-1:0] decode_rs2_capture;
    logic [DATA_WIDTH-1:0] decode_rd_old_capture;
    logic [1:0]            forward_rs1_sel;
    logic [1:0]            forward_rs2_sel;
    logic [1:0]            forward_rd_old_sel;

    // EX/MEM: execute results and controls consumed by data memory.
    logic                  ex_mem_valid;
    logic [4:0]            ex_mem_rd;
    logic [DATA_WIDTH-1:0] ex_mem_alu_result;
    logic [DATA_WIDTH-1:0] ex_mem_rs2_val;
    logic [DATA_WIDTH-1:0] ex_mem_imm_out;
    logic [ADDR_WIDTH-1:0] ex_mem_instr_pc;
    logic                  ex_mem_mem_read;
    logic                  ex_mem_mem_write;
    logic                  ex_mem_mem_to_reg_write;
    logic [1:0]            ex_mem_mem_size;
    logic                  ex_mem_mem_unsigned;
    logic                  ex_mem_reg_write;
    logic [1:0]            ex_mem_wb_sel;
    logic                  ex_mem_illegal_instr;

    // MEM/WB: values and controls consumed by writeback.
    logic                  mem_wb_valid;
    logic [4:0]            mem_wb_rd;
    logic [DATA_WIDTH-1:0] mem_wb_alu_result;
    logic [DATA_WIDTH-1:0] mem_wb_d_rdata;
    logic [DATA_WIDTH-1:0] mem_wb_imm_out;
    logic [ADDR_WIDTH-1:0] mem_wb_instr_pc;
    logic                  mem_wb_mem_to_reg_write;
    logic [1:0]            mem_wb_mem_size;
    logic                  mem_wb_mem_unsigned;
    logic                  mem_wb_reg_write;
    logic [1:0]            mem_wb_sel;
    logic                  mem_wb_illegal_instr;

    // Writeback formatting.
    logic [DATA_WIDTH-1:0] wb_data;
    logic [DATA_WIDTH-1:0] load_data_formatted;
    logic [7:0]             load_byte;
    logic [15:0]            load_half;
    logic [31:0]            load_word;
    // Pipeline advance controls.
    // A data-side wait request stalls the front end and holds EX/MEM. A
    // load-use hazard stalls only the front end and inserts an ID/EX bubble.
    logic fetch_enable;
    logic decode_enable;
    logic memory_advance;
    logic id_ex_is_div;
    logic div_instruction_hold;
    logic div_pending;
    logic div_req_valid;
    logic div_req_ready;
    logic div_resp_valid;
    logic div_resp_ready;
    logic div_result_accept;
    logic [DATA_WIDTH-1:0] div_resp_result;
    logic [4:0] div_resp_tag;
    logic [4:0] div_req_tag;
    logic div_req_signed;
    logic div_req_remainder;

    // ------------------------------------------------------------------------
    // Memory request and pipeline control signals
    // ------------------------------------------------------------------------
    assign d_read  = ex_mem_valid && ex_mem_mem_read;
    assign d_write = ex_mem_valid && ex_mem_mem_write;
    assign d_addr  = ex_mem_alu_result;
    assign pipeline_stall = rst_n && d_waitrequest;
    assign front_stall = pipeline_stall || hazard_stall;

    assign id_ex_is_div = (id_ex_alu_op == ALU_DIV) ||
                          (id_ex_alu_op == ALU_DIVU) ||
                          (id_ex_alu_op == ALU_REM) ||
                          (id_ex_alu_op == ALU_REMU);
    assign div_req_signed = (id_ex_alu_op == ALU_DIV) || (id_ex_alu_op == ALU_REM);
    assign div_req_remainder = (id_ex_alu_op == ALU_REM) || (id_ex_alu_op == ALU_REMU);
    assign div_req_tag = id_ex_rd;
    assign div_req_valid = rst_n && id_ex_valid && id_ex_is_div &&
                           !div_pending && !pipeline_stall;
    assign div_resp_ready = div_pending && !pipeline_stall;
    assign div_result_accept = div_pending && div_resp_valid && div_resp_ready;
    assign div_instruction_hold = id_ex_valid && id_ex_is_div && !div_result_accept;

    alu_div #(.DATA_WIDTH(DATA_WIDTH), .TAG_WIDTH(5)) u_divider (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(div_req_valid),
        .req_ready(div_req_ready),
        .req_dividend(execute_rs1_val),
        .req_divisor(execute_rs2_val),
        .req_signed(div_req_signed),
        .req_remainder(div_req_remainder),
        .req_tag(div_req_tag),
        .resp_valid(div_resp_valid),
        .resp_ready(div_resp_ready),
        .resp_result(div_resp_result),
        .resp_tag(div_resp_tag)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_pending <= 1'b0;
        end else begin
            if (div_req_valid && div_req_ready)
                div_pending <= 1'b1;
            if (div_result_accept)
                div_pending <= 1'b0;
        end
    end

    assign branch_update_valid = memory_advance && id_ex_valid &&
                                 id_ex_branch && !id_ex_illegal_instr;
    assign branch_update_pc = id_ex_instr_pc;
    assign branch_update_taken = alu_result[0];

    // A load-use dependency no longer needs a dedicated bubble. The load is
    // allowed into EX/MEM, and the dependent instruction is held there until
    // the data-side response is available for direct forwarding into EX.
    // Keep hazard_stall as the externally visible *actual* stall metric; it is
    // zero for dependencies handled by the data-response bypass.
    assign hazard_stall = 1'b0;

    // Format a load response while it is still on the data-cache interface.
    // This is the same operation used for MEM/WB writeback, but it is needed
    // one stage earlier for a dependent instruction executing behind a load.
    always_comb begin
        ex_mem_load_forward_data = '0;
        case (ex_mem_mem_size)
            MEM_BYTE: begin
                if (ex_mem_mem_unsigned)
                    ex_mem_load_forward_data = {{(DATA_WIDTH-8){1'b0}},
                                                 d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 8]};
                else
                    ex_mem_load_forward_data = {{(DATA_WIDTH-8){d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) + 7]}},
                                                 d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 8]};
            end

            MEM_HALF: begin
                if (ex_mem_mem_unsigned)
                    ex_mem_load_forward_data = {{(DATA_WIDTH-16){1'b0}},
                                                 d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 16]};
                else
                    ex_mem_load_forward_data = {{(DATA_WIDTH-16){d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) + 15]}},
                                                 d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 16]};
            end

            MEM_WORD: begin
                ex_mem_load_forward_data = {{(DATA_WIDTH-32){d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) + 31]}},
                                             d_rdata[(ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 32]};
            end

            default: begin
                ex_mem_load_forward_data = '0;
            end
        endcase
    end

    always_comb begin
        ex_mem_forward_data = '0;
        case (ex_mem_wb_sel)
            WB_ALU: ex_mem_forward_data = ex_mem_alu_result;
            WB_LOAD: ex_mem_forward_data = ex_mem_load_forward_data;
            WB_PC4: ex_mem_forward_data = DATA_WIDTH'(ex_mem_instr_pc) + DATA_WIDTH'(4);
            WB_IMM: ex_mem_forward_data = ex_mem_imm_out;
            default: ex_mem_forward_data = '0;
        endcase

        // Capture the youngest already-produced value when an instruction
        // enters ID/EX. This matters when a following instruction is then
        // held behind a long data miss: the producer may leave MEM/WB before
        // the held instruction finally executes.
        decode_rs1_capture = rs1_val;
        decode_rs2_capture = rs2_val;
        decode_rd_old_capture = rd_old_val;

        if (mem_wb_valid && mem_wb_reg_write && mem_wb_rd != 5'd0) begin
            if (mem_wb_rd == instr[19:15]) decode_rs1_capture = wb_data;
            if (mem_wb_rd == instr[24:20]) decode_rs2_capture = wb_data;
            if (mem_wb_rd == instr[11:7]) decode_rd_old_capture = wb_data;
        end

        if (ex_mem_valid && ex_mem_reg_write && ex_mem_rd != 5'd0 &&
            (!ex_mem_mem_read || !d_waitrequest)) begin
            if (ex_mem_rd == instr[19:15])
                decode_rs1_capture = ex_mem_mem_read ? ex_mem_load_forward_data : ex_mem_forward_data;
            if (ex_mem_rd == instr[24:20])
                decode_rs2_capture = ex_mem_mem_read ? ex_mem_load_forward_data : ex_mem_forward_data;
            if (ex_mem_rd == instr[11:7])
                decode_rd_old_capture = ex_mem_mem_read ? ex_mem_load_forward_data : ex_mem_forward_data;
        end

        forward_rs1_sel = FWD_REG;
        forward_rs2_sel = FWD_REG;
        forward_rd_old_sel = FWD_REG;

        if (id_ex_valid && ex_mem_valid && ex_mem_reg_write &&
            (ex_mem_rd != 5'd0)) begin
            if (ex_mem_mem_read) begin
                // d_rdata is meaningful for the current EX/MEM load only
                // when the cache has dropped waitrequest.
                if (!d_waitrequest) begin
                    if (ex_mem_rd == id_ex_rs1_addr)
                        forward_rs1_sel = FWD_DMEM;
                    if (ex_mem_rd == id_ex_rs2_addr)
                        forward_rs2_sel = FWD_DMEM;
                    if (ex_mem_rd == id_ex_rd)
                        forward_rd_old_sel = FWD_DMEM;
                end
            end else begin
                if (ex_mem_rd == id_ex_rs1_addr)
                    forward_rs1_sel = FWD_EXMEM;
                if (ex_mem_rd == id_ex_rs2_addr)
                    forward_rs2_sel = FWD_EXMEM;
                if (ex_mem_rd == id_ex_rd)
                    forward_rd_old_sel = FWD_EXMEM;
            end
        end

        if (id_ex_valid && mem_wb_valid && mem_wb_reg_write &&
            (mem_wb_rd != 5'd0)) begin
            if ((forward_rs1_sel == FWD_REG) && (mem_wb_rd == id_ex_rs1_addr))
                forward_rs1_sel = FWD_MEMWB;
            if ((forward_rs2_sel == FWD_REG) && (mem_wb_rd == id_ex_rs2_addr))
                forward_rs2_sel = FWD_MEMWB;
            if ((forward_rd_old_sel == FWD_REG) && (mem_wb_rd == id_ex_rd))
                forward_rd_old_sel = FWD_MEMWB;
        end

        case (forward_rs1_sel)
            FWD_EXMEM: execute_rs1_val = ex_mem_forward_data;
            FWD_DMEM: execute_rs1_val = ex_mem_load_forward_data;
            FWD_MEMWB: execute_rs1_val = wb_data;
            default: execute_rs1_val = id_ex_rs1_val;
        endcase

        case (forward_rs2_sel)
            FWD_EXMEM: execute_rs2_val = ex_mem_forward_data;
            FWD_DMEM: execute_rs2_val = ex_mem_load_forward_data;
            FWD_MEMWB: execute_rs2_val = wb_data;
            default: execute_rs2_val = id_ex_rs2_val;
        endcase

        case (forward_rd_old_sel)
            FWD_EXMEM: execute_rd_old_val = ex_mem_forward_data;
            FWD_DMEM: execute_rd_old_val = ex_mem_load_forward_data;
            FWD_MEMWB: execute_rd_old_val = wb_data;
            default: execute_rd_old_val = id_ex_rd_old_val;
        endcase
    end

    // Format store data and byte enables for the addressed memory lanes.
    always_comb begin
        d_wdata = '0;
        d_wstrb = '0;

        case (ex_mem_mem_size)
            MEM_BYTE: begin
                d_wdata[ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8 +: 8]
                    = ex_mem_rs2_val[7:0];
                d_wstrb[ex_mem_alu_result[BYTE_OFFSET_BITS-1:0]] = 1'b1;
            end

            MEM_HALF: begin
                d_wdata[ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8 +: 16]
                    = ex_mem_rs2_val[15:0];
                d_wstrb[ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] +: 2] = 2'b11;
            end

            MEM_WORD: begin
                d_wdata[ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] * 8 +: 32]
                    = ex_mem_rs2_val[31:0];
                d_wstrb[ex_mem_alu_result[BYTE_OFFSET_BITS-1:0] +: 4] = 4'b1111;
            end

            default: begin
                d_wdata = '0;
                d_wstrb = '0;
            end
        endcase
    end

    // sequential logic
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // ID/EX reset
            id_ex_valid              <= 1'b0;
            id_ex_rd                 <= 5'b0;
            id_ex_rs1_addr           <= 5'b0;
            id_ex_rs2_addr           <= 5'b0;
            id_ex_rs1_val            <= '0;
            id_ex_rs2_val            <= '0;
            id_ex_rd_old_val         <= '0;
            id_ex_imm_out            <= '0;
            id_ex_instr_pc           <= '0;
            id_ex_alu_op             <= ALU_ADD;
            id_ex_alu_src_imm        <= 1'b0;
            id_ex_alu_src_pc         <= 1'b0;
            id_ex_branch             <= 1'b0;
            id_ex_pred_taken         <= 1'b0;
            id_ex_jump               <= 1'b0;
            id_ex_jalr               <= 1'b0;
            id_ex_mem_read           <= 1'b0;
            id_ex_mem_write          <= 1'b0;
            id_ex_mem_to_reg_write   <= 1'b0;
            id_ex_mem_size           <= MEM_WORD;
            id_ex_mem_unsigned       <= 1'b0;
            id_ex_reg_write          <= 1'b0;
            id_ex_wb_sel             <= WB_ALU;
            id_ex_illegal_instr      <= 1'b0;

            // EX/MEM reset
            ex_mem_valid             <= 1'b0;
            ex_mem_rd                <= 5'b0;
            ex_mem_alu_result        <= '0;
            ex_mem_rs2_val           <= '0;
            ex_mem_imm_out           <= '0;
            ex_mem_instr_pc          <= '0;
            ex_mem_mem_read          <= 1'b0;
            ex_mem_mem_write         <= 1'b0;
            ex_mem_mem_to_reg_write  <= 1'b0;
            ex_mem_mem_size          <= MEM_WORD;
            ex_mem_mem_unsigned      <= 1'b0;
            ex_mem_reg_write         <= 1'b0;
            ex_mem_wb_sel            <= WB_ALU;
            ex_mem_illegal_instr     <= 1'b0;

            // MEM/WB reset
            mem_wb_valid              <= 1'b0;
            mem_wb_rd                 <= 5'b0;
            mem_wb_alu_result         <= '0;
            mem_wb_d_rdata            <= '0;
            mem_wb_imm_out            <= '0;
            mem_wb_instr_pc           <= '0;
            mem_wb_mem_to_reg_write   <= 1'b0;
            mem_wb_mem_size           <= MEM_WORD;
            mem_wb_mem_unsigned       <= 1'b0;
            mem_wb_reg_write          <= 1'b0;
            mem_wb_sel                <= WB_ALU;
            mem_wb_illegal_instr      <= 1'b0;

        end else begin
            // ID/EX: accept a decoded instruction, or insert a bubble when
            // the front end is stalled or execute redirects the fetch PC.
            if (decode_enable) begin
                id_ex_valid <= 1'b1;
                id_ex_wb_sel <= cur_id_wb_sel;
                id_ex_reg_write <= cur_id_reg_write;
                id_ex_rd <= instr[11:7];
                id_ex_rs1_addr <= instr[19:15];
                id_ex_rs2_addr <= instr[24:20];
                id_ex_imm_out <= imm_out;
                id_ex_instr_pc <= instr_pc;
                // Decode and register writeback sample the same edge. Bypass
                // WB here so ID/EX does not capture the pre-write register value.
                id_ex_rs1_val <= decode_rs1_capture;
                id_ex_rs2_val <= decode_rs2_capture;
                id_ex_rd_old_val <= decode_rd_old_capture;
                id_ex_alu_op <= cur_id_alu_op;
                id_ex_alu_src_imm <= cur_id_alu_src_imm;
                id_ex_alu_src_pc <= cur_id_alu_src_pc;
                id_ex_branch <= cur_id_branch;
                id_ex_pred_taken <= instr_pred_taken;
                id_ex_jump <= cur_id_jump;
                id_ex_jalr <= cur_id_jalr;
                id_ex_mem_to_reg_write <= cur_id_mem_to_reg_write;
                id_ex_mem_read <= cur_id_mem_read;
                id_ex_mem_write <= cur_id_mem_write;
                id_ex_mem_size <= cur_id_mem_size;
                id_ex_mem_unsigned <= cur_id_mem_unsigned;
                id_ex_illegal_instr <= cur_id_illegal_instr;
            end else if (!pipeline_stall && !div_instruction_hold) begin
                // No fetched instruction this cycle: insert a bubble.
                id_ex_valid <= 1'b0;

                if (jump_en || hazard_stall) begin
                    // Clear the remaining ID/EX state so a redirected or
                    // stalled instruction cannot create side effects later.
                    id_ex_rd                 <= 5'b0;
                    id_ex_rs1_addr           <= 5'b0;
                    id_ex_rs2_addr           <= 5'b0;
                    id_ex_rs1_val            <= '0;
                    id_ex_rs2_val            <= '0;
                    id_ex_rd_old_val         <= '0;
                    id_ex_imm_out            <= '0;
                    id_ex_instr_pc           <= '0;
                    id_ex_alu_op             <= ALU_ADD;
                    id_ex_alu_src_imm        <= 1'b0;
                    id_ex_alu_src_pc         <= 1'b0;
                    id_ex_branch             <= 1'b0;
                    id_ex_pred_taken         <= 1'b0;
                    id_ex_jump               <= 1'b0;
                    id_ex_jalr               <= 1'b0;
                    id_ex_mem_read           <= 1'b0;
                    id_ex_mem_write          <= 1'b0;
                    id_ex_mem_to_reg_write  <= 1'b0;
                    id_ex_mem_size           <= MEM_WORD;
                    id_ex_mem_unsigned       <= 1'b0;
                    id_ex_reg_write          <= 1'b0;
                    id_ex_wb_sel             <= WB_ALU;
                    id_ex_illegal_instr      <= 1'b0;
                end
            end

            // EX/MEM: advance only when the data-side request is not stalled.
            if (memory_advance) begin
                if (id_ex_valid && id_ex_is_div) begin
                    // The divider request leaves ID/EX immediately. Keep a
                    // bubble in EX/MEM until its tagged result returns.
                    ex_mem_valid <= div_result_accept;
                    ex_mem_wb_sel <= id_ex_wb_sel;
                    ex_mem_reg_write <= div_result_accept && id_ex_reg_write;
                    ex_mem_rd <= div_resp_tag;
                    ex_mem_imm_out <= id_ex_imm_out;
                    ex_mem_instr_pc <= id_ex_instr_pc;
                    ex_mem_alu_result <= div_result_accept ? div_resp_result : '0;
                    ex_mem_mem_to_reg_write <= 1'b0;
                    ex_mem_mem_read <= 1'b0;
                    ex_mem_mem_write <= 1'b0;
                    ex_mem_mem_size <= id_ex_mem_size;
                    ex_mem_mem_unsigned <= id_ex_mem_unsigned;
                    ex_mem_illegal_instr <= id_ex_illegal_instr;
                    ex_mem_rs2_val <= '0;
                end else begin
                    ex_mem_valid <= id_ex_valid;
                    ex_mem_wb_sel <= id_ex_wb_sel;
                    ex_mem_reg_write <= id_ex_reg_write;
                    ex_mem_rd <= id_ex_rd;
                    ex_mem_imm_out <= id_ex_imm_out;
                    ex_mem_instr_pc <= id_ex_instr_pc;
                    ex_mem_alu_result <= alu_result;
                    ex_mem_mem_to_reg_write <= id_ex_mem_to_reg_write;
                    ex_mem_mem_read <= id_ex_mem_read;
                    ex_mem_mem_write <= id_ex_mem_write;
                    ex_mem_mem_size <= id_ex_mem_size;
                    ex_mem_mem_unsigned <= id_ex_mem_unsigned;
                    ex_mem_illegal_instr <= id_ex_illegal_instr;
                    ex_mem_rs2_val <= execute_rs2_val;
                end
            end

            // MEM/WB: capture the memory response and writeback metadata.
            if (memory_advance) begin
                mem_wb_valid <= ex_mem_valid;
                mem_wb_sel <= ex_mem_wb_sel;
                mem_wb_reg_write <= ex_mem_reg_write;
                mem_wb_rd <= ex_mem_rd;
                mem_wb_imm_out <= ex_mem_imm_out;
                mem_wb_instr_pc <= ex_mem_instr_pc;
                mem_wb_alu_result <= ex_mem_alu_result;
                mem_wb_mem_to_reg_write <= ex_mem_mem_to_reg_write;
                mem_wb_mem_size <= ex_mem_mem_size;
                mem_wb_mem_unsigned <= ex_mem_mem_unsigned;
                mem_wb_illegal_instr <= ex_mem_illegal_instr;
                mem_wb_d_rdata <= d_rdata;
            end else begin
                // The current MEM/WB instruction retires on this edge. Do not
                // keep it valid while an older memory request is stalled.
                mem_wb_valid <= 1'b0;
            end
        end    
    end

    // ------------------------------------------------------------------------
    // Control-flow resolution
    // ------------------------------------------------------------------------
    always_comb begin
        // Fetch runs independently and fills the instruction FIFO even while
        // the in-order backend is blocked. Decode still waits for the backend
        // to resume, so ID/EX remains stable during a data-cache wait.
        fetch_enable = rst_n && !pipeline_stall && !div_instruction_hold;
        memory_advance = rst_n && !pipeline_stall;

        // Direct conditional branches use the prediction already applied in
        // fetch. Execute redirects only when the prediction was wrong.
        // JAL/JALR remain unconditional execute-time redirects.
        jump_en = 1'b0;
        jump_target = '0;

        // A control-flow instruction resolves only when it can advance. This
        // prevents a younger branch from redirecting fetch while an older
        // memory operation is holding EX/MEM.
        if (memory_advance && id_ex_valid && id_ex_jump) begin
            jump_en = 1'b1;

            if (id_ex_jalr) begin
                // JALR clears bit 0 of the computed target.
                jump_target = alu_addr;
                jump_target[0] = 1'b0;
            end else begin
                // JAL target is the instruction PC plus its J immediate.
                jump_target = ADDR_WIDTH'(id_ex_instr_pc) +
                              ADDR_WIDTH'(id_ex_imm_out);
            end
        end else if (memory_advance && id_ex_valid && id_ex_branch && !id_ex_illegal_instr &&
                     (id_ex_pred_taken != alu_result[0])) begin
            jump_en = 1'b1;
            if (alu_result[0]) begin
                jump_target = ADDR_WIDTH'(id_ex_instr_pc) +
                              ADDR_WIDTH'(id_ex_imm_out);
            end else begin
                jump_target = ADDR_WIDTH'(id_ex_instr_pc) + ADDR_WIDTH'(4);
            end
        end

        // Do not allow the sequentially fetched instruction into ID/EX on
        // the same cycle that execute redirects fetch.
        decode_enable = fetch_enable && instr_valid && !jump_en;
    end

    // ------------------------------------------------------------------------
    // Load formatting and writeback selection
    // ------------------------------------------------------------------------
    always_comb begin
        load_byte = mem_wb_d_rdata[(mem_wb_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 8];
        load_half = mem_wb_d_rdata[(mem_wb_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 16];
        load_word = mem_wb_d_rdata[(mem_wb_alu_result[BYTE_OFFSET_BITS-1:0] * 8) +: 32];
        load_data_formatted = '0;

        case (mem_wb_mem_size)
            MEM_BYTE: begin
                if (mem_wb_mem_unsigned)
                    load_data_formatted = {{(DATA_WIDTH-8){1'b0}}, load_byte};
                else
                    load_data_formatted = {{(DATA_WIDTH-8){load_byte[7]}}, load_byte};
            end

            MEM_HALF: begin
                if (mem_wb_mem_unsigned)
                    load_data_formatted = {{(DATA_WIDTH-16){1'b0}}, load_half};
                else
                    load_data_formatted = {{(DATA_WIDTH-16){load_half[15]}}, load_half};
            end

            MEM_WORD: begin
                load_data_formatted = {{(DATA_WIDTH-32){load_word[31]}}, load_word};
            end

            default: begin
                load_data_formatted = '0;
            end
        endcase

        wb_data = '0;

        case (mem_wb_sel)
            WB_ALU: begin
                wb_data = mem_wb_alu_result;
            end

            WB_LOAD: begin
                wb_data = load_data_formatted;
            end

            WB_PC4: begin
                wb_data = DATA_WIDTH'(mem_wb_instr_pc) + DATA_WIDTH'(4);
            end

            WB_IMM: begin
                wb_data = mem_wb_imm_out;
            end
        endcase
    end
endmodule

`include "cpu_pkg.sv"
`include "./alu/alu.sv"
`include "./memory/memory_system.sv"
`include "decoder.sv"
`include "fetch.sv"
`include "regfile.sv"
`include "imm_gen.sv"

import cpu_pkg::*;

module core #(
    // set up the parameters
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 32

)(
    input logic clk,
    input logic rst_n
);
    /////////////////
    // fetch stage //
    /////////////////
    // fetch stage signals
    logic                  jump_en; 
    logic [ADDR_WIDTH-1:0] jump_target;
    logic                  i_read;
    logic [ADDR_WIDTH-1:0] i_addr;
    logic [DATA_WIDTH-1:0] i_data;
    logic                  i_waitrequest;
    logic [DATA_WIDTH-1:0] instr; 
    logic                  instr_valid;
    logic [ADDR_WIDTH-1:0] instr_pc;
    logic                  pipeline_stall;
    // fetch stage declaration
    fetch u_fetch(
        .clk(clk),
        .rst_n(rst_n),
        .stall(pipeline_stall),
        .jump_en(jump_en),
        .jump_target(jump_target),
        .i_read(i_read),
        .i_addr(i_addr),
        .i_data(i_data),
        .i_waitrequest(i_waitrequest),
        .instr(instr),
        .instr_valid(instr_valid),
        .instr_pc(instr_pc)
    ); 

    ///////////////////
    // decoder stage //
    ///////////////////
    // decoder signals
    opcode_e cur_opcode;
    logic [2:0] cur_funct3;
    logic [6:0] cur_funct7;
    assign cur_opcode = opcode_e'(instr[6:0]);
    assign cur_funct3 = instr[14:12];
    assign cur_funct7 = instr[31:25];
    alu_op_e    cur_id_alu_op; // identify the alu operation
    logic       cur_id_mem_read;
    logic       cur_id_mem_write;
    logic       cur_id_reg_write; 
    logic       cur_id_mem_to_reg_write;
    logic       cur_id_alu_src_imm; // to identify usage of immediate value
    logic       cur_id_alu_src_pc;
    logic       cur_id_branch;
    logic       cur_id_jump;
    logic       cur_id_jalr;
    imm_src_e   cur_id_imm_type;
    logic [1:0] cur_id_wb_sel;
    logic [1:0] cur_id_mem_size;
    logic       cur_id_mem_unsigned;
    logic       cur_id_illegal_instr;
    // decoder stage declaration
    decoder u_decoder(
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
        .cur_id_imm_type(cur_id_imm_type),
        .cur_id_wb_sel(cur_id_wb_sel),
        .cur_id_mem_size(cur_id_mem_size),
        .cur_id_mem_unsigned(cur_id_mem_unsigned),
        .cur_id_illegal_instr(cur_id_illegal_instr)
    );

    // imm_gen signals
    logic [DATA_WIDTH-1:0] imm_out;
    // imm_gen declaration
    imm_gen u_imm_gen(
        .instr(instr),
        .imm_type(cur_id_imm_type),
        .imm_out(imm_out)
    );

    // Register-file read values feed the execute-stage operands.
    logic [DATA_WIDTH-1:0] rs1_val;
    logic [DATA_WIDTH-1:0] rs2_val;
    logic [DATA_WIDTH-1:0] rd_old_val;

    /////////////
    // regfile //
    /////////////
    // Register write control is carried through the pipeline to writeback.
    regfile #(
        .ADDR_WIDTH(5),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_regfile(
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
    ///////////////
    // alu stage //
    ///////////////
    // alu signals
    // cur_id_alu_op and cur_id_alu_src_imm already defined prior
    logic [DATA_WIDTH-1:0] alu_result;
    logic [ADDR_WIDTH-1:0] alu_addr;

    alu #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_alu(
        .rs1_val(id_ex_rs1_val),
        .rs2_val(id_ex_rs2_val),
        .rd_old_val(id_ex_rd_old_val),
        .pc_val(DATA_WIDTH'(id_ex_instr_pc)),
        .imm_val(id_ex_imm_out),
        .cur_id_alu_op(id_ex_alu_op),
        .cur_id_alu_src_imm(id_ex_alu_src_imm),
        .cur_id_alu_src_pc(id_ex_alu_src_pc),
        .alu_result(alu_result),
        .alu_addr(alu_addr)
    );

    //////////////////
    // memory stage //
    //////////////////
    // memory system L1I path signals
    // logic                  i_read; 
    // logic [ADDR_WIDTH-1:0] i_addr;
    // logic [DATA_WIDTH-1:0]  i_data;
    // logic                  i_waitrequest; 

    // memory system L1D path signals
    logic                  d_read;
    logic                  d_write;
    logic [ADDR_WIDTH-1:0] d_addr;
    logic [DATA_WIDTH-1:0] d_wdata;
    logic [DATA_WIDTH/8-1:0] d_wstrb;
    logic [DATA_WIDTH-1:0] d_rdata;
    logic                  d_waitrequest;
    
    memory_system u_memory_system(
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

    // ============================================================
    // Pipeline registers
    // ============================================================

    // ID/EX: decoded instruction and values consumed by execute.
    logic                  id_ex_valid;
    logic [4:0]            id_ex_rd;
    logic [DATA_WIDTH-1:0] id_ex_rs1_val;
    logic [DATA_WIDTH-1:0] id_ex_rs2_val;
    logic [DATA_WIDTH-1:0] id_ex_rd_old_val;
    logic [DATA_WIDTH-1:0] id_ex_imm_out;
    logic [ADDR_WIDTH-1:0] id_ex_instr_pc;
    alu_op_e               id_ex_alu_op;
    logic                  id_ex_alu_src_imm;
    logic                  id_ex_alu_src_pc;
    logic                  id_ex_branch;
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

    // EX/MEM: execute result and controls consumed by data memory.
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

    // MEM/WB: values and controls consumed by register writeback.
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

    // Final value written to the register file.
    logic [DATA_WIDTH-1:0] wb_data;
    logic [DATA_WIDTH-1:0] load_data_formatted;
    logic [7:0]             load_byte;
    logic [15:0]            load_half;
    logic [31:0]            load_word;
    // Pipeline advance controls.
    // fetch_enable reflects when the instruction request can complete;
    // decode_enable prevents a waiting fetch or data access from accepting a
    // new instruction; memory_advance prevents overwriting a stalled memory
    // transaction and its eventual writeback data.
    logic fetch_enable;
    logic decode_enable;
    logic memory_advance;

    assign d_read  = ex_mem_valid && ex_mem_mem_read;
    assign d_write = ex_mem_valid && ex_mem_mem_write;
    assign d_addr  = ex_mem_alu_result;
    assign pipeline_stall = rst_n && d_waitrequest;

    // Format store data and byte enables for the addressed memory lanes.
    always_comb begin
        d_wdata = '0;
        d_wstrb = '0;

        case (ex_mem_mem_size)
            2'b00: begin
                d_wdata[ex_mem_alu_result[$clog2(DATA_WIDTH / 8)-1:0] * 8 +: 8]
                    = ex_mem_rs2_val[7:0];
                d_wstrb[ex_mem_alu_result[$clog2(DATA_WIDTH / 8)-1:0]] = 1'b1;
            end

            2'b01: begin
                d_wdata[ex_mem_alu_result[$clog2(DATA_WIDTH / 8)-1:0] * 8 +: 16]
                    = ex_mem_rs2_val[15:0];
                d_wstrb[ex_mem_alu_result[$clog2(DATA_WIDTH / 8)-1:0] +: 2] = 2'b11;
            end

            2'b10: begin
                d_wdata[ex_mem_alu_result[$clog2(DATA_WIDTH / 8)-1:0] * 8 +: 32]
                    = ex_mem_rs2_val[31:0];
                d_wstrb[ex_mem_alu_result[$clog2(DATA_WIDTH / 8)-1:0] +: 4] = 4'b1111;
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
            id_ex_rs1_val            <= '0;
            id_ex_rs2_val            <= '0;
            id_ex_rd_old_val         <= '0;
            id_ex_imm_out            <= '0;
            id_ex_instr_pc           <= '0;
            id_ex_alu_op             <= ALU_ADD;
            id_ex_alu_src_imm        <= 1'b0;
            id_ex_alu_src_pc         <= 1'b0;
            id_ex_branch             <= 1'b0;
            id_ex_jump               <= 1'b0;
            id_ex_jalr               <= 1'b0;
            id_ex_mem_read           <= 1'b0;
            id_ex_mem_write          <= 1'b0;
            id_ex_mem_to_reg_write   <= 1'b0;
            id_ex_mem_size           <= 2'b10;
            id_ex_mem_unsigned       <= 1'b0;
            id_ex_reg_write          <= 1'b0;
            id_ex_wb_sel             <= 2'b00;
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
            ex_mem_mem_size          <= 2'b10;
            ex_mem_mem_unsigned      <= 1'b0;
            ex_mem_reg_write         <= 1'b0;
            ex_mem_wb_sel            <= 2'b00;
            ex_mem_illegal_instr     <= 1'b0;

            // MEM/WB reset
            mem_wb_valid              <= 1'b0;
            mem_wb_rd                 <= 5'b0;
            mem_wb_alu_result         <= '0;
            mem_wb_d_rdata            <= '0;
            mem_wb_imm_out            <= '0;
            mem_wb_instr_pc           <= '0;
            mem_wb_mem_to_reg_write   <= 1'b0;
            mem_wb_mem_size           <= 2'b10;
            mem_wb_mem_unsigned       <= 1'b0;
            mem_wb_reg_write          <= 1'b0;
            mem_wb_sel                <= 2'b00;
            mem_wb_illegal_instr      <= 1'b0;

        end else begin
            // FETCH STAGE
            
            // DECODE STAGE
            if (decode_enable) begin
                id_ex_valid <= 1'b1;
                // decoder 
                id_ex_wb_sel <= cur_id_wb_sel;
                id_ex_reg_write <= cur_id_reg_write;
                id_ex_rd <= instr[11:7];
                // imm value
                id_ex_imm_out <= imm_out;
                // fetch
                id_ex_instr_pc <= instr_pc;
                // register values
                id_ex_rs1_val <= rs1_val;
                id_ex_rs2_val <= rs2_val;
                id_ex_rd_old_val <= rd_old_val;
                // alu signals
                id_ex_alu_op <= cur_id_alu_op;
                id_ex_alu_src_imm <= cur_id_alu_src_imm;
                id_ex_alu_src_pc <= cur_id_alu_src_pc;
                id_ex_branch <= cur_id_branch;
                id_ex_jump <= cur_id_jump;
                id_ex_jalr <= cur_id_jalr;
                id_ex_mem_to_reg_write <= cur_id_mem_to_reg_write;
                id_ex_mem_read <= cur_id_mem_read;
                id_ex_mem_write <= cur_id_mem_write;
                id_ex_mem_size <= cur_id_mem_size;
                id_ex_mem_unsigned <= cur_id_mem_unsigned;
                id_ex_illegal_instr <= cur_id_illegal_instr;
            end
            else if (!d_waitrequest) begin
                // No fetched instruction this cycle: insert a bubble.
                id_ex_valid <= 1'b0;

                // A taken control-flow instruction invalidates only the
                // younger instruction that would otherwise enter ID/EX.
                // EX/MEM and MEM/WB continue advancing below.
                if (jump_en) begin
                    id_ex_rd                 <= 5'b0;
                    id_ex_rs1_val            <= '0;
                    id_ex_rs2_val            <= '0;
                    id_ex_rd_old_val         <= '0;
                    id_ex_imm_out            <= '0;
                    id_ex_instr_pc           <= '0;
                    id_ex_alu_op             <= ALU_ADD;
                    id_ex_alu_src_imm        <= 1'b0;
                    id_ex_alu_src_pc         <= 1'b0;
                    id_ex_branch             <= 1'b0;
                    id_ex_jump               <= 1'b0;
                    id_ex_jalr               <= 1'b0;
                    id_ex_mem_read           <= 1'b0;
                    id_ex_mem_write          <= 1'b0;
                    id_ex_mem_to_reg_write  <= 1'b0;
                    id_ex_mem_size           <= 2'b10;
                    id_ex_mem_unsigned       <= 1'b0;
                    id_ex_reg_write          <= 1'b0;
                    id_ex_wb_sel             <= 2'b00;
                    id_ex_illegal_instr      <= 1'b0;
                end
            end

            // EXECUTE STAGE
            if (memory_advance) begin
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
                ex_mem_rs2_val <= id_ex_rs2_val;
            end

            // MEMORY STAGE
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
                // The current MEM/WB instruction retires on this clock edge;
                // do not keep it valid while the older memory request stalls.
                mem_wb_valid <= 1'b0;
            end
        end    
    end

    // Pipeline controls and writeback mux.
    always_comb begin
        fetch_enable = rst_n && !i_waitrequest && !pipeline_stall;
        memory_advance = rst_n && !pipeline_stall;

        // Control-flow redirects are resolved in execute.  The decoder only
        // identifies a branch or jump; the ALU supplies the branch condition
        // and the effective address for JALR.
        jump_en = 1'b0;
        jump_target = '0;

        if (id_ex_valid && id_ex_jump) begin
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
        end else if (id_ex_valid && id_ex_branch && alu_result[0]) begin
            jump_en = 1'b1;
            jump_target = ADDR_WIDTH'(id_ex_instr_pc) +
                          ADDR_WIDTH'(id_ex_imm_out);
        end

        // Do not allow the sequentially fetched instruction into ID/EX on
        // the same cycle that execute redirects fetch.
        decode_enable = rst_n && fetch_enable && instr_valid &&
                        !pipeline_stall && !jump_en;

        load_byte = d_rdata[(mem_wb_alu_result[$clog2(DATA_WIDTH / 8)-1:0] * 8) +: 8];
        load_half = d_rdata[(mem_wb_alu_result[$clog2(DATA_WIDTH / 8)-1:0] * 8) +: 16];
        load_word = d_rdata[(mem_wb_alu_result[$clog2(DATA_WIDTH / 8)-1:0] * 8) +: 32];
        load_data_formatted = '0;

        case (mem_wb_mem_size)
            2'b00: begin
                if (mem_wb_mem_unsigned)
                    load_data_formatted = {{(DATA_WIDTH-8){1'b0}}, load_byte};
                else
                    load_data_formatted = {{(DATA_WIDTH-8){load_byte[7]}}, load_byte};
            end

            2'b01: begin
                if (mem_wb_mem_unsigned)
                    load_data_formatted = {{(DATA_WIDTH-16){1'b0}}, load_half};
                else
                    load_data_formatted = {{(DATA_WIDTH-16){load_half[15]}}, load_half};
            end

            2'b10: begin
                load_data_formatted = {{(DATA_WIDTH-32){load_word[31]}}, load_word};
            end

            default: begin
                load_data_formatted = '0;
            end
        endcase

        wb_data = '0;

        case (mem_wb_sel)
            2'b00: begin
                wb_data = mem_wb_alu_result;
            end

            2'b01: begin
                wb_data = load_data_formatted;
            end

            2'b10: begin
                wb_data = DATA_WIDTH'(mem_wb_instr_pc) + DATA_WIDTH'(4);
            end

            2'b11: begin
                wb_data = mem_wb_imm_out;
            end

            default: begin
                wb_data = '0;
            end
        endcase
    end
endmodule

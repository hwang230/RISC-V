`include "cpu_pkg.sv"
import cpu_pkg::*;

module decoder(
    input opcode_e cur_opcode,
    input logic [2:0] cur_funct3,
    input logic [6:0] cur_funct7,
    output alu_op_e cur_id_alu_op, // identify the alu operation
    output logic cur_id_mem_read, 
    output logic cur_id_mem_write,
    output logic cur_id_reg_write, 
    output logic cur_id_mem_to_reg_write,
    output logic cur_id_alu_src_imm, // to identify usage of immediate value
    output logic cur_id_alu_src_pc,
    output logic cur_id_branch,
    output logic cur_id_jump,
    output logic cur_id_jalr,
    output imm_src_e cur_id_imm_type,
    output logic [1:0] cur_id_wb_sel,
    output logic [1:0] cur_id_mem_size,
    output logic cur_id_mem_unsigned,
    output logic cur_id_illegal_instr
); 
    
    always_comb begin
        // set the output to zeros initially
        cur_id_alu_op          = ALU_ADD;
        cur_id_mem_read        = 1'b0;
        cur_id_mem_write       = 1'b0;
        cur_id_reg_write       = 1'b0;
        cur_id_mem_to_reg_write= 1'b0;
        cur_id_alu_src_imm     = 1'b0;
        cur_id_alu_src_pc      = 1'b0;
        cur_id_branch          = 1'b0;
        cur_id_jump            = 1'b0;
        cur_id_jalr            = 1'b0;
        cur_id_imm_type        = IMM_R;
        cur_id_wb_sel          = 2'b00;
        cur_id_mem_size        = 2'b10;
        cur_id_mem_unsigned    = 1'b0;
        cur_id_illegal_instr   = 1'b0;

        // decode the opcode/funct7/funct3
        case (cur_opcode) 
            // REGISTER OPERATION
            OP_ALU_R: begin
                cur_id_reg_write = 1'b1;
                // RV32M register-register operations use funct7=0000001.
                if (cur_funct7 == 7'b0000001) begin
                    case (cur_funct3)
                        3'b000: cur_id_alu_op = ALU_MUL;
                        3'b001: cur_id_alu_op = ALU_MULH;
                        3'b010: cur_id_alu_op = ALU_MULHSU;
                        3'b011: cur_id_alu_op = ALU_MULHU;
                        3'b100: cur_id_alu_op = ALU_DIV;
                        3'b101: cur_id_alu_op = ALU_DIVU;
                        3'b110: cur_id_alu_op = ALU_REM;
                        3'b111: cur_id_alu_op = ALU_REMU;
                        default: cur_id_illegal_instr = 1'b1;
                    endcase
                end

                // RV32I register-register operations.
                else if (cur_funct3 == 3'b000) begin
                    if (cur_funct7 == 7'b0000000) begin
                        cur_id_alu_op = ALU_ADD;
                    end else if (cur_funct7 == 7'b0100000) begin
                        cur_id_alu_op = ALU_SUB;
                    end else begin
                        cur_id_illegal_instr = 1'b1;
                    end
                end

                // xor
                else if (cur_funct3 == 3'b100) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_XOR;
                    else
                        cur_id_illegal_instr = 1'b1;
                end

                // or
                else if (cur_funct3 == 3'b110) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_OR;
                    else
                        cur_id_illegal_instr = 1'b1;
                end

                // and
                else if (cur_funct3 == 3'b111) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_AND;
                    else
                        cur_id_illegal_instr = 1'b1;
                end
                
                // sll
                else if (cur_funct3 == 3'b001) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_SLL;
                    else
                        cur_id_illegal_instr = 1'b1;
                end
                
                // srl/sra
                else if (cur_funct3 == 3'b101) begin
                    if (cur_funct7 == 7'b0000000) begin
                        cur_id_alu_op = ALU_SRL;
                    end else if (cur_funct7 == 7'b0100000) begin
                        cur_id_alu_op = ALU_SRA;
                    end else begin
                        cur_id_illegal_instr = 1'b1;
                    end
                end

                // slt
                else if (cur_funct3 == 3'b010) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_SLT;
                    else
                        cur_id_illegal_instr = 1'b1;
                end

                // sltu
                else if (cur_funct3 == 3'b011) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_SLTU;
                    else
                        cur_id_illegal_instr = 1'b1;
                end

                else begin
                    cur_id_illegal_instr = 1'b1;
                end
            end

            // IMMEDIATE OPERATION
            OP_ALU_I: begin
                // set control signals
                cur_id_reg_write   = 1'b1;
                cur_id_alu_src_imm = 1'b1;
                cur_id_imm_type    = IMM_I;

                if (cur_funct3 == 3'b000) begin
                    cur_id_alu_op = ALU_ADD;
                end
                else if (cur_funct3 == 3'b100) begin
                    cur_id_alu_op = ALU_XOR;
                end
                else if (cur_funct3 == 3'b110) begin
                    cur_id_alu_op = ALU_OR;
                end
                else if (cur_funct3 == 3'b111) begin
                    cur_id_alu_op = ALU_AND;
                end
                else if (cur_funct3 == 3'b001) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_SLL;
                    else
                        cur_id_illegal_instr = 1'b1;
                end
                else if (cur_funct3 == 3'b101) begin
                    if (cur_funct7 == '0)
                        cur_id_alu_op = ALU_SRL;
                    else if (cur_funct7 == 7'b0100000)
                        cur_id_alu_op = ALU_SRA;
                    else
                        cur_id_illegal_instr = 1'b1;
                end
                else if (cur_funct3 == 3'b010) begin
                    cur_id_alu_op = ALU_SLT;
                end
                else if (cur_funct3 == 3'b011) begin
                    cur_id_alu_op = ALU_SLTU;
                end else begin
                    cur_id_illegal_instr = 1'b1;
                end
            end

            // LOAD OPERATION
            OP_LOAD: begin
                cur_id_mem_read = 1'b1;
                cur_id_reg_write = 1'b1;
                cur_id_alu_op = ALU_ADD;
                cur_id_imm_type = IMM_I;
                cur_id_alu_src_imm = 1'b1;
                cur_id_mem_to_reg_write = 1'b1;
                cur_id_wb_sel = 2'b01;
                // load byte
                if (cur_funct3 == '0) begin
                    cur_id_mem_size = 2'b00;
                end 

                // load half
                else if (cur_funct3 == 3'b001) begin
                    cur_id_mem_size = 2'b01;
                end

                // load word
                else if (cur_funct3 == 3'b010) begin
                    cur_id_mem_size = 2'b10;
                end

                // load byte (U) 
                else if (cur_funct3 == 3'b100) begin
                    cur_id_mem_size = 2'b00; 
                    cur_id_mem_unsigned = 1'b1;
                end

                // load half (U)
                else if (cur_funct3 == 3'b101) begin
                    cur_id_mem_size = 2'b01;
                    cur_id_mem_unsigned = 1'b1;
                end 

                else begin
                    cur_id_illegal_instr = 1'b1;
                end
            end

            // STORE OPERATION
            OP_STORE: begin
                cur_id_alu_op = ALU_ADD;
                cur_id_mem_write = 1'b1;
                cur_id_alu_src_imm = 1'b1;
                cur_id_imm_type = IMM_S;


                // store byte
                if (cur_funct3 == 3'b0) begin
                    cur_id_mem_size = 2'b00;
                end

                // store half
                else if (cur_funct3 == 3'b001) begin
                    cur_id_mem_size = 2'b01;
                end

                // store word
                else if (cur_funct3 == 3'b010) begin
                    cur_id_mem_size = 2'b10;
                end

                else begin
                    cur_id_illegal_instr = 1'b1;
                end
            end

            // CUSTOM OPERATION
            OP_CUSTOM: begin
                cur_id_alu_op = ALU_MAC;
                cur_id_reg_write = 1'b1;
                cur_id_imm_type = IMM_R;
                cur_id_wb_sel = 2'b00;
            end 


            // BRANCH OPERATION
            OP_BRANCH: begin
                cur_id_imm_type = IMM_B;
                cur_id_branch = 1'b1;
                
                if (cur_funct3 == 3'b0) begin
                    cur_id_alu_op = ALU_BEQ;
                end 

                else if (cur_funct3 == 3'b001) begin
                    cur_id_alu_op = ALU_BNE;
                end

                else if (cur_funct3 == 3'b100) begin
                    cur_id_alu_op = ALU_BLT;
                end

                else if (cur_funct3 == 3'b101) begin
                    cur_id_alu_op = ALU_BGE;
                end

                else if (cur_funct3 == 3'b110) begin
                    cur_id_alu_op = ALU_BLTU;
                end

                else if (cur_funct3 == 3'b111) begin
                    cur_id_alu_op = ALU_BGEU;
                end

                else begin
                    cur_id_illegal_instr = 1'b1;
                end
            end

            // OTHER OPERATION
            OP_LUI, OP_AUIPC, OP_JAL, OP_JALR: begin
                cur_id_reg_write = 1'b1;

                if (cur_opcode == OP_LUI) begin
                    cur_id_imm_type = IMM_U;
                    cur_id_wb_sel   = 2'b11;
                end
                else if (cur_opcode == OP_AUIPC) begin
                    cur_id_alu_op      = ALU_ADD;
                    cur_id_imm_type    = IMM_U;
                    cur_id_alu_src_imm = 1'b1;
                    cur_id_alu_src_pc  = 1'b1;
                    cur_id_wb_sel      = 2'b00;
                end
                else if (cur_opcode == OP_JAL) begin
                    cur_id_jump     = 1'b1;
                    cur_id_imm_type = IMM_J;
                    cur_id_wb_sel   = 2'b10;
                end
                else begin
                    cur_id_jump        = 1'b1;
                    cur_id_jalr        = 1'b1;
                    cur_id_alu_op      = ALU_ADD;
                    cur_id_imm_type    = IMM_I;
                    cur_id_alu_src_imm = 1'b1;
                    cur_id_wb_sel      = 2'b10;
                end
            end

            default: cur_id_illegal_instr = 1'b1;

        endcase

        // Unsupported encodings must not produce architectural side effects.
        // Keep the illegal flag asserted for future exception/trap handling,
        // but turn the instruction into a harmless pipeline operation for
        // now.
        if (cur_id_illegal_instr) begin
            cur_id_alu_op           = ALU_ADD;
            cur_id_mem_read         = 1'b0;
            cur_id_mem_write        = 1'b0;
            cur_id_reg_write        = 1'b0;
            cur_id_mem_to_reg_write = 1'b0;
            cur_id_alu_src_imm      = 1'b0;
            cur_id_alu_src_pc       = 1'b0;
            cur_id_branch           = 1'b0;
            cur_id_jump             = 1'b0;
            cur_id_jalr             = 1'b0;
            cur_id_imm_type         = IMM_R;
            cur_id_wb_sel           = 2'b00;
            cur_id_mem_size         = 2'b10;
            cur_id_mem_unsigned     = 1'b0;
        end

    end
endmodule

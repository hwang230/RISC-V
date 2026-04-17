`include "cpu_pkg.sv"
`include "decoder.sv"
`include "imm_gen.sv"


// Goal of this is to combine decoder.sv and imm_gen.sv to provide inputs to the next stage
module decode_stage(
    // signals from decoder
    input logic [31:0] instr,
    output logic [31:0] imm_val,
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
    output logic [1:0] cur_id_wb_sel,
    output logic [1:0] cur_id_mem_size,
    output logic cur_id_mem_unsigned,
    output logic cur_id_illegal_instr
);
    immsrc_e cur_id_imm_type; 
    opcode_e cur_opcode; 
    logic [2:0] cur_funct3;
    logic [6:0] cur_funct7;

    decoder decode(
        // inputs definition
        .cur_opcode(cur_opcode),
        .cur_funct3(cur_funct3),
        .cur_funct7(cur_funct7),

        // output definition
        .cur_id_alu_op(cur_id_alu_op),
        .cur_id_mem_read         (id_mem_read),
        .cur_id_mem_write        (id_mem_write),
        .cur_id_reg_write        (id_reg_write),
        .cur_id_mem_to_reg_write (id_mem_to_reg_write),
        .cur_id_alu_src_imm      (id_alu_src_imm),
        .cur_id_alu_src_pc       (id_alu_src_pc),
        .cur_id_branch           (id_branch),
        .cur_id_jump             (id_jump),
        .cur_id_jalr             (id_jalr),
        .cur_id_imm_type         (cur_id_imm_type),
        .cur_id_wb_sel           (id_wb_sel),
        .cur_id_mem_size         (id_mem_size),
        .cur_id_mem_unsigned     (id_mem_unsigned),
        .cur_id_illegal_instr    (id_illegal_instr)

    );

    imm_gen immediate_generate(
        .instr(instr),
        .imm_type(cur_id_imm_type),
        .imm_out(imm_val)
    );



endmodule
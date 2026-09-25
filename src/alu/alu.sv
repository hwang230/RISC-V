`include "cpu_pkg.sv"
`include "alu_arithmetic.sv"
`include "alu_branch.sv"
`include "alu_div.sv"
`include "alu_logical.sv"
`include "alu_mac.sv"
`include "alu_multiply.sv"
`include "alu_shift.sv"

import cpu_pkg::*;

module alu #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ADDR_WIDTH = 32
)(
    // input definition
    input logic [DATA_WIDTH-1:0] rs1_val,
    input logic [DATA_WIDTH-1:0] rs2_val,
    input logic [DATA_WIDTH-1:0] rd_old_val,
    input logic [DATA_WIDTH-1:0] pc_val,
    input logic [DATA_WIDTH-1:0] imm_val,
    input alu_op_e cur_id_alu_op, 
    input logic cur_id_alu_src_imm, // to identify usage of immediate value
    input logic cur_id_alu_src_pc,

    // output signal
    output logic [DATA_WIDTH-1:0] alu_result,
    // Address view of the result for load/store effective-address calculation.
    output logic [ADDR_WIDTH-1:0] alu_addr
); 
    logic [DATA_WIDTH-1:0] alu_rs1_val;
    logic [DATA_WIDTH-1:0] alu_rs2_val;
    logic [DATA_WIDTH-1:0] arithmetic_result;
    logic [DATA_WIDTH-1:0] branch_result;
    logic [DATA_WIDTH-1:0] div_result;
    logic [DATA_WIDTH-1:0] logical_result;
    logic [DATA_WIDTH-1:0] mac_result;
    logic [DATA_WIDTH-1:0] multiply_result;
    logic [DATA_WIDTH-1:0] shift_result;

    initial begin
        if (DATA_WIDTH < 2 || (DATA_WIDTH & (DATA_WIDTH - 1)) != 0)
            $fatal(1, "alu DATA_WIDTH must be a power of two and at least 2");
        if (ADDR_WIDTH < 1)
            $fatal(1, "alu ADDR_WIDTH must be positive");
    end

    assign alu_rs1_val = cur_id_alu_src_pc ? pc_val : rs1_val;
    assign alu_rs2_val = cur_id_alu_src_imm ? imm_val : rs2_val;
    // Arithmetic wraps at DATA_WIDTH. A narrower address keeps the low bits;
    // a wider address zero-extends the unsigned result.
    assign alu_addr = ADDR_WIDTH'(alu_result);

    // modules instantiation
    alu_arithmetic #(.DATA_WIDTH(DATA_WIDTH)) arithmetic_unit(
        .rs1_val(alu_rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(arithmetic_result)
    ); 

    alu_branch #(.DATA_WIDTH(DATA_WIDTH)) branch_unit(
        .rs1_val(alu_rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(branch_result)
    );

    alu_div #(.DATA_WIDTH(DATA_WIDTH)) div_unit(
        .rs1_val(alu_rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(div_result)
    );

    alu_logical #(.DATA_WIDTH(DATA_WIDTH)) logical_unit(
        .rs1_val(alu_rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(logical_result)
    );

    alu_mac #(.DATA_WIDTH(DATA_WIDTH)) mac_unit(
        .rs1_val(alu_rs1_val),
        .rs2_val(alu_rs2_val),
        .rd_old_val(rd_old_val),
        .alu_op(cur_id_alu_op),
        .result(mac_result)
    );

    alu_multiply #(.DATA_WIDTH(DATA_WIDTH)) multiply_unit(
        .rs1_val(alu_rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(multiply_result)
    );

    alu_shift #(.DATA_WIDTH(DATA_WIDTH)) shift_unit(
        .rs1_val(alu_rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(shift_result)
    );


    // should now assign the result onto the correct one
    always_comb begin
        case(cur_id_alu_op)
            ALU_ADD, ALU_SUB: begin
                alu_result = arithmetic_result;
            end

            ALU_AND, ALU_OR, ALU_XOR: begin
                alu_result = logical_result;
            end

            ALU_SLL, ALU_SRL, ALU_SRA: begin
                alu_result = shift_result;
            end

            ALU_SLT, ALU_SLTU,
            ALU_BEQ, ALU_BNE, ALU_BLT, ALU_BGE, ALU_BLTU, ALU_BGEU: begin
                alu_result = branch_result;
            end

            ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU: begin
                alu_result = multiply_result;
            end

            ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: begin
                alu_result = div_result;
            end

            ALU_MAC: begin
                alu_result = mac_result;
            end

            default: begin
                alu_result = '0;
            end
        endcase
    end
endmodule

`include "cpu_pkg.sv"
`include "alu_arithmetic.sv"
`include "alu_branch.sv"
`include "alu_div.sv"
`include "alu_logical.sv"
`include "alu_mac.sv"
`include "alu_multiply.sv"
`include "alu_shift.sv"

import cpu_pkg::*;

module alu(
    // input definition
    input logic [31:0] rs1_val,
    input logic [31:0] rs2_val,
    input logic [31:0] rd_old_val,
    input logic [31:0] imm_val,
    input alu_op_e cur_id_alu_op, 
    input logic cur_id_alu_src_imm, // to identify usage of immediate value

    // output signal
    output logic [31:0] alu_result
); 
    logic [31:0] alu_rs2_val;
    logic [31:0] arithmetic_result;
    logic [31:0] branch_result;
    logic [31:0] div_result;
    logic [31:0] logical_result;
    logic [31:0] mac_result;
    logic [31:0] multiply_result;
    logic [31:0] shift_result;

    assign alu_rs2_val = cur_id_alu_src_imm ? imm_val : rs2_val;

    // modules instantiation
    alu_arithmetic arithmetic_unit(
        .rs1_val(rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(arithmetic_result)
    ); 

    alu_branch branch_unit(
        .rs1_val(rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(branch_result)
    );

    alu_div div_unit(
        .rs1_val(rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(div_result)
    );

    alu_logical logical_unit(
        .rs1_val(rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(logical_result)
    );

    alu_mac mac_unit(
        .rs1_val(rs1_val),
        .rs2_val(alu_rs2_val),
        .rd_old_val(rd_old_val),
        .alu_op(cur_id_alu_op),
        .result(mac_result)
    );

    alu_multiply multiply_unit(
        .rs1_val(rs1_val),
        .rs2_val(alu_rs2_val),
        .alu_op(cur_id_alu_op),
        .result(multiply_result)
    );

    alu_shift shift_unit(
        .rs1_val(rs1_val),
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

            ALU_DIV, ALU_DIVU, ALU_REM: begin
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

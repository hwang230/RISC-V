import cpu_pkg::*;

module imm_gen (
    input  logic [31:0]  instr,
    input  imm_src_e     imm_type,
    output logic [31:0]  imm_out
);

    always_comb begin
        unique case (imm_type)
            // I-Type: 12-bit signed immediate (e.g., ADDI, LW)
            IMM_I: imm_out = { {20{instr[31]}}, instr[31:20] };

            // S-Type: 12-bit signed immediate (e.g., SW, SB)
            IMM_S: imm_out = { {20{instr[31]}}, instr[31:25], instr[11:7] };

            // B-Type: 13-bit signed offset (e.g., BEQ) - LSB is always 0
            IMM_B: imm_out = { {19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0 };

            // U-Type: 20-bit upper immediate (e.g., LUI, AUIPC)
            IMM_U: imm_out = { instr[31:12], 12'b0 };

            // J-Type: 21-bit signed offset (e.g., JAL) - LSB is always 0
            IMM_J: imm_out = { {11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0 };

            // Default / R-Type: No immediate
            default: imm_out = 32'b0;
        endcase
    end

endmodule
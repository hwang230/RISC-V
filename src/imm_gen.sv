import cpu_pkg::*;

module imm_gen #(
    parameter int DATA_WIDTH = 32
)(
    input  logic [31:0]  instr,
    input  imm_src_e     imm_type,
    output logic [DATA_WIDTH-1:0] imm_out
);
    logic [31:0] imm32;

    initial begin
        if (DATA_WIDTH < 32)
            $fatal(1, "imm_gen DATA_WIDTH must be at least 32");
    end

    always_comb begin
        unique case (imm_type)
            // I-Type: 12-bit signed immediate (e.g., ADDI, LW)
            IMM_I: imm32 = { {20{instr[31]}}, instr[31:20] };

            // S-Type: 12-bit signed immediate (e.g., SW, SB)
            IMM_S: imm32 = { {20{instr[31]}}, instr[31:25], instr[11:7] };

            // B-Type: 13-bit signed offset (e.g., BEQ) - LSB is always 0
            IMM_B: imm32 = { {19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0 };

            // U-Type is formed as a 32-bit RV32 immediate, then extended.
            IMM_U: imm32 = { instr[31:12], 12'b0 };

            // J-Type: 21-bit signed offset (e.g., JAL) - LSB is always 0
            IMM_J: imm32 = { {11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0 };

            // Default / R-Type: No immediate
            default: imm32 = 32'b0;
        endcase

        imm_out = {{(DATA_WIDTH-32){imm32[31]}}, imm32};
    end

endmodule

`ifndef OOO_CSR_SV
`define OOO_CSR_SV

// Machine-only CSR subset. CSR operations are presented only at the ROB head.
// Zicsr access rules: https://docs.riscv.org/reference/isa/unpriv/zicsr.html
// Trap/WARL rules: https://docs.riscv.org/reference/isa/priv/machine.html
module ooo_csr (
    input  logic clk,
    input  logic rst_n,
    input  logic access_valid,
    input  logic [11:0] addr,
    input  logic [2:0] funct3,
    input  logic [31:0] source,
    // This tests the encoded rs1/uimm field, not the value read from rs1.
    input  logic source_nonzero,
    output logic [31:0] read_data,
    output logic illegal,
    input  logic trap_valid,
    input  logic [31:0] trap_pc,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_tval,
    input  logic mret_valid,
    output logic [31:0] mtvec,
    output logic [31:0] mepc,
    output logic [31:0] mstatus,
    output logic [31:0] mcause,
    output logic [31:0] mtval,
    output logic [31:0] mscratch
);
    localparam logic [31:0] MISA_VALUE = 32'h4000_1100; // MXL=RV32, I and M.
    localparam logic [31:0] MSTATUS_FIXED = 32'h0000_1800; // MPP=M; no lower mode.
    localparam logic [31:0] MSTATUS_WRITABLE = 32'h0000_0088; // MIE and MPIE.
    logic supported, write_enable;
    logic [31:0] write_data;

    function automatic logic [31:0] legal_cause(input logic [31:0] value);
        case (value)
            32'd0, 32'd2, 32'd3, 32'd4, 32'd6, 32'd11: legal_cause = value;
            default: legal_cause = 32'd0;
        endcase
    endfunction

    always_comb begin
        supported = 1'b1;
        read_data = '0;
        case (addr)
            12'h300: read_data = mstatus;
            12'h301: read_data = MISA_VALUE;
            12'h304: read_data = '0; // No interrupt sources or enables.
            12'h305: read_data = mtvec;
            12'h340: read_data = mscratch;
            12'h341: read_data = mepc;
            12'h342: read_data = mcause;
            12'h343: read_data = mtval;
            12'h344: read_data = '0;
            // Noncommercial single-hart implementation; all IDs may be zero.
            12'hf11, 12'hf12, 12'hf13, 12'hf14: read_data = '0;
            default: supported = 1'b0;
        endcase
        write_enable = 1'b0;
        write_data = read_data;
        case (funct3)
            3'b001, 3'b101: begin
                write_enable = 1'b1;
                write_data = source;
            end
            3'b010, 3'b110: begin
                write_enable = source_nonzero;
                write_data = read_data | source;
            end
            3'b011, 3'b111: begin
                write_enable = source_nonzero;
                write_data = read_data & ~source;
            end
            default: begin end
        endcase
        illegal = !supported || (funct3[1:0] == 2'b00) ||
                  (write_enable && addr[11:10] == 2'b11);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mstatus <= MSTATUS_FIXED;
            mtvec <= '0;
            mscratch <= '0;
            mepc <= '0;
            mcause <= '0;
            mtval <= '0;
        end else if (trap_valid) begin
            mepc <= {trap_pc[31:2], 2'b00};
            mcause <= trap_cause;
            mtval <= trap_tval;
            mstatus <= MSTATUS_FIXED | (mstatus[3] ? 32'h80 : 32'h0);
        end else if (mret_valid) begin
            // With only M mode, the least privileged supported mode is M.
            mstatus <= MSTATUS_FIXED | 32'h80 | (mstatus[7] ? 32'h8 : 32'h0);
        end else if (access_valid && !illegal && write_enable) begin
            case (addr)
                12'h300: mstatus <= MSTATUS_FIXED | (write_data & MSTATUS_WRITABLE);
                12'h305: mtvec <= {write_data[31:2], 2'b00}; // Direct mode only.
                12'h340: mscratch <= write_data;
                12'h341: mepc <= {write_data[31:2], 2'b00}; // IALIGN=32.
                12'h342: mcause <= legal_cause(write_data);
                12'h343: mtval <= write_data;
                // misa is fixed WARL; mie/mip have no writable interrupt bits.
                default: begin end
            endcase
        end
    end
endmodule
`endif

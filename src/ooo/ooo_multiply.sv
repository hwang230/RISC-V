`ifndef OOO_MULTIPLY_SV
`define OOO_MULTIPLY_SV
`include "cpu_pkg.sv"

// One multiplier shared by all RV32M products and the custom three-source MAC.
// Each of the three registered stages is elastic, including the result stage.
module ooo_multiply #(
    parameter int TAG_WIDTH = 11
)(
    input  logic clk,
    input  logic rst_n,
    input  logic req_valid,
    output logic req_ready,
    input  logic [31:0] req_a,
    input  logic [31:0] req_b,
    input  logic [31:0] req_c,
    input  cpu_pkg::alu_op_e req_op,
    input  logic [TAG_WIDTH-1:0] req_tag,
    output logic resp_valid,
    input  logic resp_ready,
    output logic [31:0] resp_result,
    output logic [TAG_WIDTH-1:0] resp_tag
);
    import cpu_pkg::*;
    logic [2:0] valid;
    logic prepare_ready, product_ready, result_ready;
    logic signed [32:0] a_prepared, b_prepared;
    logic [31:0] accumulator_prepared, accumulator_product;
    logic [63:0] product;
    alu_op_e op_prepared, op_product;
    logic [TAG_WIDTH-1:0] tag_prepared, tag_product;

    initial begin
        if (TAG_WIDTH < 1) $fatal(1, "ooo_multiply TAG_WIDTH must be positive");
    end

    assign result_ready = !valid[2] || resp_ready;
    assign product_ready = !valid[1] || result_ready;
    assign prepare_ready = !valid[0] || product_ready;
    assign req_ready = prepare_ready;
    assign resp_valid = valid[2];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid <= '0;
        end else begin
            // Operand preparation supplies a sign bit only for signed inputs.
            // This single signed multiplier also handles the full unsigned range.
            if (prepare_ready) begin
                valid[0] <= req_valid;
                if (req_valid) begin
                    a_prepared <= $signed({((req_op == ALU_MULH || req_op == ALU_MULHSU) && req_a[31]), req_a});
                    b_prepared <= $signed({((req_op == ALU_MULH) && req_b[31]), req_b});
                    accumulator_prepared <= req_c;
                    op_prepared <= req_op;
                    tag_prepared <= req_tag;
                end
            end
            if (product_ready) begin
                valid[1] <= valid[0];
                if (valid[0]) begin
                    product <= 64'(a_prepared * b_prepared);
                    accumulator_product <= accumulator_prepared;
                    op_product <= op_prepared;
                    tag_product <= tag_prepared;
                end
            end
            if (result_ready) begin
                valid[2] <= valid[1];
                if (valid[1]) begin
                    case (op_product)
                        ALU_MULH, ALU_MULHSU, ALU_MULHU: resp_result <= product[63:32];
                        ALU_MAC: resp_result <= product[31:0] + accumulator_product;
                        default: resp_result <= product[31:0];
                    endcase
                    resp_tag <= tag_product;
                end
            end
        end
    end
endmodule
`endif

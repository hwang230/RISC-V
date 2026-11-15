// Fully pipelined radix-2 divider. Requests and responses use ready/valid
// handshakes; tags travel with the arithmetic state through the pipeline.
module alu_div #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned TAG_WIDTH = 5
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    req_valid,
    output logic                    req_ready,
    input  logic [DATA_WIDTH-1:0]   req_dividend,
    input  logic [DATA_WIDTH-1:0]   req_divisor,
    input  logic                    req_signed,
    input  logic                    req_remainder,
    input  logic [TAG_WIDTH-1:0]    req_tag,
    output logic                    resp_valid,
    input  logic                    resp_ready,
    output logic [DATA_WIDTH-1:0]   resp_result,
    output logic [TAG_WIDTH-1:0]    resp_tag
);
    localparam logic [DATA_WIDTH-1:0] SIGNED_MIN =
        {1'b1, {(DATA_WIDTH-1){1'b0}}};
    localparam logic [DATA_WIDTH-1:0] ALL_ONES = '1;

    logic [DATA_WIDTH-1:0] quotient_pipe [0:DATA_WIDTH-1];
    logic [DATA_WIDTH:0] remainder_pipe [0:DATA_WIDTH-1];
    logic [DATA_WIDTH-1:0] divisor_pipe [0:DATA_WIDTH-1];
    logic [TAG_WIDTH-1:0] tag_pipe [0:DATA_WIDTH-1];
    logic signed_op_pipe [0:DATA_WIDTH-1];
    logic quotient_negative_pipe [0:DATA_WIDTH-1];
    logic remainder_negative_pipe [0:DATA_WIDTH-1];
    logic remainder_op_pipe [0:DATA_WIDTH-1];
    logic special_pipe [0:DATA_WIDTH-1];
    logic [DATA_WIDTH-1:0] special_result_pipe [0:DATA_WIDTH-1];
    logic [DATA_WIDTH-1:0] valid_pipe;
    logic [DATA_WIDTH-1:0] stage_ready;

    initial begin
        if (DATA_WIDTH < 2)
            $fatal(1, "alu_div DATA_WIDTH must be at least 2");
        if (TAG_WIDTH < 1)
            $fatal(1, "alu_div TAG_WIDTH must be positive");
    end

    assign stage_ready[DATA_WIDTH-1] = !valid_pipe[DATA_WIDTH-1] || resp_ready;
    for (genvar r = 0; r < DATA_WIDTH-1; r++) begin : gen_ready
        assign stage_ready[r] = !valid_pipe[r] || stage_ready[r+1];
    end
    assign req_ready = stage_ready[0];
    assign resp_valid = valid_pipe[DATA_WIDTH-1];
    assign resp_tag = resp_valid ? tag_pipe[DATA_WIDTH-1] : '0;

    logic [DATA_WIDTH-1:0] quotient_result;
    logic [DATA_WIDTH-1:0] remainder_result;
    always_comb begin
        quotient_result = quotient_pipe[DATA_WIDTH-1];
        remainder_result = remainder_pipe[DATA_WIDTH-1][DATA_WIDTH-1:0];
        if (quotient_negative_pipe[DATA_WIDTH-1])
            quotient_result = -quotient_result;
        if (remainder_negative_pipe[DATA_WIDTH-1])
            remainder_result = -remainder_result;

        if (!resp_valid) begin
            resp_result = '0;
        end else if (special_pipe[DATA_WIDTH-1]) begin
            resp_result = special_result_pipe[DATA_WIDTH-1];
        end else if (remainder_op_pipe[DATA_WIDTH-1]) begin
            resp_result = remainder_result;
        end else begin
            resp_result = quotient_result;
        end
    end

    for (genvar s = 0; s < DATA_WIDTH; s++) begin : gen_div_stage
        logic in_valid;
        logic [DATA_WIDTH-1:0] in_quotient;
        logic [DATA_WIDTH:0] in_remainder;
        logic [DATA_WIDTH-1:0] in_divisor;
        logic [TAG_WIDTH-1:0] in_tag;
        logic in_signed_op;
        logic in_quotient_negative;
        logic in_remainder_negative;
        logic in_remainder_op;
        logic in_special;
        logic [DATA_WIDTH-1:0] in_special_result;
        logic [DATA_WIDTH:0] trial_remainder;
        logic [DATA_WIDTH:0] next_remainder;
        logic [DATA_WIDTH-1:0] next_quotient;
        logic [DATA_WIDTH-1:0] request_abs_dividend;
        logic [DATA_WIDTH-1:0] request_abs_divisor;
        logic request_overflow;
        logic request_special;
        logic [DATA_WIDTH-1:0] request_special_result;

        if (s == 0) begin : gen_input
            assign in_valid = req_valid;
            assign in_quotient = request_abs_dividend;
            assign in_remainder = '0;
            assign in_divisor = request_abs_divisor;
            assign in_tag = req_tag;
            assign in_signed_op = req_signed;
            assign in_quotient_negative = req_signed &&
                                            (req_dividend[DATA_WIDTH-1] ^ req_divisor[DATA_WIDTH-1]);
            assign in_remainder_negative = req_signed && req_dividend[DATA_WIDTH-1];
            assign in_remainder_op = req_remainder;
            assign in_special = request_special;
            assign in_special_result = request_special_result;

            always_comb begin
                request_abs_dividend = req_dividend;
                request_abs_divisor = req_divisor;
                if (req_signed && req_dividend[DATA_WIDTH-1])
                    request_abs_dividend = -req_dividend;
                if (req_signed && req_divisor[DATA_WIDTH-1])
                    request_abs_divisor = -req_divisor;

                request_overflow = req_signed &&
                    (req_dividend == SIGNED_MIN) && (req_divisor == ALL_ONES);
                request_special = (req_divisor == '0) || request_overflow;
                request_special_result = '0;
                if (req_divisor == '0)
                    request_special_result = req_remainder ? req_dividend : ALL_ONES;
                else if (request_overflow)
                    request_special_result = req_remainder ? '0 : req_dividend;
            end
        end else begin : gen_pipe_input
            assign in_valid = valid_pipe[s-1];
            assign in_quotient = quotient_pipe[s-1];
            assign in_remainder = remainder_pipe[s-1];
            assign in_divisor = divisor_pipe[s-1];
            assign in_tag = tag_pipe[s-1];
            assign in_signed_op = signed_op_pipe[s-1];
            assign in_quotient_negative = quotient_negative_pipe[s-1];
            assign in_remainder_negative = remainder_negative_pipe[s-1];
            assign in_remainder_op = remainder_op_pipe[s-1];
            assign in_special = special_pipe[s-1];
            assign in_special_result = special_result_pipe[s-1];
        end

        always_comb begin
            trial_remainder = {in_remainder[DATA_WIDTH-1:0], in_quotient[DATA_WIDTH-1]};
            if (trial_remainder >= {1'b0, in_divisor}) begin
                next_remainder = trial_remainder - {1'b0, in_divisor};
                next_quotient = {in_quotient[DATA_WIDTH-2:0], 1'b1};
            end else begin
                next_remainder = trial_remainder;
                next_quotient = {in_quotient[DATA_WIDTH-2:0], 1'b0};
            end
        end

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                valid_pipe[s] <= 1'b0;
            end else if (stage_ready[s]) begin
                valid_pipe[s] <= in_valid;
                if (in_valid) begin
                    quotient_pipe[s] <= next_quotient;
                    remainder_pipe[s] <= next_remainder;
                    divisor_pipe[s] <= in_divisor;
                    tag_pipe[s] <= in_tag;
                    signed_op_pipe[s] <= in_signed_op;
                    quotient_negative_pipe[s] <= in_quotient_negative;
                    remainder_negative_pipe[s] <= in_remainder_negative;
                    remainder_op_pipe[s] <= in_remainder_op;
                    special_pipe[s] <= in_special;
                    special_result_pipe[s] <= in_special_result;
                end
            end
        end
    end
endmodule

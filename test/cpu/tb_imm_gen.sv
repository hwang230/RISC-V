module tb_imm_gen #(
    parameter integer DATA_WIDTH = 32
)(output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import cpu_pkg::*;

    logic [31:0] instr;
    logic [DATA_WIDTH-1:0] imm_out;
    imm_src_e imm_type;

    imm_gen #(.DATA_WIDTH(DATA_WIDTH)) dut (
        .instr(instr),
        .imm_type(imm_type),
        .imm_out(imm_out)
    );

    function automatic logic [31:0] encode_i(input logic [11:0] imm);
        encode_i = {imm, 5'd1, 3'b000, 5'd2, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_s(input logic [11:0] imm);
        encode_s = {imm[11:5], 5'd2, 5'd1, 3'b010, imm[4:0], 7'b0100011};
    endfunction

    function automatic logic [31:0] encode_b(input logic [12:0] imm);
        encode_b = {imm[12], imm[10:5], 5'd2, 5'd1, 3'b000,
                    imm[4:1], imm[11], 7'b1100011};
    endfunction

    function automatic logic [31:0] encode_u(input logic [19:0] imm);
        encode_u = {imm, 5'd2, 7'b0110111};
    endfunction

    function automatic logic [31:0] encode_j(input logic [20:0] imm);
        encode_j = {imm[20], imm[10:1], imm[11], imm[19:12], 5'd2, 7'b1101111};
    endfunction

    function automatic logic [DATA_WIDTH-1:0] extend_rv32(input logic [31:0] value);
        logic [DATA_WIDTH-1:0] extended;
        integer bit_index;
        begin
            extended = '0;
            extended[31:0] = value;
            if (value[31]) begin
                for (bit_index = 32; bit_index < DATA_WIDTH; bit_index = bit_index + 1)
                    extended[bit_index] = 1'b1;
            end
            extend_rv32 = extended;
        end
    endfunction

    task automatic check(input string name, input logic [31:0] instruction,
                        input imm_src_e kind, input logic [31:0] expected);
        instr = instruction;
        imm_type = kind;
        #1;
        if (imm_out !== extend_rv32(expected))
            $fatal(1, "imm_gen DATA_WIDTH=%0d %s: got %h expected %h",
                   DATA_WIDTH, name, imm_out, extend_rv32(expected));
        $display("PASS: imm_gen DATA_WIDTH=%0d %-20s -> %h", DATA_WIDTH, name, imm_out);
    endtask

    initial begin
        done = 1'b0;
        check("I positive", encode_i(12'h123), IMM_I, 32'h0000_0123);
        check("I negative one", encode_i(12'hfff), IMM_I, 32'hffff_ffff);
        check("I minimum", encode_i(12'h800), IMM_I, 32'hffff_f800);
        check("S positive", encode_s(12'h456), IMM_S, 32'h0000_0456);
        check("S minimum", encode_s(12'h800), IMM_S, 32'hffff_f800);
        check("B positive maximum", encode_b(13'h0ffe), IMM_B, 32'h0000_0ffe);
        check("B negative", encode_b(13'h1ffc), IMM_B, 32'hffff_fffc);
        check("B minimum", encode_b(13'h1000), IMM_B, 32'hffff_f000);
        check("U ordinary", encode_u(20'habcd_e), IMM_U, 32'habcd_e000);
        check("U high bit", encode_u(20'h80000), IMM_U, 32'h8000_0000);
        check("J positive", encode_j(21'h000100), IMM_J, 32'h0000_0100);
        check("J negative", encode_j(21'h1fff00), IMM_J, 32'hffff_ff00);
        check("J minimum", encode_j(21'h100000), IMM_J, 32'hfff0_0000);
        check("J maximum", encode_j(21'h0ffffe), IMM_J, 32'h000f_fffe);
        check("R format", 32'h1234_5678, IMM_R, 32'd0);
        check("unknown format", encode_i(12'hfff), imm_src_e'(3'b111), 32'd0);

        done = 1'b1;
        $display("PASS: tb_imm_gen DATA_WIDTH=%0d (16 immediate cases)", DATA_WIDTH);
    end
endmodule

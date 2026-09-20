module tb_cpu_unit_suite;
    timeunit 1ns;
    timeprecision 1ps;

    logic [14:0] done;

    tb_alu_arithmetic arithmetic_test(.done(done[0]));
    tb_alu_branch branch_test(.done(done[1]));
    tb_alu_div div_test(.done(done[2]));
    tb_alu_logical logical_test(.done(done[3]));
    tb_alu_mac mac_test(.done(done[4]));
    tb_alu_multiply multiply_test(.done(done[5]));
    tb_alu_shift shift_test(.done(done[6]));
    tb_alu_top alu_top_test(.done(done[7]));
    tb_fetch #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) fetch_32_32_test(.done(done[8]));
    tb_fetch #(.ADDR_WIDTH(40), .DATA_WIDTH(64)) fetch_40_64_test(.done(done[9]));
    tb_fetch #(.ADDR_WIDTH(40), .DATA_WIDTH(128)) fetch_40_128_test(.done(done[10]));
    tb_imm_gen #(.DATA_WIDTH(32)) imm_gen_32_test(.done(done[11]));
    tb_imm_gen #(.DATA_WIDTH(64)) imm_gen_64_test(.done(done[12]));
    tb_regfile regfile_test(.done(done[13]));
    tb_alu_widths alu_width_test(.done(done[14]));

    initial begin
        wait (&done);
        $display("PASS: tb_cpu_unit_suite (15 unit benches)");
        $finish;
    end
endmodule

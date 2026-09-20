module tb_cpu_unit_suite;
    timeunit 1ns;
    timeprecision 1ps;

    logic [11:0] done;

    tb_alu_arithmetic arithmetic_test(.done(done[0]));
    tb_alu_branch branch_test(.done(done[1]));
    tb_alu_div div_test(.done(done[2]));
    tb_alu_logical logical_test(.done(done[3]));
    tb_alu_mac mac_test(.done(done[4]));
    tb_alu_multiply multiply_test(.done(done[5]));
    tb_alu_shift shift_test(.done(done[6]));
    tb_alu_top alu_top_test(.done(done[7]));
    tb_fetch fetch_test(.done(done[8]));
    tb_imm_gen imm_gen_test(.done(done[9]));
    tb_regfile regfile_test(.done(done[10]));
    tb_alu_widths alu_width_test(.done(done[11]));

    initial begin
        wait (&done);
        $display("PASS: tb_cpu_unit_suite (12 unit benches)");
        $finish;
    end
endmodule

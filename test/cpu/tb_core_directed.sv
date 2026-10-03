`timescale 1ns/1ps
// Structural tests intentionally inject pipeline states. This exercises paths
// hidden by the current fetch bubbles. Program tests separately prove reachability
// and architectural behavior without forcing any core signals.
module tb_core_directed;
    import cpu_pkg::*;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    core dut(.clk(clk),.rst_n(rst_n));
    int checks=0;
    logic [31:0] injected_instr=0, injected_pc=0;
    logic injected_valid=0;

    task automatic check(input bit condition,input string message);
        checks++;
        if (!condition) $fatal(1,"%s",message);
    endtask

    task automatic tick();
        @(posedge clk); #1;
        @(negedge clk);
    endtask

    task automatic clear_pipeline();
        rst_n=0;
        injected_valid=0;
        dut.u_memory_system.manual_d_wait=0;
        dut.u_memory_system.manual_i_wait=0;
        tick();
        check(!dut.id_ex_valid && !dut.ex_mem_valid && !dut.mem_wb_valid,"reset valids");
        check(dut.id_ex_mem_size==2 && dut.mem_wb_sel==0,"reset controls");
        rst_n=1;
    endtask

    initial begin : tests
        logic [31:0] expected_value;
        logic [31:0] saved_pc;
        logic [31:0] load_values [0:3];
        dut.u_memory_system.manual=1;
        force dut.instr=injected_instr;
        force dut.instr_valid=injected_valid;
        force dut.instr_pc=injected_pc;
        for (int r=1;r<32;r++) dut.u_regfile.regs[r]=32'(r*10);
        @(negedge clk);
        clear_pipeline();

        // Decode captures every control/data group; ADD and then a load-use
        // hazard on each of rs1, rs2 and the MAC accumulator destination.
        injected_instr=32'h002081b3; // add x3,x1,x2
        injected_pc=32'h24;
        injected_valid=1;
        #1;
        check(dut.decode_enable,"decode enable");
        tick();
        check(dut.id_ex_valid && dut.id_ex_rs1_val==10 && dut.id_ex_rs2_val==20 &&
              dut.id_ex_rd_old_val==30 && dut.id_ex_rd==3 && dut.id_ex_instr_pc==32'h24,"decode latches");
        injected_valid=0;
        tick();
        check(dut.ex_mem_valid && dut.ex_mem_alu_result==30,"execute latches");
        tick();
        check(dut.mem_wb_valid && dut.wb_data==30,"writeback latches");
        tick();
        check(dut.u_regfile.regs[3]==30,"register write");
        clear_pipeline();
        injected_instr=32'h0052828b; // mac x5,x5,x5, all three WB-to-ID bypasses
        injected_valid=1;
        dut.mem_wb_valid=1; dut.mem_wb_reg_write=1; dut.mem_wb_rd=5; dut.mem_wb_alu_result=91;
        tick();
        check(dut.id_ex_rs1_val==91 && dut.id_ex_rs2_val==91 && dut.id_ex_rd_old_val==91,"same-cycle WB/decode bypass");
        injected_valid=0;
        for (int operand=0;operand<3;operand++) begin
            clear_pipeline();
            dut.id_ex_valid=1;
            dut.id_ex_mem_read=1;
            dut.id_ex_rd=5;
            injected_instr=(operand==0) ? 32'h00128333 : // add x6,x5,x1
                           (operand==1) ? 32'h00508333 : // add x6,x1,x5
                                          32'h0020828b; // mac x5,x1,x2
            injected_valid=1;
            #1;
            check(dut.hazard_stall && dut.front_stall && !dut.decode_enable,"load-use detection");
            tick();
            check(!dut.id_ex_valid && dut.id_ex_rd==0 && dut.ex_mem_valid,"load advances, bubble inserted");
            #1;
            check(!dut.hazard_stall,"load-use clears after one cycle");
            injected_valid=0;
        end
        clear_pipeline();
        dut.id_ex_valid=1; dut.id_ex_mem_read=1; dut.id_ex_rd=0;
        injected_instr=32'h00000013; injected_valid=1;
        #1; check(!dut.hazard_stall,"x0 creates no load-use stall");
        dut.id_ex_rd=5;
        injected_instr=32'h00500313; // addi has no rs2 despite immediate bits
        #1; check(!dut.hazard_stall,"unused source field creates no hazard");

        // Forwarding defaults, all three inputs, both producers, and youngest
        // producer priority. Also exercise LUI and link-value forwarding.
        for (int select_wb=0;select_wb<4;select_wb++) begin
            for (int source=0;source<4;source++) begin
                clear_pipeline();
                dut.id_ex_valid=1; dut.id_ex_rd=5;
                dut.id_ex_rs1_addr=5; dut.id_ex_rs2_addr=5;
                dut.id_ex_rs1_val=11; dut.id_ex_rs2_val=12; dut.id_ex_rd_old_val=13;
                dut.ex_mem_valid=(source==2 || source==3);
                dut.ex_mem_reg_write=1; dut.ex_mem_rd=5;
                dut.ex_mem_wb_sel=2'(select_wb);
                dut.ex_mem_alu_result=32'h120; dut.ex_mem_instr_pc=32'h80; dut.ex_mem_imm_out=32'h12345000;
                dut.mem_wb_valid=(source==1 || source==3);
                dut.mem_wb_reg_write=1; dut.mem_wb_rd=5;
                dut.mem_wb_alu_result=99;
                #1;
                case(select_wb)
                    0: expected_value=32'h120;
                    1: expected_value=0;
                    2: expected_value=32'h84;
                    3: expected_value=32'h12345000;
                endcase
                if (source==1) expected_value=99;
                if (source==0) begin
                    check(dut.execute_rs1_val==11 && dut.execute_rs2_val==12 && dut.execute_rd_old_val==13,"unforwarded operands");
                end else begin
                    check(dut.execute_rs1_val==expected_value && dut.execute_rs2_val==expected_value &&
                          dut.execute_rd_old_val==expected_value,"forwarding data/priority");
                end
                dut.ex_mem_mem_read=1;
                #1;
                check(dut.forward_rs1_sel != 2,"never forward load address");
                dut.ex_mem_mem_read=0; dut.ex_mem_rd=0; dut.mem_wb_rd=0;
                #1;
                check(dut.forward_rs1_sel==0 && dut.forward_rs2_sel==0 && dut.forward_rd_old_sel==0,"never forward x0");
            end
        end

        // Stable request and operands during long data waits; WB drains once.
        clear_pipeline();
        dut.id_ex_valid=1; dut.id_ex_rs1_val=22; dut.id_ex_rs2_val=33;
        dut.ex_mem_valid=1; dut.ex_mem_mem_write=1; dut.ex_mem_alu_result=32'h80000; dut.ex_mem_rs2_val=77;
        dut.mem_wb_valid=1; dut.mem_wb_reg_write=1; dut.mem_wb_rd=10; dut.mem_wb_alu_result=123;
        dut.u_memory_system.manual_d_wait=1;
        #1; saved_pc=dut.u_fetch.pc;
        repeat(3) begin
            tick();
            check(dut.id_ex_valid && dut.id_ex_rs1_val==22 && dut.ex_mem_alu_result==32'h80000 && dut.d_wdata==77,"stall holds pipeline");
            check(!dut.mem_wb_valid && dut.u_fetch.pc==saved_pc,"WB drains and PC holds");
        end
        check(dut.u_regfile.regs[10]==123,"older WB completes during data wait");
        dut.u_memory_system.manual_d_wait=0;
        tick();
        check(dut.mem_wb_valid,"memory resumes");

        clear_pipeline();
        dut.id_ex_valid=1; dut.id_ex_rs1_addr=5; dut.id_ex_rs2_addr=5; dut.id_ex_rd=5;
        dut.id_ex_rs1_val=1; dut.id_ex_rs2_val=2; dut.id_ex_rd_old_val=3;
        dut.mem_wb_valid=1; dut.mem_wb_reg_write=1; dut.mem_wb_rd=5; dut.mem_wb_alu_result=92;
        dut.u_memory_system.manual_d_wait=1;
        #1;
        check(dut.execute_rs1_val==92 && dut.execute_rs2_val==92 && dut.execute_rd_old_val==92,"forwarded operands survive WB draining during stall");
        tick();

        // Every legal store width/offset plus reserved size safety behavior.
        for (int size=0;size<4;size++) begin
            for (int lane=0;lane<4;lane++) begin
                clear_pipeline();
                dut.ex_mem_valid=1; dut.ex_mem_mem_write=1;
                dut.ex_mem_mem_size=2'(size); dut.ex_mem_alu_result=32'h80000+32'(lane);
                dut.ex_mem_rs2_val=32'h89abcdef;
                #1;
                if (size==0) check(dut.d_wstrb==(4'b1<<lane) && dut.d_wdata==(32'hef<<(8*lane)),"byte store lane");
                if (size==1 && lane%2==0) check(dut.d_wstrb==(4'b11<<lane) && dut.d_wdata==(32'hcdef<<(8*lane)),"half store lane");
                if (size==2 && lane==0) check(dut.d_wstrb==15 && dut.d_wdata==32'h89abcdef,"word store");
                if (size==3) check(dut.d_wstrb==0 && dut.d_wdata==0,"reserved store size");
            end
        end

        // Load data must be the latched response even if the live bus changes.
        load_values[0]=32'h89abcdef; load_values[1]=32'h12345678;
        load_values[2]=32'h80008000; load_values[3]=32'h0001007f;
        for (int pattern=0;pattern<4;pattern++)
            for (int size=0;size<4;size++)
                for (int unsigned_load=0;unsigned_load<2;unsigned_load++)
                    for (int lane=0;lane<4;lane++) begin
                        if ((size==1 && lane%2!=0) || (size==2 && lane!=0)) continue;
                        clear_pipeline();
                        dut.mem_wb_valid=1; dut.mem_wb_sel=1;
                        dut.mem_wb_d_rdata=load_values[pattern];
                        dut.mem_wb_alu_result=32'(lane); dut.mem_wb_mem_size=2'(size);
                        dut.mem_wb_mem_unsigned=1'(unsigned_load);
                        dut.u_memory_system.manual_d_data=32'hdeaddead;
                        expected_value=load_values[pattern]>>(8*lane);
                        case(size)
                            0: expected_value=unsigned_load ? {24'b0,expected_value[7:0]} : {{24{expected_value[7]}},expected_value[7:0]};
                            1: expected_value=unsigned_load ? {16'b0,expected_value[15:0]} : {{16{expected_value[15]}},expected_value[15:0]};
                            2: begin end
                            default: expected_value=0;
                        endcase
                        #1; check(dut.wb_data===expected_value,"latched load data and extension");
                    end

        // All writeback selectors and both PC-relative and register redirects.
        for (int select_wb=0;select_wb<4;select_wb++) begin
            clear_pipeline();
            dut.mem_wb_sel=2'(select_wb); dut.mem_wb_alu_result=44;
            dut.mem_wb_d_rdata=55; dut.mem_wb_instr_pc=64; dut.mem_wb_imm_out=77;
            #1;
            case(select_wb)
                0: check(dut.wb_data==44,"ALU WB");
                1: check(dut.wb_data==55,"load WB");
                2: check(dut.wb_data==68,"PC+4 WB");
                3: check(dut.wb_data==77,"immediate WB");
            endcase
        end
        clear_pipeline();
        dut.mem_wb_sel=2'bxx;
        #1; check(dut.wb_data==0,"invalid writeback selector is harmless");
        for (int kind=0;kind<4;kind++) begin
            clear_pipeline();
            dut.id_ex_valid=1; dut.id_ex_instr_pc=32'h100; dut.id_ex_imm_out=32'hffffffe0;
            dut.id_ex_jump=(kind<2); dut.id_ex_jalr=(kind==1); dut.id_ex_branch=(kind>=2);
            dut.id_ex_alu_op=(kind>=2) ? ALU_BEQ : ALU_ADD;
            dut.id_ex_rs1_val=32'h201; dut.id_ex_rs2_val=(kind==3) ? 32'h202 : 32'h201;
            if (kind==1) dut.id_ex_rs2_val=0;
            #1;
            check(dut.jump_en==(kind!=3),"redirect condition");
            if (kind!=3) check(dut.jump_target==((kind==1)?32'h200:32'he0),"redirect target");
            tick();
            if (kind!=3) check(!dut.id_ex_valid && dut.ex_mem_valid && dut.id_ex_rd==0,"flush younger only");
        end
        clear_pipeline();
        injected_valid=1; injected_instr=32'h00100093;
        dut.u_memory_system.manual_i_wait=1;
        // A queued instruction may decode while a younger fetch request waits.
        #1; check(dut.fetch_enable && dut.decode_enable,"instruction wait does not block queued decode");
        tick();
        dut.u_memory_system.manual_i_wait=0;
        #1; check(dut.decode_enable,"queued decode remains enabled");
        clear_pipeline();
        $display("PASS: tb_core_directed (%0d checks)",checks);
        $finish;
    end
endmodule

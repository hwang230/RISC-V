`timescale 1ns/1ps
`include "ooo/ooo_multiply.sv"
`include "ooo/ooo_csr.sv"

module tb_ooo_units;
    import cpu_pkg::*;
    logic clk = 0;
    always #5 clk = ~clk;
    logic multiply_done = 0, csr_done = 0;

    logic mul_rst_n = 0, req_valid = 0, req_ready;
    logic [31:0] req_a = 0, req_b = 0, req_c = 0;
    alu_op_e req_op = ALU_MUL;
    logic [10:0] req_tag = 0;
    logic resp_valid, resp_ready = 0;
    logic [31:0] resp_result;
    logic [10:0] resp_tag;
    ooo_multiply multiplier (
        .clk(clk), .rst_n(mul_rst_n), .req_valid(req_valid), .req_ready(req_ready),
        .req_a(req_a), .req_b(req_b), .req_c(req_c), .req_op(req_op), .req_tag(req_tag),
        .resp_valid(resp_valid), .resp_ready(resp_ready), .resp_result(resp_result), .resp_tag(resp_tag)
    );

    logic csr_rst_n = 0, access_valid = 0;
    logic [11:0] addr = 0;
    logic [2:0] funct3 = 0;
    logic [31:0] source = 0, read_data;
    logic source_nonzero = 0, illegal;
    logic trap_valid = 0, mret_valid = 0;
    logic [31:0] trap_pc = 0, trap_cause = 0, trap_tval = 0;
    logic [31:0] mtvec, mepc, mstatus, mcause, mtval, mscratch;
    ooo_csr csrs(.*,.rst_n(csr_rst_n));

    function automatic logic [31:0] golden_product(
        input alu_op_e op, input logic [31:0] a, b, c
    );
        longint signed sa, sb, signed_product;
        logic [63:0] unsigned_product;
        sa = 64'($signed(a));
        sb = 64'($signed(b));
        unsigned_product = 64'(a) * 64'(b);
        case (op)
            ALU_MULH: begin
                signed_product = sa * sb;
                return signed_product[63:32];
            end
            ALU_MULHSU: begin
                signed_product = sa * $signed({32'b0,b});
                return signed_product[63:32];
            end
            ALU_MULHU: return unsigned_product[63:32];
            ALU_MAC: return unsigned_product[31:0] + c;
            default: return unsigned_product[31:0];
        endcase
    endfunction

    logic [31:0] expected_results [0:4095];
    logic [10:0] expected_tags [0:4095];
    int submitted = 0, received = 0, stalled = 0, tick = 0;
    bit pattern_enable = 1;
    always @(negedge clk) begin
        tick++;
        if (pattern_enable) resp_ready = ((tick % 19) >= 12);
    end
    always @(posedge clk) begin
        if (!mul_rst_n) begin
            submitted = 0;
            received = 0;
        end else begin
            if (req_valid && req_ready) begin
                expected_results[submitted] = golden_product(req_op, req_a, req_b, req_c);
                expected_tags[submitted] = req_tag;
                submitted++;
            end
            if (req_valid && !req_ready) stalled++;
            if (resp_valid && resp_ready) begin
                if (received >= submitted) $fatal(1,"unexpected multiplier response");
                if (resp_result !== expected_results[received] || resp_tag !== expected_tags[received])
                    $fatal(1,"multiplier response %0d: result=%08x tag=%x expected=%08x/%x",
                        received,resp_result,resp_tag,expected_results[received],expected_tags[received]);
                received++;
            end
        end
    end
    assert property (@(posedge clk) disable iff (!mul_rst_n)
        resp_valid && !resp_ready |=> !mul_rst_n ||
        (resp_valid && $stable({resp_result,resp_tag})));

    task automatic send_product(input alu_op_e op, input logic [31:0] a,b,c, input int tag);
        @(negedge clk);
        req_valid = 1;
        req_op = op;
        req_a = a;
        req_b = b;
        req_c = c;
        req_tag = 11'(tag);
        do @(posedge clk); while (!req_ready);
    endtask

    initial begin : multiply_test
        logic [31:0] corners [0:7];
        alu_op_e ops [0:4];
        corners[0]=0; corners[1]=1; corners[2]=32'hffffffff; corners[3]=32'h80000000;
        corners[4]=32'h7fffffff; corners[5]=32'hffff0001; corners[6]=32'h0000ffff; corners[7]=32'hdeadbeef;
        ops[0]=ALU_MUL; ops[1]=ALU_MULH; ops[2]=ALU_MULHSU; ops[3]=ALU_MULHU; ops[4]=ALU_MAC;
        repeat (3) @(negedge clk);
        mul_rst_n = 1;
        for (int op=0; op<5; op++)
            for (int a=0; a<8; a++)
                for (int b=0; b<8; b++)
                    send_product(ops[op],corners[a],corners[b],corners[(a+b)%8],op*64+a*8+b);
        for (int i=0; i<500; i++)
            send_product(ops[i%5],$urandom,$urandom,$urandom,320+i);
        @(negedge clk);
        req_valid = 0;
        wait (received == 820);
        if (stalled == 0) $fatal(1,"backpressure did not fill multiplier");
        // Flush occupied stages, then reuse tags and verify no stale output.
        @(negedge clk);
        pattern_enable = 0;
        resp_ready = 0;
        send_product(ALU_MUL,32'd9,32'd13,0,1);
        send_product(ALU_MULH,32'hffffffff,32'h80000000,0,2);
        send_product(ALU_MAC,32'd5,32'd7,32'd11,3);
        @(negedge clk);
        req_valid = 0;
        mul_rst_n = 0;
        @(negedge clk);
        mul_rst_n = 1;
        resp_ready = 1;
        repeat (5) @(negedge clk);
        if (resp_valid || received != 0) $fatal(1,"flush leaked a stale product");
        send_product(ALU_MAC,32'hffffffff,32'd2,32'd3,1);
        @(negedge clk);
        req_valid = 0;
        wait (received == 1);
        multiply_done = 1;
        $display("PASS: ooo_multiply (820 streamed/corner products, backpressure and flush)");
    end

    task automatic access_csr(
        input logic [11:0] csr_addr, input logic [2:0] operation,
        input logic [31:0] value, input bit nonzero, expect_illegal,
        input logic [31:0] expected_old
    );
        @(negedge clk);
        addr = csr_addr;
        funct3 = operation;
        source = value;
        source_nonzero = nonzero;
        access_valid = 1;
        #1;
        if (illegal !== expect_illegal || (!expect_illegal && read_data !== expected_old))
            $fatal(1,"CSR %03x funct3=%x illegal=%b read=%08x expected=%b/%08x",
                csr_addr,operation,illegal,read_data,expect_illegal,expected_old);
        @(negedge clk);
        access_valid = 0;
    endtask

    initial begin : csr_test
        repeat (3) @(negedge clk);
        csr_rst_n = 1;
        access_csr(12'h300,3'b010,0,0,0,32'h1800);
        access_csr(12'h301,3'b001,0,0,0,32'h40001100);
        access_csr(12'h301,3'b010,0,0,0,32'h40001100);
        access_csr(12'h300,3'b001,32'hffffffff,1,0,32'h1800);
        access_csr(12'h300,3'b010,0,0,0,32'h1888);
        access_csr(12'h300,3'b011,32'h80,1,0,32'h1888);
        access_csr(12'h300,3'b010,0,0,0,32'h1808);
        access_csr(12'h305,3'b001,32'h123,1,0,0);
        access_csr(12'h305,3'b010,0,0,0,32'h120);
        access_csr(12'h341,3'b101,32'h1f,1,0,0);
        access_csr(12'h341,3'b010,0,0,0,32'h1c);
        access_csr(12'h340,3'b001,32'hdeadbeef,1,0,0);
        access_csr(12'h340,3'b110,32'h10,1,0,32'hdeadbeef);
        access_csr(12'h340,3'b111,32'hf,1,0,32'hdeadbeff);
        access_csr(12'h340,3'b010,0,0,0,32'hdeadbef0);
        access_csr(12'h343,3'b001,32'h87654321,1,0,0);
        access_csr(12'h343,3'b010,0,0,0,32'h87654321);
        access_csr(12'h342,3'b001,32'd11,1,0,0);
        access_csr(12'h342,3'b001,32'd31,1,0,32'd11);
        access_csr(12'h342,3'b010,0,0,0,0);
        access_csr(12'h304,3'b001,32'hffffffff,1,0,0);
        access_csr(12'h304,3'b010,0,0,0,0);
        access_csr(12'h344,3'b001,32'hffffffff,1,0,0);
        access_csr(12'h344,3'b010,0,0,0,0);
        for (int ident=32'hf11; ident<=32'hf14; ident++) begin
            access_csr(12'(ident),3'b010,0,0,0,0);
            access_csr(12'(ident),3'b011,0,0,0,0);
            access_csr(12'(ident),3'b110,0,0,0,0);
            access_csr(12'(ident),3'b111,0,0,0,0);
            access_csr(12'(ident),3'b001,0,0,1,0);
            // A non-x0 source containing zero still attempts a write.
            access_csr(12'(ident),3'b010,0,1,1,0);
            access_csr(12'(ident),3'b111,1,1,1,0);
        end
        access_csr(12'hc00,3'b010,0,0,1,0); // Counter extension absent.
        access_csr(12'hb00,3'b001,0,0,1,0);
        access_csr(12'h100,3'b010,0,0,1,0); // Supervisor mode absent.
        access_csr(12'h306,3'b010,0,0,1,0);
        access_csr(12'h340,3'b000,0,0,1,0);
        access_csr(12'h340,3'b100,0,0,1,0);
        // Trap entry has priority over simultaneous CSR write and MRET.
        @(negedge clk);
        access_valid=1; addr=12'h340; funct3=3'b001; source=0; source_nonzero=1;
        trap_valid=1; trap_pc=32'h246; trap_cause=32'd6; trap_tval=32'h80003; mret_valid=1;
        @(negedge clk);
        access_valid=0; trap_valid=0; mret_valid=0;
        if (mepc!==32'h244 || mcause!==32'd6 || mtval!==32'h80003 || mstatus!==32'h1880 || mscratch!==32'hdeadbef0)
            $fatal(1,"trap entry state or priority mismatch");
        @(negedge clk);
        mret_valid=1;
        @(negedge clk);
        mret_valid=0;
        if (mstatus!==32'h1888 || mepc!==32'h244) $fatal(1,"MRET did not restore MIE/MPIE/MPP");
        // Nested trap after clearing MIE must save MPIE=0.
        access_csr(12'h300,3'b001,0,0,0,32'h1888);
        @(negedge clk);
        trap_valid=1; trap_pc=32'h100; trap_cause=32'd11; trap_tval=0;
        @(negedge clk);
        trap_valid=0;
        if (mstatus!==32'h1800) $fatal(1,"trap saved an incorrect interrupt-enable bit");
        // Synchronous reset dominates every simultaneous action.
        @(negedge clk);
        trap_valid=1; mret_valid=1; csr_rst_n=0;
        @(negedge clk);
        trap_valid=0; mret_valid=0; csr_rst_n=1;
        if ({mtvec,mepc,mcause,mtval,mscratch} !== 160'b0 || mstatus!==32'h1800)
            $fatal(1,"CSR reset priority mismatch");
        csr_done=1;
        $display("PASS: ooo_csr (CSR access restrictions, WARL, traps, MRET and priority)");
    end

    initial begin
        wait (multiply_done && csr_done);
        $display("PASS: tb_ooo_units");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1,"OOO unit timeout");
    end
endmodule

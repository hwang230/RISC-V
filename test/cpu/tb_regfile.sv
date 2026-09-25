module tb_regfile(output logic done);
    timeunit 1ns;
    timeprecision 1ps;

    logic clk;
    logic we;
    logic [4:0] rs1_addr, rs2_addr, rd_old_addr, rd_addr;
    logic [31:0] rd_data, rs1_data, rs2_data, rd_old_data;
    logic small_we;
    logic [2:0] small_rs1_addr, small_rs2_addr, small_rd_addr;
    logic [7:0] small_rd_data, small_rs1_data, small_rs2_data;
    logic [31:0] expected_values [1:31];

    regfile dut(.*);
    regfile #(.DATA_WIDTH(8), .ADDR_WIDTH(3)) small_dut (
        .clk(clk),
        .we(small_we),
        .rs1_addr(small_rs1_addr),
        .rs2_addr(small_rs2_addr),
        .rd_old_addr(small_rd_addr),
        .rd_addr(small_rd_addr),
        .rd_data(small_rd_data),
        .rs1_data(small_rs1_data),
        .rs2_data(small_rs2_data),
        .rd_old_data()
    );

    always #5 clk = ~clk;

    function automatic logic [31:0] pattern(input int index);
        pattern = 32'hc001_0000 ^ index;
    endfunction

    initial begin
        done = 1'b0;
        clk = 1'b0;
        we = 1'b0;
        rs1_addr = '0;
        rs2_addr = '0;
        rd_old_addr = '0;
        rd_addr = '0;
        rd_data = '0;
        small_we = 1'b0;
        small_rs1_addr = '0;
        small_rs2_addr = '0;
        small_rd_addr = '0;
        small_rd_data = '0;

        #1;
        if (rs1_data !== 32'd0 || rs2_data !== 32'd0)
            $fatal(1, "regfile x0 read did not return zero");

        // Writes to x0 are ignored.
        @(negedge clk);
        we = 1'b1;
        rd_addr = 5'd0;
        rd_data = 32'hdead_beef;
        @(posedge clk);
        #1;
        rs1_addr = 5'd0;
        rs2_addr = 5'd0;
        #1;
        if (rs1_data !== 32'd0 || rs2_data !== 32'd0)
            $fatal(1, "regfile allowed a write to x0");

        // Initialize every writable architectural register.
        for (int i = 1; i < 32; i++) begin
            @(negedge clk);
            we = 1'b1;
            rd_addr = i[4:0];
            rd_data = pattern(i);
            @(posedge clk);
            #1;
            expected_values[i] = pattern(i);
        end

        @(negedge clk);
        we = 1'b0;
        for (int i = 1; i < 32; i++) begin
            rs1_addr = i[4:0];
            rs2_addr = 5'd31 - (i[4:0] - 5'd1);
            #1;
            if (rs1_data !== expected_values[i])
                $fatal(1, "regfile rs1 x%0d: got %08h expected %08h",
                       i, rs1_data, expected_values[i]);
            if (rs2_data !== expected_values[32-i])
                $fatal(1, "regfile rs2 x%0d: got %08h expected %08h",
                       32-i, rs2_data, expected_values[32-i]);
        end

        // A disabled write must preserve the stored value.
        @(negedge clk);
        we = 1'b0;
        rd_addr = 5'd5;
        rd_data = 32'hdead_beef;
        @(posedge clk);
        #1;
        rs1_addr = 5'd5;
        #1;
        if (rs1_data !== expected_values[5])
            $fatal(1, "regfile changed x5 while write enable was low");

        // Both asynchronous read ports can select the same register.
        rs1_addr = 5'd7;
        rs2_addr = 5'd7;
        #1;
        if (rs1_data !== expected_values[7] || rs2_data !== expected_values[7])
            $fatal(1, "regfile two-port same-address read mismatch");

        // Confirm the geometry parameters work for a small register file too.
        @(negedge clk);
        small_we = 1'b1;
        small_rd_addr = 3'd7;
        small_rd_data = 8'ha5;
        @(posedge clk);
        #1;
        small_we = 1'b0;
        small_rs1_addr = 3'd7;
        small_rs2_addr = 3'd0;
        #1;
        if (small_rs1_data !== 8'ha5 || small_rs2_data !== 8'd0)
            $fatal(1, "parameterized regfile read/write mismatch");

        done = 1'b1;
        $display("PASS: tb_regfile (x0, 31 registers, dual reads, write enable, parameters)");
    end
endmodule

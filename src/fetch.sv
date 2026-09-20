`include "cpu_pkg.sv"
import cpu_pkg::*;

module fetch(
    input logic clk,
    input logic rst_n, 

    // to enable jumps
    input logic jump_en,
    input logic [31:0] jump_target, 

    // CPU-side L1I request/response interface. Keep i_read asserted while
    // i_waitrequest is high; the instruction is returned when it goes low.
    output logic i_read,
    output logic [31:0] i_addr,
    input logic [31:0] i_data,
    input logic i_waitrequest,

    // output what decoder needs -- let decode figure out what goes where
    output logic [31:0] instr, 
    output logic instr_valid
); 
    logic [31:0] pc;

    assign i_addr = pc;
    assign i_read = rst_n;
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc <= PC_RESET_VEC; 
            instr <= '0;
            instr_valid <= 1'b0;
        end 

        else begin
            instr_valid <= 1'b0;

            // L1I holds i_waitrequest high until its instruction response is
            // ready. The request address stays stable because PC advances
            // only when that response is consumed.
            if (!i_waitrequest) begin
                instr <= i_data;
                // should stay in fetch stage until this is true
                instr_valid <= 1'b1;
                pc <= jump_en ? jump_target : pc + 32'd4;
            end
        end

    end
endmodule

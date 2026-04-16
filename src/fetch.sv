`include "cpu_pkg.sv"
import cpu_pkg::*;

module fetch(
    input logic clk,
    input logic rst_n, 

    // to enable jumps
    input logic jump_en,
    input logic [31:0] jump_target, 

    // axi ports
    output logic [31:0] araddr,
    output logic arvalid,
    output logic rready, 
    input logic [31:0] rdata,
    input logic arready, 
    input logic rvalid, 

    // output what decoder needs -- let decode figure out what goes where
    output logic [31:0] instr, 
    output logic instr_valid
); 
    logic [31:0] pc;
    logic fetch_pending;

    assign araddr  = pc;
    assign arvalid = !fetch_pending;
    assign rready  = fetch_pending;
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc <= PC_RESET_VEC; 
            fetch_pending <= 1'b0;
            instr <= '0;
            instr_valid <= 1'b0;
        end 

        else begin
            instr_valid <= 1'b0;

            if (!fetch_pending && arvalid && arready) begin
                fetch_pending <= 1'b1;
            end

            if (fetch_pending && rvalid && rready) begin
                instr <= rdata;
                instr_valid <= 1'b1;
                pc <= jump_en ? jump_target : pc + 32'd4;
                fetch_pending <= 1'b0;
            end
        end

    end
endmodule

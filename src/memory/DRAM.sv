`include "axi_interface.sv"

module DRAM #(
    // cache parameters
    // direct-mapped
    parameter MEM_SIZE = 1024*1024, // 1MB
    parameter LINE_SIZE  = 64,
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter LATENCY = 100
)(
    input logic clk, 
    input logic rst_n, 
    axi_lite_if.slave axi
); 
    // internal signal
    // ACTUAL STORAGE AND METADATA
    localparam NUM_WORDS = MEM_SIZE / (DATA_WIDTH / 8);
    logic [DATA_WIDTH-1:0] memory [0:NUM_WORDS-1];
    localparam BYTE_OFFSET_BITS = $clog2(DATA_WIDTH / 8);
    // use =  for combinational logic
    // use <= for sequential logic

    typedef enum logic [2:0] {
        IDLE,
        READ_WAIT, 
        READ_RESP, 
        WRITE_WAIT,
        WRITE_RESP
    } state_t;

    state_t state; 

    // internal variable for latching purpose
    logic [DATA_WIDTH-1:0] writedata;
    logic [ADDR_WIDTH-1:0] writeaddr;
    logic [ADDR_WIDTH-1:0] readaddr; 
    logic [DATA_WIDTH-1:0] readdata;

    // internal signal allowing waddr and wdata to not arrival at the same time
    logic w_received = 1'b0;
    logic aw_received = 1'b0;

    // LATENCY COUNTER
    localparam LAT_CNT_WIDTH = $clog2(LATENCY + 1);
    logic [LAT_CNT_WIDTH-1:0] latency_count;

    // for state transition
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // reset logic here
            state <= IDLE;
            w_received <= 1'b0;
            aw_received <= 1'b0;
            writedata <= '0;
            writeaddr <= '0;
            readaddr <= '0;
            readdata <= '0;
            latency_count <= '0;
        end else begin
            case (state)
                IDLE: begin
                    if (axi.awvalid && axi.awready) begin
                        // handshake for aw channel
                        writeaddr <= axi.awaddr;
                        aw_received <= 1'b1; 
                    end 

                    if (axi.wvalid && axi.wready) begin
                        // handshake for w channel
                        writedata <= axi.wdata;
                        w_received <= 1'b1;
                    end

                    if ((aw_received || (axi.awvalid && axi.awready)) && 
                    (w_received  || (axi.wvalid  && axi.wready))) begin
                        // received both aw and w
                        state <= WRITE_WAIT;
                    end else if (axi.arvalid && axi.arready) begin
                        // handshake for read
                        readaddr <= axi.araddr;
                        state <= READ_WAIT;
                    end
                end

                WRITE_WAIT: begin
                    if (latency_count == LATENCY - 1) begin
                        memory[writeaddr >> BYTE_OFFSET_BITS] <= writedata;
                        latency_count <= '0;
                        state <= WRITE_RESP;
                    end else begin
                        latency_count <= latency_count + 1'b1;
                    end
                end

                READ_WAIT: begin
                    // stay in this state until the latency is reached
                    if (latency_count == LATENCY - 1) begin
                        readdata      <= memory[readaddr >> BYTE_OFFSET_BITS];
                        latency_count <= '0;
                        state         <= READ_RESP;
                    end else begin
                        latency_count <= latency_count + 1'b1;
                    end
                end

                WRITE_RESP: begin
                    if (axi.bready && axi.bvalid) begin
                        aw_received <= 1'b0;
                        w_received <= 1'b0;
                        writedata <= '0;
                        writeaddr <= '0;
                        state <= IDLE;
                    end
                end

                READ_RESP: begin
                    if (axi.rvalid && axi.rready) begin
                        readaddr <= '0;
                        readdata <= '0;
                        state <= IDLE;
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

    // for output 
    always_comb begin
        // default values
        axi.arready = 1'b0;
        axi.awready = 1'b0;
        axi.wready  = 1'b0;

        axi.rvalid  = 1'b0;
        axi.rdata   = readdata;

        axi.bvalid  = 1'b0;

        case (state) 
            IDLE: begin
                if (aw_received || w_received || axi.awvalid || axi.wvalid) begin
                    // Write in progress or master is requesting a write
                    axi.arready = 1'b0;
                    axi.awready = !aw_received;
                    axi.wready  = !w_received;
                end
                else begin
                    // No write request, allow read -- ensure only one request goes through
                    axi.arready = 1'b1;
                end
            end

            READ_WAIT: begin
                // no AXI signal update
            end

            READ_RESP: begin
                axi.rvalid = 1'b1;
                axi.rdata = readdata;
            end

            WRITE_WAIT: begin
                // no AXI signal update
            end

            WRITE_RESP: begin
                axi.bvalid = 1'b1;
            end

            default: begin
            end
        endcase
    end
endmodule
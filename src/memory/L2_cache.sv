`include "axi_interface.sv"
// write-through to DRAM
module l2_cache #(
    // cache parameters
    parameter CACHE_SIZE = 256*1024, //256 kB
    parameter LINE_SIZE  = 64,
    parameter NUM_WAYS   = 4,
    parameter ADDR_WIDTH = 32, 
    parameter DATA_WIDTH = 32, 
    parameter LATENCY = 20
)(
    input logic clk, 
    input logic rst_n, 
    axi_lite_if.slave axi_slave_i, // for l1i
    axi_lite_if.slave axi_slave_d, // for l1d
    axi_lite_if.master axi_master
);  
    // internal signal
    // ACTUAL STORAGE AND METADATA
    localparam NUM_SETS = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam INDEX_BITS = $clog2(NUM_SETS);
    localparam OFFSET_BITS = $clog2(LINE_SIZE);
    localparam TAG_BITS = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    logic [LINE_SIZE*8-1:0] data_array  [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic [TAG_BITS-1:0]    tag_array   [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic                   valid_array [0:NUM_SETS-1][0:NUM_WAYS-1];
    logic [1:0]             lru_rank    [0:NUM_SETS-1][0:NUM_WAYS-1]; // 0 - MRU & 3 - LRU

    typedef enum logic [1:0]{
        OWNER_NONE,
        OWNER_I,
        OWNER_D
    } owner_t;

    typedef enum logic [2:0] { 
        IDLE, 
        READ_WAIT, 
        READ_MISS,
        READ_RESP,
        WRITE_WAIT,
        WRITE_MISS,
        WRITE_RESP,
        WRITE_BACK
    } state_t; 

    state_t state = IDLE;
    owner_t owner = OWNER_NONE; 

    // internal variable for latching purpose
    logic [DATA_WIDTH-1:0] writedata;
    logic [ADDR_WIDTH-1:0] writeaddr;
    logic [ADDR_WIDTH-1:0] readaddr; 
    logic [DATA_WIDTH-1:0] readdata;
    logic [DATA_WIDTH-1:0] resp; 
    logic [INDEX_BITS-1:0] set_idx;
    logic [TAG_BITS-1:0] tag; 
    logic [OFFSET_BITS-1:0] word_off; 

    // internal signal allowing waddr and wdata to not arrival at the same time
    logic w_received = 1'b0;
    logic aw_received = 1'b0;

    logic hit = 1'b0;
    logic [1:0] hit_way;
    // LATENCY COUNTER
    localparam LAT_CNT_WIDTH = $clog2(LATENCY + 1);
    logic [LAT_CNT_WIDTH-1:0] latency_count;

    // for state transition
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // reset oepration
            state <= IDLE;
            w_received <= 1'b0;
            aw_received <= 1'b0;
            latency_count <= '0;
        end else begin
            case (state)
                // assign both arbiter and internal signal right away
                IDLE: begin
                    // L1D write operation 
                    if (axi_slave_d.awvalid && axi_slave_d.awready) begin
                        writeaddr <= axi_slave_d.awaddr;
                        aw_received <= 1'b1;
                    end

                    if (axi_slave_d.wvalid && axi_slave_d.wready) begin
                        writedata <= axi_slave_d.wdata;
                        w_received <= 1'b1;
                    end

                    if ((aw_received || (axi_slave_d.awvalid && axi_slave_d.awready)) &&
                    (w_received || (axi_slave_d.wvalid && axi_slave_d.wready))) begin
                        state <= WRITE_WAIT; 
                        owner <= OWNER_D;
                    end else if (axi_slave_d.arvalid && axi_slave_d.arready) begin
                        // L1D read operation
                        readaddr <= axi_slave_d.araddr;
                        state <= READ_WAIT;
                        owner <= OWNER_D;
                    end else if (axi_slave_i.arvalid && axi_slave_i.arready) begin
                        // L1I read operation
                        readaddr <= axi_slave_i.araddr;
                        state <= READ_WAIT;
                        owner <= OWNER_I;
                    end
                end

                READ_WAIT: begin
                    if (latency_count == LATENCY - 1) begin
                        latency_count <= '0;
                        if (hit) begin
                            state <= READ_RESP;
                            readdata <= data_array[set_idx][hit_way]
                            [word_off * DATA_WIDTH +: DATA_WIDTH];

                            // update LRU bits
                            for (int way = 0; way < NUM_WAYS; way++) begin
                                if (lru_rank[set_idx][way] < old_hit_rank) begin
                                    lru_rank[set_idx][way] <= lru_rank[set_idx][way] + 1'b1;
                                end else if (way == hit_way) begin
                                    lru_rank[set_idx][hit_way] <= '0;
                                end
                            end
                        end else begin
                            // miss case
                            state <= READ_MISS;
                        end
                    end else begin
                        latency_count <= latency_count + 1'b1;
                    end
                end

                READ_MISS: begin 
                    // if DRAM not return yet, stay in here
                    if (axi_master.rvalid && axi_master.rready) begin
                        // after DRAM comes back, go in READ_RESP
                        //TODO: need to fetch the whole block - and read it from there
                        // Need to incorporate LRU + add valid bits

                        readdata <= axi_master.rdata;
                        state <= READ_RESP;
                    end 
                    
                end

                READ_RESP: begin
                    if (owner == OWNER_D) begin
                        if (axi_slave_d.rvalid && axi_slave_d.rready) begin
                            readaddr <= '0;
                            readdata <= '0;
                            state <= IDLE;
                        end
                    end else if (owner == OWNER_I) begin
                        if (axi_slave_i.rvalid && axi_slave_i.rready) begin
                            readaddr <= '0;
                            readdata <= '0;
                            state <= IDLE;
                        end
                    end
                end

                WRITE_WAIT: begin
                    if (latency_count == LATENCY - 1) begin
                        latency_count <= '0;
                        if (hit) begin
                            state <= WRITE_BACK;
                            data_array[set_idx][hit_way]
                            [word_off * DATA_WIDTH +: DATA_WIDTH] = writedata;

                            // update LRU
                            for (int way = 0; way < NUM_WAYS; way++) begin
                                if (lru_rank[set_idx][way] < old_hit_rank) begin
                                    lru_rank[set_idx][way] <= lru_rank[set_idx][way] + 1'b1;
                                end else if (way == hit_way) begin
                                    lru_rank[set_idx][hit_way] <= '0;
                                end
                            end

                        end else begin
                            // miss case
                            latency_count <= '0;
                            state <= WRITE_MISS;
                        end
                    end else begin
                        latency_count <= latency_count + 1'b1;
                    end
                end 

                WRITE_MISS: begin
                    // if DRAM not return yet, stay in here
                    if (axi_master.bvalid && axi_master.bready) begin
                        // after DRAM comes back, go in WRITE_RESP
                        // TODO: need to fetch the whole block - and write it there
                        // then write it through to DRAM
                        // update LRU + valid bits

                        resp <= axi_master.bresp;
                        state <= WRITE_BACK;
                    end 
                    
                end

                WRITE_RESP: begin
                    if (owner == OWNER_D) begin
                        if (axi_slave_d.bready && axi_slave_d.bvalid) begin
                            axi_slave_d.bresp <= resp;  
                            aw_received <= 1'b0;
                            w_received <= 1'b0;
                            writedata <= '0;
                            writeaddr <= '0;
                            state <= IDLE;
                        end
                    end 
                end

                WRITE_BACK: begin
                    // TODO: write-through part
                    // need to raise AXI signal for axi_master 
                end
            endcase
        end
    end

    // for axi signal
    always_comb begin
        case (state)
            IDLE: begin
                if (aw_received || w_received || axi_slave_d.awvalid 
                    || axi_slave_d.wvalid) begin
                    // Write in progress or master is requesting a write
                    axi_slave_d.arready = 1'b0;
                    axi_slave_d.awready = !aw_received;
                    axi_slave.wready  = !w_received;
                end else begin
                    // No write request, allow read -- ensure only one request goes through
                    axi_slave.arready = 1'b1;
                end
            end

            READ_WAIT: begin
                // no AXI signal update
                set_idx  = readaddr[OFFSET_BITS +: INDEX_BITS];
                tag      = readaddr[ADDR_WIDTH-1 -: TAG_BITS];
                word_off = readaddr[OFFSET_BITS-1:2];
                hit = 1'b0;
                hit_way = '0;
                old_hit_rank = 2'b00;
                // compare here
                for (int way = 0; way < NUM_WAYS; way++) begin
                    if (valid_array[set_idx][way] && tag_array[set_idx][way] == tag) begin
                        hit = 1'b1;
                        hit_way = way;
                        old_hit_rank = lru_rank[set_idx][way];
                    end 
                end
            end

            READ_MISS: begin
                // should raise master here
                axi_master.araddr = readaddr;
                axi_master.arvalid = 1'b1;
                axi_master.rready = 1'b1;
            end

            READ_RESP: begin
                if (owner == OWNER_D) begin
                    axi_slave_d.rvalid = 1'b1;
                    axi_slave_d.rdata = readdata;
                end else if (owner == OWNER_I) begin
                    axi_slave_i.rvalid = 1'b1;
                end
            end

            WRITE_WAIT: begin
                // no AXI signal update
                set_idx  = readaddr[OFFSET_BITS +: INDEX_BITS];
                tag      = readaddr[ADDR_WIDTH-1 -: TAG_BITS];
                word_off = readaddr[OFFSET_BITS-1:2];
                hit = 1'b0;
                hit_way = '0;
                old_hit_rank = 2'b00;
                // compare here
                for (int way = 0; way < NUM_WAYS; way++) begin
                    if (valid_array[set_idx][way] && tag_array[set_idx][way] == tag) begin
                        hit = 1'b1;
                        hit_way = way;
                        old_hit_rank = lru_rank[set_idx][way];
                    end
                end
            end 

            WRITE_MISS: begin
                // should raise master here
                axi_master.awaddr = writeaddr;
                axi_master.awvalid = 1'b1;
                axi_master.wdata = writedata;
                axi_master.wvalid = 1'b1;
            end
            WRITE_RESP: begin
                if (owner == OWNER_D) begin
                    axi_slave_d.bvalid = 1'b1;
                end else if (owner == OWNER_I) begin
                    axi_slave_i.bvalid = 1'b1;
                end
            end

            WRITE_BACK: begin
            end
            default: begin
            end
        endcase
    end
endmodule
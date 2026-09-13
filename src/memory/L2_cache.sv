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
    logic [1:0] victim_way;
    logic found_invalid;
    logic [1:0] old_hit_rank;
    
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
        WRITE_THROUGH,
        WRITE_RESP
    } state_t; 

    state_t state = IDLE;
    owner_t owner = OWNER_NONE; 

    // internal variable for latching purpose
    logic [DATA_WIDTH-1:0] writedata;
    logic [ADDR_WIDTH-1:0] writeaddr;
    logic [ADDR_WIDTH-1:0] readaddr; 
    logic [DATA_WIDTH-1:0] readdata;
    logic [1:0] resp; 
    logic [INDEX_BITS-1:0] read_set_idx;
    logic [TAG_BITS-1:0] read_tag; 
    logic [OFFSET_BITS-1:0] read_word_off; 
    logic [INDEX_BITS-1:0] write_set_idx;
    logic [TAG_BITS-1:0] write_tag; 
    logic [OFFSET_BITS-1:0] write_word_off; 

    // for master-slave ack
    // only needed miss case
    logic ar_sent; // dram accepts araddr
    logic aw_sent; // dram accepts awaddr
    logic w_sent; // dram accepts wdata

    // internal signal allowing waddr and wdata to not arrival at the same time
    logic w_received = 1'b0;
    logic aw_received = 1'b0;

    logic hit = 1'b0;
    logic [1:0] hit_way;
    // LATENCY COUNTER
    localparam LAT_CNT_WIDTH = $clog2(LATENCY + 1);
    logic [LAT_CNT_WIDTH-1:0] latency_count;


    // set/tag/offset
    assign write_set_idx  = writeaddr[OFFSET_BITS +: INDEX_BITS];
    assign write_tag      = writeaddr[ADDR_WIDTH-1 -: TAG_BITS];
    assign write_word_off = writeaddr[OFFSET_BITS-1:2];

    assign read_set_idx  = readaddr[OFFSET_BITS +: INDEX_BITS];
    assign read_tag      = readaddr[ADDR_WIDTH-1 -: TAG_BITS];
    assign read_word_off = readaddr[OFFSET_BITS-1:2];

    // for state transition
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // reset oepration
            state <= IDLE;
            owner <= OWNER_NONE;
            w_received <= 1'b0;
            aw_received <= 1'b0;
            latency_count <= '0;
            readaddr  <= '0;
            writeaddr <= '0;
            readdata  <= '0;
            writedata <= '0;
            resp      <= '0;
            ar_sent   <= 1'b0;
            aw_sent   <= 1'b0;
            w_sent    <= 1'b0;
            for (int set = 0; set < NUM_SETS; set++) begin
                for (int way = 0; way < NUM_WAYS; way++) begin
                    valid_array[set][way] <= 1'b0;
                    lru_rank[set][way]    <= way;
                end
            end
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
                            readdata <= data_array[read_set_idx][hit_way]
                            [read_word_off * DATA_WIDTH +: DATA_WIDTH];

                            // update LRU bits
                            for (int way = 0; way < NUM_WAYS; way++) begin
                                if (lru_rank[read_set_idx][way] < old_hit_rank) begin
                                    lru_rank[read_set_idx][way] <= lru_rank[read_set_idx][way] + 1'b1;
                                end else if (way == hit_way) begin
                                    lru_rank[read_set_idx][hit_way] <= '0;
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

                    if (axi_master.arvalid && axi_master.arready)
                        ar_sent <= 1'b1;

                    if (axi_master.rvalid && axi_master.rready) 
                        ar_sent <= 1'b0;

                    // if DRAM not return yet, stay in here
                    if (axi_master.rvalid && axi_master.rready) begin
                        // after DRAM comes back, go in READ_RESP
                        // update LRU bits
                        for (int way = 0; way < NUM_WAYS; way++) begin
                            if (way == victim_way) begin
                                // set this and shift the rest
                                lru_rank[read_set_idx][way] <= '0;
                            end else if (valid_array[read_set_idx][way] &&
                                    lru_rank[read_set_idx][way] < NUM_WAYS-1) begin
                                lru_rank[read_set_idx][way]
                                    <= lru_rank[read_set_idx][way] + 1'b1;
                            end
                        end
                        // TODO: perform refill logic here to bring all line
                        data_array[read_set_idx][victim_way] <= axi_master.rdata;
                        tag_array[read_set_idx][victim_way]  <= read_tag;
                        valid_array[read_set_idx][victim_way] <= 1'b1;
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
                            state <= WRITE_THROUGH;
                            data_array[write_set_idx][hit_way]
                            [write_word_off * DATA_WIDTH +: DATA_WIDTH] <= writedata;

                            // update LRU
                            for (int way = 0; way < NUM_WAYS; way++) begin
                                if (lru_rank[write_set_idx][way] < old_hit_rank) begin
                                    lru_rank[write_set_idx][way] <= lru_rank[write_set_idx][way] + 1'b1;
                                end else if (way == hit_way) begin
                                    lru_rank[write_set_idx][hit_way] <= '0;
                                end
                            end
                            
                        end else begin
                            // miss case
                            latency_count <= '0;
                            state <= WRITE_THROUGH;
                        end
                    end else begin
                        latency_count <= latency_count + 1'b1;
                    end
                end 

                WRITE_THROUGH: begin
                    // write-address accepted by DRAM
                    if (axi_master.awvalid && axi_master.awready) begin
                        aw_sent <= 1'b1;
                    end

                    // write-data accepted by DRAM
                    if (axi_master.wvalid && axi_master.wready) begin
                        w_sent <= 1'b1;
                    end

                    // DRAM write completed
                    if (axi_master.bvalid && axi_master.bready) begin

                        resp <= axi_master.bresp;

                        aw_sent <= 1'b0;
                        w_sent  <= 1'b0;

                        state <= WRITE_RESP;
                    end
                    
                end

                WRITE_RESP: begin
                    if (axi_slave_d.bready && axi_slave_d.bvalid) begin
                        aw_received <= 1'b0;
                        w_received <= 1'b0;
                        writedata <= '0;
                        writeaddr <= '0;                            
                        state <= IDLE;
                    end
                end

                
            endcase
        end
    end

    // for axi signal
    always_comb begin
        // L1I-facing
        axi_slave_i.arready = 1'b0;
        axi_slave_i.rvalid  = 1'b0;
        axi_slave_i.rdata   = '0;

        // L1D-facing
        axi_slave_d.arready = 1'b0;
        axi_slave_d.awready = 1'b0;
        axi_slave_d.wready  = 1'b0;
        axi_slave_d.rvalid  = 1'b0;
        axi_slave_d.rdata   = '0;
        axi_slave_d.bvalid  = 1'b0;
        axi_slave_d.bresp   = resp;

        // DRAM-facing
        axi_master.arvalid = 1'b0;
        axi_master.araddr  = '0;
        axi_master.rready  = 1'b0;

        axi_master.awvalid = 1'b0;
        axi_master.awaddr  = '0;
        axi_master.wvalid  = 1'b0;
        axi_master.wdata   = '0;
        axi_master.bready  = 1'b0;

        hit         = 1'b0;
        hit_way     = '0;
        old_hit_rank = '0;
        victim_way = '0;
        found_invalid = 1'b0;
        case (state)
            IDLE: begin
                if (aw_received || w_received || axi_slave_d.awvalid 
                    || axi_slave_d.wvalid) begin
                    // Write in progress or master is requesting a write
                    axi_slave_d.arready = 1'b0;
                    axi_slave_d.awready = !aw_received;
                    axi_slave_d.wready  = !w_received;
                end else begin
                    // No write request, allow read -- ensure only one request goes through
                    // give L1D priroity like usual
                    if (axi_slave_d.arvalid) begin
                        axi_slave_d.arready = 1'b1;
                        axi_slave_i.arready = 1'b0;
                    end
                    else begin
                        axi_slave_d.arready = 1'b0;
                        axi_slave_i.arready = 1'b1;
                    end
                end
            end

            READ_WAIT: begin
                // no AXI signal update
                hit = 1'b0;
                hit_way = '0;
                old_hit_rank = 2'b00;
                // compare here
                for (int way = 0; way < NUM_WAYS; way++) begin
                    if (valid_array[read_set_idx][way] 
                    && tag_array[read_set_idx][way] == read_tag) begin
                        hit = 1'b1;
                        hit_way = way;
                        old_hit_rank = lru_rank[read_set_idx][way];
                    end 
                end
            end

            READ_MISS: begin
                // should raise master here
                axi_master.araddr = readaddr;
                axi_master.arvalid = !ar_sent;
                axi_master.rready = ar_sent;

                // check for invalid
                for (int way = 0; way < NUM_WAYS; way++) begin
                    if (!found_invalid && !valid_array[read_set_idx][way]) begin
                        victim_way    = way;
                        found_invalid = 1'b1;
                    end
                end

                // no invalid then evict the LRU way
                if (!found_invalid) begin
                    for (int way = 0; way < NUM_WAYS; way++) begin
                        if (lru_rank[read_set_idx][way] == 2'b11)
                            victim_way = way;
                    end
                end
            end

            READ_RESP: begin
                if (owner == OWNER_D) begin
                    axi_slave_d.rvalid = 1'b1;
                    axi_slave_d.rdata = readdata;
                end else if (owner == OWNER_I) begin
                    axi_slave_i.rvalid = 1'b1;
                    axi_slave_i.rdata = readdata;
                end
            end

            WRITE_WAIT: begin
                // no AXI signal update
                hit = 1'b0;
                hit_way = '0;
                old_hit_rank = 2'b00;

                // find the old rank and the correct way
                for (int way = 0; way < NUM_WAYS; way++) begin
                    if (valid_array[write_set_idx][way] && 
                    tag_array[write_set_idx][way] == write_tag) begin
                        hit = 1'b1;
                        hit_way = way;
                        old_hit_rank = lru_rank[write_set_idx][way];
                    end
                end
            end 

            // The replacement logic should be kept
            // Commented out for now
            // WRITE_THROUGH: begin
            //     // should raise master here
            //     axi_master.awaddr = writeaddr;
            //     axi_master.awvalid = 1'b1;
            //     axi_master.wdata = writedata;
            //     axi_master.wvalid = 1'b1;
            //     axi_master.bready  = 1'b1;
            //     // reset victim finding vars
            //     victim_way   = '0;
            //     found_invalid = 1'b0;
                

            //     // check for invalid
            //     for (int way = 0; way < NUM_WAYS; way++) begin
            //         if (!found_invalid && !valid_array[write_set_idx][way]) begin
            //             victim_way    = way;
            //             found_invalid = 1'b1;
            //         end
            //     end

            //     // no invalid then evict the LRU way
            //     if (!found_invalid) begin
            //         for (int way = 0; way < NUM_WAYS; way++) begin
            //             if (lru_rank[write_set_idx][way] == 2'b11)
            //                 victim_way = way;
            //         end
            //     end
            // end

            WRITE_THROUGH: begin

                axi_master.awaddr  = writeaddr;
                axi_master.wdata   = writedata;

                axi_master.awvalid = !aw_sent;
                axi_master.wvalid  = !w_sent;

                if (aw_sent && w_sent)
                    axi_master.bready = 1'b1;

            end

            WRITE_RESP: begin
                if (owner == OWNER_D) begin
                    axi_slave_d.bvalid = 1'b1;
                end else if (owner == OWNER_I) begin
                    axi_slave_i.bvalid = 1'b1;
                end
            end

           
            default: begin
            end
        endcase
    end
endmodule
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
    // ============================================================
    // CACHE GEOMETRY / DERIVED PARAMETERS
    // ============================================================
    localparam NUM_SETS    = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam INDEX_BITS  = $clog2(NUM_SETS);
    localparam OFFSET_BITS = $clog2(LINE_SIZE);
    localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
    localparam WAY_BITS = (NUM_WAYS <= 1) ? 1 : $clog2(NUM_WAYS);

    localparam WORDS_PER_LINE   = LINE_SIZE / (DATA_WIDTH / 8);
    localparam REFILL_CNT_WIDTH = $clog2(WORDS_PER_LINE);

    localparam LAT_CNT_WIDTH = $clog2(LATENCY + 1);


    // ============================================================
    // CACHE STORAGE / METADATA   
    // ============================================================
    logic [LINE_SIZE*8-1:0] data_array
        [0:NUM_SETS-1][0:NUM_WAYS-1];

    logic [TAG_BITS-1:0] tag_array
        [0:NUM_SETS-1][0:NUM_WAYS-1];

    logic valid_array
        [0:NUM_SETS-1][0:NUM_WAYS-1];

    // 0 = MRU, NUM_WAYS-1 = LRU
    logic [WAY_BITS-1:0] lru_rank
        [0:NUM_SETS-1][0:NUM_WAYS-1];


    // ============================================================
    // CACHE LOOKUP / REPLACEMENT
    // ============================================================
    logic                hit;
    logic [WAY_BITS-1:0] hit_way;
    logic [WAY_BITS-1:0] old_hit_rank;

    logic                found_invalid;
    logic [WAY_BITS-1:0] victim_way;


    // ============================================================
    // MISS / REFILL STATE
    // ============================================================
    logic [WAY_BITS-1:0]         miss_way;
    logic                        miss_way_selected;
    logic [REFILL_CNT_WIDTH-1:0] refill_count;


    // ============================================================
    // TRANSACTION OWNER
    // ============================================================
    typedef enum logic [1:0] {
        OWNER_NONE,
        OWNER_I,
        OWNER_D
    } owner_t;

    owner_t owner = OWNER_NONE;


    // ============================================================
    // CACHE CONTROLLER STATE
    // ============================================================
    typedef enum logic [2:0] {
        IDLE,
        READ_WAIT,
        READ_MISS,
        READ_RESP,
        WRITE_WAIT,
        WRITE_MISS,
        WRITE_THROUGH,
        WRITE_RESP
    } state_t;

    state_t state = IDLE;


    // ============================================================
    // LATCHED REQUEST / RESPONSE DATA
    // ============================================================
    logic [ADDR_WIDTH-1:0] writeaddr;
    logic [ADDR_WIDTH-1:0] readaddr;

    logic [DATA_WIDTH-1:0] writedata;
    logic [DATA_WIDTH-1:0] readdata;

    logic [1:0] resp;


    // ============================================================
    // ADDRESS DECODE
    // ============================================================
    logic [INDEX_BITS-1:0]  write_set_idx;
    logic [TAG_BITS-1:0]    write_tag;
    logic [OFFSET_BITS-1:0] write_word_off;

    logic [INDEX_BITS-1:0]  read_set_idx;
    logic [TAG_BITS-1:0]    read_tag;
    logic [OFFSET_BITS-1:0] read_word_off;


    // Write address decode
    assign write_set_idx  = writeaddr[OFFSET_BITS +: INDEX_BITS];
    assign write_tag      = writeaddr[ADDR_WIDTH-1 -: TAG_BITS];
    assign write_word_off = writeaddr[OFFSET_BITS-1:2];

    // Read address decode
    assign read_set_idx  = readaddr[OFFSET_BITS +: INDEX_BITS];
    assign read_tag      = readaddr[ADDR_WIDTH-1 -: TAG_BITS];
    assign read_word_off = readaddr[OFFSET_BITS-1:2];


    // ============================================================
    // AXI HANDSHAKE TRACKING
    // ============================================================

    // L2 -> DRAM
    logic ar_sent;
    logic aw_sent;
    logic w_sent;

    // L1D -> L2
    logic aw_received = 1'b0;
    logic w_received  = 1'b0;


    // ============================================================
    // LATENCY TRACKING
    // ============================================================
    logic [LAT_CNT_WIDTH-1:0] latency_count;

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
            miss_way_selected <= 1'b0;
            miss_way          <= '0;
            refill_count      <= '0;
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
                            miss_way_selected <= 1'b0;
                            refill_count      <= '0;
                            state <= READ_MISS;
                        end
                    end else begin
                        latency_count <= latency_count + 1'b1;
                    end
                end

                READ_MISS: begin 
                    if (!miss_way_selected) begin
                        // latch the signal 
                        miss_way <= victim_way;
                        miss_way_selected <= 1'b1;
                    end

                    if (miss_way_selected) begin
                        if (axi_master.arvalid && axi_master.arready)
                            ar_sent <= 1'b1;
                        if (axi_master.rvalid && axi_master.rready) begin
                            ar_sent <= 1'b0;
                            // store this 32-bit refill word
                            data_array[read_set_idx][miss_way]
                                    [refill_count * DATA_WIDTH +: DATA_WIDTH]
                                <= axi_master.rdata;

                            // if this is the originally requested word
                            if (refill_count == read_word_off)
                                readdata <= axi_master.rdata;

                            // reached end of cache line transfer
                            if (refill_count == WORDS_PER_LINE - 1) begin
                                // full line is now complete
                                tag_array[read_set_idx][miss_way]   <= read_tag;
                                valid_array[read_set_idx][miss_way] <= 1'b1;

                                // update LRU ONCE here
                                for (int way = 0; way < NUM_WAYS; way++) begin
                                    if (way == miss_way)
                                        lru_rank[read_set_idx][way] <= '0;
                                    else if (valid_array[read_set_idx][way] &&
                                            lru_rank[read_set_idx][way] < NUM_WAYS-1)
                                        lru_rank[read_set_idx][way]
                                            <= lru_rank[read_set_idx][way] + 1'b1;
                                end

                                refill_count <= '0;
                                state <= READ_RESP;

                            end else begin
                                refill_count <= refill_count + 1'b1;
                            end
                        end
                    end
                end

                READ_RESP: begin
                    if (owner == OWNER_D) begin
                        if (axi_slave_d.rvalid && axi_slave_d.rready) begin
                            readaddr <= '0;
                            readdata <= '0;
                            state <= IDLE;
                            owner <= OWNER_NONE;
                            miss_way_selected <= 1'b0;
                        end
                    end else if (owner == OWNER_I) begin
                        if (axi_slave_i.rvalid && axi_slave_i.rready) begin
                            readaddr <= '0;
                            readdata <= '0;
                            state <= IDLE;
                            owner <= OWNER_NONE;
                            miss_way_selected <= 1'b0;
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
                            miss_way_selected <= 1'b0;
                            refill_count      <= '0;
                            state <= WRITE_MISS;
                        end
                    end else begin
                        latency_count <= latency_count + 1'b1;
                    end
                end 

                WRITE_MISS: begin
                    // Refill the missed block
                    // Then write the data to this new block in L2
                    // Then adjust LRU
                    if (!miss_way_selected) begin
                        miss_way <= victim_way;
                        miss_way_selected <= 1'b1;
                    end

                    if (miss_way_selected) begin
                        if (axi_master.arvalid && axi_master.arready) 
                            ar_sent <= 1'b1;
                        if (axi_master.rvalid && axi_master.rready) begin
                            ar_sent <= 1'b0;
                            // store the 32-bit refill word
                            data_array[write_set_idx][miss_way]
                                    [refill_count * DATA_WIDTH +: DATA_WIDTH]
                                <= axi_master.rdata;

                            // if this is the originally request word
                            if (refill_count == write_word_off)
                                data_array[write_set_idx][miss_way]
                                        [refill_count * DATA_WIDTH +: DATA_WIDTH]
                                    <= writedata;
                            
                            if (refill_count == WORDS_PER_LINE - 1) begin
                                // update tag and valid
                                tag_array[write_set_idx][miss_way] <= write_tag;
                                valid_array[write_set_idx][miss_way] <= 1'b1;
                                // update LRU
                                for (int way = 0; way < NUM_WAYS; way++) begin
                                    if (way == miss_way) 
                                        lru_rank[write_set_idx][way] <= '0;
                                    else if (valid_array[write_set_idx][way] &&
                                        lru_rank[write_set_idx][way] < NUM_WAYS-1) begin
                                            lru_rank[write_set_idx][way] <=
                                                lru_rank[write_set_idx][way] + 1'b1;
                                        end
                                end
                                refill_count <= '0;
                                state <= WRITE_THROUGH;

                            end else begin
                                refill_count <= refill_count + 1'b1;
                            end
                        end
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
                        owner <= OWNER_NONE;
                        miss_way_selected <= 1'b0;
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
                old_hit_rank = '0;
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
                victim_way = '0;
                found_invalid = 1'b0;
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
                        if (lru_rank[read_set_idx][way] == NUM_WAYS-1)
                            victim_way = way;
                    end
                end

                // should raise master here
                // this increments araddr for each refill_count
                if (miss_way_selected) begin
                    axi_master.araddr = {readaddr[ADDR_WIDTH-1:OFFSET_BITS],
                    {OFFSET_BITS{1'b0}}} + refill_count * (DATA_WIDTH / 8);

                    axi_master.arvalid = !ar_sent;
                    axi_master.rready = ar_sent;
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
                old_hit_rank = '0;

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

            WRITE_MISS: begin
                victim_way = '0;
                found_invalid = 1'b0;
                for (int way = 0; way < NUM_WAYS; way++) begin
                     if (!found_invalid && !valid_array[write_set_idx][way]) begin
                         victim_way    = way;
                         found_invalid = 1'b1;
                     end
                 end

                 // no invalid then evict the LRU way
                 if (!found_invalid) begin
                     for (int way = 0; way < NUM_WAYS; way++) begin
                         if (lru_rank[write_set_idx][way] == NUM_WAYS-1)
                             victim_way = way;
                     end
                 end

                 // should raise master here ti refill
                 // read request to get the block
                 if (miss_way_selected) begin
                    axi_master.araddr = {writeaddr[ADDR_WIDTH-1:OFFSET_BITS], 
                    {OFFSET_BITS{1'b0}}} + refill_count * (DATA_WIDTH/8);

                    axi_master.arvalid = !ar_sent;
                    axi_master.rready = ar_sent;
                 end
            end


            WRITE_THROUGH: begin

                axi_master.awaddr  = writeaddr;
                axi_master.wdata   = writedata;

                axi_master.awvalid = !aw_sent;
                axi_master.wvalid  = !w_sent;

                if (aw_sent && w_sent)
                    axi_master.bready = 1'b1;

            end

            WRITE_RESP: begin
                axi_slave_d.bvalid = 1'b1;
            end

           
            default: begin
            end
        endcase
    end
endmodule
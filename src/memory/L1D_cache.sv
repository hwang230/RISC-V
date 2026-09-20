    `include "axi_interface.sv"
    `include "L1_cache_interface.sv"

    // write-back on dirty
    module l1d_cache #(
        // cache parameters
        parameter CACHE_SIZE = 64*1024, //64kB
        parameter LINE_SIZE  = 64,
        parameter NUM_WAYS   = 4,
        parameter ADDR_WIDTH = 32,  
        parameter DATA_WIDTH = 32,
        parameter LATENCY = 5
    )(
        input logic clk, 
        input logic rst_n, 
        l1_cache_if.l1d l1d, 
        // technically, axi only gets triggered in miss cases where we need to 
        // get data from L2 
        axi_lite_if.master axi
    ); 
        // ============================================================
        // CACHE GEOMETRY / DERIVED PARAMETERS
        // ============================================================
        localparam NUM_SETS    = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
        localparam INDEX_BITS  = $clog2(NUM_SETS);
        localparam OFFSET_BITS = $clog2(LINE_SIZE);
        localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
        localparam WAY_BITS = (NUM_WAYS <= 1) ? 1 : $clog2(NUM_WAYS);

        localparam BYTE_OFFSET_BITS = $clog2(DATA_WIDTH / 8);
        localparam WORDS_PER_LINE   = LINE_SIZE / (DATA_WIDTH / 8);
        localparam WORD_OFFSET_BITS = (WORDS_PER_LINE > 1) ? $clog2(WORDS_PER_LINE) : 1;
        localparam REFILL_CNT_WIDTH = WORD_OFFSET_BITS;

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

        logic dirty_array 
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
        logic [REFILL_CNT_WIDTH-1:0] refill_count;
        logic [REFILL_CNT_WIDTH-1:0] writeback_count;
        // ============================================================
        // CACHE CONTROLLER STATE
        // ============================================================
        typedef enum logic [2:0] {
            IDLE,
            READ_WAIT,
            READ_REFILL,
            READ_RESP,
            WRITE_WAIT,
            WRITE_BACK,
            WRITE_REFILL,
            WRITE_RESP
        } state_t;

        state_t state = IDLE;

        logic [LAT_CNT_WIDTH-1:0] latency_count;   

        // ============================================================
        // LATCHED REQUEST / RESPONSE DATA
        // ============================================================
        logic [ADDR_WIDTH-1:0] writeaddr;
        logic [ADDR_WIDTH-1:0] readaddr;

        logic [DATA_WIDTH-1:0] writedata;
        logic [DATA_WIDTH-1:0] readdata;

        
        // ============================================================
        // ADDRESS DECODE
        // ============================================================
        logic [INDEX_BITS-1:0]  write_set_idx;
        logic [TAG_BITS-1:0]    write_tag;
        logic [WORD_OFFSET_BITS-1:0] write_word_off;

        logic [INDEX_BITS-1:0]  read_set_idx;
        logic [TAG_BITS-1:0]    read_tag;
        logic [WORD_OFFSET_BITS-1:0] read_word_off;


        // Write address decode
        assign write_set_idx  = writeaddr[OFFSET_BITS +: INDEX_BITS];
        assign write_tag      = writeaddr[ADDR_WIDTH-1 -: TAG_BITS];
        // Read address decode
        assign read_set_idx  = readaddr[OFFSET_BITS +: INDEX_BITS];
        assign read_tag      = readaddr[ADDR_WIDTH-1 -: TAG_BITS];
        generate
            if (WORDS_PER_LINE > 1) begin : gen_word_offsets
                assign write_word_off = writeaddr[BYTE_OFFSET_BITS +: WORD_OFFSET_BITS];
                assign read_word_off  = readaddr[BYTE_OFFSET_BITS +: WORD_OFFSET_BITS];
            end else begin : gen_single_word_line
                assign write_word_off = '0;
                assign read_word_off  = '0;
            end
        endgenerate

        initial begin
            if (DATA_WIDTH < 32 || (DATA_WIDTH % 8) != 0 ||
                (DATA_WIDTH & (DATA_WIDTH - 1)) != 0 ||
                (LINE_SIZE % (DATA_WIDTH / 8)) != 0 || WORDS_PER_LINE < 1)
                $fatal(1, "l1d_cache requires a power-of-two DATA_WIDTH >= 32 that divides LINE_SIZE");
            if ((LINE_SIZE & (LINE_SIZE - 1)) != 0 ||
                CACHE_SIZE % (LINE_SIZE * NUM_WAYS) != 0 || NUM_SETS < 2 ||
                (NUM_SETS & (NUM_SETS - 1)) != 0 || TAG_BITS < 1)
                $fatal(1, "l1d_cache requires power-of-two line/set geometry and a positive tag width");
        end

        // ============================================================
        // AXI HANDSHAKE TRACKING
        // ============================================================

        // L1D -> L2
        logic ar_sent;
        logic aw_sent;
        logic w_sent;

        
        // to keep track of read or write
        logic miss_is_write;
        // to check if replaced block is dirty 
        // go into REFILL if not dirty/ WRITE_BACK if dirty
        logic block_is_dirty; 

        // l1d logic - state transition + refill
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                // reset oepration
                state <= IDLE;
                latency_count <= '0;
                readaddr  <= '0;
                writeaddr <= '0;
                readdata  <= '0;
                writedata <= '0;
                ar_sent   <= 1'b0;
                aw_sent   <= 1'b0;
                w_sent    <= 1'b0;
                miss_way          <= '0;
                refill_count      <= '0;
                writeback_count <= '0;
                miss_is_write <= 1'b0;
                
                for (int set = 0; set < NUM_SETS; set++) begin
                    for (int way = 0; way < NUM_WAYS; way++) begin
                        valid_array[set][way] <= 1'b0;
                        lru_rank[set][way]    <= way;
                        dirty_array[set][way] <= 1'b0;
                    end
                end
            end else begin
                case (state)
                    IDLE: begin
                        if (l1d.d_write) begin
                            state <= WRITE_WAIT;
                            writedata <= l1d.wdata; 
                            writeaddr <= l1d.daddr;
                        end else if (l1d.d_read) begin
                            state <= READ_WAIT;
                            readaddr <= l1d.daddr;
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
                                refill_count      <= '0;
                                miss_is_write <= 1'b0;
                                if (block_is_dirty) begin
                                    state <= WRITE_BACK;
                                end else begin 
                                    state <= READ_REFILL;
                                end
                                miss_way <= victim_way;
                            end
                        end else begin
                            latency_count <= latency_count + 1'b1;
                        end
                    end

                    READ_REFILL: begin
                        if (axi.arvalid && axi.arready)
                            ar_sent <= 1'b1;
                        if (axi.rvalid && axi.rready) begin
                            ar_sent <= 1'b0;
                            // store this 32-bit refill word
                            data_array[read_set_idx][miss_way]
                                            [refill_count * DATA_WIDTH +: DATA_WIDTH]
                                        <= axi.rdata;

                            // if this is the originally requested word
                            if (refill_count == read_word_off)
                                readdata <= axi.rdata;

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
                                dirty_array[read_set_idx][miss_way] <= 1'b0;

                            end else begin
                                refill_count <= refill_count + 1'b1;
                            end
                        end
                    end

                    READ_RESP: begin
                       state <= IDLE;
                    end

                    WRITE_WAIT: begin
                        if (latency_count == LATENCY - 1) begin
                            latency_count <= '0;

                            if (hit) begin
                                state <= WRITE_RESP;
                                data_array[write_set_idx][hit_way]
                                [write_word_off * DATA_WIDTH +: DATA_WIDTH] <= writedata;
                                // L1D is writeback, need to update dirty
                                dirty_array[write_set_idx][hit_way] <= 1'b1;
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
                                refill_count      <= '0;
                                // used by write back to differentiate between W/R
                                miss_is_write <= 1'b1;
                                if (block_is_dirty) begin
                                    state <= WRITE_BACK;
                                end else begin
                                    state <= WRITE_REFILL;
                                end
                                miss_way <= victim_way;
                            end
                        end else begin
                            latency_count <= latency_count + 1'b1;
                        end
                    end

                    WRITE_BACK: begin
                        if (axi.awvalid && axi.awready)
                            aw_sent <= 1'b1;

                        if (axi.wvalid && axi.wready)
                            w_sent <= 1'b1;

                        if (axi.bvalid && axi.bready) begin
                            aw_sent <= 1'b0;
                            w_sent  <= 1'b0;

                            if (writeback_count == WORDS_PER_LINE-1) begin
                                writeback_count <= '0;

                                if (miss_is_write)
                                    state <= WRITE_REFILL;
                                else
                                    state <= READ_REFILL;
                            end else begin
                                writeback_count <= writeback_count + 1'b1;
                            end
                        end
                    end

                    WRITE_REFILL: begin
                        if (axi.arvalid && axi.arready)
                            ar_sent <= 1'b1;
                        if (axi.rvalid && axi.rready) begin
                            ar_sent <= 1'b0;
                            // store this 32-bit refill word
                            data_array[write_set_idx][miss_way]
                                    [refill_count * DATA_WIDTH +: DATA_WIDTH]
                                <= axi.rdata;

                            // if this is the originally requested word
                            if (refill_count == write_word_off)
                                data_array[write_set_idx][miss_way]
                                    [refill_count * DATA_WIDTH +: DATA_WIDTH]
                                <= writedata;

                            // reached end of cache line transfer
                            if (refill_count == WORDS_PER_LINE - 1) begin
                                // full line is now complete
                                tag_array[write_set_idx][miss_way]   <= write_tag;
                                valid_array[write_set_idx][miss_way] <= 1'b1;

                                // update LRU ONCE here
                                for (int way = 0; way < NUM_WAYS; way++) begin
                                    if (way == miss_way)
                                        lru_rank[write_set_idx][way] <= '0;
                                    else if (valid_array[write_set_idx][way] &&
                                            lru_rank[write_set_idx][way] < NUM_WAYS-1)
                                        lru_rank[write_set_idx][way]
                                            <= lru_rank[write_set_idx][way] + 1'b1;
                                end

                                refill_count <= '0;
                                state <= WRITE_RESP;
                                dirty_array[write_set_idx][miss_way] <= 1'b1;

                            end else begin
                                refill_count <= refill_count + 1'b1;
                            end                           
                        end
                    end

                    WRITE_RESP: begin
                        writedata <= '0;
                        writeaddr <= '0;
                        state <= IDLE;
                    end
            endcase
            end
        end


        // signal raising
        always_comb begin
            axi.arvalid = 0;
            axi.araddr  = 0;
            axi.rready  = 0;

            axi.awvalid = 0;
            axi.awaddr  = 0;
            axi.wvalid  = 0;
            axi.wdata   = 0;
            axi.wstrb   = '0;
            axi.bready  = 0;

            l1d.d_waitrequest = 1'b0;
            l1d.data          = '0;

            hit            = 1'b0;
            hit_way        = '0;
            old_hit_rank   = '0;
            victim_way     = '0;
            found_invalid  = 1'b0;
            block_is_dirty = 1'b0;
            case (state)
                IDLE: begin
                    if (l1d.d_write || l1d.d_read) begin
                        l1d.d_waitrequest = 1'b1;
                    end
                end

                READ_WAIT: begin
                    // hit case
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
                    l1d.d_waitrequest = 1'b1;

                    // miss case
                    victim_way = '0;
                    found_invalid = 1'b0;
                    block_is_dirty = 1'b0;
                    // check for invalid
                    for (int way = 0; way < NUM_WAYS; way++) begin
                        if (!found_invalid && !valid_array[read_set_idx][way]) begin
                            // it can't be dirty if it is invalid
                            victim_way    = way;
                            found_invalid = 1'b1;
                        end
                    end
                    // no invalid then evict the LRU way
                    if (!found_invalid) begin
                        for (int way = 0; way < NUM_WAYS; way++) begin
                            if (lru_rank[read_set_idx][way] == NUM_WAYS-1) begin
                                victim_way = way;
                            end
                        end
                        // this tells that the victim way is dirty 
                        if (dirty_array[read_set_idx][victim_way]) begin
                            block_is_dirty = 1'b1;
                        end else begin
                            block_is_dirty = 1'b0;
                        end
                    end
                end

                READ_REFILL: begin
                    // bring the block from L2 to L1
                    // should raise master here
                    // this increments araddr for each refill_count

                     axi.araddr = {readaddr[ADDR_WIDTH-1:OFFSET_BITS],
                    {OFFSET_BITS{1'b0}}} + refill_count * (DATA_WIDTH / 8);

                    axi.arvalid = !ar_sent;
                    axi.rready = ar_sent;
                    
                    l1d.d_waitrequest = 1'b1;
                end

                READ_RESP: begin
                    l1d.data = readdata;
                    l1d.d_waitrequest = 1'b0;
                end

                WRITE_WAIT: begin
                    // no AXI signal update
                    // just perform comparison to see if a hit occurs, if so which way
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
                    l1d.d_waitrequest = 1'b1;

                    // miss case
                    victim_way = '0;
                    found_invalid = 1'b0;
                    // check for invalid
                    for (int way = 0; way < NUM_WAYS; way++) begin
                        if (!found_invalid && !valid_array[write_set_idx][way]) begin
                            // it can't be dirty if it is invalid
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
                        // this tells that the victim way is dirty 
                        if (dirty_array[write_set_idx][victim_way]) begin
                            block_is_dirty = 1'b1;
                        end else begin
                            block_is_dirty = 1'b0;
                        end
                    end
                end

                WRITE_BACK: begin
                    // TODO: use the dirty block's tag and set instead of missed
                    // tweak the awaddr 
                    // tweak the wdata as well
                    if (miss_is_write) begin
                        axi.awaddr = {
                            tag_array[write_set_idx][miss_way],
                            write_set_idx,
                            {OFFSET_BITS{1'b0}}
                        } + writeback_count * (DATA_WIDTH/8);

                        axi.wdata =
                            data_array[write_set_idx][miss_way]
                            [writeback_count*DATA_WIDTH +: DATA_WIDTH];
                    end else begin
                        axi.awaddr = {
                            tag_array[read_set_idx][miss_way],
                            read_set_idx,
                            {OFFSET_BITS{1'b0}}
                        } + writeback_count * (DATA_WIDTH/8);

                        axi.wdata =
                            data_array[read_set_idx][miss_way]
                            [writeback_count*DATA_WIDTH +: DATA_WIDTH];
                    end

                    axi.awvalid = !aw_sent;
                    axi.wvalid  = !w_sent;
                    axi.wstrb   = '1;
                    axi.bready  = aw_sent && w_sent;
                    l1d.d_waitrequest = 1'b1;
                end

                WRITE_REFILL: begin
                    // bring the block from L2 to L1
                    // should raise master here
                    // this increments araddr for each refill_count
                    axi.araddr = {writeaddr[ADDR_WIDTH-1:OFFSET_BITS],
                        {OFFSET_BITS{1'b0}}} + refill_count * (DATA_WIDTH / 8);

                    axi.arvalid = !ar_sent;
                    axi.rready = ar_sent;
                    
                    l1d.d_waitrequest = 1'b1;
                    l1d.d_waitrequest = 1'b1;
                end

                WRITE_RESP: begin
                    l1d.d_waitrequest = 1'b0;
                end

                default: begin
                end
            endcase
        end
    endmodule

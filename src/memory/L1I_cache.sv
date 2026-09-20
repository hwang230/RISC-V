    `include "axi_interface.sv"
    `include "L1_cache_interface.sv"
    module l1i_cache #(
        // cache parameters
        parameter CACHE_SIZE = 64*1024, // 64kB
        parameter LINE_SIZE  = 64,
        parameter NUM_WAYS   = 4,
        parameter ADDR_WIDTH = 32,
        parameter DATA_WIDTH = 32,
        parameter LATENCY = 5
    )(
        input logic clk, 
        input logic rst_n,
        l1_cache_if.l1i l1i, 
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
        // CACHE CONTROLLER STATE
        // ============================================================
        typedef enum logic [1:0] {
            IDLE,
            READ_WAIT,
            READ_MISS,
            READ_RESP
        } state_t;

        state_t state;

        logic [LAT_CNT_WIDTH-1:0] latency_count;   

        // ============================================================
        // LATCHED REQUEST / RESPONSE DATA
        // ============================================================
        logic [ADDR_WIDTH-1:0] readaddr;
        logic [DATA_WIDTH-1:0] readdata;

        // ============================================================
        // ADDRESS DECODE
        // ============================================================
        logic [INDEX_BITS-1:0]  read_set_idx;
        logic [TAG_BITS-1:0]    read_tag;
        logic [WORD_OFFSET_BITS-1:0] read_word_off;

        // Read address decode
        assign read_set_idx  = readaddr[OFFSET_BITS +: INDEX_BITS];
        assign read_tag      = readaddr[ADDR_WIDTH-1 -: TAG_BITS];
        generate
            if (WORDS_PER_LINE > 1) begin : gen_word_offset
                assign read_word_off = readaddr[BYTE_OFFSET_BITS +: WORD_OFFSET_BITS];
            end else begin : gen_single_word_line
                assign read_word_off = '0;
            end
        endgenerate

        initial begin
            if (DATA_WIDTH < 32 || (DATA_WIDTH % 8) != 0 ||
                (DATA_WIDTH & (DATA_WIDTH - 1)) != 0 ||
                (LINE_SIZE % (DATA_WIDTH / 8)) != 0 || WORDS_PER_LINE < 1)
                $fatal(1, "l1i_cache requires a power-of-two DATA_WIDTH >= 32 that divides LINE_SIZE");
            if ((LINE_SIZE & (LINE_SIZE - 1)) != 0 ||
                CACHE_SIZE % (LINE_SIZE * NUM_WAYS) != 0 || NUM_SETS < 2 ||
                (NUM_SETS & (NUM_SETS - 1)) != 0 || TAG_BITS < 1)
                $fatal(1, "l1i_cache requires power-of-two line/set geometry and a positive tag width");
        end

        logic ar_sent;
        // l1i logic
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                // reset oepration
                state <= IDLE;
                latency_count <= '0;
                readaddr  <= '0;
                readdata  <= '0;
                ar_sent   <= 1'b0;
                miss_way_selected <= 1'b0;
                miss_way          <= '0;
                refill_count      <= '0;
                
                for (int i = 0; i < NUM_SETS; i++) begin
                    for (int j = 0; j < NUM_WAYS; j++) begin
                        valid_array[i][j] <= 1'b0;
                        lru_rank[i][j]    <= j;
                    end
                end

            end else begin
                // use states here for transition
                case (state) 
                    IDLE: begin
                        if (l1i.i_read) begin
                            state <= READ_WAIT;
                            readaddr <= l1i.iaddr;
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

                                end else begin
                                    refill_count <= refill_count + 1'b1;
                                end
                            end
                        end
                    end

                    READ_RESP: begin
                        readaddr <= '0;
                        readdata <= '0;
                        state <= IDLE;
                        miss_way_selected <= 1'b0;
                    end

                    default: begin
                    end
                endcase

            end 
        end 

        always_comb begin
            // we only need ar channel, but still instantiate aw and w channel to 0
            axi.arvalid = 1'b0;
            axi.araddr  = '0;
            axi.rready  = 1'b0;

            axi.awvalid = 1'b0;
            axi.awaddr  = '0;
            axi.wvalid  = 1'b0;
            axi.wdata   = '0;
            axi.wstrb   = '0;
            axi.bready  = 1'b0;

            l1i.i_waitrequest = 1'b0;
            l1i.instr         = '0;
            hit         = 1'b0;
            hit_way     = '0;
            old_hit_rank = '0;
            victim_way = '0;
            found_invalid = 1'b0;
            
            case (state) 
                IDLE: begin
                    if (l1i.i_read) begin
                        // to avoid sequentail latch delay
                        l1i.i_waitrequest = 1'b1;
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
                    l1i.i_waitrequest = 1'b1;
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
                        axi.araddr = {readaddr[ADDR_WIDTH-1:OFFSET_BITS],
                        {OFFSET_BITS{1'b0}}} + refill_count * (DATA_WIDTH / 8);

                        axi.arvalid = !ar_sent;
                        axi.rready = ar_sent;
                    end
                    l1i.i_waitrequest = 1'b1;
                end

                READ_RESP: begin
                    l1i.instr = readdata;
                    l1i.i_waitrequest = 1'b0;
                end

                default: begin
                end
            endcase
        end
    endmodule

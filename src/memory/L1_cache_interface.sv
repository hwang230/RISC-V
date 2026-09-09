interface l1_cache_if();
    // L1D cache
    // input channels for L1D addr 
    // used by both load and store
    // load or store depends on opcode 
    logic [31:0] daddr; // assert by cpu for load and store operation
    logic [31:0] wdata; // assert by cpu for write operation
    logic d_write; // assert by cpu instr to determine if write 
    logic d_read; // assert by cpu instr to determine if read
    
    // output channel for L1D addr
    logic [1:0] resp;
    logic [31:0] data; // return by load operation from L1D
    logic d_waitrequest; // stall if not brought down - between OOO CPU and L1D
    

    // L1I cache 
    // input channels for L1I addr
    // only fetch/load needs it
    logic [31:0] iaddr; // assert by cpu fetch when loading instruction
    // output channels for L1I
    logic [31:0] instr; // return by L1I for fetched instruction
    // used between OOO CPU and L1I
    logic i_waitrequest; // stall if not brought down - meaning data not there yet
    
    // defining the signal for L1D cache
    modport l1d(
        input daddr, wdata, d_write, d_read, 
        output resp, data, d_waitrequest
    ); 

    // defining the signal for L1I cache
    modport l1i(
        input iaddr, i_arready, i_rdata, i_rvalid, 
        output instr, i_waitrequest, i_araddr, i_arvalid, i_rready, i_bready
    ); 

endinterface

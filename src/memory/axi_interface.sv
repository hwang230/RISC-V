`ifndef AXI_INTERFACE_SV
`define AXI_INTERFACE_SV
interface axi_lite_if();
    // Address Write Channel
    logic [31:0] awaddr; // assert by master to indicate address
    logic awvalid; // assert by master to indicate address is valid
    logic awready; // assert by slave to indicate ready to accept address

    // Write Data Channel
    logic [31:0] wdata; // assert by master to indicate the data
    logic wvalid; // assert by master when data is valid
    logic wready; // assert by slave when ready to accept data

    // Write Response Channel
    logic [1:0] bresp; // 00: OKAY, 01: EXOKAY, 10: SLVERR, 11: DECERR
    logic bvalid; // assert by slave when response on bus
    logic bready; // assert by master when ready to receive response

    // Write signal to inform what to store
    logic [3:0] wstrb; 
    
    // Address Read Channel
    logic [31:0] araddr; // assert by master to indicate address
    logic arvalid; // assert by master to indicate address is valid
    logic arready; // assert by slave to indicate ready to accept address

    // Read Data Channel
    logic [31:0] rdata; // store data here
    logic rvalid; // assert by slave when data on bus
    logic rready; // assert by master when ready to receive data

    // defining the signals for the slave interface
    modport slave(
        input awaddr, awvalid, wdata, wvalid, wstrb, araddr, arvalid, rready, bready,
        output awready, wready, bresp, bvalid, arready, rdata, rvalid
    ); 

    // defining the signals for the master interface
    modport master(
        output awaddr, awvalid, wdata, wvalid, wstrb, araddr, arvalid, rready, bready,
        input awready, wready, bresp, bvalid, arready, rdata, rvalid
    );

endinterface
`endif

`ifndef AXI_MACROS_SVH
`define AXI_MACROS_SVH

// =============================================================================
// axi_macros.svh
//
// Tie-offs for axi_if instances that have nothing on one side. Same idea as
// the OBI tie-offs in obi_macros.svh: mechanical wiring only, no policy.
// =============================================================================

// ---- Write channels of a bus whose master only reads (I-cache, modport
//      master_rd): the master side of AW/W/B is driven idle.
`define AXI_TIE_OFF_MASTER_WR(BUS) \
    assign BUS.awid    = '0; \
    assign BUS.awaddr  = '0; \
    assign BUS.awlen   = '0; \
    assign BUS.awsize  = '0; \
    assign BUS.awburst = '0; \
    assign BUS.awvalid = 1'b0; \
    assign BUS.wdata   = '0; \
    assign BUS.wstrb   = '0; \
    assign BUS.wlast   = 1'b0; \
    assign BUS.wvalid  = 1'b0; \
    assign BUS.bready  = 1'b0;

// ---- A crossbar slave port with no slave attached (empty spare slot). The
//      crossbar never routes to it (its M_PRESENT bit is 0 and accesses get
//      DECERR), this only keeps the slave side driven.
`define AXI_TIE_OFF_SLAVE(BUS) \
    assign BUS.awready = 1'b0; \
    assign BUS.wready  = 1'b0; \
    assign BUS.bid     = '0; \
    assign BUS.bresp   = '0; \
    assign BUS.bvalid  = 1'b0; \
    assign BUS.arready = 1'b0; \
    assign BUS.rid     = '0; \
    assign BUS.rdata   = '0; \
    assign BUS.rresp   = '0; \
    assign BUS.rlast   = 1'b0; \
    assign BUS.rvalid  = 1'b0;

`endif // AXI_MACROS_SVH

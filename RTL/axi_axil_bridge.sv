`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// axi_axil_bridge
//
// axi_if slave port in front of axi_axil_adapter (Alex Forencich, verilog-axi,
// MIT licence; axi_axil_adapter*.v), which turns AXI4 into AXI4-Lite for IP
// with a flat AXI4-Lite port such as the Xilinx UART16550.
//
// clk and rst_n come from the bus. The adapter itself has an active-high
// synchronous reset; this is the one place where rst_n is inverted.
// =============================================================================
module axi_axil_bridge
    import axi_pkg::*;
(
    axi_if.slave bus,

    output wire [AXI_ADDR_WIDTH-1:0] m_axil_awaddr,
    output wire                      m_axil_awvalid,
    input  wire                      m_axil_awready,
    output wire [AXI_DATA_WIDTH-1:0] m_axil_wdata,
    output wire [AXI_STRB_WIDTH-1:0] m_axil_wstrb,
    output wire                      m_axil_wvalid,
    input  wire                      m_axil_wready,
    input  wire [1:0]                m_axil_bresp,
    input  wire                      m_axil_bvalid,
    output wire                      m_axil_bready,
    output wire [AXI_ADDR_WIDTH-1:0] m_axil_araddr,
    output wire                      m_axil_arvalid,
    input  wire                      m_axil_arready,
    input  wire [AXI_DATA_WIDTH-1:0] m_axil_rdata,
    input  wire [1:0]                m_axil_rresp,
    input  wire                      m_axil_rvalid,
    output wire                      m_axil_rready
);

    axi_axil_adapter #(
        .ADDR_WIDTH      (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH  (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH    (AXI_ID_WIDTH),
        .AXIL_DATA_WIDTH (AXI_DATA_WIDTH)
    ) u_adapter (
        .clk            (bus.clk),
        .rst            (!bus.rst_n),

        .s_axi_awid     (bus.awid),
        .s_axi_awaddr   (bus.awaddr),
        .s_axi_awlen    (bus.awlen),
        .s_axi_awsize   (bus.awsize),
        .s_axi_awburst  (bus.awburst),
        .s_axi_awlock   (1'b0),
        .s_axi_awcache  (4'b0),
        .s_axi_awprot   (3'b0),
        .s_axi_awvalid  (bus.awvalid),
        .s_axi_awready  (bus.awready),
        .s_axi_wdata    (bus.wdata),
        .s_axi_wstrb    (bus.wstrb),
        .s_axi_wlast    (bus.wlast),
        .s_axi_wvalid   (bus.wvalid),
        .s_axi_wready   (bus.wready),
        .s_axi_bid      (bus.bid),
        .s_axi_bresp    (bus.bresp),
        .s_axi_bvalid   (bus.bvalid),
        .s_axi_bready   (bus.bready),
        .s_axi_arid     (bus.arid),
        .s_axi_araddr   (bus.araddr),
        .s_axi_arlen    (bus.arlen),
        .s_axi_arsize   (bus.arsize),
        .s_axi_arburst  (bus.arburst),
        .s_axi_arlock   (1'b0),
        .s_axi_arcache  (4'b0),
        .s_axi_arprot   (3'b0),
        .s_axi_arvalid  (bus.arvalid),
        .s_axi_arready  (bus.arready),
        .s_axi_rid      (bus.rid),
        .s_axi_rdata    (bus.rdata),
        .s_axi_rresp    (bus.rresp),
        .s_axi_rlast    (bus.rlast),
        .s_axi_rvalid   (bus.rvalid),
        .s_axi_rready   (bus.rready),

        .m_axil_awaddr  (m_axil_awaddr),
        .m_axil_awprot  (),
        .m_axil_awvalid (m_axil_awvalid),
        .m_axil_awready (m_axil_awready),
        .m_axil_wdata   (m_axil_wdata),
        .m_axil_wstrb   (m_axil_wstrb),
        .m_axil_wvalid  (m_axil_wvalid),
        .m_axil_wready  (m_axil_wready),
        .m_axil_bresp   (m_axil_bresp),
        .m_axil_bvalid  (m_axil_bvalid),
        .m_axil_bready  (m_axil_bready),
        .m_axil_araddr  (m_axil_araddr),
        .m_axil_arprot  (),
        .m_axil_arvalid (m_axil_arvalid),
        .m_axil_arready (m_axil_arready),
        .m_axil_rdata   (m_axil_rdata),
        .m_axil_rresp   (m_axil_rresp),
        .m_axil_rvalid  (m_axil_rvalid),
        .m_axil_rready  (m_axil_rready)
    );

endmodule

`default_nettype wire

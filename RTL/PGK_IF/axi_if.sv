`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// axi_if
//
// AXI4 bus between the caches, axi_xbar and the AXI slaves. Signal set and
// default widths: axi_pkg.
//
// The interface carries clk and rst_n (active low, asynchronous assertion),
// so a module that only sits on AXI (axi_xbar, axi_ram, axi_axil_bridge)
// needs no clock or reset port of its own.
//
// Modports:
//   master     drives AW/W/AR, receives B/R            (D-cache, axi_xbar slave side)
//   slave      receives AW/W/AR, drives B/R            (axi_ram, axi_xbar master side)
//   master_rd  read channels only                      (I-cache). The write
//              channels of that instance must be tied off where it is
//              declared: `AXI_TIE_OFF_MASTER_WR in axi_macros.svh.
// =============================================================================
interface axi_if #(
    parameter int ADDR_WIDTH = axi_pkg::AXI_ADDR_WIDTH,
    parameter int DATA_WIDTH = axi_pkg::AXI_DATA_WIDTH,
    parameter int ID_WIDTH   = axi_pkg::AXI_ID_WIDTH
)(
    input wire clk,
    input wire rst_n
);
    // write address
    logic [ID_WIDTH-1:0]     awid;
    logic [ADDR_WIDTH-1:0]   awaddr;
    logic [7:0]              awlen;
    logic [2:0]              awsize;
    logic [1:0]              awburst;
    logic                    awvalid;
    logic                    awready;
    // write data
    logic [DATA_WIDTH-1:0]   wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic                    wlast;
    logic                    wvalid;
    logic                    wready;
    // write response
    logic [ID_WIDTH-1:0]     bid;
    logic [1:0]              bresp;
    logic                    bvalid;
    logic                    bready;
    // read address
    logic [ID_WIDTH-1:0]     arid;
    logic [ADDR_WIDTH-1:0]   araddr;
    logic [7:0]              arlen;
    logic [2:0]              arsize;
    logic [1:0]              arburst;
    logic                    arvalid;
    logic                    arready;
    // read data
    logic [ID_WIDTH-1:0]     rid;
    logic [DATA_WIDTH-1:0]   rdata;
    logic [1:0]              rresp;
    logic                    rlast;
    logic                    rvalid;
    logic                    rready;

    modport master (
        input  clk, rst_n,
        output awid, awaddr, awlen, awsize, awburst, awvalid,
        input  awready,
        output wdata, wstrb, wlast, wvalid,
        input  wready,
        input  bid, bresp, bvalid,
        output bready,
        output arid, araddr, arlen, arsize, arburst, arvalid,
        input  arready,
        input  rid, rdata, rresp, rlast, rvalid,
        output rready
    );

    modport slave (
        input  clk, rst_n,
        input  awid, awaddr, awlen, awsize, awburst, awvalid,
        output awready,
        input  wdata, wstrb, wlast, wvalid,
        output wready,
        output bid, bresp, bvalid,
        input  bready,
        input  arid, araddr, arlen, arsize, arburst, arvalid,
        output arready,
        output rid, rdata, rresp, rlast, rvalid,
        input  rready
    );

    modport master_rd (
        input  clk, rst_n,
        output arid, araddr, arlen, arsize, arburst, arvalid,
        input  arready,
        input  rid, rdata, rresp, rlast, rvalid,
        output rready
    );

endinterface : axi_if

`default_nettype wire

`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// obi_instr_if / obi_data_if
//
// OBI-lite bus interfaces.
//
// These are real SystemVerilog interfaces with modports, UNLIKE the
// id_ex/ex_mem/mem_wb packed structs in core_pkg. The reasoning is the
// inverse of the one that kept the pipeline bundles as plain structs: the
// thing on the other end of instr_bus / data_bus is not a fixed neighbor.
// In simulation it is a simple single-cycle BRAM model; on real hardware it
// might be a Vivado AXI<->OBI bridge, an instruction cache, or a shared bus
// fabric with other masters behind it. Multiple possible, interchangeable
// connectees implementing the same request/grant/response contract is
// exactly the case a modport exists for, so each side (core-as-master,
// memory-as-slave) gets one.
//
// Two separate interfaces rather than one generic parameterized one,
// because the instruction channel in this core is genuinely read-only --
// there is no we/be/wdata anywhere on the instruction OBI path in the RTL
// being converted. Giving obi_instr_if write signals it can never use
// would just be dead ports pretending to be part of a real contract, which
// is the same trap core_pkg's header warns against for alu_ctrl/mem_ctrl.
// =============================================================================

interface obi_instr_if #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 32
);
    logic                  req;     // master: fetch request
    logic [ADDR_WIDTH-1:0] addr;    // master: fetch address
    logic                  gnt;     // slave : request accepted this cycle
    logic                  rvalid;  // slave : rdata valid this cycle
    logic [DATA_WIDTH-1:0] rdata;   // slave : fetched instruction word

    modport master (
        output req, addr,
        input  gnt, rvalid, rdata
    );

    modport slave (
        input  req, addr,
        output gnt, rvalid, rdata
    );

endinterface : obi_instr_if


interface obi_data_if #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 32
);
    logic                    req;    // master: transaction request
    logic [ADDR_WIDTH-1:0]   addr;   // master: byte address
    logic                    we;     // master: 1 = write, 0 = read
    logic [DATA_WIDTH/8-1:0] be;     // master: per-byte write enable
    logic [DATA_WIDTH-1:0]   wdata;  // master: store data
    logic                    gnt;    // slave : request accepted this cycle
    logic                    rvalid; // slave : rdata valid this cycle
    logic [DATA_WIDTH-1:0]   rdata;  // slave : load data

    modport master (
        output req, addr, we, be, wdata,
        input  gnt, rvalid, rdata
    );

    modport slave (
        input  req, addr, we, be, wdata,
        output gnt, rvalid, rdata
    );

endinterface : obi_data_if

`default_nettype wire
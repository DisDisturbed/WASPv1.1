`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// obi_instr_if / obi_data_if
//
// OBI-lite bus interfaces.
//
// Real SystemVerilog interfaces with modports, unlike the pipeline bundles
// in core_pkg, which are plain structs. A pipeline stage always has the
// same fixed neighbour; the thing on the other end of instr_bus / data_bus
// is not fixed: the I-cache or D-cache, the PLIC, the CLINT, a simulation
// memory model. Several interchangeable connectees implementing the same
// request/grant/response contract is the case a modport exists for, so
// each side (master, slave) gets one.
//
// Two interfaces, not one generic parameterized one, because the
// instruction channel is read-only: there is no we/be/wdata anywhere on
// the instruction path, and obi_instr_if does not carry them.
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
    logic                  err;     // slave : with rvalid, fetch not allowed (instruction access fault)

    modport master (
        output req, addr,
        input  gnt, rvalid, rdata, err
    );

    modport slave (
        input  req, addr,
        output gnt, rvalid, rdata, err
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
    logic                    err;    // slave : with rvalid, access failed (load/store access fault).
                                     //         A slave that can fail a WRITE must give rvalid+err
                                     //         in its gnt cycle (the core retires stores at gnt).

    modport master (
        output req, addr, we, be, wdata,
        input  gnt, rvalid, rdata, err
    );

    modport slave (
        input  req, addr, we, be, wdata,
        output gnt, rvalid, rdata, err
    );

endinterface : obi_data_if

`default_nettype wire
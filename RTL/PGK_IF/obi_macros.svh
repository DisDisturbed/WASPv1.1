`ifndef OBI_MACROS_SVH
`define OBI_MACROS_SVH

// =============================================================================
// obi_macros.svh
//
// (Also hosts the one small irq_if tie-off macro at the bottom -- kept in
// this file rather than a separate one-macro header, since it's the same
// "mechanical glue, not policy" category as everything else here.)
//
// Why these exist: SystemVerilog interface *arrays* are real
// (`obi_data_if bus[N] ();`), but which array element a port connects to
// must be resolved at elaboration time (a genvar/constant index) -- you
// cannot pick "leg i" of an interface array using a runtime signal the way
// you'd index a data bus. A one-master-to-many-slave OBI decoder (like
// cache_system_top's core -> {dcache, plic} split) needs a runtime
// decision, so it cannot be expressed as an array select; it has to be
// explicit per-field muxing. These macros exist to make that muxing
// mechanical/boilerplate-free at the call site, NOT to hide the
// arbitration policy itself -- who wins arbitration (outstanding-transaction
// tracking, address decode, priority) stays hand-written RTL wherever it's
// used, because that's real design logic a macro shouldn't swallow.
//
// A plain 1:1 master<->slave connection (Core_Top's instr_bus <-> icache,
// e.g.) needs NO macro and no glue at all: just declare one interface
// instance and pass it to both module ports. The modports alone make req/
// addr flow one way and gnt/rvalid/rdata flow the other. Macros only earn
// their keep at genuine N:1 fan-out/arbitration points.
// =============================================================================

// ---- Address-phase broadcast: master's req-independent fields fan out to
//      every candidate slave unconditionally (only req/gnt/rvalid/rdata are
//      arbitrated) -- this is the standard OBI/AXI-lite decoder shape.
`define OBI_DATA_BROADCAST_AP(SLV, MST) \
    assign SLV.addr  = MST.addr; \
    assign SLV.we    = MST.we; \
    assign SLV.be    = MST.be; \
    assign SLV.wdata = MST.wdata;

// ---- Gate one slave leg's request with an arbitration-decision EN
//      expression (e.g. "address decode & outstanding-transaction allow").
`define OBI_DATA_GATE_REQ(SLV, MST, EN) \
    assign SLV.req = MST.req & (EN);

// ---- Straight 1:1 pass-through for cases where declaring/sharing a single
//      interface instance between two ports isn't convenient (e.g. bridging
//      an interface leg to a not-yet-converted flat-port module). Response
//      side still needs a real mux if there is more than one slave leg --
//      this macro is only correct for an actual 1:1 connection.
`define OBI_DATA_CONNECT(SLV, MST) \
    assign SLV.req   = MST.req; \
    assign SLV.addr  = MST.addr; \
    assign SLV.we    = MST.we; \
    assign SLV.be    = MST.be; \
    assign SLV.wdata = MST.wdata; \
    assign MST.gnt    = SLV.gnt; \
    assign MST.rvalid = SLV.rvalid; \
    assign MST.rdata  = SLV.rdata;

`define OBI_INSTR_CONNECT(SLV, MST) \
    assign SLV.req  = MST.req; \
    assign SLV.addr = MST.addr; \
    assign MST.gnt    = SLV.gnt; \
    assign MST.rvalid = SLV.rvalid; \
    assign MST.rdata  = SLV.rdata;

// ---- Tie-offs for a leg that legitimately has no connectee (optional
//      peripherals, unused legs in a testbench, etc.) -- kept here for the
//      same "expandability" reason core_pkg.sv keeps priv_mode around
//      unused: cheap to have available, one line to use when needed.
`define OBI_DATA_TIE_OFF_MASTER(MST) \
    assign MST.req   = 1'b0; \
    assign MST.addr  = '0; \
    assign MST.we    = 1'b0; \
    assign MST.be    = '0; \
    assign MST.wdata = '0;

`define OBI_DATA_TIE_OFF_SLAVE(SLV) \
    assign SLV.gnt    = 1'b0; \
    assign SLV.rvalid = 1'b0; \
    assign SLV.rdata  = '0;

`define OBI_INSTR_TIE_OFF_SLAVE(SLV) \
    assign SLV.gnt    = 1'b0; \
    assign SLV.rvalid = 1'b0; \
    assign SLV.rdata  = '0;

// ---- Tie off an unused irq_if source leg (e.g. a PLIC source index with
//      no peripheral wired up in a given build).
`define IRQ_TIE_OFF_SOURCE(SRC) \
    assign SRC.pending = 1'b0;

`endif // OBI_MACROS_SVH

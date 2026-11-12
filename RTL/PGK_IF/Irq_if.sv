`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// irq_if
//
// One interrupt line, one interface instance. The PLIC takes an array of
// them, irq_if.sink irq_lines [N_SRC-1:0]. Each slot is a separate
// connectee: a different peripheral can drive each source index without
// knowing N_SRC or which index it landed on, it only drives its one
// irq_if.source port.
//
// Which slot a source lands in is fixed at elaboration time (a genvar or a
// specific instantiation), never chosen at run time, so a plain interface
// array fits here. The OBI data-bus decode is different: there the slave
// is picked at run time, which is why it is written with the macros in
// obi_macros.svh.
//
// Level-sensitive: the PLIC's pending latch reads `pending` as a level,
// not an edge.
// =============================================================================

interface irq_if;
    logic pending;

    modport source (output pending);  // peripheral driving one interrupt line
    modport sink   (input  pending);  // consumer (PLIC) receiving it
endinterface : irq_if

`default_nettype wire
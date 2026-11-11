`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// irq_if
//
// One interrupt line, one interface instance. plic's irq_src_i used to be
// a single flat [N_SRC-1:0] vector; it's now an ARRAY of these,
// irq_if.sink irq_lines [N_SRC-1:0]. Each array slot is a genuinely
// separate connectee -- a different peripheral IP block can drive each
// source index, and that peripheral shouldn't need to know N_SRC or which
// index it landed on, just "drive my one irq_if.source port". That's the
// same "multiple interchangeable parties implementing a shared contract"
// justification core_pkg.sv's header uses for modports generally, applied
// one level down (per-source instead of per-bus).
//
// This is NOT the same situation as the OBI data-bus arbiter: which array
// SLOT a given source lands in is fixed at elaboration time (a genvar / a
// specific instantiation), never chosen at runtime, so a plain interface
// array is the right tool here -- unlike the dcache/PLIC OBI arbitration,
// there is no dynamic "pick element i" problem to work around with macros.
//
// Level-sensitive, matching the original irq_src_i[i] semantics exactly
// (plic's pending-latch reads it combinationally as a level, not an edge).
// =============================================================================

interface irq_if;
    logic pending;

    modport source (output pending);  // peripheral driving one interrupt line
    modport sink   (input  pending);  // consumer (PLIC) receiving it
endinterface : irq_if

`default_nettype wire
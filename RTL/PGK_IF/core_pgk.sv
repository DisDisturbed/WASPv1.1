`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// core_pkg
//
// Consolidated definitions for the core: PC-mux encodings, CSR address map,
// trap cause codes, and packed pipeline-register bundles (ID/EX, EX/MEM,
// MEM/WB).
//
// WHAT WAS PROMOTED HERE, AND WHY:
//   - pc_mux_sel_e / exc_pc_mux_e / trap_mode_e
//       Previously defined independently in BOTH IF_stage (as a local
//       typedef) and hazard_unit (as raw localparams with hand-copied
//       values). Two definitions of the same encoding with no compiler
//       link between them -- this is the actual duplication risk that
//       justified a package, not a stylistic preference.
//   - CSR address map, CSR op encoding
//       Previously localparams local to csr_file only. Promoted because
//       U/S-mode work needs S-mode addresses added, and other stages
//       (ID_stage decodes csr_addr, EX_stage forms csr_wdata_final_w)
//       reference CSR semantics and will benefit from named constants
//       instead of raw 12-bit literals.
//   - Trap cause codes
//       Previously raw 6-bit magic numbers (6'd0, 6'd2, 6'd3, 6'd7,
//       6'd11) scattered across ID_stage and EX_stage. This list is
//       about to roughly double for U/S-mode delegation (separate
//       ECALL-from-U / ECALL-from-S causes) -- naming them now, before
//       that expansion, is the whole point.
//   - Branch-type encoding, WB-mux encoding
//       Both are explicitly given in your EX_stage (branch_dec block)
//       and WB_stage (wb_mux block) source as literal case values. Named
//       here so the two locations that must agree can't silently drift.
//   - id_ex_bundle_t / ex_mem_bundle_t / mem_wb_bundle_t
//       Packed structs matching your CURRENT port lists field-for-field.
//       These are NOT SystemVerilog interfaces/modports -- deliberately.
//       Your pipeline stages are always connected to the same fixed
//       neighbor (ID always drives EX, never anything else), so a
//       modport's "contract between interchangeable parties" justification
//       doesn't apply here, and it would add an abstraction tax on
//       exactly the part of the design meant to stay approachable to
//       future undergrad contributors. A plain packed struct still solves
//       the actual problem (adding a field, e.g. priv_mode for U/S-mode,
//       currently means editing N ports across 3 stage boundaries AND
//       their instantiations in Core_Top) by making it a one-line change
//       in ONE place. Waveform viewers expand packed structs like any
//       other bus, so nothing gets harder to debug.
//
// WHAT WAS DELIBERATELY *NOT* PROMOTED HERE:
//   - alu_ctrl, mem_ctrl, muldiv_ctrl encodings: control_unit, Alu, and
//     MulDiv were not part of what was reviewed, so their actual
//     encodings are unknown. Guessing an enum here would risk creating a
//     THIRD, WRONG definition instead of preventing a duplicate one.
//     These fields are left as plain logic vectors below -- if you want
//     them enumerated too, do it from the real control_unit/Alu source,
//     not from this file.
//   - OBI / AXI bus signals: those get real SystemVerilog interfaces
//     with modports (separate file), because a modport's justification
//     -- multiple possible connectees implementing a shared contract --
//     genuinely applies there (peripherals, masters, slaves), unlike the
//     fixed stage-to-stage pipeline wiring below. See obi_if.sv.
//
// HOW TO ADOPT THIS INCREMENTALLY (no big-bang rewrite required):
//   1. `import core_pkg::*;` at the top of each module that currently
//      redefines any of the enums/params below, delete the local
//      redefinition, confirm the module still elaborates identically.
//   2. Re-run your riscv-dv/Spike regression after each module you
//      convert. Do this one module at a time, not all five stages at
//      once -- if something breaks you want to know which conversion did
//      it.
//   3. The packed structs at the bottom are ready to use whenever you
//      want to switch a stage boundary over, but adopting them is
//      optional and separate from step 1/2 -- the enum/param cleanup is
//      the higher-value, lower-risk part of this and can be done first
//      on its own.
// =============================================================================

package core_pkg;

    // -------------------------------------------------------------------
    // Global widths
    // Hardcoded to match every current instantiation (Core_Top is always
    // built with DATA_WIDTH=32, RF_ADDR_WIDTH=5). If you ever actually
    // instantiate the core with different widths, these structs need to
    // become parameterized packages (`package core_pkg #(...)`) instead --
    // not worth doing until/unless that's a real requirement.
    // -------------------------------------------------------------------
    localparam int CORE_DATA_WIDTH    = 32;
    localparam int CORE_RF_ADDR_WIDTH = 5;

    // =====================================================================
    // PC mux selection
    // Source of truth was duplicated between IF_stage's local typedef and
    // hazard_unit's raw localparams. Values below match both existing
    // definitions exactly -- this promotion changes nothing behaviorally.
    // =====================================================================
    typedef enum logic [3:0] {
        PC_BOOT      = 4'd0,
        PC_JUMP      = 4'd1,
        PC_BRANCH    = 4'd2,
        PC_EXCEPTION = 4'd3,
        PC_MRET      = 4'd4,
        PC_URET      = 4'd5,
        PC_FENCEI    = 4'd6,
        PC_PLUS4     = 4'd7
    } pc_mux_sel_e;

    typedef enum logic [2:0] {
        EXC_PC_EXCEPTION = 3'd0,
        EXC_PC_IRQ       = 3'd1,
        EXC_PC_DBE       = 3'd2
    } exc_pc_mux_e;

    typedef enum logic [1:0] {
        TRAP_M = 2'd0,
        TRAP_U = 2'd1
        // TRAP_S left unassigned deliberately -- add it here (and only
        // here) when S-mode trap-base routing is implemented, instead of
        // adding a third scattered definition somewhere else.
    } trap_addr_mux_e;

    // =====================================================================
    // Privilege levels
    // Matches RISC-V privilege encoding (used directly as mstatus.MPP /
    // mstatus.SPP values). Not present in your current RTL -- new for the
    // U/S-mode work, defined here so there's exactly one definition from
    // the start instead of one appearing ad hoc wherever it's first needed.
    // =====================================================================
    typedef enum logic [1:0] {
        PRIV_U = 2'b00,
        PRIV_S = 2'b01,
        // 2'b10 reserved (Hypervisor, not implemented)
        PRIV_M = 2'b11
    } priv_mode_e;

    // =====================================================================
    // CSR address map
    // M-mode addresses match your existing csr_file localparams exactly.
    // S-mode addresses are the standard RISC-V assignments, added now
    // since U/S-mode work needs them and this is the one place they
    // should be defined.
    // =====================================================================
    localparam logic [11:0]
        // ---- Machine mode (existing) ----
        CSR_ADDR_MSTATUS   = 12'h300,
        CSR_ADDR_MISA      = 12'h301,
        CSR_ADDR_MEDELEG   = 12'h302,   // new: exception delegation
        CSR_ADDR_MIDELEG   = 12'h303,   // new: interrupt delegation
        CSR_ADDR_MIE       = 12'h304,
        CSR_ADDR_MTVEC     = 12'h305,
        CSR_ADDR_MSCRATCH  = 12'h340,
        CSR_ADDR_MEPC      = 12'h341,
        CSR_ADDR_MCAUSE    = 12'h342,
        CSR_ADDR_MTVAL     = 12'h343,
        CSR_ADDR_MIP       = 12'h344,
        CSR_ADDR_MVENDORID = 12'hF11,
        CSR_ADDR_MARCHID   = 12'hF12,
        CSR_ADDR_MIMPID    = 12'hF13,
        CSR_ADDR_MHARTID   = 12'hF14,

        // ---- Supervisor mode (new) ----
        CSR_ADDR_SSTATUS   = 12'h100,
        CSR_ADDR_SIE       = 12'h104,
        CSR_ADDR_STVEC     = 12'h105,
        CSR_ADDR_SSCRATCH  = 12'h140,
        CSR_ADDR_SEPC      = 12'h141,
        CSR_ADDR_SCAUSE    = 12'h142,
        CSR_ADDR_STVAL     = 12'h143,
        CSR_ADDR_SIP       = 12'h144,
        CSR_ADDR_SATP      = 12'h180,  // only relevant if/when a TLB stretch
                                        // goal is attempted -- harmless to
                                        // have reserved either way

        // ---- Counter enables (Zicntr) ----
        // Present as plain R/W registers today (reset = all ones = "every
        // counter visible to the lower mode"). Nothing checks them yet
        // because the core is M-mode only; csr_file exports them so the
        // U/S-mode work can gate cycle/time/instret reads with them.
        CSR_ADDR_SCOUNTEREN    = 12'h106,
        CSR_ADDR_MCOUNTEREN    = 12'h306,
        CSR_ADDR_MSTATUSH      = 12'h310,   // RV32 only, all fields 0 (little-endian, no H)
        CSR_ADDR_MCOUNTINHIBIT = 12'h320,   // bit0 CY, bit2 IR writable
        CSR_ADDR_MCONFIGPTR    = 12'hF15,   // 0 = no config structure

        // ---- Machine counters (Zicntr / Zihpm) ----
        CSR_ADDR_MCYCLE        = 12'hB00,
        CSR_ADDR_MINSTRET      = 12'hB02,
        CSR_ADDR_MCYCLEH       = 12'hB80,
        CSR_ADDR_MINSTRETH     = 12'hB82,
        // mhpmcounter3..31  = 0xB03..0xB1F, mhpmcounter3h..31h = 0xB83..0xB9F
        // mhpmevent3..31    = 0x323..0x33F   (all hardwired to 0)

        // ---- User read-only shadows ----
        CSR_ADDR_CYCLE         = 12'hC00,
        CSR_ADDR_TIME          = 12'hC01,   // = CLINT mtime
        CSR_ADDR_INSTRET       = 12'hC02,
        CSR_ADDR_CYCLEH        = 12'hC80,
        CSR_ADDR_TIMEH         = 12'hC81,
        CSR_ADDR_INSTRETH      = 12'hC82;
        // hpmcounter3..31 = 0xC03..0xC1F, hpmcounter3h..31h = 0xC83..0xC9F (0)

    // CSR RMW operation encoding (from csr_file's `unique case (csr_op_i)`)
    typedef enum logic [1:0] {
        CSR_OP_NOP   = 2'b00,
        CSR_OP_WRITE = 2'b01,   // CSRRW: unconditional write
        CSR_OP_SET   = 2'b10,   // CSRRS: old | wdata
        CSR_OP_CLEAR = 2'b11    // CSRRC: old & ~wdata
    } csr_op_e;

    // =====================================================================
    // Trap cause codes
    // mcause/scause layout: bit[5] = interrupt (1) vs exception (0),
    // bits[4:0] = cause number. Exception and interrupt numbers below are
    // BOTH width-6 constants with the interrupt bit already baked in, so
    // they can be assigned directly to a 6-bit trap_cause signal without
    // extra concatenation at each use site.
    //
    // Existing values (already in your ID_stage / EX_stage as raw
    // literals) are unchanged. New ECALL-per-privilege-level causes are
    // added since plain ECALL (6'd11, M-mode only) stops being sufficient
    // the moment U/S mode exists.
    // =====================================================================

    // ---- Exceptions (bit 5 = 0) ----
    localparam logic [5:0]
        TRAP_CAUSE_INSTR_ADDR_MISALIGNED = 6'd0,
        TRAP_CAUSE_INSTR_ACCESS_FAULT    = 6'd1,   // fetch outside IMEM/DMEM (icache err)
        TRAP_CAUSE_ILLEGAL_INSTRUCTION   = 6'd2,   // existing: illegal_instr_w
        TRAP_CAUSE_BREAKPOINT            = 6'd3,   // existing: ebreak_w
        TRAP_CAUSE_LOAD_ADDR_MISALIGNED  = 6'd4,
        TRAP_CAUSE_LOAD_ACCESS_FAULT     = 6'd5,   // data bus err on a load
        TRAP_CAUSE_STORE_ADDR_MISALIGNED = 6'd6,
        TRAP_CAUSE_STORE_ACCESS_FAULT    = 6'd7,   // data bus err on a store
        // (6'd7 used to be a custom divide-by-zero trap; division by zero
        //  is not an exception in RISC-V, see docs/riscv_tests.md)
        TRAP_CAUSE_ECALL_FROM_U          = 6'd8,    // new: needed once U-mode exists
        TRAP_CAUSE_ECALL_FROM_S          = 6'd9,    // new: needed once S-mode exists
        TRAP_CAUSE_ECALL_FROM_M          = 6'd11;   // existing behavior, renamed
                                                     // from the old unlabeled
                                                     // ecall_w -> 6'd11 assignment

    // ---- Interrupts (bit 5 = 1, i.e. 6'd32 + cause number) ----
    localparam logic [5:0]
        TRAP_CAUSE_SW_INTERRUPT_M    = 6'd35,  // {1'b1, 5'd3}
        TRAP_CAUSE_TIMER_INTERRUPT_M = 6'd39,  // {1'b1, 5'd7}  (existing)
        TRAP_CAUSE_EXT_INTERRUPT_M   = 6'd43;  // {1'b1, 5'd11} (existing)

    // =====================================================================
    // Branch comparison type
    // Matches EX_stage's `branch_dec` case exactly -- promoted so
    // control_unit (which must produce the same encoding) and EX_stage
    // (which consumes it) share one definition instead of agreeing by
    // convention only.
    // =====================================================================
    typedef enum logic [2:0] {
        BR_BEQ  = 3'b000,
        BR_BNE  = 3'b001,
        BR_BLT  = 3'b100,
        BR_BGE  = 3'b101,
        BR_BLTU = 3'b110,
        BR_BGEU = 3'b111
    } branch_type_e;

    // =====================================================================
    // WB source select
    // Matches WB_stage's `wb_mux` case exactly.
    // =====================================================================
    typedef enum logic [1:0] {
        WB_SEL_ALU_RESULT = 2'b00,
        WB_SEL_LOAD_DATA  = 2'b01,
        WB_SEL_PC_PLUS4   = 2'b10
    } wb_sel_e;

    // =====================================================================
    // Pipeline register bundles
    //
    // Field-for-field match to your CURRENT id_ex_* / ex_mem_* / mem_wb_*
    // port lists in Core_Top, so adopting these is a mechanical
    // substitution, not a redesign. alu_ctrl / mem_ctrl / muldiv_ctrl kept
    // as plain vectors -- see file header for why.
    //
    // priv_mode field added to each bundle now, unused until the U/S-mode
    // work begins, so that adding it later doesn't require editing three
    // struct definitions plus every stage's port list a second time.
    // =====================================================================

    typedef struct packed {
        logic [CORE_DATA_WIDTH-1:0]     pc;
        logic [CORE_DATA_WIDTH-1:0]     rs1_data;
        logic [CORE_DATA_WIDTH-1:0]     rs2_data;
        logic [CORE_DATA_WIDTH-1:0]     imm;
        logic [CORE_RF_ADDR_WIDTH-1:0]  rd_addr;
        logic [CORE_RF_ADDR_WIDTH-1:0]  rs1_addr;
        logic [CORE_RF_ADDR_WIDTH-1:0]  rs2_addr;

        logic                            reg_write;
        logic                            alu_src;
        logic [3:0]                      alu_ctrl;      // encoding: see control_unit/Alu
        logic                            is_muldiv;
        logic [2:0]                      muldiv_ctrl;   // encoding: see MulDiv

        branch_type_e                    branch_type;
        logic                            is_branch;
        logic                            is_jump;
        logic                            jalr;

        logic [2:0]                      mem_ctrl;      // encoding: see MEM_stage
        logic                            is_load;
        logic                            is_store;
        wb_sel_e                         wb_ctrl;

        logic                            csr_access;
        logic [11:0]                     csr_addr;
        csr_op_e                         csr_op;
        logic [CORE_DATA_WIDTH-1:0]      csr_wdata;
        logic                            csr_use_imm;
        logic [CORE_DATA_WIDTH-1:0]      csr_rdata;
        logic                            csr_we;
        logic                            mret;
        logic                            fencei;        // FENCE.I (Zifencei)

        logic                            trap;
        logic [5:0]                      trap_cause;
        logic [CORE_DATA_WIDTH-1:0]     tval;          // mtval value for this trap

        priv_mode_e                      priv_mode;     // NEW: unused until
                                                          // U/S-mode work lands
        logic                            valid;         // real, non-trapping instruction (minstret)
    } id_ex_bundle_t;

    typedef struct packed {
        logic [CORE_DATA_WIDTH-1:0]     alu_res;
        logic                            alu_zero;
        logic                            alu_error;
        logic                            alu_carry;
        logic [CORE_DATA_WIDTH-1:0]     rs2_data;
        logic [CORE_DATA_WIDTH-1:0]     branch_target;
        logic [CORE_RF_ADDR_WIDTH-1:0]  rd_addr;

        logic [2:0]                      mem_ctrl;
        wb_sel_e                         wb_ctrl;
        logic [CORE_DATA_WIDTH-1:0]     pc;
        logic [CORE_DATA_WIDTH-1:0]     pc_plus4;

        logic                            is_load;
        logic                            is_store;
        logic                            reg_write;
        logic                            is_jump;
        logic                            is_jarl;

        logic                            trap;
        logic                            trap_late;     // trap raised in EX (not yet redirected)
        logic [5:0]                      trap_cause;
        logic [CORE_DATA_WIDTH-1:0]     tval;          // mtval value for this trap

        logic [11:0]                     csr_addr;
        csr_op_e                         csr_op;
        logic [CORE_DATA_WIDTH-1:0]     csr_wdata;
        logic                            csr_access;
        logic                            csr_we;
        logic                            mret;
        logic                            fencei;        // FENCE.I: cache maintenance in MEM

        priv_mode_e                      priv_mode;     // NEW
        logic                            valid;         // real, non-trapping instruction (minstret)
    } ex_mem_bundle_t;

    typedef struct packed {
        logic [CORE_DATA_WIDTH-1:0]     alu_res;
        logic [CORE_DATA_WIDTH-1:0]     rdata;
        logic [CORE_RF_ADDR_WIDTH-1:0]  rd_addr;
        wb_sel_e                         wb_ctrl;
        logic [CORE_DATA_WIDTH-1:0]     pc_plus4;
        logic [CORE_DATA_WIDTH-1:0]     pc;

        logic                            is_load;
        logic                            is_jump;
        logic                            is_jarl;
        logic                            reg_write;

        logic                            trap;
        logic [5:0]                      trap_cause;
        logic [CORE_DATA_WIDTH-1:0]     tval;          // mtval value for this trap

        logic [11:0]                     csr_addr;
        csr_op_e                         csr_op;
        logic [CORE_DATA_WIDTH-1:0]     csr_wdata;
        logic                            csr_access;
        logic                            csr_we;
        logic                            mret;

        priv_mode_e                      priv_mode;     // NEW
        logic                            valid;         // real, non-trapping instruction (minstret)
    } mem_wb_bundle_t;

endpackage : core_pkg

`default_nettype wire
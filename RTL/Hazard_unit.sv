`timescale 1ns / 1ps
`default_nettype none

//  hazard_unit
//         priority :
//          1. lsu_busy    absolute freeze no redirect may override a live
//                         memory transaction
//          2. trap/mret   flush ID and redirect PC; pipeline was clean
//          3. branch      flush IF/ID/EX and redirect PC
//          4. jump        flush IF/ID/EX and redirect PC
//                         branches and jump are same
//          5. if_busy     I-cache miss stall IF, insert NOP into IF/ID
//          6. ex_busy     multi-cycle ALU stall IF+ID
//          7. load_use    raw stall stall IF, bubble ID
//
// pc_mux_o / exc_pc_mux_o now carry core_pkg's pc_mux_sel_e / exc_pc_mux_e
// types directly instead of raw [3:0]/[2:0] -- this was previously the
// other of the two places (with IF_stage) that hand-copied the same
// encoding as raw localparams; see core_pkg.sv header.
//
// Forwarding/hazard detection now reads directly from the id_ex/ex_mem/
// mem_wb pipeline bundles instead of ~15 individually-named ports per
// stage boundary.

module hazard_unit
    import core_pkg::*;
#(
    parameter int RF_ADDR_WIDTH = core_pkg::CORE_RF_ADDR_WIDTH
)(
    input wire clk,
    input wire rst_n,

    input  wire [RF_ADDR_WIDTH-1:0] id_rs1_addr_i,
    input  wire [RF_ADDR_WIDTH-1:0] id_rs2_addr_i,

    input  wire                     id_is_branch_i,
    input  wire                     id_jalr_i,
    input  wire                     id_csr_read_i,       // CSR instr or MRET (reads mepc) in ID
    input  wire                     id_cnt_read_i,       // CSR instr in ID reads minstret/instret(h)
    input  wire                     id_trap_req_i,       // ID wants to trap / take irq / mret

    input  id_ex_bundle_t           id_ex_i,
    input  ex_mem_bundle_t          ex_mem_i,
    input  mem_wb_bundle_t          mem_wb_i,

    input  wire                     branch_decision_i,   // from EX_stage

    input  wire                     ex_busy_i,           // multi-cycle ALU
    input  wire                     lsu_busy_i,          // data-memory transaction
    input  wire                     if_busy_i,           // I-cache miss

    input  wire                     trap_take_i,
    input  wire                     mret_take_i,
    input  wire                     mem_exc_i,           // MEM_stage: exception not yet redirected

    output logic [1:0]              forward_a_sel_o,
    output logic [1:0]              forward_b_sel_o,

    output logic                    pc_set_o,
    output pc_mux_sel_e             pc_mux_o,
    output exc_pc_mux_e             exc_pc_mux_o,

    output logic                    stall_if_o,
    output logic                    stall_id_o,
    output logic                    stall_ex_o,
    output logic                    stall_mem_o,
    output logic                    stall_wb_o,
    output logic                    flush_if_o,
    output logic                    flush_id_o,
    output logic                    flush_ex_o,
    output logic                    flush_mem_o,
    output logic                    flush_wb_o,

    output logic                    trap_redirect_accepted_o,

    // ID slot must not act this cycle (no trap / irq / mret, latch a plain
    // bubble): either it is on the wrong path behind a taken branch/jump,
    // or it reads a CSR that an older in-flight instruction still writes.
    output logic                    id_kill_o
);

    logic ex_redirect_jump;
    assign ex_redirect_jump = ex_mem_i.is_jump | ex_mem_i.is_jarl;

    // FENCE.I in MEM: once the caches are synchronised (lsu_busy drops) it
    // redirects to pc+4 exactly like a jump, so everything fetched after it
    // (possibly stale) is flushed and refetched from the invalidated I-cache.
    logic ex_redirect;
    assign ex_redirect = ex_redirect_jump | ex_mem_i.fencei;

    always_comb begin : fwd_a
        if (ex_mem_i.reg_write && (ex_mem_i.rd_addr != '0) &&
            (ex_mem_i.rd_addr == id_ex_i.rs1_addr))
            forward_a_sel_o = 2'b01;
        else if (mem_wb_i.reg_write && (mem_wb_i.rd_addr != '0) &&
                 (mem_wb_i.rd_addr == id_ex_i.rs1_addr))
            forward_a_sel_o = 2'b10;
        else
            forward_a_sel_o = 2'b00;
    end

    always_comb begin : fwd_b
        if (ex_mem_i.reg_write && (ex_mem_i.rd_addr != '0) &&
            (ex_mem_i.rd_addr == id_ex_i.rs2_addr))
            forward_b_sel_o = 2'b01;
        else if (mem_wb_i.reg_write && (mem_wb_i.rd_addr != '0) &&
                 (mem_wb_i.rd_addr == id_ex_i.rs2_addr))
            forward_b_sel_o = 2'b10;
        else
            forward_b_sel_o = 2'b00;
    end

    logic load_use_stall;

    always_comb begin : lu_detect
        load_use_stall = 1'b0;
        if (id_ex_i.is_load && (id_ex_i.rd_addr != '0)) begin
            if ((id_ex_i.rd_addr == id_rs1_addr_i) ||
                (id_ex_i.rd_addr == id_rs2_addr_i))
                load_use_stall = 1'b1;
        end
    end

    // CSR read-after-write: CSRs are read in ID but written in WB, so a
    // CSR access (or MRET, which reads mepc) has to wait until no older
    // CSR write is left in EX/MEM/WB. Same bubble mechanism as load-use.
    // Traps and MRETs write CSRs in WB as well (mepc/mcause/mtval/mstatus),
    // so they count as in-flight CSR writes: a handler's first
    // `csrr t0, mcause` must not read the previous cause because the
    // trap it belongs to has not reached WB yet.
    logic csr_raw_stall;
    assign csr_raw_stall = id_csr_read_i &&
                           (id_ex_i.csr_we || ex_mem_i.csr_we || mem_wb_i.csr_we ||
                            id_ex_i.trap   || ex_mem_i.trap   || mem_wb_i.trap   ||
                            id_ex_i.mret   || ex_mem_i.mret   || mem_wb_i.mret);

    // minstret is read in ID but counts in WB: a read must wait until every
    // older instruction has retired, or it misses up to three of them.
    logic cnt_read_stall;
    assign cnt_read_stall = id_cnt_read_i &&
                            (id_ex_i.valid || ex_mem_i.valid || mem_wb_i.valid);

    // Wrong-path kill: when EX/MEM redirects, the instruction in ID is on
    // the wrong path. Before this, trap_take (incl. interrupts) had priority
    // over the redirect, so an IRQ arriving in that cycle saved the
    // wrong-path PC in mepc and the branch/jump was silently lost (and a
    // wrong-path illegal word, e.g. 0x0 padding after a `ret`, trapped).
    //
    // Trap hold: a branch/jump that is in EX right now resolves (and may
    // redirect + flush EX) next cycle. A trap/irq/mret taken in ID this
    // cycle would be flushed out of EX by that redirect, its PC redirect
    // overridden, and trap_in_flight would never clear (irqs masked for
    // good). So ID waits one cycle until the older control flow resolves.
    // Same while a multi-cycle MUL/DIV is busy in EX: trap priority used to
    // beat the ex_busy stall, the trap bubble overwrote id_ex mid-operation
    // and the MUL/DIV result was lost.
    logic ex_ctrl_flow, trap_hold;
    assign ex_ctrl_flow = id_ex_i.is_branch || id_ex_i.is_jump || id_ex_i.jalr || id_ex_i.fencei;
    assign trap_hold    = id_trap_req_i && (ex_ctrl_flow || ex_busy_i);

    logic id_hold;
    assign id_hold = csr_raw_stall || cnt_read_stall || trap_hold;

    assign id_kill_o = !lsu_busy_i &&
                       (mem_exc_i || branch_decision_i || ex_redirect || id_hold);

    always_comb begin : pc_ctrl
        pc_set_o                 = 1'b0;
        pc_mux_o                 = PC_PLUS4;
        exc_pc_mux_o             = EXC_PC_EXCEPTION;
        trap_redirect_accepted_o = 1'b0;

        if (lsu_busy_i) begin
            // Absolute freeze - no redirect allowed; pc_set stays 0
        end else if (mem_exc_i) begin
            // Exception raised in EX/MEM (misaligned jump target, misaligned
            // load/store): it is older than anything in IF/ID/EX, so it wins
            // over an ID trap/mret and over its own branch/jump redirect.
            pc_set_o                 = 1'b1;
            pc_mux_o                 = PC_EXCEPTION;
            exc_pc_mux_o             = EXC_PC_EXCEPTION;
            trap_redirect_accepted_o = 1'b1;
        end else if (trap_take_i) begin
            pc_set_o                 = 1'b1;
            pc_mux_o                 = PC_EXCEPTION;
            exc_pc_mux_o             = EXC_PC_EXCEPTION;
            trap_redirect_accepted_o = 1'b1;
        end else if (mret_take_i) begin
            pc_set_o                 = 1'b1;
            pc_mux_o                 = PC_MRET;
            trap_redirect_accepted_o = 1'b1;
        end else if (branch_decision_i) begin
            pc_set_o = 1'b1;
            pc_mux_o = PC_BRANCH;
        end else if (ex_redirect) begin
            pc_set_o = 1'b1;
            pc_mux_o = PC_JUMP;
        end
    end


    always_comb begin : stall_flush


        stall_if_o  = 1'b0;
        stall_id_o  = 1'b0;
        stall_ex_o  = 1'b0;
        stall_mem_o = 1'b0;
        stall_wb_o  = 1'b0;
        flush_if_o  = 1'b0;
        flush_id_o  = 1'b0;
        flush_ex_o  = 1'b0;
        flush_mem_o = 1'b0;
        flush_wb_o  = 1'b0;


        if (lsu_busy_i) begin
            stall_if_o  = 1'b1;
            stall_id_o  = 1'b1;
            stall_ex_o  = 1'b1;
            stall_mem_o = 1'b1;

        end else if (mem_exc_i) begin
            // squash the younger instructions; the excepting one moves on
            // to WB and commits mepc/mcause there
            flush_if_o = 1'b1;
            flush_id_o = 1'b1;
            flush_ex_o = 1'b1;

        end else if (trap_take_i || mret_take_i) begin
            flush_id_o = 1'b1;

        end else if (branch_decision_i || ex_redirect) begin
            flush_if_o = 1'b1;
            flush_id_o = 1'b1;
            flush_ex_o = 1'b1;

        end else if (if_busy_i) begin
            stall_if_o = 1'b1;
            flush_if_o = 1'b1;

        end else if (ex_busy_i) begin
            stall_if_o = 1'b1;
            stall_id_o = 1'b1;

        end else if (load_use_stall || id_hold) begin
            stall_if_o = 1'b1;
            flush_id_o = 1'b1;

        end
    end

    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (rst_n) begin

            if (lsu_busy_i && branch_decision_i) begin
                $display("HAZARD FATAL @ %0t: lsu_busy AND branch_decision in same cycle",
                         $time);
                $stop;
            end
            if (lsu_busy_i && ex_redirect_jump) begin
                $display("HAZARD FATAL @ %0t: lsu_busy AND ex_redirect_jump in same cycle",
                         $time);
                $stop;
            end

            if (lsu_busy_i && trap_take_i) begin
                $display("HAZARD INFO  @ %0t: lsu_busy suppressed trap redirect - will retry",
                         $time);
            end
            if (lsu_busy_i && mret_take_i) begin
                $display("HAZARD INFO  @ %0t: lsu_busy suppressed mret redirect - will retry",
                         $time);
            end

            if (if_busy_i && (branch_decision_i || ex_redirect_jump)) begin
                $display("HAZARD WARN  @ %0t: if_busy and branch/jump simultaneously - redirect wins",
                         $time);
            end

        end
    end
    // synthesis translate_on

endmodule
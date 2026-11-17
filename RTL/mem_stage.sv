`timescale 1ns / 1ps
`default_nettype none

// core_pkg::ex_mem_bundle_t in, core_pkg::mem_wb_bundle_t out. Owns the
// external obi_data_if.master port (data_bus) and two internal obi_data_if
// instances: lsu_bus to load_store_unit and core_bus to the store buffer.
// Every field except req passes straight from lsu_bus to core_bus; req is
// gated by wait_rvalid_q, which is state this stage owns and load_store_unit
// knows nothing about. The store buffer (store_buffer.sv) sits between
// core_bus and data_bus; FENCE and FENCE.I wait here until it is empty.
module MEM_stage
    import core_pkg::*;
#(
    parameter int DATA_WIDTH    = core_pkg::CORE_DATA_WIDTH,
    parameter int RF_ADDR_WIDTH = core_pkg::CORE_RF_ADDR_WIDTH,
    // store buffer (0 = off) and the ranges whose stores it may buffer
    parameter int          SB_DEPTH     = 16,
    parameter logic [31:0] SB_BUF0_BASE = 32'h8000_0000,
    parameter logic [31:0] SB_BUF0_SIZE = 32'h0001_0000,
    parameter logic [31:0] SB_BUF1_BASE = 32'h0000_0000,
    parameter logic [31:0] SB_BUF1_SIZE = 32'h0000_0000
)(
    input  wire clk,
    input  wire rst_n,

    input  wire stall_i,

    input  ex_mem_bundle_t   ex_mem_i,

    // OBI data-memory master port
    obi_data_if.master        data_bus,

    output logic              lsu_busy_o,

    output logic [DATA_WIDTH-1:0] mem_forward_data_o,

    // exception that still needs its PC redirect: misaligned load/store
    // (detected here) or a trap raised in EX. ID-raised traps were already
    // redirected when they were taken, so they are excluded.
    output logic              mem_exc_o,

    // FENCE.I cache maintenance: held while FENCE.I sits in MEM; the
    // caches answer with a one-cycle done after the D-cache write-back
    output logic              fencei_req_o,
    input  wire               fencei_done_i,

    // the next MEM instruction's address (still in EX) and "EX/MEM loads
    // this cycle": the store buffer matches it against its entries early
    input  wire [DATA_WIDTH-1:0] ex_addr_i,
    input  wire               ex_adv_i,

    output mem_wb_bundle_t    mem_wb_o
);

    logic data_req_ex_w;
    assign data_req_ex_w = ex_mem_i.is_load | ex_mem_i.is_store;

    logic [DATA_WIDTH-1:0] lsu_rdata_w;
    logic                  lsu_trap_raw_w;      // incoming trap or misaligned (from the LSU)
    logic [5:0]            lsu_trap_cause_raw_w;
    logic                  lsu_trap_w;          // + bus error on this instruction's access
    logic [5:0]            lsu_trap_cause_w;

    // Internal hops: this stage <-> load_store_unit, this stage <-> store buffer
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) lsu_bus();
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) core_bus();

    logic sb_empty, sb_err;

    store_buffer #(
        .DEPTH     (SB_DEPTH),
        .BUF0_BASE (SB_BUF0_BASE),
        .BUF0_SIZE (SB_BUF0_SIZE),
        .BUF1_BASE (SB_BUF1_BASE),
        .BUF1_SIZE (SB_BUF1_SIZE)
    ) sb_inst (
        .clk     (clk),
        .rst_n   (rst_n),
        .core    (core_bus),
        .mem     (data_bus),
        .ex_addr_i (ex_addr_i),
        .ex_adv_i  (ex_adv_i),
        .empty_o (sb_empty),
        .err_o   (sb_err)
    );

    // Avoid delta-cycle issues on Xsim
    logic [31:0]          ex_mem_alu_res;
    assign ex_mem_alu_res = ex_mem_i.alu_res;

    logic [RF_ADDR_WIDTH-1:0] ex_mem_rd_addr_safe;
    assign ex_mem_rd_addr_safe = ex_mem_i.rd_addr;

    logic ex_mem_rf_we;
    assign ex_mem_rf_we = ex_mem_i.reg_write & ~lsu_trap_w;


    logic wait_rvalid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_rvalid_q <= 1'b0;
        end else if (ex_mem_i.is_load) begin
            wait_rvalid_q <= (wait_rvalid_q | (lsu_bus.req & core_bus.gnt)) & ~core_bus.rvalid;
        end else begin
            wait_rvalid_q <= 1'b0;
        end
    end

    // Bus access faults are taken one cycle late, from a register (timing: a
    // gnt/err must not reach the trap / PC redirect logic in the same cycle).
    // In the cycle the faulting response comes, the instruction is held in
    // MEM (lsu_busy); the next cycle it leaves with the trap, from fault_q.
    // The access is not issued again meanwhile. Still precise: same cause,
    // same mtval, nothing younger has retired.
    logic fault_q;
    logic bus_resp_w, bus_fault_w;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          fault_q <= 1'b0;
        else if (!stall_i)   fault_q <= 1'b0;          // the instruction left MEM
        else if (bus_fault_w) fault_q <= 1'b1;
    end

    // req alone is gated; addr/we/be/wdata pass straight through
    assign core_bus.req   = lsu_bus.req & ~wait_rvalid_q & ~fault_q;
    assign core_bus.addr  = lsu_bus.addr;
    assign core_bus.we    = lsu_bus.we;
    assign core_bus.be    = lsu_bus.be;
    assign core_bus.wdata = lsu_bus.wdata;

    assign lsu_bus.gnt    = core_bus.gnt;
    assign lsu_bus.rvalid = core_bus.rvalid;
    assign lsu_bus.rdata  = core_bus.rdata;
    assign lsu_bus.err    = core_bus.err;

    // Access fault: err on the response that belongs to this instruction's
    // own access -- gnt+rvalid in the same cycle (D-cache, error responder;
    // the only slaves that can fail, so stores see it at gnt), or the
    // rvalid a load is waiting for.
    assign bus_resp_w  = (lsu_bus.req & ~wait_rvalid_q & ~fault_q & core_bus.gnt & core_bus.rvalid) |
                         (wait_rvalid_q & core_bus.rvalid);
    assign bus_fault_w = bus_resp_w & core_bus.err;

    assign lsu_trap_w       = lsu_trap_raw_w | fault_q;
    assign lsu_trap_cause_w = lsu_trap_raw_w     ? lsu_trap_cause_raw_w :
                              ex_mem_i.is_store  ? TRAP_CAUSE_STORE_ACCESS_FAULT
                                                 : TRAP_CAUSE_LOAD_ACCESS_FAULT;

    // -----------------------------------------------------------------------
    assign lsu_busy_o = (lsu_bus.req & ~wait_rvalid_q & ~fault_q & (~core_bus.gnt | (ex_mem_i.is_load & ~core_bus.rvalid)))
                      | (wait_rvalid_q & ~core_bus.rvalid)
                      | bus_fault_w                           // hold one cycle: trap from fault_q next cycle
                      | (ex_mem_i.fencei & ~fencei_done_i)    // FENCE.I: drain, then wait for the caches
                      | (ex_mem_i.fence  & ~sb_empty);        // FENCE: wait until every buffered store is done

    // the caches start FENCE.I maintenance only once the store buffer is empty
    assign fencei_req_o = ex_mem_i.fencei & sb_empty;

    load_store_unit lsu_inst (
        .data_bus         (lsu_bus),

        .ex_mem_i         (ex_mem_i),

        .data_rdata_ex_o  (lsu_rdata_w),
        .data_req_ex_i    (data_req_ex_w),

        .lsu_trap_o       (lsu_trap_raw_w),
        .lsu_trap_cause_o (lsu_trap_cause_raw_w)
    );

    assign mem_exc_o = ex_mem_i.trap ? ex_mem_i.trap_late : lsu_trap_w;

    always_comb begin : fwd_mux
        mem_forward_data_o = ex_mem_i.is_load ? lsu_rdata_w : ex_mem_alu_res;
    end

    always_ff @(posedge clk or negedge rst_n) begin : mem_wb_reg
        if (!rst_n) begin
            mem_wb_o          <= '0;
        end else if (!stall_i) begin
            mem_wb_o.alu_res    <= ex_mem_alu_res;
            mem_wb_o.rdata      <= lsu_rdata_w;
            mem_wb_o.rd_addr    <= ex_mem_rd_addr_safe;
            mem_wb_o.wb_ctrl    <= ex_mem_i.wb_ctrl;
            mem_wb_o.pc_plus4   <= ex_mem_i.pc_plus4;
            mem_wb_o.pc         <= ex_mem_i.pc;
            mem_wb_o.is_load    <= ex_mem_i.is_load;
            mem_wb_o.is_jump    <= ex_mem_i.is_jump;
            mem_wb_o.is_jarl    <= ex_mem_i.is_jarl;
            mem_wb_o.reg_write  <= ex_mem_rf_we;
            mem_wb_o.trap       <= lsu_trap_w;
            mem_wb_o.trap_cause <= lsu_trap_cause_w;
            mem_wb_o.tval       <= ex_mem_i.trap ? ex_mem_i.tval :
                                   lsu_trap_w    ? ex_mem_alu_res : '0;   // misaligned / faulting address
            mem_wb_o.csr_addr   <= ex_mem_i.csr_addr;
            mem_wb_o.csr_op     <= ex_mem_i.csr_op;
            mem_wb_o.csr_wdata  <= ex_mem_i.csr_wdata;
            mem_wb_o.csr_access <= ex_mem_i.csr_access;
            mem_wb_o.csr_we     <= ex_mem_i.csr_we;
            mem_wb_o.mret       <= ex_mem_i.mret;
            mem_wb_o.priv_mode  <= ex_mem_i.priv_mode;
            mem_wb_o.valid      <= ex_mem_i.valid && !lsu_trap_w;
        end else begin
            // MEM stalled: WB keeps showing the previous instruction, which
            // already retired on its first cycle -- don't count it again.
            mem_wb_o.valid      <= 1'b0;
        end
    end

endmodule
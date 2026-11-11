`timescale 1ns / 1ps
`default_nettype none

// Takes core_pkg::ex_mem_bundle_t in, produces core_pkg::mem_wb_bundle_t
// out. Owns an external obi_data_if.master port (data_bus) plus a second,
// internal-only obi_data_if instance (lsu_bus) that connects to
// load_store_unit -- every field except req passes straight from lsu_bus
// to data_bus; req alone is gated by wait_rvalid_q, which is state this
// stage owns and load_store_unit has no notion of. This mirrors exactly
// the "lsu_raw_req -> data_req_o" split the pre-interface version of this
// module already had; it's now expressed as two interface instances
// instead of a bundle of loose wires.
module MEM_stage
    import core_pkg::*;
#(
    parameter int DATA_WIDTH    = core_pkg::CORE_DATA_WIDTH,
    parameter int RF_ADDR_WIDTH = core_pkg::CORE_RF_ADDR_WIDTH
)(
    input  wire clk,
    input  wire rst_n,

    input  wire stall_i,
    input  wire flush_i,

    input  ex_mem_bundle_t   ex_mem_i,

    // OBI data-memory master port
    obi_data_if.master        data_bus,

    output logic              lsu_busy_o,
    output logic              lsu_ready_ex_o,
    output logic              lsu_ready_commit_o,

    output logic [DATA_WIDTH-1:0] mem_forward_data_o,

    // exception that still needs its PC redirect: misaligned load/store
    // (detected here) or a trap raised in EX. ID-raised traps were already
    // redirected when they were taken, so they are excluded.
    output logic              mem_exc_o,

    // FENCE.I cache maintenance: held while FENCE.I sits in MEM; the
    // caches answer with a one-cycle done after the D-cache write-back
    output logic              fencei_req_o,
    input  wire               fencei_done_i,

    output mem_wb_bundle_t    mem_wb_o,
    output logic [DATA_WIDTH-1:0] mem_jump_target_o
);

    logic data_req_ex_w;
    assign data_req_ex_w = ex_mem_i.is_load | ex_mem_i.is_store;

    logic [DATA_WIDTH-1:0] lsu_rdata_w;
    logic                  lsu_trap_raw_w;      // incoming trap or misaligned (from the LSU)
    logic [5:0]            lsu_trap_cause_raw_w;
    logic                  lsu_trap_w;          // + bus error on this instruction's access
    logic [5:0]            lsu_trap_cause_w;
    logic                  lsu_raw_busy;

    // Internal hop between this stage and load_store_unit -- see header.
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) lsu_bus();

    // Avoid delta-cycle issues on Xsim
    logic [31:0]          ex_mem_alu_res;
    assign ex_mem_alu_res = ex_mem_i.alu_res;

    logic [RF_ADDR_WIDTH-1:0] ex_mem_rd_addr_safe;
    assign ex_mem_rd_addr_safe = ex_mem_i.rd_addr;

    logic ex_mem_rf_we;
    assign ex_mem_rf_we = ex_mem_i.reg_write & ~lsu_trap_w;


    logic wait_rvalid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_i) begin
            wait_rvalid_q <= 1'b0;
        end else if (ex_mem_i.is_load) begin
            wait_rvalid_q <= (wait_rvalid_q | (lsu_bus.req & data_bus.gnt)) & ~data_bus.rvalid;
        end else begin
            wait_rvalid_q <= 1'b0;
        end
    end

    // req alone is gated; addr/we/be/wdata pass straight through
    assign data_bus.req   = lsu_bus.req & ~wait_rvalid_q;
    assign data_bus.addr  = lsu_bus.addr;
    assign data_bus.we    = lsu_bus.we;
    assign data_bus.be    = lsu_bus.be;
    assign data_bus.wdata = lsu_bus.wdata;

    assign lsu_bus.gnt    = data_bus.gnt;
    assign lsu_bus.rvalid = data_bus.rvalid;
    assign lsu_bus.rdata  = data_bus.rdata;
    assign lsu_bus.err    = data_bus.err;

    // Access fault: err on the response that belongs to this instruction's
    // own access -- gnt+rvalid in the same cycle (D-cache, error responder;
    // the only slaves that can fail, so stores see it at gnt), or the
    // rvalid a load is waiting for.
    logic bus_resp_w, bus_fault_w;
    assign bus_resp_w  = (lsu_bus.req & ~wait_rvalid_q & data_bus.gnt & data_bus.rvalid) |
                         (wait_rvalid_q & data_bus.rvalid);
    assign bus_fault_w = bus_resp_w & data_bus.err;

    assign lsu_trap_w       = lsu_trap_raw_w | bus_fault_w;
    assign lsu_trap_cause_w = lsu_trap_raw_w     ? lsu_trap_cause_raw_w :
                              ex_mem_i.is_store  ? TRAP_CAUSE_STORE_ACCESS_FAULT
                                                 : TRAP_CAUSE_LOAD_ACCESS_FAULT;

    // -----------------------------------------------------------------------
    assign lsu_busy_o = (lsu_bus.req & ~wait_rvalid_q & (~data_bus.gnt | (ex_mem_i.is_load & ~data_bus.rvalid)))
                      | (wait_rvalid_q & ~data_bus.rvalid)
                      | (ex_mem_i.fencei & ~fencei_done_i);   // FENCE.I: wait for the caches

    assign fencei_req_o = ex_mem_i.fencei;

    load_store_unit lsu_inst (
        .clk              (clk),
        .rst_n            (rst_n),

        .data_bus         (lsu_bus),

        .ex_mem_i         (ex_mem_i),

        .data_rdata_ex_o  (lsu_rdata_w),
        .data_req_ex_i    (data_req_ex_w),

        .lsu_trap_o       (lsu_trap_raw_w),
        .lsu_trap_cause_o (lsu_trap_cause_raw_w),

        .lsu_ready_ex_o     (lsu_ready_ex_o),
        .lsu_ready_commit_o (lsu_ready_commit_o),
        .lsu_busy_o         (lsu_raw_busy)
    );

    assign mem_exc_o = ex_mem_i.trap ? ex_mem_i.trap_late : lsu_trap_w;

    always_comb begin : fwd_mux
        mem_forward_data_o = ex_mem_i.is_load ? lsu_rdata_w : ex_mem_alu_res;
    end

    always_ff @(posedge clk or negedge rst_n) begin : mem_wb_reg
        if (!rst_n || flush_i) begin
            mem_wb_o          <= '0;
            mem_jump_target_o <= '0;
        end else if (!stall_i) begin
            mem_jump_target_o   <= ex_mem_i.branch_target;
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
`timescale 1ns / 1ps
`default_nettype none
//top module for core it is designed to be able to work without system dependency
// there is rst clk output ports they are routed from here because core need to function by itself
// ROUTE THE OTHER CLK AND RESET SIGNAL OUTSIDE OF THIS MODULE IF YOU DONT WHAT TO MESS WITH CDC
//
// CONVERSION NOTES (core_pkg / interface adoption):
//   - instr_en_o/instr_addr_o/instr_gnt_i/instr_rvalid_i/instr_rdata_i and
//     data_req_o/data_gnt_i/.../data_rdata_i are GONE from the port list --
//     replaced by two real interface ports, obi_instr_if.master and
//     obi_data_if.master. The instantiator (cache_system_top) now owns the
//     interface instances and connects them to icache/dcache directly.
//     For the 1:1 instruction path that's literally zero glue: one
//     obi_instr_if instance shared between Core_Top's master port and
//     icache's slave port. For the arbitrated data path (dcache vs PLIC)
//     see obi_macros.svh + cache_system_top.sv -- a runtime slave choice
//     cannot be expressed as an interface-array index (array element
//     selection has to be elaboration-time), so that fan-out is explicit
//     per-field muxing, done through the OBI_DATA_* macros.
//   - id_ex_pc/id_ex_rs1_data/... (~26 wires), ex_mem_alu_res/... (~24
//     wires) and mem_wb_alu_res/... (~18 wires) collapse into three
//     bundle-typed wires: id_ex_bus, ex_mem_bus, mem_wb_bus. hazard_unit
//     now takes the id_ex/ex_mem/mem_wb bundles directly instead of ~15
//     individually named ports per boundary.

module Core_Top
    import core_pkg::*;
#(
    parameter int DATA_WIDTH    = core_pkg::CORE_DATA_WIDTH,
    parameter int RF_ADDR_WIDTH = core_pkg::CORE_RF_ADDR_WIDTH
)(
    input  wire clk_in,
    input  wire ext_rst_n,
    output logic clk_o,
    output logic rst_o,

    input  wire [DATA_WIDTH-1:0] boot_addr_i,

    input  wire external_irq_i,
    input  wire timer_irq_i,
    input  wire soft_irq_i,            // CLINT msip
    input  wire [63:0] mtime_i,        // CLINT mtime (time/timeh CSRs)

    // OBI instruction-memory master port (was instr_en_o/instr_addr_o/
    // instr_gnt_i/instr_rvalid_i/instr_rdata_i)
    obi_instr_if.master instr_bus,

    // OBI data-memory master port (was data_req_o/data_gnt_i/
    // data_rvalid_i/data_addr_o/data_we_o/data_strb_o/data_wdata_o/
    // data_rdata_i)
    obi_data_if.master  data_bus,

    // FENCE.I cache maintenance (Zifencei): fencei_req_o is held while a
    // FENCE.I is in MEM; the cache system writes back the D-cache,
    // invalidates the I-cache and pulses fencei_done_i for one cycle.
    output logic fencei_req_o,
    input  wire  fencei_done_i,

    output logic csr_mie_reg_o
);
   // simple clk_wiz instantation for generating reset and clk signals
    logic locked, clk;

    `ifdef VERILATOR
    // When compiling inside Verilator, bypass Xilinx PLL primitives completely

    assign clk = clk_in;
    assign locked = 1'b1;
`else
    // Your original Vivado IP block remains untouched for your FPGA build
    clk_wiz_0 clkwiz0 (
        .clk_out1 (clk),
        .reset    (~ext_rst_n),
        .locked   (locked),
        .clk_in1  (clk_in)
    );
`endif



    assign clk_o = clk;
    logic rst_n;
    assign rst_n = ext_rst_n & locked;
    assign rst_o = rst_n;

    //internal wires for routing hazards and mux selections
    logic stall_if, stall_id, stall_ex, flush_if, flush_id, flush_ex;
    logic stall_mem, flush_mem;
    logic wb_stall, wb_flush;
    logic [1:0] forward_a_sel, forward_b_sel;
    logic if_busy;
    logic trap_redirect_accepted;

    //pc control wires jump target mem is not used jumps solved on the ex stage
    pc_mux_sel_e            pc_mux;
    exc_pc_mux_e            exc_pc_mux;
    logic                  pc_set;
    logic [DATA_WIDTH-1:0] jump_target_ex;
    logic [DATA_WIDTH-1:0] jump_target_mem;
    logic                  trap_take;
    logic [DATA_WIDTH-1:0] trap_target_pc;
    logic                  mret_take;
    logic [DATA_WIDTH-1:0] mret_target_pc;
    logic                  branch_decision;

    assign jump_target_ex = ex_mem_bus.branch_target;

    // commiting logic for csr it is not tested
    logic                  wb_commit_trap;
    logic [5:0]            wb_commit_trap_cause;
    logic [DATA_WIDTH-1:0] wb_commit_trap_tval;
    logic [11:0]           wb_commit_csr_addr;
    csr_op_e               wb_commit_csr_op;
    logic [DATA_WIDTH-1:0] wb_commit_csr_wdata;
    logic                  wb_commit_csr_access;
    logic                  wb_commit_csr_we;
    logic                  wb_commit_mret;
    logic                  wb_commit_retire;
    logic [DATA_WIDTH-1:0] csr_mcounteren, csr_scounteren;  // for future U/S counter gating
    //csr wires

    // THERE IS NOT A MIE ADDER ALLIGN IT WITH 256 on your codes otherwise it will not work
    logic [DATA_WIDTH-1:0] csr_mtvec;
    logic [DATA_WIDTH-1:0] csr_mepc;
    logic                  csr_mstatus_mie;
    logic [DATA_WIDTH-1:0] csr_mie_reg;
    logic [23:0]           m_trap_base_addr;
    logic [DATA_WIDTH-1:0] csr_rdata_id;

    // user mode / debug stubs
    logic [23:0]           u_trap_base_addr;
    trap_addr_mux_e         trap_addr_mux;
    logic [4:0]             m_exc_vec_pc_mux;
    logic [4:0]             u_exc_vec_pc_mux;
    logic [DATA_WIDTH-1:0]  uepc;
    logic [DATA_WIDTH-1:0]  dm_exception_addr;

    assign u_trap_base_addr  = 24'h000000;
    assign trap_addr_mux     = TRAP_M;
    assign m_exc_vec_pc_mux  = 5'd0;
    assign u_exc_vec_pc_mux  = 5'd0;
    assign uepc              = '0;
    assign dm_exception_addr = '0;

    //  trap_in_flight register
    //  prevents a long-held IRQ from re-firing during the ~4-cycle pipeline
    //  drain between trap detection id and MIE commit wb.
    //  rationale: the only cycle where both could be asserted is when a
    //  this loses at most one clock not correctness.
    logic trap_in_flight;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            trap_in_flight <= 1'b0;
        else if (wb_commit_trap || wb_commit_mret)
            trap_in_flight <= 1'b0;                   //  commit wins
        else if (trap_redirect_accepted)
            trap_in_flight <= 1'b1;                   // only when clear
    end

    // actual mie  global enable && no trap already in flight
    logic csr_mie_effective;
    assign csr_mie_effective = csr_mstatus_mie && !trap_in_flight;

    //  IF/ID pipeline wires
    logic [DATA_WIDTH-1:0] if_id_instr;
    logic [DATA_WIDTH-1:0] if_id_pc;
    logic                  if_id_valid;
    logic                  if_id_err;
    logic [DATA_WIDTH-1:0] pc_if;
    logic                  csr_mtvec_init;

    logic id_is_branch_w, id_is_jump_w, id_jalr_w;
    assign id_is_branch_w = (if_id_instr[6:0] == 7'b110_0011);
    assign id_is_jump_w   = (if_id_instr[6:0] == 7'b110_1111) ||
                            (if_id_instr[6:0] == 7'b110_0111);
    assign id_jalr_w      = (if_id_instr[6:0] == 7'b110_0111);

    // CSR access (SYSTEM, funct3 != 0) or MRET in ID -> CSR RAW check
    logic id_csr_read_w, id_kill, id_trap_req;
    assign id_csr_read_w = (if_id_instr[6:0] == 7'b111_0011) &&
                           ((if_id_instr[14:12] != 3'b000) || (if_id_instr == 32'h3020_0073));

    // CSR access to minstret/minstreth/instret/instreth (precise read)
    logic id_cnt_read_w;
    assign id_cnt_read_w = (if_id_instr[6:0] == 7'b111_0011) && (if_id_instr[13:12] != 2'b00) &&
                           (if_id_instr[31:20] inside {CSR_ADDR_MINSTRET, CSR_ADDR_MINSTRETH,
                                                       CSR_ADDR_INSTRET,  CSR_ADDR_INSTRETH});
    logic mem_exc;

    // pipeline-register bundles: these replace the ~26/~24/~18 individually
    // named id_ex_*/ex_mem_*/mem_wb_* wires the pre-conversion Core_Top had.
    id_ex_bundle_t  id_ex_bus;
    ex_mem_bundle_t ex_mem_bus;
    mem_wb_bundle_t mem_wb_bus;

    // instr_bus / data_bus are now real module ports (see header) --
    // IF_stage / MEM_stage connect to them directly, no local instance or
    // glue assigns needed inside this module anymore.

    //  csr
    csr_file #(
        .DATA_WIDTH (DATA_WIDTH)
    ) csr_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        .csr_raddr_i        (if_id_instr[31:20]),
        .csr_rdata_o        (csr_rdata_id),
        .csr_we_i           (wb_commit_csr_we),
        .csr_waddr_i        (wb_commit_csr_addr),
        .csr_op_i           (wb_commit_csr_op),
        .csr_wdata_i        (wb_commit_csr_wdata),
        .trap_i             (wb_commit_trap),
        .trap_cause_i       (wb_commit_trap_cause),
        .trap_tval_i        (wb_commit_trap_tval),
        .trap_pc_i          (mem_wb_bus.pc),
        .mret_i             (wb_commit_mret),
        .instr_retire_i     (wb_commit_retire),
        .mtime_i            (mtime_i),
        .external_irq_i     (external_irq_i),
        .timer_irq_i        (timer_irq_i),
        .soft_irq_i         (soft_irq_i),
        .mtvec_o            (csr_mtvec),
        .mepc_o             (csr_mepc),
        .mstatus_mie_o      (csr_mstatus_mie),
        .mie_o              (csr_mie_reg),
        .m_trap_base_addr_o (m_trap_base_addr),
        .mcounteren_o       (csr_mcounteren),
        .scounteren_o       (csr_scounteren)
    );
    assign csr_mie_reg_o = csr_mstatus_mie;

    logic ex_busy, lsu_busy, lsu_ready_ex, lsu_ready_commit;
    logic [DATA_WIDTH-1:0] mem_forward_data, wb_forward_data;

    //hazard unit
    hazard_unit #(.RF_ADDR_WIDTH(RF_ADDR_WIDTH)) haz_inst (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .id_rs1_addr_i            (if_id_instr[19:15]),
        .id_rs2_addr_i            (if_id_instr[24:20]),
        .id_is_branch_i           (id_is_branch_w),
        .id_jalr_i                (id_jalr_w),
        .id_csr_read_i            (id_csr_read_w),
        .id_cnt_read_i            (id_cnt_read_w),
        .id_trap_req_i            (id_trap_req),
        .id_ex_i                  (id_ex_bus),
        .ex_mem_i                 (ex_mem_bus),
        .mem_wb_i                 (mem_wb_bus),
        .branch_decision_i        (branch_decision),
        .ex_busy_i                (ex_busy),
        .lsu_busy_i               (lsu_busy),
        .if_busy_i                (if_busy),
        .trap_take_i              (trap_take),
        .mret_take_i              (mret_take),
        .mem_exc_i                (mem_exc),
        .forward_a_sel_o          (forward_a_sel),
        .forward_b_sel_o          (forward_b_sel),
        .pc_set_o                 (pc_set),
        .pc_mux_o                 (pc_mux),
        .exc_pc_mux_o             (exc_pc_mux),
        .stall_if_o               (stall_if),
        .stall_id_o               (stall_id),
        .stall_ex_o               (stall_ex),
        .stall_mem_o              (stall_mem),
        .stall_wb_o               (wb_stall),
        .flush_if_o               (flush_if),
        .flush_id_o               (flush_id),
        .flush_ex_o               (flush_ex),
        .flush_mem_o              (flush_mem),
        .flush_wb_o               (wb_flush),
        .trap_redirect_accepted_o (trap_redirect_accepted),
        .id_kill_o                (id_kill)
    );

    //  IF
    IF_stage #(
        .DATA_WIDTH (DATA_WIDTH)
    ) if_stage_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        .boot_addr_i        (boot_addr_i),
        .dm_exception_addr_i(dm_exception_addr),
        .m_trap_base_addr_i (m_trap_base_addr),
        .u_trap_base_addr_i (u_trap_base_addr),
        .trap_addr_mux_i    (trap_addr_mux),
        .m_exc_vec_pc_mux_i (m_exc_vec_pc_mux),
        .u_exc_vec_pc_mux_i (u_exc_vec_pc_mux),
        .mepc_i             (csr_mepc),
        .uepc_i             (uepc),
        .pc_mux_i           (pc_mux),
        .exc_pc_mux_i       (exc_pc_mux),
        .pc_set_i           (pc_set),
        .jump_target_mem_i  (jump_target_mem),
        .jump_target_ex_i   (jump_target_ex),
        .instr_bus          (instr_bus),
        .stall_i            (stall_if),
        .flush_i            (flush_if),
        .if_busy_o          (if_busy),
        .csr_mtvec_init_o   (csr_mtvec_init),
        .instr_rdata_id_o   (if_id_instr),
        .instr_valid_id_o   (if_id_valid),
        .instr_err_id_o     (if_id_err),
        .pc_if_o            (pc_if),
        .pc_id_o            (if_id_pc)
    );

    logic                     wb_rf_wen;
    logic [RF_ADDR_WIDTH-1:0] wb_rf_waddr;
    logic [DATA_WIDTH-1:0]    wb_rf_wdata;

     //  ID
    ID_stage #(
        .DATA_WIDTH       (DATA_WIDTH),
        .RF_ADDR_WIDTH    (RF_ADDR_WIDTH),
        .INSTR_TYPE_WIDTH (3)
    ) id_stage_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        .stall_i            (stall_id),
        .flush_i            (flush_id),
        .kill_i             (id_kill),
        .if_id_instr_i      (if_id_instr),
        .if_id_pc_i         (if_id_pc),
        .if_id_valid_i      (if_id_valid),
        .if_id_err_i        (if_id_err),
        .wb_id_rf_wen_i     (wb_rf_wen),
        .wb_id_rf_waddr_i   (wb_rf_waddr),
        .wb_id_rf_wdata_i   (wb_rf_wdata),
        .external_irq_i     (external_irq_i),
        .timer_irq_i        (timer_irq_i),
        .soft_irq_i         (soft_irq_i),
        // CSR inputs
        .csr_rdata_i        (csr_rdata_id),
        .csr_mtvec_i        (csr_mtvec),
        .csr_mepc_i         (csr_mepc),
        .csr_mie_i          (csr_mie_effective),   // mstatus.MIE && !trap_in_flight
        .csr_mie_regs_i     (csr_mie_reg),         // full mie register for per-source bits
        // Trap / MRET outputs
        .trap_req_o         (id_trap_req),
        .trap_take_o        (trap_take),
        .trap_target_pc_o   (trap_target_pc),
        .mret_take_o        (mret_take),
        .mret_target_pc_o   (mret_target_pc),
        // ID/EX pipeline bundle out
        .id_ex_o            (id_ex_bus)
    );

    logic [DATA_WIDTH-1:0] ex_combinational_res;

    //  EX (why did she choose a misunderstanding over me)
    EX_stage #(
        .DATA_WIDTH     (DATA_WIDTH),
        .REG_ADDR_WIDTH (RF_ADDR_WIDTH)
    ) ex_stage_inst (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .stall_i                (stall_ex),
        .flush_i                (flush_ex),
        .ex_busy_o              (ex_busy),
        .forward_a_sel_i        (forward_a_sel),
        .forward_b_sel_i        (forward_b_sel),
        .mem_forward_data_i     (mem_forward_data),
        .wb_forward_data_i      (wb_forward_data),
        .id_ex_i                (id_ex_bus),
        .ex_combinational_res_o (ex_combinational_res),
        .ex_mem_o               (ex_mem_bus),
        .ex_branch_decision_o   (branch_decision)
    );

    //  MEM
    MEM_stage #(
        .DATA_WIDTH    (DATA_WIDTH),
        .RF_ADDR_WIDTH (RF_ADDR_WIDTH)
    ) mem_stage_inst (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .stall_i                (stall_mem),
        .flush_i                (flush_mem),
        .ex_mem_i               (ex_mem_bus),
        .data_bus               (data_bus),
        .lsu_busy_o             (lsu_busy),
        .lsu_ready_ex_o         (lsu_ready_ex),
        .lsu_ready_commit_o     (lsu_ready_commit),
        .mem_forward_data_o     (mem_forward_data),
        .mem_exc_o              (mem_exc),
        .fencei_req_o           (fencei_req_o),
        .fencei_done_i          (fencei_done_i),
        .mem_wb_o               (mem_wb_bus),
        .mem_jump_target_o      (jump_target_mem)
    );

    //  WB
    WB_stage #(
        .DATA_WIDTH    (DATA_WIDTH),
        .RF_ADDR_WIDTH (RF_ADDR_WIDTH)
    ) wb_stage_inst (
        .clk                 (clk),
        .flush_i             (wb_flush),
        .stall_i             (wb_stall),
        .mem_wb_i            (mem_wb_bus),
        .wb_rf_wen_o         (wb_rf_wen),
        .wb_rf_waddr_o       (wb_rf_waddr),
        .wb_rf_wdata_o       (wb_rf_wdata),
        .wb_forward_data_o   (wb_forward_data),
        .wb_trap_o           (wb_commit_trap),
        .wb_trap_cause_o     (wb_commit_trap_cause),
        .wb_trap_tval_o      (wb_commit_trap_tval),
        .wb_csr_addr_o       (wb_commit_csr_addr),
        .wb_csr_op_o         (wb_commit_csr_op),
        .wb_csr_wdata_o      (wb_commit_csr_wdata),
        .wb_csr_access_o     (wb_commit_csr_access),
        .wb_csr_we_o         (wb_commit_csr_we),
        .wb_mret_o           (wb_commit_mret),
        .wb_retire_o         (wb_commit_retire)
    );



    // just a debugging block it doesnt have anything to do with rtl
    //  execution tracer
    // synthesis translate_off
`ifndef WASP_NO_TRACE   // define it for long simulations (sim/Makefile "fast")
    integer trace_fd;
    initial begin
        trace_fd = $fopen("cpu_trace.log", "w");
        if (trace_fd == 0) $display("ERROR: Could not open trace file!");
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            // wb_commit_retire: while MEM stalls, WB keeps re-asserting the
            // same register write (to keep forwarding alive) -- log it once
            if (wb_rf_wen && wb_rf_waddr != 0 && wb_commit_retire)
                $fdisplay(trace_fd, "[COMMIT] PC:%h x%0d<-%h",
                          mem_wb_bus.pc, wb_rf_waddr, wb_rf_wdata);
            if (data_bus.req && data_bus.gnt && data_bus.we)
                $fdisplay(trace_fd, "[STORE]  PC:%h addr:%h data:%h strb:%b",
                          ex_mem_bus.pc, data_bus.addr, data_bus.wdata, data_bus.be);
            if (data_bus.req && data_bus.gnt && !data_bus.we)
                $fdisplay(trace_fd, "[LOAD]   PC:%h addr:%h", ex_mem_bus.pc, data_bus.addr);
            if (data_bus.rvalid)
                $fdisplay(trace_fd, "  -> [RAM_RX] %h", data_bus.rdata);
            if ((id_ex_bus.is_branch || id_ex_bus.is_jump || id_ex_bus.jalr) && !stall_ex && !flush_ex) begin
                if (branch_decision || id_ex_bus.is_jump || id_ex_bus.jalr)
                    $fdisplay(trace_fd, "[JUMP]   PC:%h TAKEN target:%h",
                              id_ex_bus.pc, ex_mem_bus.branch_target);
                else
                    $fdisplay(trace_fd, "[BRANCH] PC:%h NOT TAKEN", id_ex_bus.pc);
            end
            if (if_busy)
                $fdisplay(trace_fd, "[ICACHE_STALL] PC:%h", pc_if);
            if (trap_in_flight && (external_irq_i || timer_irq_i) && !csr_mie_effective)
                $fdisplay(trace_fd, "[IRQ_HELD] trap_in_flight=1, IRQ masked until WB commit");
        end
    end

    final begin
        $fclose(trace_fd);
    end
`endif
    // synthesis translate_on

endmodule
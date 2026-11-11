`timescale 1ns / 1ps
`default_nettype none

//  ID_stage
//
// Outputs a single core_pkg::id_ex_bundle_t instead of the ~25 individual
// id_ex_*_o ports this module used to have -- the bundle is a field-for-
// field match to what those ports used to be (see core_pkg.sv), so this is
// a mechanical port-list collapse, not a behavior change. Trap causes use
// the named core_pkg constants instead of raw 6-bit literals.

module ID_stage
    import core_pkg::*;
#(
    parameter int DATA_WIDTH = core_pkg::CORE_DATA_WIDTH,
    parameter int RF_ADDR_WIDTH = core_pkg::CORE_RF_ADDR_WIDTH,
    parameter int INSTR_TYPE_WIDTH = 3
)(
    input wire clk,
    input wire rst_n,

    input wire stall_i,
    input wire flush_i,
    input wire kill_i,      // hazard_unit id_kill: no trap/irq/mret from this slot, latch bubble

    input wire [DATA_WIDTH-1:0] if_id_instr_i,
    input wire [DATA_WIDTH-1:0] if_id_pc_i,
    input wire                  if_id_valid_i,      // 0 = IF bubble (NOP)
    input wire                  if_id_err_i,        // fetch refused by the I-cache (access fault)

    input wire                     wb_id_rf_wen_i,
    input wire [RF_ADDR_WIDTH-1:0] wb_id_rf_waddr_i,
    input wire [DATA_WIDTH-1:0]    wb_id_rf_wdata_i,

    input  wire                   external_irq_i,
    input  wire                   timer_irq_i,
    input  wire                   soft_irq_i,       // CLINT msip

    input  wire [DATA_WIDTH-1:0]  csr_rdata_i,
    input  wire [DATA_WIDTH-1:0]  csr_mtvec_i,
    input  wire [DATA_WIDTH-1:0]  csr_mepc_i,
    input  wire                   csr_mie_i,
    input  wire [DATA_WIDTH-1:0]  csr_mie_regs_i,

    output logic                  trap_req_o,       // ID wants to trap/irq/mret (ungated)
    output logic                  trap_take_o,
    output logic [DATA_WIDTH-1:0] trap_target_pc_o,
    output logic                  mret_take_o,
    output logic [DATA_WIDTH-1:0] mret_target_pc_o,

    output id_ex_bundle_t         id_ex_o
);

    logic [31:0] imm_extended_w;
    logic [11:0] csr_addr_w;
    csr_op_e     csr_op_w;
    logic [31:0] csr_wdata_w;       // zero-extended zimm
    logic [4:0]  rs1_addr_w, rs2_addr_w, rd_addr_w;
    logic        reg_write_con_w;
    logic [1:0]  rs1_src_w;
    logic        alu_src_w;
    logic [3:0]  alu_ctrl_w;
    branch_type_e branch_type_w;
    logic        is_branch_w, is_jump_w, jalr_w;
    logic        is_muldiv_w, is_mul_w, is_div_w;
    logic [2:0]  muldiv_ctrl_w, mem_ctrl_w;
    logic        is_load_w, is_store_w;
    wb_sel_e     wb_ctrl_w;
    logic        csr_access_w;
    logic        mret_w;
    logic        fencei_w;
    logic        ecall_w, ebreak_w, illegal_instr_w;

    control_unit ctrl_inst (
        .instr_i         (if_id_instr_i),
        .imm_extended_o  (imm_extended_w),
        .csr_addr_o      (csr_addr_w),
        .csr_op_o        (csr_op_w),
        .csr_wdata_o     (csr_wdata_w),
        .rs1_addr_o      (rs1_addr_w),
        .rs2_addr_o      (rs2_addr_w),
        .rd_addr_o       (rd_addr_w),
        .reg_write_o     (reg_write_con_w),
        .rs1_src_o       (rs1_src_w),
        .alu_src_o       (alu_src_w),
        .alu_ctrl_o      (alu_ctrl_w),
        .branch_type_o   (branch_type_w),
        .is_branch_o     (is_branch_w),
        .is_jump_o       (is_jump_w),
        .jalr_o          (jalr_w),
        .is_muldiv_o     (is_muldiv_w),
        .muldiv_ctrl_o   (muldiv_ctrl_w),
        .is_mul_o        (is_mul_w),
        .is_div_o        (is_div_w),
        .mem_ctrl_o      (mem_ctrl_w),
        .is_load_o       (is_load_w),
        .is_store_o      (is_store_w),
        .wb_ctrl_o       (wb_ctrl_w),
        .csr_access_o    (csr_access_w),
        .mret_o          (mret_w),
        .fencei_o        (fencei_w),
        .ecall_o         (ecall_w),
        .ebreak_o        (ebreak_w),
        .illegal_instr_o (illegal_instr_w)
    );

   // reg file ff based
    logic [DATA_WIDTH-1:0] rf_read1_data_w, rf_read2_data_w;

    register_file #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(RF_ADDR_WIDTH)
    ) rf_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        .read_port1_addr_i  (rs1_addr_w),
        .read_port2_addr_i  (rs2_addr_w),
        .read_port1_data_o  (rf_read1_data_w),
        .read_port2_data_o  (rf_read2_data_w),
        .write_port1_en_i   (wb_id_rf_wen_i),
        .write_port1_addr_i (wb_id_rf_waddr_i),
        .write_port1_data_i (wb_id_rf_wdata_i)
    );


     // rs1 source mux
    logic [DATA_WIDTH-1:0] rs1_muxed_val_w;
    always_comb begin
        case (rs1_src_w)
            2'b00:   rs1_muxed_val_w = rf_read1_data_w;
            2'b01:   rs1_muxed_val_w = if_id_pc_i;
            2'b10:   rs1_muxed_val_w = '0;
            default: rs1_muxed_val_w = rf_read1_data_w;
        endcase
    end

    logic csr_use_imm_w;
    assign csr_use_imm_w = csr_access_w && if_id_instr_i[14];

    // Source registers the instruction really reads. The rs1/rs2 fields of
    // U/J/I-type and CSRxI encodings are immediate bits; passing them on
    // let hazard_unit forward a register value into e.g. LUI/AUIPC
    // (lui sp,0xf0f0f has rs1 field = x1 -> ra got added to the result).
    // An unused source is handed to EX as x0, which never forwards.
    logic uses_rs1_w, uses_rs2_w;
    assign uses_rs1_w = (rs1_src_w == 2'b00) && !csr_use_imm_w;
    assign uses_rs2_w = is_store_w || is_branch_w || (if_id_instr_i[6:0] == 7'b011_0011);

    logic [DATA_WIDTH-1:0] csr_wdata_operand_w;
    assign csr_wdata_operand_w = csr_use_imm_w ? csr_wdata_w : rs1_muxed_val_w;

    logic csr_we_w;
    always_comb begin
        csr_we_w = 1'b0;
        if (csr_access_w) begin
            unique case (csr_op_w)
                CSR_OP_WRITE: csr_we_w = 1'b1;     // CSRRW: always write
                CSR_OP_SET: begin                   // CSRRS: write only if mask != 0
                    if (csr_use_imm_w)
                        csr_we_w = |csr_wdata_w;
                    else
                        csr_we_w = |rs1_addr_w;
                end
                CSR_OP_CLEAR: begin                 // CSRRC: write only if mask != 0
                    if (csr_use_imm_w)
                        csr_we_w = |csr_wdata_w;
                    else
                        csr_we_w = |rs1_addr_w;
                end
                default: csr_we_w = 1'b0;           // CSR_OP_NOP: no-op
            endcase
        end
    end

    assign trap_target_pc_o = csr_mtvec_i;
    assign mret_target_pc_o = csr_mepc_i;

    logic       generated_trap_w;
    logic [5:0] generated_trap_cause_w;

    always_comb begin
        generated_trap_w       = 1'b0;
        generated_trap_cause_w = 6'd0;

        if (external_irq_i && csr_mie_i && csr_mie_regs_i[11]) begin
            generated_trap_w       = 1'b1;
            generated_trap_cause_w = TRAP_CAUSE_EXT_INTERRUPT_M;
        end else if (soft_irq_i && csr_mie_i && csr_mie_regs_i[3]) begin
            // priority per priv spec: MEI > MSI > MTI
            generated_trap_w       = 1'b1;
            generated_trap_cause_w = TRAP_CAUSE_SW_INTERRUPT_M;
        end else if (timer_irq_i && csr_mie_i && csr_mie_regs_i[7]) begin
            // mstatus.MIE=1 AND mie.MTIE=1 AND !trap_in_flight
            generated_trap_w       = 1'b1;
            generated_trap_cause_w = TRAP_CAUSE_TIMER_INTERRUPT_M;
        end else if (if_id_err_i && if_id_valid_i) begin
            // fetch outside IMEM/DMEM: the word is not an instruction
            generated_trap_w       = 1'b1;
            generated_trap_cause_w = TRAP_CAUSE_INSTR_ACCESS_FAULT;
        end else if (illegal_instr_w) begin
            generated_trap_w       = 1'b1;
            generated_trap_cause_w = TRAP_CAUSE_ILLEGAL_INSTRUCTION;
        end else if (ebreak_w) begin
            generated_trap_w       = 1'b1;
            generated_trap_cause_w = TRAP_CAUSE_BREAKPOINT;
        end else if (ecall_w) begin
            generated_trap_w       = 1'b1;
            generated_trap_cause_w = TRAP_CAUSE_ECALL_FROM_M;
        end
    end

    // raw request (before stall/kill gating) so hazard_unit can hold it
    // while an older branch/jump in EX is still unresolved
    assign trap_req_o  = generated_trap_w || mret_w;

    assign trap_take_o = generated_trap_w && !stall_i && !kill_i;
    assign mret_take_o = mret_w           && !stall_i && !kill_i;

    // NOTE: preserves the original quirk where id_ex_o.mret is driven by
    // the combinational mret_w even while everything else in the bundle
    // is zeroed as a bubble (the original per-signal version left
    // id_ex_mret_o out of its own bubble-clear list the same way).
    // An MRET leaves ID as one of these bubbles (flush_id on mret_take) but
    // it still retires, so it keeps its valid bit for minstret; every
    // other bubble is not an instruction.
    task automatic latch_bubble();
        id_ex_o       <= '0;
        id_ex_o.mret  <= mret_w;
        id_ex_o.valid <= mret_w && if_id_valid_i;
    endtask

    always_ff @(posedge clk or negedge rst_n) begin : id_ex_reg
        if (!rst_n) begin
            latch_bubble();

        end else if (kill_i && !stall_i) begin
            // wrong-path or CSR-RAW-held slot: a true bubble (mret/valid
            // cleared too, so a wrong-path MRET can't commit in WB)
            id_ex_o <= '0;

        end else if (generated_trap_w && !stall_i) begin

            latch_bubble();
            id_ex_o.valid      <= 1'b0;    // trapped instruction does not retire
            id_ex_o.trap       <= 1'b1;
            id_ex_o.trap_cause <= generated_trap_cause_w;
            id_ex_o.pc         <= if_id_pc_i;
            id_ex_o.tval       <= (generated_trap_cause_w == TRAP_CAUSE_ILLEGAL_INSTRUCTION) ? if_id_instr_i :
                                  (generated_trap_cause_w == TRAP_CAUSE_BREAKPOINT ||
                                   generated_trap_cause_w == TRAP_CAUSE_INSTR_ACCESS_FAULT)  ? if_id_pc_i    : '0;

        end else if (flush_i) begin

            latch_bubble();

        end else if (!stall_i) begin
            id_ex_o.pc          <= if_id_pc_i;
            id_ex_o.rs1_data    <= rs1_muxed_val_w;
            id_ex_o.rs2_data    <= rf_read2_data_w;
            id_ex_o.imm         <= imm_extended_w;
            id_ex_o.rd_addr     <= rd_addr_w;
            id_ex_o.rs1_addr    <= uses_rs1_w ? rs1_addr_w : '0;
            id_ex_o.rs2_addr    <= uses_rs2_w ? rs2_addr_w : '0;
            id_ex_o.csr_rdata   <= csr_rdata_i;

            id_ex_o.trap        <= 1'b0;
            id_ex_o.trap_cause  <= 6'b0;
            id_ex_o.tval        <= '0;

            id_ex_o.reg_write   <= reg_write_con_w;
            id_ex_o.alu_src     <= alu_src_w;
            id_ex_o.alu_ctrl    <= alu_ctrl_w;
            id_ex_o.is_muldiv   <= is_muldiv_w;
            id_ex_o.muldiv_ctrl <= muldiv_ctrl_w;
            id_ex_o.branch_type <= branch_type_w;
            id_ex_o.is_branch   <= is_branch_w;
            id_ex_o.is_jump     <= is_jump_w;
            id_ex_o.jalr        <= jalr_w;
            id_ex_o.mem_ctrl    <= mem_ctrl_w;
            id_ex_o.is_load     <= is_load_w;
            id_ex_o.is_store    <= is_store_w;
            id_ex_o.wb_ctrl     <= wb_ctrl_w;
            id_ex_o.csr_access  <= csr_access_w;
            id_ex_o.csr_we      <= csr_we_w;
            id_ex_o.csr_addr    <= csr_addr_w;
            id_ex_o.csr_op      <= csr_op_w;
            id_ex_o.csr_wdata   <= csr_wdata_operand_w;
            id_ex_o.csr_use_imm <= csr_use_imm_w;
            id_ex_o.mret        <= mret_w;
            id_ex_o.fencei      <= fencei_w;
            id_ex_o.priv_mode   <= PRIV_M;  // core is M-mode only today
            id_ex_o.valid       <= if_id_valid_i;
        end
    end

endmodule
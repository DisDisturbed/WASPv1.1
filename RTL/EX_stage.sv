`timescale 1ns / 1ps
`default_nettype none

//  EX_stage
//
// Takes a single core_pkg::id_ex_bundle_t in and produces a single
// core_pkg::ex_mem_bundle_t out, instead of ~20 individual ports on each
// side. branch_dec now switches on branch_type_e values instead of raw
// 3-bit literals, and trap causes use the named core_pkg constants.

module EX_stage
    import core_pkg::*;
#(
    parameter  int          DATA_WIDTH       = core_pkg::CORE_DATA_WIDTH,
    parameter  int          REG_ADDR_WIDTH   = core_pkg::CORE_RF_ADDR_WIDTH
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     stall_i,
    input  wire                     flush_i,


    output logic                    ex_busy_o,

    input  wire [1:0]               forward_a_sel_i,
    input  wire [1:0]               forward_b_sel_i, 
    input  wire [DATA_WIDTH-1:0]    mem_forward_data_i,
    input  wire [DATA_WIDTH-1:0]    wb_forward_data_i,

    input   id_ex_bundle_t           id_ex_i,

    output logic [DATA_WIDTH-1:0]   ex_combinational_res_o,

    output  ex_mem_bundle_t          ex_mem_o,

    output logic                    ex_branch_decision_o
);


    logic [DATA_WIDTH-1:0] alu_result_w;
    logic                  alu_zero_w, alu_error_w, alu_carry_w;
    logic [DATA_WIDTH-1:0] alu_mux_a_val;
    logic [DATA_WIDTH-1:0] forward_mux_b_val;
    logic [DATA_WIDTH-1:0] alu_mux_b_val;
    logic [DATA_WIDTH-1:0] branch_target_w;
    logic [DATA_WIDTH-1:0] datapath_result_w;
    logic                  generated_trap_w;
    logic [5:0]            generated_trap_cause_w;
    logic                  inst_addr_misaligned_w;
    logic                  branch_decision_w;

    always_comb begin : fwd_mux_a
        case (forward_a_sel_i)
            2'b00:   alu_mux_a_val = id_ex_i.rs1_data;
            2'b01:   alu_mux_a_val = mem_forward_data_i;
            2'b10:   alu_mux_a_val = wb_forward_data_i;
            default: begin
                alu_mux_a_val = id_ex_i.rs1_data;
                // synthesis translate_off
                $error("EX_stage: illegal forward_a_sel %b", forward_a_sel_i);
                // synthesis translate_on
            end
        endcase
    end

    always_comb begin : fwd_mux_b
        case (forward_b_sel_i)
            2'b00:   forward_mux_b_val = id_ex_i.rs2_data;
            2'b01:   forward_mux_b_val = mem_forward_data_i;
            2'b10:   forward_mux_b_val = wb_forward_data_i;
            default: begin
                forward_mux_b_val = id_ex_i.rs2_data;
                // synthesis translate_off
                $error("EX_stage: illegal forward_b_sel %b", forward_b_sel_i);
                // synthesis translate_on
            end
        endcase
    end

    assign alu_mux_b_val = id_ex_i.alu_src ? id_ex_i.imm : forward_mux_b_val;

    always_comb begin : branch_target
        if (id_ex_i.jalr)
            branch_target_w = {alu_result_w[DATA_WIDTH-1:1], 1'b0}; // mask bit 0 per spec
        else
            branch_target_w = $signed(id_ex_i.pc) + $signed(id_ex_i.imm);
    end

    always_comb begin : branch_dec
        branch_decision_w = 1'b0;
        if (id_ex_i.is_branch) begin
            case (id_ex_i.branch_type)
                BR_BEQ:  branch_decision_w = alu_zero_w;        // BEQ
                BR_BNE:  branch_decision_w = ~alu_zero_w;       // BNE
                BR_BLT:  branch_decision_w = alu_result_w[0];   // BLT  (SLT result)
                BR_BGE:  branch_decision_w = ~alu_result_w[0];  // BGE  (SLT result)
                BR_BLTU: branch_decision_w = alu_result_w[0];   // BLTU (SLTU result)
                BR_BGEU: branch_decision_w = ~alu_result_w[0];  // BGEU (SLTU result)
                default: branch_decision_w = 1'b0;
            endcase
        end
    end

    always_comb begin : iaddr_misalign
        inst_addr_misaligned_w = 1'b0;

        if (id_ex_i.jalr || id_ex_i.is_jump || (id_ex_i.is_branch && branch_decision_w)) begin
            if (branch_target_w[1:0] != 2'b00) begin
                inst_addr_misaligned_w = 1'b1;
            end
        end
    end

    logic div_by_zero;

    always_comb begin : trap_prop
        generated_trap_w       = id_ex_i.trap;
        generated_trap_cause_w = id_ex_i.trap_cause;

        if (!id_ex_i.trap) begin
            if (inst_addr_misaligned_w) begin
                generated_trap_w       = 1'b1;
                generated_trap_cause_w = TRAP_CAUSE_INSTR_ADDR_MISALIGNED;
            end else if (alu_error_w) begin
                generated_trap_w       = 1'b1;
                generated_trap_cause_w = TRAP_CAUSE_ILLEGAL_INSTRUCTION;
            end else if (div_by_zero) begin
                generated_trap_w       = 1'b1;
                generated_trap_cause_w = TRAP_CAUSE_DIV_BY_ZERO_CUSTOM;
            end
        end
    end

`ifdef SIMULATION
    always_ff @(posedge clk) begin
        if (rst_n && !stall_i  && !id_ex_i.trap) begin
            if (inst_addr_misaligned_w)
                $display("[EX TRAP] Time: %0t | PC: %h | cause: inst misaligned | target: %h",
                         $time, id_ex_i.pc, branch_target_w);
            else if (alu_error_w)
                $display("[EX TRAP] Time: %0t | PC: %h | cause: illegal instruction",
                         $time, id_ex_i.pc);
            else if (div_by_zero)
                $display("[EX TRAP] Time: %0t | PC: %h | cause: division by zero",
                         $time, id_ex_i.pc);
        end
    end
`endif

    Alu #(
        .DATA_WIDTH   (DATA_WIDTH),
        .CONTROL_WIDTH(4)
    ) alu_inst (
        .a_in          (alu_mux_a_val),
        .b_in          (alu_mux_b_val),
        .alu_control_i (id_ex_i.alu_ctrl),
        .result        (alu_result_w),
        .zero_flag     (alu_zero_w),
        .error_flag    (alu_error_w),
        .carry_flag    (alu_carry_w)
    );

     logic muldiv_busy_w, muldiv_done_w, muldiv_div_zero_w;
logic [DATA_WIDTH-1:0] muldiv_result_w;
logic muldiv_start_w;
logic [DATA_WIDTH-1:0] muldiv_res_w;

assign muldiv_start_w = id_ex_i.is_muldiv & ~muldiv_busy_w & ~muldiv_done_w & ~flush_i;

assign ex_busy_o = id_ex_i.is_muldiv & ~muldiv_done_w;
assign div_by_zero  = muldiv_div_zero_w;
assign muldiv_res_w = muldiv_result_w;

MulDiv #(.DATA_WIDTH(DATA_WIDTH)) muldiv_inst (
    .clk(clk), .rst_n(rst_n),
    .start_i(muldiv_start_w), .kill_i(flush_i), .stall_i(stall_i),
    .ctrl_i(id_ex_i.muldiv_ctrl),
    .operand_a_i(alu_mux_a_val),
    .operand_b_i(forward_mux_b_val),
    .busy_o(muldiv_busy_w), .done_o(muldiv_done_w),
    .result_o(muldiv_result_w), .div_by_zero_o(muldiv_div_zero_w)
);


     logic mul_div_control_mux;
     assign mul_div_control_mux = muldiv_done_w;


    always_comb begin : dp_res_mux
        if (id_ex_i.csr_access)
            datapath_result_w = id_ex_i.csr_rdata;
        else if (muldiv_done_w)
            datapath_result_w = muldiv_res_w;
        else if (id_ex_i.is_jump)
            datapath_result_w = id_ex_i.pc + DATA_WIDTH'(4);
        else
            datapath_result_w = alu_result_w;
    end

    logic [DATA_WIDTH-1:0] csr_wdata_final_w;
    always_comb begin : csr_wdata_sel
        if (!id_ex_i.csr_use_imm && (id_ex_i.csr_op != CSR_OP_NOP))
            csr_wdata_final_w = alu_mux_a_val;
        else
            csr_wdata_final_w = id_ex_i.csr_wdata;
    end



   // synthesis translate_off
//    always_ff @(posedge clk) begin
//    $display("[EX_MEM @ %0t] flush=%b stall=%b alu_res=%h",
//              $time, flush_i, stall_i, ex_mem_o.alu_res);
//    end
    // synthesis translate_on
    task automatic latch_bubble();
        ex_mem_o              <= '0;
        ex_branch_decision_o  <= 1'b0;
    endtask




   always_ff @(posedge clk or negedge rst_n) begin : ex_mem_reg
        if (!rst_n || flush_i) begin

            latch_bubble();
        end else if (!stall_i) begin
            if (ex_busy_o) begin
                latch_bubble();
            end else begin
                ex_branch_decision_o   <= branch_decision_w;
                ex_mem_o.alu_res       <= datapath_result_w;
                ex_mem_o.alu_zero      <= alu_zero_w;
                ex_mem_o.alu_error     <= alu_error_w;
                ex_mem_o.alu_carry     <= alu_carry_w;
                ex_mem_o.rs2_data      <= forward_mux_b_val;
                ex_mem_o.branch_target <= branch_target_w;
                ex_mem_o.rd_addr       <= id_ex_i.rd_addr;
                ex_mem_o.pc            <= id_ex_i.pc;
                ex_mem_o.pc_plus4      <= id_ex_i.pc + DATA_WIDTH'(4);
                ex_mem_o.trap          <= generated_trap_w;
                ex_mem_o.trap_cause    <= generated_trap_cause_w;
                ex_mem_o.is_load       <= id_ex_i.is_load;
                ex_mem_o.is_store      <= id_ex_i.is_store;
                ex_mem_o.is_jump       <= id_ex_i.is_jump;
                ex_mem_o.is_jarl       <= id_ex_i.jalr;
                ex_mem_o.csr_addr      <= id_ex_i.csr_addr;
                ex_mem_o.csr_op        <= id_ex_i.csr_op;
                ex_mem_o.csr_wdata     <= csr_wdata_final_w;
                ex_mem_o.csr_access    <= id_ex_i.csr_access;
                ex_mem_o.csr_we        <= id_ex_i.csr_we;
                ex_mem_o.mret          <= id_ex_i.mret;
                ex_mem_o.priv_mode     <= id_ex_i.priv_mode;
                ex_mem_o.valid         <= id_ex_i.valid && !generated_trap_w;

                if (generated_trap_w) begin
                    ex_mem_o.reg_write  <= 1'b0;
                    ex_mem_o.mem_ctrl   <= '0;
                    ex_mem_o.wb_ctrl    <= WB_SEL_ALU_RESULT;
                    ex_mem_o.csr_access <= 1'b0;
                    ex_mem_o.csr_we     <= 1'b0;
                    ex_mem_o.mret       <= 1'b0;
                end else begin
                    ex_mem_o.reg_write  <= id_ex_i.reg_write;
                    ex_mem_o.mem_ctrl   <= id_ex_i.mem_ctrl;
                    ex_mem_o.wb_ctrl    <= id_ex_i.wb_ctrl;
                end
            end
        end
    end

endmodule
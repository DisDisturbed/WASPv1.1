`timescale 1ns / 1ps
`default_nettype none

// pc_mux_sel_e / exc_pc_mux_e / trap_mode_e used to be defined locally
// here AND duplicated (as raw localparams) in hazard_unit -- both are now
// core_pkg::pc_mux_sel_e / core_pkg::exc_pc_mux_e / core_pkg::trap_addr_mux_e,
// so the two modules that must agree on these encodings share one
// definition instead of two hand-copied ones.
//
// instr_en_o/instr_addr_o/instr_gnt_i/instr_rvalid_i/instr_rdata_i are
// replaced by a single obi_instr_if.master port: this is exactly the OBI
// bus core_pkg.sv's header calls out as belonging in a real interface,
// since the memory on the other end is not a fixed connectee (sim BRAM
// model vs. real memory controller vs. icache).
module IF_stage
    import core_pkg::*;
#(
    parameter int DATA_WIDTH = core_pkg::CORE_DATA_WIDTH
)(
    input  wire clk,
    input  wire rst_n,

    //  boot and debug
    input  wire [DATA_WIDTH-1:0] boot_addr_i,
    input  wire [DATA_WIDTH-1:0] dm_exception_addr_i,

    //  trap addr
    input  wire [23:0]      m_trap_base_addr_i,
    input  wire [23:0]      u_trap_base_addr_i,
    input  wire trap_addr_mux_e  trap_addr_mux_i,

    // vector irq
    input  wire [4:0]  m_exc_vec_pc_mux_i,
    input  wire [4:0]  u_exc_vec_pc_mux_i,

    // exception return
    input  wire [DATA_WIDTH-1:0] mepc_i,
    input  wire [DATA_WIDTH-1:0] uepc_i,

    // pc mux control
    input  wire pc_mux_sel_e          pc_mux_i,
    input  wire exc_pc_mux_e          exc_pc_mux_i,
    input  wire                  pc_set_i,

    // jump and branches
    input  wire [DATA_WIDTH-1:0] jump_target_mem_i,
    input  wire [DATA_WIDTH-1:0] jump_target_ex_i,

    // OBI instruction-memory master port
    obi_instr_if.master instr_bus,

    // pipeline control
    input  wire stall_i,
    input  wire flush_i,

    //  csr
    output logic csr_mtvec_init_o,

    // if/id pipeline
    output logic [DATA_WIDTH-1:0] instr_rdata_id_o,
    output logic                  instr_valid_id_o,   // 0 = NOP bubble inserted by IF (for minstret)
    output logic                  instr_err_id_o,     // fetch refused (instruction access fault)
    output logic [DATA_WIDTH-1:0] pc_if_o,
    output logic [DATA_WIDTH-1:0] pc_id_o,
    output logic                  if_busy_o
);
    assign if_busy_o = 1'b0;

    logic [23:0]           trap_base_w;
    logic [4:0]            exc_vec_w;
    logic [DATA_WIDTH-1:0] exc_pc_w;

    always_comb begin
        unique case (trap_addr_mux_i)
            TRAP_M:  begin trap_base_w = m_trap_base_addr_i; exc_vec_w = m_exc_vec_pc_mux_i; end
            TRAP_U:  begin trap_base_w = u_trap_base_addr_i; exc_vec_w = u_exc_vec_pc_mux_i; end
            default: begin trap_base_w = m_trap_base_addr_i; exc_vec_w = m_exc_vec_pc_mux_i; end
        endcase

        unique case (exc_pc_mux_i)
            EXC_PC_EXCEPTION: exc_pc_w = {trap_base_w, 8'h00};
            EXC_PC_IRQ:       exc_pc_w = {trap_base_w, 1'b0, exc_vec_w, 2'b00};
            EXC_PC_DBE:       exc_pc_w = {dm_exception_addr_i[31:2], 2'b00};
            default:          exc_pc_w = {trap_base_w, 8'h00};
        endcase
    end

    logic [DATA_WIDTH-1:0] branch_addr_w;

    always_comb begin
        branch_addr_w = {boot_addr_i[31:2], 2'b00};
        unique case (pc_mux_i)
            PC_BOOT:      branch_addr_w = {boot_addr_i[31:2], 2'b00};
            PC_JUMP:      branch_addr_w = jump_target_ex_i;
            PC_BRANCH:    branch_addr_w = jump_target_ex_i;
            PC_EXCEPTION: branch_addr_w = exc_pc_w;
            PC_MRET:      branch_addr_w = mepc_i;
            PC_URET:      branch_addr_w = uepc_i;
            PC_FENCEI:    branch_addr_w = pc_id_o + DATA_WIDTH'(4);
            PC_PLUS4:     branch_addr_w = pc_if_o + DATA_WIDTH'(4);
            default:      branch_addr_w = {boot_addr_i[31:2], 2'b00};
        endcase
    end

    logic mtvec_init_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mtvec_init_r <= 1'b1;
        else        mtvec_init_r <= 1'b0;
    end
    assign csr_mtvec_init_o = mtvec_init_r;

    logic [DATA_WIDTH-1:0] pc_r;
    logic pending_q;     // obi signals
    logic fetch_valid_r;
    logic [DATA_WIDTH-1:0] fetch_buffer_r;
    logic fetch_err_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q     <= 1'b0;
            fetch_valid_r <= 1'b0;
        end else if (pc_set_i || flush_i) begin
            pending_q     <= 1'b0;
            fetch_valid_r <= 1'b0;
        end else begin
            pending_q <= (pending_q | instr_bus.gnt) & ~instr_bus.rvalid;

            if (instr_bus.rvalid && stall_i) begin
                fetch_buffer_r <= instr_bus.rdata;
                fetch_err_r    <= instr_bus.err;
                fetch_valid_r  <= 1'b1;
            end else if (!stall_i) begin
                fetch_valid_r  <= 1'b0;
            end
        end
    end

    // ins source mux skid buffer takes priority
    logic        current_valid_w;
    logic [31:0] current_instr_w;
    logic        current_err_w;
    assign current_valid_w = instr_bus.rvalid | fetch_valid_r;
    assign current_instr_w = fetch_valid_r  ? fetch_buffer_r : instr_bus.rdata;
    assign current_err_w   = fetch_valid_r  ? fetch_err_r    : instr_bus.err;

    assign instr_bus.req  = pc_set_i | (~pending_q & ~fetch_valid_r & ~flush_i);
    assign instr_bus.addr = pc_set_i ? branch_addr_w : pc_r;

    logic [DATA_WIDTH-1:0] next_pc_w;

    always_comb begin
        if (pc_set_i)
            next_pc_w = branch_addr_w;
        else if (current_valid_w && !stall_i)
            next_pc_w = pc_r + DATA_WIDTH'(4);
        else
            next_pc_w = pc_r;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc_r <= {boot_addr_i[31:2], 2'b00};
        else        pc_r <= next_pc_w;
    end

    assign pc_if_o = pc_r;


    //  IF/ID
    //  Priority redirect/flush > stall > cache hit  > miss

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_rdata_id_o <= 32'h00000013; // NOP
            instr_valid_id_o <= 1'b0;
            instr_err_id_o   <= 1'b0;
            pc_id_o          <= '0;
        end else if (flush_i || pc_set_i) begin
            // redirect of flush
            // The bubble's PC is where execution resumes if an interrupt is
            // taken on it (mepc = if_id_pc). On a redirect that is the new
            // target, not pc_r (= old, wrong-path fetch address).
            instr_rdata_id_o <= 32'h00000013;
            instr_valid_id_o <= 1'b0;
            instr_err_id_o   <= 1'b0;
            pc_id_o          <= pc_set_i ? branch_addr_w : pc_r;
        end else if (stall_i) begin
            //stalled input hold on skip buffer
        end else if (current_valid_w) begin
            // cache valid
            instr_rdata_id_o <= current_instr_w;
            instr_valid_id_o <= 1'b1;
            instr_err_id_o   <= current_err_w;
            pc_id_o          <= pc_r;
        end else begin
            //pipeline bubble on cahce miss
            instr_rdata_id_o <= 32'h00000013;
            instr_valid_id_o <= 1'b0;
            instr_err_id_o   <= 1'b0;
            pc_id_o          <= pc_r;
        end
    end

endmodule
`timescale 1ns / 1ps
`default_nettype none

// i still have no idea how i pulled this off
//  csr_file  machine mode only

//  Registers
//  0x300  mstatus   MIE[3] MPIE[7] MPP[12:11]=2'b11 (M-only)
//  0x301  misa      RV32IM read-only
//  0x304  mie       MSIE[3] MTIE[7] MEIE[11]
//  0x305  mtvec     BASE+MODE
//  0x306  mcounteren  R/W, reset all-ones, not enforced until U/S mode exists
//  0x106  scounteren  R/W, reset all-ones, not enforced until U/S mode exists
//  0x310  mstatush  read-only 0 (RV32)
//  0x320  mcountinhibit  CY[0] IR[2] writable, rest 0
//  0x323-0x33F mhpmevent3..31   hardwired 0
//  0x340  mscratch
//  0x341  mepc      [1:0] forced 0
//  0x342  mcause    [31]=interrupt [4:0]=cause
//  0x343  mtval     on trap entry: misaligned address (fetch target /
//                   load / store), illegal instruction bits, ebreak pc; else 0
//  0x344  mip       read-only mirror of live IRQ lines: MSIP[3] MTIP[7] MEIP[11]
//  0xB00/0xB80  mcycle / mcycleh       64-bit, +1 every clock (unless inhibited)
//  0xB02/0xB82  minstret / minstreth   64-bit, +1 per retired instruction
//  0xB03-0xB1F, 0xB83-0xB9F  mhpmcounter3..31(h)  hardwired 0
//  0xC00/0xC80  cycle / cycleh      read-only shadow of mcycle
//  0xC01/0xC81  time / timeh        read-only shadow of CLINT mtime
//  0xC02/0xC82  instret / instreth  read-only shadow of minstret
//  0xC03-0xC1F, 0xC83-0xC9F  hpmcounter3..31(h)   hardwired 0
//  0xF11-0xF15      all-zero read-only IDs (mvendorid..mconfigptr)
//  Write priority: reset > trap_i > mret_i > csr_we_i
//  Counters live in their own always_ff: they keep counting through
//  trap/mret cycles, and a CSR write to a counter wins over that cycle's
//  increment (the next instruction reads exactly the value written).
//
// The CSR address map and csr_op_e are defined in core_pkg, so the other
// stages that decode CSR accesses use the same names.
//
// NOTE: accesses to non-existent CSRs and writes to read-only CSRs never
// reach this module: control_unit (csr_legal) decodes them as illegal
// instructions. Existing CSRs without state here read 0 / ignore writes.

module csr_file
    import core_pkg::*;
#(
    parameter int DATA_WIDTH = core_pkg::CORE_DATA_WIDTH
)(
    input  wire clk,
    input  wire rst_n,

    //  combinational read port
    input  wire [11:0]            csr_raddr_i,
    output logic [DATA_WIDTH-1:0] csr_rdata_o,


    // driven by wb stage
    // csr_we_i MUST only be asserted when wb_commit_csr_access is set AND
    // the slot is not flushed (WB_stage gates this).
    input  wire                   csr_we_i,
    input  wire [11:0]            csr_waddr_i,
    input  wire csr_op_e               csr_op_i,
    input  wire [DATA_WIDTH-1:0]  csr_wdata_i,

    //  trap commit
    input  wire                   trap_i,
    input  wire [5:0]             trap_cause_i,    // is_interrupt[5], cause[4:0]
    input  wire [DATA_WIDTH-1:0]  trap_tval_i,     // mtval: bad address / instruction / pc, else 0
    input  wire [DATA_WIDTH-1:0]  trap_pc_i,

    //  MRET commit
    input  wire                   mret_i,          // wb_commit_mret gated by WB flush

    //  instruction retired this cycle (WB valid bit)
    input  wire                   instr_retire_i,

    //  Live interrupt lines
    input  wire                   external_irq_i,
    input  wire                   timer_irq_i,
    input  wire                   soft_irq_i,

    //  CLINT mtime, shadowed by the read-only time/timeh CSRs
    input  wire [63:0]            mtime_i,

    // current register states for pipeline visiblity
    output logic [DATA_WIDTH-1:0] mepc_o,
    output logic                  mstatus_mie_o,
    output logic [DATA_WIDTH-1:0] mie_o,
    output logic [23:0]           m_trap_base_addr_o,

    // counter-enable registers, for the future U/S-mode access check
    output logic [DATA_WIDTH-1:0] mcounteren_o,
    output logic [DATA_WIDTH-1:0] scounteren_o
);

    //  registers
    logic mstatus_mie_r;
    logic mstatus_mpie_r;
    // MPP[12:11] hardwired 2'b11

    logic mie_msie_r;
    logic mie_mtie_r;
    logic mie_meie_r;

    logic [DATA_WIDTH-1:0] mtvec_r;
    logic [DATA_WIDTH-1:0] mscratch_r;
    logic [DATA_WIDTH-1:0] mepc_r;
    logic [DATA_WIDTH-1:0] mcause_r;
    logic [DATA_WIDTH-1:0] mtval_r;

    //  counters
    logic [63:0]           mcycle_r;
    logic [63:0]           minstret_r;
    logic                  inhibit_cy_r;   // mcountinhibit[0]
    logic                  inhibit_ir_r;   // mcountinhibit[2]
    logic [DATA_WIDTH-1:0] mcounteren_r;
    logic [DATA_WIDTH-1:0] scounteren_r;

    //  Read back
    logic [DATA_WIDTH-1:0] mstatus_rdata_w;
    always_comb begin
        mstatus_rdata_w        = '0;
        mstatus_rdata_w[3]     = mstatus_mie_r;
        mstatus_rdata_w[7]     = mstatus_mpie_r;
        mstatus_rdata_w[12:11] = 2'b11;
    end

    logic [DATA_WIDTH-1:0] mie_rdata_w;
    always_comb begin
        mie_rdata_w     = '0;
        mie_rdata_w[3]  = mie_msie_r;
        mie_rdata_w[7]  = mie_mtie_r;
        mie_rdata_w[11] = mie_meie_r;
    end

    logic [DATA_WIDTH-1:0] mip_w;
    always_comb begin
        mip_w     = '0;
        mip_w[11] = external_irq_i;
        mip_w[7]  = timer_irq_i;
        mip_w[3]  = soft_irq_i;
    end

    logic [DATA_WIDTH-1:0] mcountinhibit_rdata_w;
    always_comb begin
        mcountinhibit_rdata_w    = '0;
        mcountinhibit_rdata_w[0] = inhibit_cy_r;
        mcountinhibit_rdata_w[2] = inhibit_ir_r;
    end

    localparam logic [DATA_WIDTH-1:0] MISA_VAL = 32'h4000_1100; // RV32IM

    //  Combinational read port
    //  mhpmcounter*/hpmcounter*/mhpmevent*, mstatush, mconfigptr and the
    //  ID registers all fall through to the zero default on purpose.
    always_comb begin : csr_read
        case (csr_raddr_i)
            CSR_ADDR_MSTATUS:                    csr_rdata_o = mstatus_rdata_w;
            CSR_ADDR_MISA:                       csr_rdata_o = MISA_VAL;
            CSR_ADDR_MIE:                        csr_rdata_o = mie_rdata_w;
            CSR_ADDR_MTVEC:                      csr_rdata_o = mtvec_r;
            CSR_ADDR_MCOUNTEREN:                 csr_rdata_o = mcounteren_r;
            CSR_ADDR_SCOUNTEREN:                 csr_rdata_o = scounteren_r;
            CSR_ADDR_MCOUNTINHIBIT:              csr_rdata_o = mcountinhibit_rdata_w;
            CSR_ADDR_MSCRATCH:                   csr_rdata_o = mscratch_r;
            CSR_ADDR_MEPC:                       csr_rdata_o = mepc_r;
            CSR_ADDR_MCAUSE:                     csr_rdata_o = mcause_r;
            CSR_ADDR_MTVAL:                      csr_rdata_o = mtval_r;
            CSR_ADDR_MIP:                        csr_rdata_o = mip_w;
            CSR_ADDR_MCYCLE,   CSR_ADDR_CYCLE:   csr_rdata_o = mcycle_r[31:0];
            CSR_ADDR_MCYCLEH,  CSR_ADDR_CYCLEH:  csr_rdata_o = mcycle_r[63:32];
            CSR_ADDR_MINSTRET, CSR_ADDR_INSTRET: csr_rdata_o = minstret_r[31:0];
            CSR_ADDR_MINSTRETH,CSR_ADDR_INSTRETH:csr_rdata_o = minstret_r[63:32];
            CSR_ADDR_TIME:                       csr_rdata_o = mtime_i[31:0];
            CSR_ADDR_TIMEH:                      csr_rdata_o = mtime_i[63:32];
            CSR_ADDR_MVENDORID, CSR_ADDR_MARCHID,
            CSR_ADDR_MIMPID,   CSR_ADDR_MHARTID,
            CSR_ADDR_MCONFIGPTR, CSR_ADDR_MSTATUSH: csr_rdata_o = '0;
            default:                             csr_rdata_o = '0;
        endcase
    end

    //  RMW for CSR writes
    logic [DATA_WIDTH-1:0] csr_old_w;
    logic [DATA_WIDTH-1:0] csr_new_w;

    always_comb begin : rmw
        case (csr_waddr_i)
            CSR_ADDR_MSTATUS:       csr_old_w = mstatus_rdata_w;
            CSR_ADDR_MIE:           csr_old_w = mie_rdata_w;
            CSR_ADDR_MTVEC:         csr_old_w = mtvec_r;
            CSR_ADDR_MCOUNTEREN:    csr_old_w = mcounteren_r;
            CSR_ADDR_SCOUNTEREN:    csr_old_w = scounteren_r;
            CSR_ADDR_MCOUNTINHIBIT: csr_old_w = mcountinhibit_rdata_w;
            CSR_ADDR_MSCRATCH:      csr_old_w = mscratch_r;
            CSR_ADDR_MEPC:          csr_old_w = mepc_r;
            CSR_ADDR_MCAUSE:        csr_old_w = mcause_r;
            CSR_ADDR_MTVAL:         csr_old_w = mtval_r;
            CSR_ADDR_MCYCLE:        csr_old_w = mcycle_r[31:0];
            CSR_ADDR_MCYCLEH:       csr_old_w = mcycle_r[63:32];
            CSR_ADDR_MINSTRET:      csr_old_w = minstret_r[31:0];
            CSR_ADDR_MINSTRETH:     csr_old_w = minstret_r[63:32];
            default:                csr_old_w = '0;
        endcase

        unique case (csr_op_i)
            CSR_OP_WRITE: csr_new_w = csr_wdata_i;
            CSR_OP_SET:   csr_new_w = csr_old_w |  csr_wdata_i;
            CSR_OP_CLEAR: csr_new_w = csr_old_w & ~csr_wdata_i;
            default:      csr_new_w = csr_old_w;
        endcase
    end

    //  priority: reset > trap > mret >  exp write
    always_ff @(posedge clk or negedge rst_n) begin : csr_ff
        if (!rst_n) begin
            mstatus_mie_r  <= 1'b0;
            mstatus_mpie_r <= 1'b0;
            mie_msie_r     <= 1'b0;
            mie_mtie_r     <= 1'b0;
            mie_meie_r     <= 1'b0;
            mtvec_r        <= '0;
            mscratch_r     <= '0;
            mepc_r         <= '0;
            mcause_r       <= '0;
            mtval_r        <= '0;
            mcounteren_r   <= '1;
            scounteren_r   <= '1;
            inhibit_cy_r   <= 1'b0;
            inhibit_ir_r   <= 1'b0;

        end else if (trap_i) begin
            //  save context, mask interrupts
            mepc_r         <= {trap_pc_i[31:2], 2'b00};
            mcause_r       <= {trap_cause_i[5], 26'b0, trap_cause_i[4:0]};
            mtval_r        <= trap_tval_i;
            mstatus_mpie_r <= mstatus_mie_r;
            mstatus_mie_r  <= 1'b0;

        end else if (mret_i) begin
            //  MRET
            mstatus_mie_r  <= mstatus_mpie_r;
            mstatus_mpie_r <= 1'b1;            // MPIE set after MRET

        end else if (csr_we_i) begin
            //  CSRRW/CSRRS/CSRRC instructions
            case (csr_waddr_i)
                CSR_ADDR_MSTATUS: begin
                    mstatus_mie_r  <= csr_new_w[3];
                    mstatus_mpie_r <= csr_new_w[7];
                end
                CSR_ADDR_MIE: begin
                    mie_msie_r <= csr_new_w[3];
                    mie_mtie_r <= csr_new_w[7];
                    mie_meie_r <= csr_new_w[11];
                end
                CSR_ADDR_MTVEC:      mtvec_r      <= csr_new_w;
                CSR_ADDR_MCOUNTEREN: mcounteren_r <= csr_new_w;
                CSR_ADDR_SCOUNTEREN: scounteren_r <= csr_new_w;
                CSR_ADDR_MCOUNTINHIBIT: begin
                    inhibit_cy_r <= csr_new_w[0];
                    inhibit_ir_r <= csr_new_w[2];
                end
                CSR_ADDR_MSCRATCH: mscratch_r <= csr_new_w;
                CSR_ADDR_MEPC:     mepc_r     <= {csr_new_w[31:2], 2'b00};
                CSR_ADDR_MCAUSE:   mcause_r   <= csr_new_w;
                CSR_ADDR_MTVAL:    mtval_r    <= csr_new_w;
                default: ;
            endcase
        end
    end

    //  64-bit counters (separate block so trap/mret never stall them)
    logic cnt_we_w;
    assign cnt_we_w = csr_we_i && !trap_i && !mret_i;

    always_ff @(posedge clk or negedge rst_n) begin : counter_ff
        if (!rst_n) begin
            mcycle_r   <= '0;
            minstret_r <= '0;
        end else begin
            if (cnt_we_w && csr_waddr_i == CSR_ADDR_MCYCLE)
                mcycle_r[31:0]  <= csr_new_w;
            else if (cnt_we_w && csr_waddr_i == CSR_ADDR_MCYCLEH)
                mcycle_r[63:32] <= csr_new_w;
            else if (!inhibit_cy_r)
                mcycle_r <= mcycle_r + 64'd1;

            if (cnt_we_w && csr_waddr_i == CSR_ADDR_MINSTRET)
                minstret_r[31:0]  <= csr_new_w;
            else if (cnt_we_w && csr_waddr_i == CSR_ADDR_MINSTRETH)
                minstret_r[63:32] <= csr_new_w;
            else if (instr_retire_i && !inhibit_ir_r)
                minstret_r <= minstret_r + 64'd1;
        end
    end

    //  outputs assigning them this was is a good idea for simulation since it add delta cycle
    assign mepc_o             = mepc_r;
    assign mstatus_mie_o      = mstatus_mie_r;
    assign mie_o              = mie_rdata_w;
    assign m_trap_base_addr_o = mtvec_r[31:8];
    assign mcounteren_o       = mcounteren_r;
    assign scounteren_o       = scounteren_r;

    //  simulation log only for debug purposes has no effect on rtl
    // synthesis translate_off
`ifndef CSR_QUIET
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (trap_i)
                $display("[CSR @%0t] TRAP  cause=%06b pc=%h -> mepc=%h MIE->0",
                         $time, trap_cause_i, trap_pc_i, {trap_pc_i[31:2],2'b00});
            if (mret_i)
                $display("[CSR @%0t] MRET  mepc=%h MIE<-MPIE(%b)",
                         $time, mepc_r, mstatus_mpie_r);
            if (csr_we_i && !trap_i && !mret_i)
                $display("[CSR @%0t] WRITE addr=%03h op=%p wdata=%h -> %h",
                         $time, csr_waddr_i, csr_op_i, csr_wdata_i, csr_new_w);
        end
    end
    logic prev_ext_irq = 0;

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (external_irq_i && !prev_ext_irq) begin
                $display("[DEBUG @%0t] ---> IRQ PIN ASSERTED HIGH | MIE=%b | MEIE=%b",
                         $time, mstatus_mie_r, mie_meie_r);
            end else if (!external_irq_i && prev_ext_irq) begin
                $display("[DEBUG @%0t] ---> IRQ PIN DE-ASSERTED LOW", $time);
            end
            prev_ext_irq <= external_irq_i;

            if (mret_i) begin
                $display("\n[DEBUG @%0t] ---> MRET FIRED! MIE will become %b next cycle. PC returning to: %h",
                         $time, mstatus_mpie_r, mepc_r);
            end

            if (trap_i) begin
                $display("[DEBUG @%0t] ---> TRAP TAKEN! Pipeline sent cause: %0d", $time, trap_cause_i);
                $display("                  State right now -> external_irq_pin: %b, mstatus.MIE: %b, mie.MEIE: %b\n",
                         external_irq_i, mstatus_mie_r, mie_meie_r);
            end
        end
    end
`endif
    // synthesis translate_on
endmodule

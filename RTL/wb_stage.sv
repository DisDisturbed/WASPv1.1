`timescale 1ns / 1ps
`default_nettype none

// Takes core_pkg::mem_wb_bundle_t in. WB is the end of the pipeline (its
// outputs feed the register file / csr_file / hazard_unit directly, not
// another pipeline bundle), so its outputs stay individual signals -- only
// the input side collapses.
module WB_stage
    import core_pkg::*;
#(
    parameter int DATA_WIDTH    = core_pkg::CORE_DATA_WIDTH,
    parameter int RF_ADDR_WIDTH = core_pkg::CORE_RF_ADDR_WIDTH
)(
    input wire clk,
    input wire flush_i,
    input wire stall_i,

    input  mem_wb_bundle_t           mem_wb_i,

    output logic                     wb_rf_wen_o,
    output logic [RF_ADDR_WIDTH-1:0] wb_rf_waddr_o,
    output logic [DATA_WIDTH-1:0]    wb_rf_wdata_o,
    output logic [DATA_WIDTH-1:0]    wb_forward_data_o,
    output logic                     wb_trap_o,
    output logic [5:0]               wb_trap_cause_o,
    output logic [11:0]              wb_csr_addr_o,
    output csr_op_e                  wb_csr_op_o,
    output logic [DATA_WIDTH-1:0]    wb_csr_wdata_o,
    output logic                     wb_csr_access_o,
    output logic                     wb_csr_we_o,
    output logic                     wb_mret_o,
    output logic                     wb_retire_o     // one pulse per retired instruction (minstret)
);
    assign wb_retire_o     = mem_wb_i.valid      && !flush_i;
    always_comb begin : wb_mux
        case (mem_wb_i.wb_ctrl)
            WB_SEL_ALU_RESULT: wb_rf_wdata_o = mem_wb_i.alu_res;   // result
            WB_SEL_LOAD_DATA:  wb_rf_wdata_o = mem_wb_i.rdata;     // load data
            WB_SEL_PC_PLUS4:   wb_rf_wdata_o = mem_wb_i.pc_plus4;  // return addr
            default:           wb_rf_wdata_o = mem_wb_i.alu_res;
        endcase
    end
    assign wb_rf_wen_o   = mem_wb_i.reg_write && !flush_i;
    assign wb_rf_waddr_o = mem_wb_i.rd_addr;
    assign wb_forward_data_o = wb_rf_wdata_o;
    assign wb_trap_o       = mem_wb_i.trap       && !flush_i;
    assign wb_mret_o       = mem_wb_i.mret       && !flush_i;
    assign wb_csr_we_o     = mem_wb_i.csr_we     && !flush_i;
    assign wb_trap_cause_o = mem_wb_i.trap_cause;
    assign wb_csr_addr_o   = mem_wb_i.csr_addr;
    assign wb_csr_op_o     = mem_wb_i.csr_op;
    assign wb_csr_wdata_o  = mem_wb_i.csr_wdata;
    assign wb_csr_access_o = mem_wb_i.csr_access;
endmodule
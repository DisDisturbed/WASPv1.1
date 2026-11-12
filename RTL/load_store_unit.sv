`timescale 1ns / 1ps
`default_nettype none

// Takes the EX/MEM bundle directly and reads only its load/store fields.
// The data memory side is one obi_data_if.master port (see obi_if.sv).
module load_store_unit
    import core_pkg::*;
(
    obi_data_if.master  data_bus,

    input  ex_mem_bundle_t ex_mem_i,

    output logic [31:0] data_rdata_ex_o,
    input  wire          data_req_ex_i,

    output logic        lsu_trap_o,
    output logic [5:0]  lsu_trap_cause_o
);

    assign data_bus.addr = ex_mem_i.alu_res;

    logic misaligned;

    always_comb begin : detect_misalign
        case (ex_mem_i.mem_ctrl)
            3'b010:  misaligned = |data_bus.addr[1:0];  // Word (funct3 = 010): must be 4-byte aligned
            3'b001, 3'b101: misaligned =  data_bus.addr[0];    // Half (funct3 = 001 or 101): must be 2-byte aligned
            default: misaligned = 1'b0;                // Byte: always aligned
        endcase
    end


    always_comb begin : gen_trap
        if (ex_mem_i.trap) begin
            lsu_trap_o       = 1'b1;
            lsu_trap_cause_o = ex_mem_i.trap_cause;
        end else if (data_req_ex_i & misaligned) begin
            lsu_trap_o       = 1'b1;
            lsu_trap_cause_o = ex_mem_i.is_store ? TRAP_CAUSE_STORE_ADDR_MISALIGNED
                                                  : TRAP_CAUSE_LOAD_ADDR_MISALIGNED;
        end else begin
            lsu_trap_o       = 1'b0;
            lsu_trap_cause_o = 6'd0;
        end
    end





    logic access_ok;
    assign access_ok = data_req_ex_i & ~misaligned & ~ex_mem_i.trap;

    assign data_bus.req = access_ok;
    assign data_bus.we  = access_ok & ex_mem_i.is_store;


    logic [3:0] byte_type;

    always_comb begin : gen_strobe
        case (ex_mem_i.mem_ctrl)

            3'b010: byte_type = 4'b1111;

            3'b001, 3'b101: byte_type = data_bus.addr[1] ? 4'b1100 : 4'b0011;

            3'b000, 3'b100: begin
                case (data_bus.addr[1:0])
                    2'b00:   byte_type = 4'b0001;
                    2'b01:   byte_type = 4'b0010;
                    2'b10:   byte_type = 4'b0100;
                    default: byte_type = 4'b1000;
                endcase
            end

            default: byte_type = 4'b0000;
        endcase
    end

    assign data_bus.be = access_ok ? byte_type : 4'h0;


    always_comb begin : align_wdata
        data_bus.wdata = 32'h0;
        case (ex_mem_i.mem_ctrl)

            3'b010: data_bus.wdata = ex_mem_i.rs2_data;

            3'b001, 3'b101: begin
                data_bus.wdata = data_bus.addr[1]
                    ? {ex_mem_i.rs2_data[15:0], 16'h0000}
                    : {16'h0000, ex_mem_i.rs2_data[15:0]};
            end

            3'b000, 3'b100: begin
                case (data_bus.addr[1:0])
                    2'b00:   data_bus.wdata = {24'h0,               ex_mem_i.rs2_data[7:0]};
                    2'b01:   data_bus.wdata = {16'h0, ex_mem_i.rs2_data[7:0],  8'h0};
                    2'b10:   data_bus.wdata = { 8'h0, ex_mem_i.rs2_data[7:0], 16'h0};
                    default: data_bus.wdata = {ex_mem_i.rs2_data[7:0],        24'h0};
                endcase
            end

            default: data_bus.wdata = 32'h0;
        endcase
    end


    logic store_to_load_match;
    assign store_to_load_match = ex_mem_i.is_load && ex_mem_i.is_store &&
                                  (data_bus.addr == ex_mem_i.alu_res);



    always_comb begin : extract_rdata
        data_rdata_ex_o = 32'h0;
        case (ex_mem_i.mem_ctrl)

            3'b010: data_rdata_ex_o = data_bus.rdata;

            3'b001: begin
                data_rdata_ex_o = data_bus.addr[1]
                    ? {{16{data_bus.rdata[31]}}, data_bus.rdata[31:16]}
                    : {{16{data_bus.rdata[15]}}, data_bus.rdata[15:0]};
            end

            3'b101: begin
                data_rdata_ex_o = data_bus.addr[1]
                    ? {16'h0000, data_bus.rdata[31:16]}
                    : {16'h0000, data_bus.rdata[15:0]};
            end

            3'b000: begin
                case (data_bus.addr[1:0])
                    2'b00:   data_rdata_ex_o = {{24{data_bus.rdata[7]}},  data_bus.rdata[7:0]};
                    2'b01:   data_rdata_ex_o = {{24{data_bus.rdata[15]}}, data_bus.rdata[15:8]};
                    2'b10:   data_rdata_ex_o = {{24{data_bus.rdata[23]}}, data_bus.rdata[23:16]};
                    default: data_rdata_ex_o = {{24{data_bus.rdata[31]}}, data_bus.rdata[31:24]};
                endcase
            end

            3'b100: begin
                case (data_bus.addr[1:0])
                    2'b00:   data_rdata_ex_o = {24'h0, data_bus.rdata[7:0]};
                    2'b01:   data_rdata_ex_o = {24'h0, data_bus.rdata[15:8]};
                    2'b10:   data_rdata_ex_o = {24'h0, data_bus.rdata[23:16]};
                    default: data_rdata_ex_o = {24'h0, data_bus.rdata[31:24]};
                endcase
            end

            default: data_rdata_ex_o = 32'h0;
        endcase
        if (store_to_load_match) begin
        data_rdata_ex_o = ex_mem_i.rs2_data;
    end
    end


endmodule
`timescale 1ns / 1ps
`default_nettype none

// instr_addr_i/instr_en_i/instr_gnt_o/instr_rvalid_o/instr_rdata_o
// collapse into a single obi_instr_if.slave port. This is the slave side
// of the same interface Core_Top exposes as instr_bus.master -- in
// cache_system_top the two are connected to the SAME interface instance,
// so this module needs no changes beyond the port declaration and
// s/instr_*_i,o/instr_bus.*/ throughout the body.
module icache #(
    parameter int ADDR_WIDTH = 32,
    parameter int TAG_BITS   = ADDR_WIDTH - 12,
    parameter int LINE_SIZE  = 16              // words per cache line
)(
    input  wire        clk,
    input  wire        rst,

    // OBI instruction-memory slave port
    obi_instr_if.slave instr_bus,

    input  wire        flush_i,

    output logic       m_axi_arvalid,
    input  wire        m_axi_arready,
    output wire [31:0] m_axi_araddr,
    output logic [1:0] m_axi_arburst,

    input  wire [31:0] m_axi_rdata,
    input  wire        m_axi_rvalid
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_LOOKUP,
        S_SEND_ADDR,
        S_REFILL,
        S_SERVE
    } state_e;

    state_e state_r;
    state_e next_s;

    logic [31:0] req_addr_r;
    logic [3:0]  refill_cnt_r;
    logic [31:0] bypass_data_r;
    logic        suppress_r;
    wire redirect_w = instr_bus.req && (instr_bus.addr != req_addr_r);

    always_ff @(posedge clk) begin
        if (rst) begin
            state_r       <= S_IDLE;
            req_addr_r    <= '0;
            refill_cnt_r  <= 4'd0;
            bypass_data_r <= '0;
            suppress_r    <= 1'b0;
        end else begin
            state_r <= next_s;

            if (state_r == S_IDLE && instr_bus.req && !flush_i)
                req_addr_r <= instr_bus.addr;

            if (state_r == S_REFILL && m_axi_rvalid)
                refill_cnt_r <= refill_cnt_r + 1;
            else if (state_r == S_IDLE || next_s == S_SEND_ADDR)
                refill_cnt_r <= 4'd0;

            if (state_r == S_REFILL && m_axi_rvalid &&
                refill_cnt_r == req_addr_r[5:2])
                bypass_data_r <= m_axi_rdata;

            if ((flush_i || redirect_w) && state_r inside {S_LOOKUP, S_SEND_ADDR, S_REFILL, S_SERVE})
                suppress_r <= 1'b1;
            else if (state_r == S_SERVE || state_r == S_IDLE)
                suppress_r <= 1'b0;
        end
    end

    wire [5:0]  active_line_w =
        (state_r == S_IDLE)   ? instr_bus.addr[11:6] :
        (state_r == S_REFILL) ? req_addr_r[11:6]   :
                                req_addr_r[11:6];

    wire [3:0]  active_word_w =
        (state_r == S_IDLE)   ? instr_bus.addr[5:2] :
        (state_r == S_REFILL) ? refill_cnt_r       :
                                req_addr_r[5:2];

    wire [31:0] active_tag_addr_w =
        (state_r == S_IDLE) ? instr_bus.addr
                            : req_addr_r;

    logic tag_wr_en, tag_valid_in, data_wr_en;

    wire [21:0] tag_ram_out;
    wire        stored_valid_w  = tag_ram_out[20];
    wire [TAG_BITS-1:0] stored_tag_w = tag_ram_out[TAG_BITS-1:0];

    wire        tag_hit_w = stored_valid_w && (stored_tag_w == req_addr_r[31:12]);
    wire [31:0] ram_data_out;

    always_comb begin
        next_s          = state_r;
        instr_bus.gnt    = 1'b0;
        instr_bus.rvalid = 1'b0;
        instr_bus.rdata  = bypass_data_r;
        tag_wr_en      = 1'b0;
        tag_valid_in   = 1'b0;
        data_wr_en     = 1'b0;
        m_axi_arvalid  = 1'b0;
        m_axi_arburst  = 2'b01; // INCR

        unique case (state_r)
            S_IDLE: begin
                if (instr_bus.req && !flush_i)
                    next_s = S_LOOKUP;
            end

            S_LOOKUP: begin
                if (flush_i || redirect_w) begin
                    next_s = S_IDLE;
                end else if (tag_hit_w) begin
                    if (!suppress_r) begin
                        instr_bus.gnt    = 1'b1;
                        instr_bus.rvalid = 1'b1;
                        instr_bus.rdata  = ram_data_out;
                    end
                    next_s = S_IDLE;
                end else begin
                    next_s = S_SEND_ADDR;
                end
            end

            S_SEND_ADDR: begin
                m_axi_arvalid = 1'b1;
                if (m_axi_arready)
                    next_s = S_REFILL;
            end

            S_REFILL: begin
                if (m_axi_rvalid) begin
                    data_wr_en = 1'b1;
                    if (refill_cnt_r == LINE_SIZE - 1) begin
                        tag_wr_en    = 1'b1;
                        tag_valid_in = 1'b1;
                        next_s       = S_SERVE;
                    end
                end
            end

            S_SERVE: begin
                if (!suppress_r) begin
                    instr_bus.gnt    = 1'b1;
                    instr_bus.rvalid = 1'b1;
                    instr_bus.rdata  = bypass_data_r;
                end
                next_s = S_IDLE;
            end

            default: next_s = S_IDLE;
        endcase
    end

    assign m_axi_araddr = {req_addr_r[31:6], 6'b0};

    icache_data_ram #(
        .line_amount(64),
        .line_size  (LINE_SIZE),
        .data_width (32)
    ) u_data_ram (
        .clk_i            (clk),
        .data_req         (1'b1),
        .line_index_i     (active_line_w),
        .line_reg_index_i (active_word_w),
        .data_i           (m_axi_rdata),
        .wr_i             (data_wr_en),
        .data_o           (ram_data_out)
    );

    icache_tag_ram #(
        .TAG_COUNT  (64),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_tag_ram (
        .clk_i          (clk),
        .rst_i          (rst),
        .ins_addr_i     (active_tag_addr_w),
        .dirty_icache_in(1'b0),
        .valid_icache_in(tag_valid_in),
        .wr_i           (tag_wr_en),
        .tag_o          (tag_ram_out)
    );

endmodule
`default_nettype wire
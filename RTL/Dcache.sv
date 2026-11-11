`timescale 1ns / 1ps
`default_nettype none

// core_addr_i/core_req_i/core_we_i/core_wstrb_i/core_wdata_i/core_rdata_o/
// core_gnt_o/core_rvalid_o collapse into a single obi_data_if.slave port
// (core_bus). In cache_system_top this connects to a dedicated interface
// instance that's one leg of the core-data-bus arbiter (see
// obi_macros.svh) -- unlike icache's 1:1 share with Core_Top, dcache
// shares its master (the core) with PLIC, so its leg needs its own
// interface instance rather than reusing Core_Top's directly.
module dcache #(
    parameter int          ADDR_WIDTH         = 32,
    parameter int          DATA_WIDTH         = 32,
    parameter int          TAG_BITS           = ADDR_WIDTH - 12,
    parameter int          LINE_SIZE          = 16,
    parameter logic [31:0] FLUSH_CTRL_ADDR    = 32'hC0003000,
    // Only [CACHE_RANGE_LOWER, CACHE_RANGE_UPPER] is cached (DMEM); every
    // other address bypasses the cache and goes straight to the AXI bus.
    parameter logic [31:0] CACHE_RANGE_LOWER  = 32'h80000000,
    parameter logic [31:0] CACHE_RANGE_UPPER  = 32'h8000FFFF
)(
    input  wire clk,
    input  wire rst,

    // OBI data-memory slave port
    obi_data_if.slave core_bus,

    // FENCE.I: write back (and invalidate) every line. Accepted in IDLE when
    // the core has no request; flush_all_done_o pulses when the walk ends.
    input  wire        flush_all_req_i,
    output logic       flush_all_done_o,

    output logic        m_axi_awvalid,
    input  wire         m_axi_awready,
    output logic [31:0] m_axi_awaddr,
    output wire  [3:0]  m_axi_awid,
    output logic [7:0]  m_axi_awlen,
    output wire  [2:0]  m_axi_awsize,
    output wire  [1:0]  m_axi_awburst,

    output logic        m_axi_wvalid,
    input  wire         m_axi_wready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,

    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,
    input  wire [1:0]   m_axi_bresp,
    input  wire [3:0]   m_axi_bid,

    output logic        m_axi_arvalid,
    input  wire         m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output wire  [3:0]  m_axi_arid,
    output logic [7:0]  m_axi_arlen,
    output wire  [2:0]  m_axi_arsize,
    output wire  [1:0]  m_axi_arburst,

    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,
    input  wire [31:0]  m_axi_rdata,
    input  wire         m_axi_rlast,
    input  wire [1:0]   m_axi_rresp,
    input  wire [3:0]   m_axi_rid
);

    assign m_axi_awid    = 4'd0;
    assign m_axi_awsize  = 3'b010;
    assign m_axi_awburst = 2'b01;   // INCR
    assign m_axi_bready  = 1'b1;

    assign m_axi_arid    = 4'd0;
    assign m_axi_arsize  = 3'b010;
    assign m_axi_arburst = 2'b01;
    assign m_axi_rready  = 1'b1;

    typedef enum logic [3:0] {
        IDLE       = 4'd0,
        LOOKUP     = 4'd1,
        EVICT_ADDR = 4'd2,
        EVICT_DATA = 4'd3,
        WAIT_BRESP = 4'd4,
        FETCH_ADDR = 4'd5,
        REFILL     = 4'd6,
        COMMIT     = 4'd7,
        SERVE      = 4'd8,
        BP_WR_ADDR = 4'd9,
        BP_WR_DATA = 4'd10,
        BP_WR_RESP = 4'd11,
        FLUSH_NEXT = 4'd12,   // flush-all: tag read of the next line
        FLUSH_DONE = 4'd13    // flush-all finished
    } state_e;

    state_e state_r, next_s;

    logic [31:0]         req_addr_r;     // latched request address
    logic                req_we_r;       // 1 = write, 0 = read
    logic [3:0]          req_wstrb_r;    // byte strobe
    logic [31:0]         req_wdata_r;    // write data
    logic [TAG_BITS-1:0] evict_tag_r;    // tag of dirty line captured in LOOKUP
    logic [3:0]          burst_cnt_r;    // AXI burst beat index
    logic [31:0]         capture_data_r; // refill / bypass word served in SERVE
    logic                is_flush_r;     // this transaction is a cache flush
    logic [5:0]          flush_line_r;   // flush target line index (from wdata)
    logic                flush_all_r;    // walking all lines (FENCE.I)
    logic                err_r;          // AXI error (rresp/bresp != OKAY) on this access
    wire                 rresp_err_w = m_axi_rvalid && (m_axi_rresp != 2'b00);

    // A flush carries FLUSH_CTRL_ADDR (outside the cacheable range) in
    // req_addr_r but writes back a cached line: it must never take the
    // single-beat bypass address/length, or the 16-beat eviction hangs AXI.
    wire is_bypass_w = !is_flush_r &&
                       ((req_addr_r < CACHE_RANGE_LOWER) ||
                        (req_addr_r > CACHE_RANGE_UPPER));

    wire incoming_flush_w = core_bus.req &&
                            core_bus.we  &&
                            (core_bus.addr == FLUSH_CTRL_ADDR);

    wire [21:0]         tag_ram_out;
    wire                stored_dirty_w = tag_ram_out[21];
    wire                stored_valid_w = tag_ram_out[20];
    wire [TAG_BITS-1:0] stored_tag_w   = tag_ram_out[TAG_BITS-1:0];

    wire tag_hit_w = stored_valid_w && (stored_tag_w == req_addr_r[31:12]) && !is_bypass_w&&!is_flush_r;

    wire [5:0] target_line_w = is_flush_r ? flush_line_r : req_addr_r[11:6];

    logic [5:0]  active_line_w;
    logic [3:0]  active_word_w;
    logic [31:0] active_tag_addr_w;

    always_comb begin
        active_line_w     = target_line_w;
        active_word_w     = req_addr_r[5:2];
        active_tag_addr_w = is_flush_r
                            ? {req_addr_r[31:12], flush_line_r, 6'b0}
                            : req_addr_r;

        unique case (state_r)
            IDLE: begin
                if (incoming_flush_w) begin
                    active_line_w     = core_bus.wdata[11:6];
                    active_word_w     = core_bus.wdata[5:2]; // unused for flush
                    active_tag_addr_w = {core_bus.addr[31:12], core_bus.wdata[11:6], 6'b0};
                end else begin
                    active_line_w     = core_bus.addr[11:6];
                    active_word_w     = core_bus.addr[5:2];
                    active_tag_addr_w = core_bus.addr;
                end
            end

            EVICT_ADDR: begin
                active_line_w = target_line_w;
                active_word_w = 4'd0;
            end

            EVICT_DATA: begin
                active_line_w = target_line_w;
                active_word_w = m_axi_wready ? burst_cnt_r + 4'd1 : burst_cnt_r;
            end

            REFILL: begin
                active_line_w = target_line_w;
                active_word_w = burst_cnt_r;
            end

            default: ;
        endcase
    end

    logic        ram_wr_en;
    logic [3:0]  ram_wstrb;
    logic [31:0] ram_wdata;
    logic        tag_wr_en;
    logic        dirty_bit_in;
    logic        valid_bit_in;

    wire [31:0] ram_rdata_w;
    always_ff @(posedge clk) begin
        if (rst) begin
            state_r        <= IDLE;
            req_addr_r     <= '0;
            req_we_r       <= 1'b0;
            req_wstrb_r    <= 4'b0;
            req_wdata_r    <= '0;
            evict_tag_r    <= '0;
            burst_cnt_r    <= 4'd0;
            capture_data_r <= '0;
            is_flush_r     <= 1'b0;
            flush_line_r   <= 6'd0;
            flush_all_r    <= 1'b0;
            err_r          <= 1'b0;
        end else begin
            state_r <= next_s;

            if (state_r == IDLE && core_bus.req) begin
                req_addr_r   <= core_bus.addr;
                req_we_r     <= core_bus.we;
                req_wstrb_r  <= core_bus.be;
                req_wdata_r  <= core_bus.wdata;
                is_flush_r   <= incoming_flush_w;
                flush_line_r <= core_bus.wdata[11:6];
                err_r        <= 1'b0;
            end else if (state_r == IDLE && flush_all_req_i) begin
                // flush-all = the single-line flush, repeated for lines 0..63
                req_addr_r   <= FLUSH_CTRL_ADDR;
                req_we_r     <= 1'b1;
                is_flush_r   <= 1'b1;
                flush_all_r  <= 1'b1;
                flush_line_r <= 6'd0;
            end else if (next_s == FLUSH_NEXT) begin
                flush_line_r <= flush_line_r + 6'd1;
            end
            if (state_r == FLUSH_DONE) begin
                is_flush_r  <= 1'b0;
                flush_all_r <= 1'b0;
            end

            if ((state_r == REFILL && rresp_err_w) ||
                (state_r == BP_WR_RESP && m_axi_bvalid && m_axi_bresp != 2'b00))
                err_r <= 1'b1;

            if (state_r == LOOKUP && !tag_hit_w)
                evict_tag_r <= stored_tag_w;

            if ((state_r == REFILL     && m_axi_rvalid) ||
                (state_r == EVICT_DATA && m_axi_wready))
                burst_cnt_r <= burst_cnt_r + 1;
            else if (state_r == IDLE      ||
                     state_r == LOOKUP    ||
                     state_r == EVICT_ADDR ||
                     state_r == FETCH_ADDR)
                burst_cnt_r <= 4'd0;

            if (state_r == REFILL && m_axi_rvalid &&
                burst_cnt_r == req_addr_r[5:2])
                capture_data_r <= m_axi_rdata;

            if (state_r == REFILL && is_bypass_w && m_axi_rvalid)
                capture_data_r <= m_axi_rdata;
        end
    end

    always_comb begin
        next_s        = state_r;
        core_bus.gnt    = 1'b0;
        core_bus.rvalid = 1'b0;
        core_bus.rdata  = capture_data_r;
        core_bus.err    = 1'b0;
        flush_all_done_o = 1'b0;

        ram_wr_en     = 1'b0;
        ram_wstrb     = 4'b1111;
        ram_wdata     = m_axi_rdata;
        tag_wr_en     = 1'b0;
        dirty_bit_in  = 1'b0;
        valid_bit_in  = 1'b0;

        m_axi_arvalid = 1'b0;
        m_axi_araddr  = is_bypass_w
                        ? {req_addr_r[31:2], 2'b0}
                        : {req_addr_r[31:6], 6'b0};
        m_axi_arlen   = is_bypass_w ? 8'd0 : 8'd15;

        m_axi_awvalid = 1'b0;
        m_axi_awaddr  = is_bypass_w
                        ? {req_addr_r[31:2], 2'b0}
                        : {evict_tag_r, target_line_w, 6'b0};
        m_axi_awlen   = is_bypass_w ? 8'd0 : 8'd15;

        m_axi_wvalid  = 1'b0;
        m_axi_wlast   = 1'b0;
        m_axi_wdata   = ram_rdata_w;
        m_axi_wstrb   = 4'b1111;

        unique case (state_r)

            IDLE: begin
                if (core_bus.req)
                    next_s = LOOKUP;
                else if (flush_all_req_i)
                    next_s = FLUSH_NEXT;
            end

            FLUSH_NEXT: next_s = LOOKUP;

            FLUSH_DONE: begin
                flush_all_done_o = 1'b1;
                next_s           = IDLE;
            end

            LOOKUP: begin
                if (is_flush_r) begin
                    if (stored_valid_w && stored_dirty_w) begin
                        next_s = EVICT_ADDR;
                    end else begin
                        tag_wr_en    = 1'b1;
                        valid_bit_in = 1'b0;
                        dirty_bit_in = 1'b0;
                        next_s       = !flush_all_r          ? SERVE      :
                                       (flush_line_r == 6'd63) ? FLUSH_DONE : FLUSH_NEXT;
                    end

                end else if (is_bypass_w) begin
                    next_s = req_we_r ? BP_WR_ADDR : FETCH_ADDR;

                end else if (tag_hit_w) begin
                    if (req_we_r) begin
                        ram_wr_en    = 1'b1;
                        ram_wstrb    = req_wstrb_r;
                        ram_wdata    = req_wdata_r;
                        tag_wr_en    = 1'b1;
                        dirty_bit_in = 1'b1;
                        valid_bit_in = 1'b1;
                    end
                    core_bus.rdata  = ram_rdata_w;
                    core_bus.gnt    = 1'b1;
                    core_bus.rvalid = 1'b1;
                    next_s        = IDLE;

                end else begin
                    if (stored_valid_w && stored_dirty_w)
                        next_s = EVICT_ADDR;
                    else
                        next_s = FETCH_ADDR;
                end
            end

            EVICT_ADDR: begin
                m_axi_awvalid = 1'b1;
                if (m_axi_awready)
                    next_s = EVICT_DATA;
            end

            EVICT_DATA: begin
                m_axi_wvalid = 1'b1;
                m_axi_wlast  = (burst_cnt_r == 4'd15);

                if (m_axi_wready && (burst_cnt_r == 4'd15))
                    next_s = WAIT_BRESP;
            end

            WAIT_BRESP: begin
                if (m_axi_bvalid) begin
                    if (is_flush_r) begin
                        tag_wr_en    = 1'b1;
                        valid_bit_in = 1'b0;
                        dirty_bit_in = 1'b0;
                        next_s       = !flush_all_r          ? SERVE      :
                                       (flush_line_r == 6'd63) ? FLUSH_DONE : FLUSH_NEXT;
                    end else begin
                        next_s = FETCH_ADDR;
                    end
                end
            end

            FETCH_ADDR: begin
                m_axi_arvalid = 1'b1;
                if (m_axi_arready)
                    next_s = REFILL;
            end

            REFILL: begin
                if (m_axi_rvalid) begin
                    ram_wr_en = !is_bypass_w;
                    ram_wstrb = 4'b1111;
                    ram_wdata = m_axi_rdata;

                    if (m_axi_rlast) begin
                        if (!is_bypass_w) begin
                            // a refill that saw an AXI error is not cached
                            tag_wr_en    = 1'b1;
                            valid_bit_in = !(err_r || rresp_err_w);
                            dirty_bit_in = 1'b0;
                        end
                        next_s = (req_we_r && !(err_r || rresp_err_w)) ? COMMIT : SERVE;
                    end
                end
            end

            COMMIT: begin
                ram_wr_en    = 1'b1;
                ram_wstrb    = req_wstrb_r;
                ram_wdata    = req_wdata_r;
                tag_wr_en    = 1'b1;
                dirty_bit_in = 1'b1;
                valid_bit_in = 1'b1;
                next_s       = SERVE;
            end

            SERVE: begin
                core_bus.gnt    = 1'b1;
                core_bus.rvalid = 1'b1;
                core_bus.rdata  = capture_data_r;
                core_bus.err    = err_r;   // load/store access fault
                next_s        = IDLE;
            end

            BP_WR_ADDR: begin
                m_axi_awvalid = 1'b1;
                if (m_axi_awready)
                    next_s = BP_WR_DATA;
            end

            BP_WR_DATA: begin
                m_axi_wvalid = 1'b1;
                m_axi_wlast  = 1'b1;
                m_axi_wdata  = req_wdata_r;
                m_axi_wstrb  = req_wstrb_r;
                if (m_axi_wready)
                    next_s = BP_WR_RESP;
            end

            BP_WR_RESP: begin
                if (m_axi_bvalid)
                    next_s = SERVE;
            end

            default: next_s = IDLE;
        endcase
    end

    dcache_data_ram u_data_ram (
        .clk_i     (clk),
        .req_i     (1'b1),
        .rst       (rst),
        .wr_en     (ram_wr_en),
        .wstrb_i   (ram_wstrb),
        .line_idx_i(active_line_w),
        .word_idx_i(active_word_w),
        .wdata_i   (ram_wdata),
        .rdata_o   (ram_rdata_w)
    );
    dcache_tag_ram u_tag_ram (
        .clk_i   (clk),
        .rst_i   (rst),
        .addr_i  (active_tag_addr_w),
        .dirty_in(dirty_bit_in),
        .valid_in(valid_bit_in),
        .wr_en   (tag_wr_en),
        .tag_o   (tag_ram_out)
    );
    logic [31:0] perf_hits_r;
    logic [31:0] perf_misses_r;
    logic [31:0] perf_evictions_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            perf_hits_r      <= '0;
            perf_misses_r    <= '0;
            perf_evictions_r <= '0;
        end else begin
            if (state_r == LOOKUP && !is_flush_r && !is_bypass_w) begin
                if (tag_hit_w) perf_hits_r   <= perf_hits_r   + 1;
                else           perf_misses_r <= perf_misses_r + 1;
            end
            if (state_r == EVICT_ADDR && m_axi_awready)
                perf_evictions_r <= perf_evictions_r + 1;
        end
    end

endmodule
`default_nettype wire
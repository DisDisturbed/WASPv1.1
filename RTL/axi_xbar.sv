`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// axi_xbar
//
// AXI4 crossbar: S_COUNT slave ports (one per master: I-cache, D-cache, ...)
// to M_COUNT master ports (one per slave: memories, UART, spare slots).
//
// Rules it is built on:
//   * One read burst and one write burst in flight per master. A second AR/AW
//     of the same master waits until the first burst has finished.
//   * A slave serves one read burst and one write burst at a time; reads and
//     writes are independent.
//   * Fixed priority, lowest slave-port index first (I-cache > D-cache > ...).
//   * No added latency: once a master holds a slave, all five channels pass
//     straight through. Only the routing state is registered.
//   * IDs are passed through unchanged; routing never looks at them.
//   * An address that matches no present slave is answered here with DECERR
//     (the burst is accepted and completed, so the master never hangs).
//
// Address map: slave m owns the addresses whose bits above M_ADDR_WIDTH[m]
// equal those of M_BASE_ADDR[m]. A port with M_PRESENT[m] = 0 has no slave
// attached and is never selected. The full address is passed on unchanged.
//
// Packed-array parameters list port 0 last: {port M_COUNT-1, ..., port 0}.
//
// clk and rst_n are taken from s_axi[0].
// =============================================================================
module axi_xbar
    import axi_pkg::*;
#(
    parameter int S_COUNT = 2,
    parameter int M_COUNT = 6,
    parameter logic [M_COUNT-1:0][AXI_ADDR_WIDTH-1:0] M_BASE_ADDR  = '0,
    parameter logic [M_COUNT-1:0][31:0]               M_ADDR_WIDTH = '0,
    parameter logic [M_COUNT-1:0]                     M_PRESENT    = '1
)(
    axi_if.slave  s_axi [S_COUNT],
    axi_if.master m_axi [M_COUNT]
);

    localparam int S_IDX_W = (S_COUNT > 1) ? $clog2(S_COUNT) : 1;
    localparam int M_IDX_W = (M_COUNT > 1) ? $clog2(M_COUNT) : 1;

    wire clk   = s_axi[0].clk;
    wire rst_n = s_axi[0].rst_n;

    // -------------------------------------------------------------------------
    // Interface arrays cannot be indexed with a run-time value, so every port
    // is first copied into plain arrays; all routing below works on those.
    // -------------------------------------------------------------------------
    axi_ax_t [S_COUNT-1:0] s_aw, s_ar;
    axi_w_t  [S_COUNT-1:0] s_w;
    axi_b_t  [S_COUNT-1:0] s_b;
    axi_r_t  [S_COUNT-1:0] s_r;
    logic    [S_COUNT-1:0] s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready;
    logic    [S_COUNT-1:0] s_arvalid, s_arready, s_rvalid, s_rready;

    axi_ax_t [M_COUNT-1:0] m_aw, m_ar;
    axi_w_t  [M_COUNT-1:0] m_w;
    axi_b_t  [M_COUNT-1:0] m_b;
    axi_r_t  [M_COUNT-1:0] m_r;
    logic    [M_COUNT-1:0] m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
    logic    [M_COUNT-1:0] m_arvalid, m_arready, m_rvalid, m_rready;

    for (genvar s = 0; s < S_COUNT; s++) begin : gen_s_port
        assign s_aw[s].id    = s_axi[s].awid;
        assign s_aw[s].addr  = s_axi[s].awaddr;
        assign s_aw[s].len   = s_axi[s].awlen;
        assign s_aw[s].size  = s_axi[s].awsize;
        assign s_aw[s].burst = s_axi[s].awburst;
        assign s_awvalid[s]  = s_axi[s].awvalid;
        assign s_axi[s].awready = s_awready[s];

        assign s_w[s].data   = s_axi[s].wdata;
        assign s_w[s].strb   = s_axi[s].wstrb;
        assign s_w[s].last   = s_axi[s].wlast;
        assign s_wvalid[s]   = s_axi[s].wvalid;
        assign s_axi[s].wready = s_wready[s];

        assign s_axi[s].bid    = s_b[s].id;
        assign s_axi[s].bresp  = s_b[s].resp;
        assign s_axi[s].bvalid = s_bvalid[s];
        assign s_bready[s]     = s_axi[s].bready;

        assign s_ar[s].id    = s_axi[s].arid;
        assign s_ar[s].addr  = s_axi[s].araddr;
        assign s_ar[s].len   = s_axi[s].arlen;
        assign s_ar[s].size  = s_axi[s].arsize;
        assign s_ar[s].burst = s_axi[s].arburst;
        assign s_arvalid[s]  = s_axi[s].arvalid;
        assign s_axi[s].arready = s_arready[s];

        assign s_axi[s].rid    = s_r[s].id;
        assign s_axi[s].rdata  = s_r[s].data;
        assign s_axi[s].rresp  = s_r[s].resp;
        assign s_axi[s].rlast  = s_r[s].last;
        assign s_axi[s].rvalid = s_rvalid[s];
        assign s_rready[s]     = s_axi[s].rready;
    end

    for (genvar m = 0; m < M_COUNT; m++) begin : gen_m_port
        assign m_axi[m].awid    = m_aw[m].id;
        assign m_axi[m].awaddr  = m_aw[m].addr;
        assign m_axi[m].awlen   = m_aw[m].len;
        assign m_axi[m].awsize  = m_aw[m].size;
        assign m_axi[m].awburst = m_aw[m].burst;
        assign m_axi[m].awvalid = m_awvalid[m];
        assign m_awready[m]     = m_axi[m].awready;

        assign m_axi[m].wdata   = m_w[m].data;
        assign m_axi[m].wstrb   = m_w[m].strb;
        assign m_axi[m].wlast   = m_w[m].last;
        assign m_axi[m].wvalid  = m_wvalid[m];
        assign m_wready[m]      = m_axi[m].wready;

        assign m_b[m].id        = m_axi[m].bid;
        assign m_b[m].resp      = m_axi[m].bresp;
        assign m_bvalid[m]      = m_axi[m].bvalid;
        assign m_axi[m].bready  = m_bready[m];

        assign m_axi[m].arid    = m_ar[m].id;
        assign m_axi[m].araddr  = m_ar[m].addr;
        assign m_axi[m].arlen   = m_ar[m].len;
        assign m_axi[m].arsize  = m_ar[m].size;
        assign m_axi[m].arburst = m_ar[m].burst;
        assign m_axi[m].arvalid = m_arvalid[m];
        assign m_arready[m]     = m_axi[m].arready;

        assign m_r[m].id        = m_axi[m].rid;
        assign m_r[m].data      = m_axi[m].rdata;
        assign m_r[m].resp      = m_axi[m].rresp;
        assign m_r[m].last      = m_axi[m].rlast;
        assign m_rvalid[m]      = m_axi[m].rvalid;
        assign m_axi[m].rready  = m_rready[m];
    end

    // -------------------------------------------------------------------------
    // Address decode
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic               hit;    // a present slave owns the address
        logic [M_IDX_W-1:0] idx;    // which one
    } dec_t;

    function automatic dec_t decode(input logic [AXI_ADDR_WIDTH-1:0] addr);
        decode = '0;
        for (int m = 0; m < M_COUNT; m++) begin
            if (M_PRESENT[m] &&
                ((addr >> M_ADDR_WIDTH[m]) == (M_BASE_ADDR[m] >> M_ADDR_WIDTH[m]))) begin
                decode.hit = 1'b1;
                decode.idx = M_IDX_W'(m);
            end
        end
    endfunction

    // =========================================================================
    // Read: AR -> R
    // =========================================================================
    // per master
    logic [S_COUNT-1:0]               rd_busy_r;    // a read burst is in flight
    logic [S_COUNT-1:0]               rd_err_r;     // ... and it is answered here (DECERR)
    logic [S_COUNT-1:0][M_IDX_W-1:0]  rd_sel_r;     // ... or by this slave
    logic [S_COUNT-1:0][AXI_ID_WIDTH-1:0] rd_id_r;  // DECERR: id and beats left - 1
    logic [S_COUNT-1:0][7:0]          rd_cnt_r;
    // per slave: an AR that was offered but not taken yet must not change
    logic [M_COUNT-1:0]               ar_lock_r;
    logic [M_COUNT-1:0][S_IDX_W-1:0]  ar_lock_mst_r;

    dec_t [S_COUNT-1:0]               ar_dec;
    logic [S_COUNT-1:0]               ar_req;       // master has a new AR to place
    logic [M_COUNT-1:0]               m_rd_busy;    // slave is serving a read burst
    logic [M_COUNT-1:0][S_IDX_W-1:0]  m_rd_own;     // ... of this master
    logic [M_COUNT-1:0]               ar_gnt_vld;
    logic [M_COUNT-1:0][S_IDX_W-1:0]  ar_gnt;

    always_comb begin
        for (int s = 0; s < S_COUNT; s++) begin
            ar_dec[s] = decode(s_ar[s].addr);
            ar_req[s] = s_arvalid[s] && !rd_busy_r[s];
        end

        for (int m = 0; m < M_COUNT; m++) begin
            m_rd_busy[m] = 1'b0;
            m_rd_own[m]  = '0;
            for (int s = 0; s < S_COUNT; s++) begin
                if (rd_busy_r[s] && !rd_err_r[s] && rd_sel_r[s] == M_IDX_W'(m)) begin
                    m_rd_busy[m] = 1'b1;
                    m_rd_own[m]  = S_IDX_W'(s);
                end
            end

            // fixed priority: lowest index wins (loop runs high to low)
            ar_gnt_vld[m] = 1'b0;
            ar_gnt[m]     = '0;
            for (int s = S_COUNT - 1; s >= 0; s--) begin
                if (ar_req[s] && ar_dec[s].hit && ar_dec[s].idx == M_IDX_W'(m)) begin
                    ar_gnt_vld[m] = 1'b1;
                    ar_gnt[m]     = S_IDX_W'(s);
                end
            end
            if (ar_lock_r[m]) begin
                ar_gnt_vld[m] = ar_req[ar_lock_mst_r[m]];
                ar_gnt[m]     = ar_lock_mst_r[m];
            end

            m_arvalid[m] = ar_gnt_vld[m] && !m_rd_busy[m];
            m_ar[m]      = s_ar[ar_gnt[m]];
            m_rready[m]  = m_rd_busy[m] && s_rready[m_rd_own[m]];
        end

        for (int s = 0; s < S_COUNT; s++) begin
            if (!ar_dec[s].hit)
                s_arready[s] = ar_req[s];                       // taken here, DECERR follows
            else
                s_arready[s] = ar_req[s] &&
                               m_arvalid[ar_dec[s].idx] && m_arready[ar_dec[s].idx] &&
                               (ar_gnt[ar_dec[s].idx] == S_IDX_W'(s));

            if (rd_busy_r[s] && rd_err_r[s]) begin
                s_rvalid[s]  = 1'b1;
                s_r[s].id    = rd_id_r[s];
                s_r[s].data  = '0;
                s_r[s].resp  = AXI_RESP_DECERR;
                s_r[s].last  = (rd_cnt_r[s] == 8'd0);
            end else begin
                s_rvalid[s]  = rd_busy_r[s] && m_rvalid[rd_sel_r[s]];
                s_r[s]       = m_r[rd_sel_r[s]];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_busy_r     <= '0;
            rd_err_r      <= '0;
            rd_sel_r      <= '0;
            rd_id_r       <= '0;
            rd_cnt_r      <= '0;
            ar_lock_r     <= '0;
            ar_lock_mst_r <= '0;
        end else begin
            for (int s = 0; s < S_COUNT; s++) begin
                if (s_arvalid[s] && s_arready[s]) begin
                    rd_busy_r[s] <= 1'b1;
                    rd_err_r[s]  <= !ar_dec[s].hit;
                    rd_sel_r[s]  <= ar_dec[s].idx;
                    rd_id_r[s]   <= s_ar[s].id;
                    rd_cnt_r[s]  <= s_ar[s].len;
                end else if (s_rvalid[s] && s_rready[s]) begin
                    rd_cnt_r[s] <= rd_cnt_r[s] - 8'd1;
                    if (s_r[s].last)
                        rd_busy_r[s] <= 1'b0;
                end
            end
            for (int m = 0; m < M_COUNT; m++) begin
                ar_lock_r[m]     <= m_arvalid[m] && !m_arready[m];
                ar_lock_mst_r[m] <= ar_gnt[m];
            end
        end
    end

    // =========================================================================
    // Write: AW -> W -> B
    // =========================================================================
    // per master
    logic [S_COUNT-1:0]               wr_busy_r;    // a write burst is in flight
    logic [S_COUNT-1:0]               wr_err_r;     // ... and it is answered here (DECERR)
    logic [S_COUNT-1:0][M_IDX_W-1:0]  wr_sel_r;     // ... or by this slave
    logic [S_COUNT-1:0][AXI_ID_WIDTH-1:0] wr_id_r;  // DECERR: id for the response
    logic [S_COUNT-1:0]               wr_wdone_r;   // last W beat has been passed on
    // per slave
    logic [M_COUNT-1:0]               aw_lock_r;
    logic [M_COUNT-1:0][S_IDX_W-1:0]  aw_lock_mst_r;

    dec_t [S_COUNT-1:0]               aw_dec;
    logic [S_COUNT-1:0]               aw_req;
    logic [M_COUNT-1:0]               m_wr_busy;
    logic [M_COUNT-1:0][S_IDX_W-1:0]  m_wr_own;
    logic [M_COUNT-1:0]               aw_gnt_vld;
    logic [M_COUNT-1:0][S_IDX_W-1:0]  aw_gnt;

    always_comb begin
        for (int s = 0; s < S_COUNT; s++) begin
            aw_dec[s] = decode(s_aw[s].addr);
            aw_req[s] = s_awvalid[s] && !wr_busy_r[s];
        end

        for (int m = 0; m < M_COUNT; m++) begin
            m_wr_busy[m] = 1'b0;
            m_wr_own[m]  = '0;
            for (int s = 0; s < S_COUNT; s++) begin
                if (wr_busy_r[s] && !wr_err_r[s] && wr_sel_r[s] == M_IDX_W'(m)) begin
                    m_wr_busy[m] = 1'b1;
                    m_wr_own[m]  = S_IDX_W'(s);
                end
            end

            aw_gnt_vld[m] = 1'b0;
            aw_gnt[m]     = '0;
            for (int s = S_COUNT - 1; s >= 0; s--) begin
                if (aw_req[s] && aw_dec[s].hit && aw_dec[s].idx == M_IDX_W'(m)) begin
                    aw_gnt_vld[m] = 1'b1;
                    aw_gnt[m]     = S_IDX_W'(s);
                end
            end
            if (aw_lock_r[m]) begin
                aw_gnt_vld[m] = aw_req[aw_lock_mst_r[m]];
                aw_gnt[m]     = aw_lock_mst_r[m];
            end

            m_awvalid[m] = aw_gnt_vld[m] && !m_wr_busy[m];
            m_aw[m]      = s_aw[aw_gnt[m]];

            m_wvalid[m]  = m_wr_busy[m] && !wr_wdone_r[m_wr_own[m]] && s_wvalid[m_wr_own[m]];
            m_w[m]       = s_w[m_wr_own[m]];
            m_bready[m]  = m_wr_busy[m] && s_bready[m_wr_own[m]];
        end

        for (int s = 0; s < S_COUNT; s++) begin
            if (!aw_dec[s].hit)
                s_awready[s] = aw_req[s];
            else
                s_awready[s] = aw_req[s] &&
                               m_awvalid[aw_dec[s].idx] && m_awready[aw_dec[s].idx] &&
                               (aw_gnt[aw_dec[s].idx] == S_IDX_W'(s));

            // W is only taken once the AW has been placed
            s_wready[s] = wr_busy_r[s] && !wr_wdone_r[s] &&
                          (wr_err_r[s] || m_wready[wr_sel_r[s]]);

            if (wr_err_r[s]) begin
                s_bvalid[s]  = wr_busy_r[s] && wr_wdone_r[s];
                s_b[s].id    = wr_id_r[s];
                s_b[s].resp  = AXI_RESP_DECERR;
            end else begin
                s_bvalid[s]  = wr_busy_r[s] && m_bvalid[wr_sel_r[s]];
                s_b[s]       = m_b[wr_sel_r[s]];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_busy_r     <= '0;
            wr_err_r      <= '0;
            wr_sel_r      <= '0;
            wr_id_r       <= '0;
            wr_wdone_r    <= '0;
            aw_lock_r     <= '0;
            aw_lock_mst_r <= '0;
        end else begin
            for (int s = 0; s < S_COUNT; s++) begin
                if (s_awvalid[s] && s_awready[s]) begin
                    wr_busy_r[s]  <= 1'b1;
                    wr_err_r[s]   <= !aw_dec[s].hit;
                    wr_sel_r[s]   <= aw_dec[s].idx;
                    wr_id_r[s]    <= s_aw[s].id;
                    wr_wdone_r[s] <= 1'b0;
                end else begin
                    if (s_wvalid[s] && s_wready[s] && s_w[s].last)
                        wr_wdone_r[s] <= 1'b1;
                    if (s_bvalid[s] && s_bready[s])
                        wr_busy_r[s] <= 1'b0;
                end
            end
            for (int m = 0; m < M_COUNT; m++) begin
                aw_lock_r[m]     <= m_awvalid[m] && !m_awready[m];
                aw_lock_mst_r[m] <= aw_gnt[m];
            end
        end
    end

endmodule

`default_nettype wire

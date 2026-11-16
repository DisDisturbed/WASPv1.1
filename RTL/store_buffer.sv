`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// store_buffer - DEPTH-entry in-order store buffer between MEM_stage and the
// core's data bus (OBI slave towards the LSU, OBI master towards the system)
//
// Which stores are buffered
//   Only stores to the bufferable ranges BUF0 / BUF1 (normal memory: DMEM in
//   WASP, DMEM + SHARED in WASP_SoC). They are granted at once (gnt + rvalid,
//   no error), so the store retires without waiting for the memory. Stores
//   anywhere else (peripherals, IMEM, the flush register, unmapped addresses)
//   are NOT buffered: they wait until the buffer is empty and then go out as
//   before, so their access faults stay precise and devices see them in order.
//   A bus error on a buffered store cannot trap any more (the store has
//   retired): it sets err_o (sticky) and prints an error in simulation.
//
// Loads
//   * to a bufferable range, no buffered byte overlaps: go out at once, past
//     the buffered stores (store -> load reordering to other addresses)
//   * every byte is in the buffer: answered from the buffer (youngest store
//     per byte), no bus access
//   * partly in the buffer: wait until the overlapping entries have drained
//   * anywhere else: wait until the buffer is empty (device ordering)
//
// Draining: one entry at a time, oldest first, whenever the bus is free.
// Loads get the bus first unless the buffer is almost full.
// empty_o: no entry and no drained store still waiting for its response.
// FENCE / FENCE.I wait for empty_o in MEM_stage.
//
// One bus transaction at a time towards the system: a new request is only
// presented once the previous one got its gnt and (if separate) its rvalid.
// DEPTH = 0 turns the buffer off (every access is passed through in order).
// =============================================================================
module store_buffer #(
    parameter int          DEPTH     = 16,
    parameter logic [31:0] BUF0_BASE = 32'h8000_0000,
    parameter logic [31:0] BUF0_SIZE = 32'h0001_0000,   // 0 = range not used
    parameter logic [31:0] BUF1_BASE = 32'h0000_0000,
    parameter logic [31:0] BUF1_SIZE = 32'h0000_0000
)(
    input  wire  clk,
    input  wire  rst_n,

    obi_data_if.slave  core,     // from MEM_stage
    obi_data_if.master mem,      // to the data bus

    output logic empty_o,
    output logic err_o           // a buffered store got a bus error (sticky)
);

    localparam int D  = (DEPTH > 0) ? DEPTH : 1;
    localparam int PW = (D > 1) ? $clog2(D) : 1;
    localparam int CW = $clog2(D + 1);

    function automatic logic in_rng(logic [31:0] a, logic [31:0] base, logic [31:0] size);
        return (size != 0) && (a >= base) && (a - base < size);
    endfunction

    // ---------------------------------------------------------------- entries
    logic [29:0]   e_wa [D];           // word address
    logic [3:0]    e_be [D];
    logic [31:0]   e_wd [D];           // lane-aligned data
    logic [PW-1:0] head_q, tail_q;
    logic [CW-1:0] cnt_q;

    wire full = (cnt_q == CW'(D));

    // ---------------------------------------------------------------- upstream request
    wire        u_buf_rng = (DEPTH > 0) && (in_rng(core.addr, BUF0_BASE, BUF0_SIZE) ||
                                            in_rng(core.addr, BUF1_BASE, BUF1_SIZE));
    wire [29:0] u_word    = core.addr[31:2];

    // bytes of the upstream word held in the buffer (youngest store per byte)
    logic [3:0]  fwd_cov;
    logic [31:0] fwd_data;
    always_comb begin
        logic [PW-1:0] k;
        fwd_cov  = '0;
        fwd_data = '0;
        for (int i = 0; i < D; i++) begin                  // oldest -> youngest
            k = PW'((int'(head_q) + i) % D);
            if (CW'(i) < cnt_q && e_wa[k] == u_word)
                for (int b = 0; b < 4; b++)
                    if (e_be[k][b]) begin
                        fwd_cov[b]          = 1'b1;
                        fwd_data[b*8 +: 8]  = e_wd[k][b*8 +: 8];
                    end
        end
    end

    wire u_ovl      = |(fwd_cov & core.be);
    wire u_full_cov = ((fwd_cov & core.be) == core.be);

    // ---------------------------------------------------------------- bus port
    typedef enum logic [1:0] { OWN_NONE, OWN_PT, OWN_DR } own_e;
    own_e own_q;                  // request presented, gnt not seen yet
    logic out_q, out_pt_q;        // gnt seen, rvalid not yet (pass-through / drain)

    wire port_free = (own_q == OWN_NONE) && !out_q;
    assign empty_o = (cnt_q == '0) && (own_q != OWN_DR) && !(out_q && !out_pt_q);

    // classify the upstream request
    wire u_st_buf  = core.req &&  core.we && u_buf_rng;                       // buffered store
    wire u_ld_fwd  = core.req && !core.we && u_buf_rng && u_ovl && u_full_cov; // answered from the buffer
    wire u_pt_ok   = core.req && ( (!core.we && u_buf_rng && !u_ovl) ||        // load past the buffer
                                   (!u_buf_rng && empty_o) );                  // anything else, in order

    wire drain_first = (cnt_q >= CW'((D > 2) ? D - 2 : D));                  // almost full: drain first
    logic pt_sel, dr_sel;
    always_comb begin
        pt_sel = 1'b0;
        dr_sel = 1'b0;
        if (own_q == OWN_PT)        pt_sel = 1'b1;           // keep a presented request
        else if (own_q == OWN_DR)   dr_sel = 1'b1;
        else if (port_free) begin
            if (cnt_q != '0 && (drain_first || !u_pt_ok)) dr_sel = 1'b1;
            else if (u_pt_ok)                             pt_sel = 1'b1;
        end
    end

    // byte offset of a buffered store = its lowest enabled byte (entries are
    // never merged, so be is one naturally aligned 1/2/4-byte run): drained
    // stores carry the same byte address the core used, so slaves that size
    // the access from addr + be (WASP_SoC's bridge) see the original store
    function automatic logic [1:0] be_off(logic [3:0] be);
        if (be[0]) return 2'd0;
        if (be[1]) return 2'd1;
        if (be[2]) return 2'd2;
        return 2'd3;
    endfunction

    always_comb begin
        mem.req   = pt_sel | dr_sel;
        mem.addr  = pt_sel ? core.addr  : {e_wa[head_q], be_off(e_be[head_q])};
        mem.we    = pt_sel ? core.we    : 1'b1;
        mem.be    = pt_sel ? core.be    : e_be[head_q];
        mem.wdata = pt_sel ? core.wdata : e_wd[head_q];
    end

    // ---------------------------------------------------------------- upstream answers
    wire st_accept = u_st_buf && !full;
    wire pt_rvalid = (pt_sel || (out_q && out_pt_q)) && mem.rvalid;
    wire dr_rvalid = (dr_sel || (out_q && !out_pt_q)) && mem.rvalid;

    always_comb begin
        core.gnt    = st_accept | u_ld_fwd | (pt_sel & mem.gnt);
        core.rvalid = st_accept | u_ld_fwd | pt_rvalid;
        core.rdata  = u_ld_fwd ? fwd_data : mem.rdata;
        core.err    = pt_rvalid & mem.err;
    end

    // ---------------------------------------------------------------- state
    wire pop = dr_sel && mem.gnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q   <= '0;
            tail_q   <= '0;
            cnt_q    <= '0;
            own_q    <= OWN_NONE;
            out_q    <= 1'b0;
            out_pt_q <= 1'b0;
            err_o    <= 1'b0;
        end else begin
            if (st_accept) begin
                e_wa[tail_q] <= u_word;
                e_be[tail_q] <= core.be;
                e_wd[tail_q] <= core.wdata;
                tail_q       <= (int'(tail_q) == D - 1) ? '0 : tail_q + 1'b1;
            end
            if (pop) head_q <= (int'(head_q) == D - 1) ? '0 : head_q + 1'b1;
            cnt_q <= cnt_q + CW'(st_accept) - CW'(pop);

            // bus port
            if (mem.req && !mem.gnt)      own_q <= pt_sel ? OWN_PT : OWN_DR;
            else if (mem.req && mem.gnt)  own_q <= OWN_NONE;
            if (mem.req && mem.gnt && !mem.rvalid) begin
                out_q    <= 1'b1;
                out_pt_q <= pt_sel;
            end else if (out_q && mem.rvalid) begin
                out_q    <= 1'b0;
            end

            if (dr_rvalid && mem.err) err_o <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- checks (sim)
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n && dr_rvalid && mem.err)
            $error("store_buffer: buffered store to %h got a bus error (imprecise, store already retired)",
                   mem.addr);
        if (rst_n && st_accept && full)
            $error("store_buffer: push into a full buffer");
    end
    // synthesis translate_on

endmodule

`default_nettype wire

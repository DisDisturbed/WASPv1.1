`timescale 1ns / 1ps
`default_nettype none

// Direct-mapped instruction cache: 64 lines of LINE_SIZE words.
// Core side: OBI slave (the same obi_instr_if instance Core_Top drives).
// Memory side: read-only AXI4 master, one INCR burst of LINE_SIZE words per
// refill.
module icache #(
    parameter int ADDR_WIDTH = 32,
    parameter int TAG_BITS   = ADDR_WIDTH - 12,
    parameter int LINE_SIZE  = 16,             // words per cache line
    // Executable regions (instruction access fault outside them). Fetches
    // anywhere else are answered with err and never reach AXI, where a
    // decode error would wedge the crossbar.
    parameter logic [31:0] EXEC0_BASE       = 32'h4000_0000,  // IMEM
    parameter int          EXEC0_ADDR_WIDTH = 16,
    parameter logic [31:0] EXEC1_BASE       = 32'h8000_0000,  // DMEM (code loaded / generated at run time)
    parameter int          EXEC1_ADDR_WIDTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // OBI instruction-memory slave port
    obi_instr_if.slave instr_bus,

    input  wire        flush_i,       // drop the in-flight request
    input  wire        invalidate_i,  // FENCE.I: invalidate every line (1 cycle)

    // AXI4 read master (refills)
    axi_if.master_rd   m_axi
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
    logic        inv_pending_r;   // invalidate arrived during a refill: do not validate that line
    wire redirect_w = instr_bus.req && (instr_bus.addr != req_addr_r);

    wire exec_ok_w = ((req_addr_r >> EXEC0_ADDR_WIDTH) == (EXEC0_BASE >> EXEC0_ADDR_WIDTH)) ||
                     ((req_addr_r >> EXEC1_ADDR_WIDTH) == (EXEC1_BASE >> EXEC1_ADDR_WIDTH));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r       <= S_IDLE;
            req_addr_r    <= '0;
            refill_cnt_r  <= 4'd0;
            bypass_data_r <= '0;
            suppress_r    <= 1'b0;
            inv_pending_r <= 1'b0;
        end else begin
            state_r <= next_s;

            if (invalidate_i && state_r != S_IDLE)
                inv_pending_r <= 1'b1;
            else if (state_r == S_IDLE)
                inv_pending_r <= 1'b0;

            if (state_r == S_IDLE && instr_bus.req && !flush_i)
                req_addr_r <= instr_bus.addr;

            if (state_r == S_REFILL && m_axi.rvalid)
                refill_cnt_r <= refill_cnt_r + 1;
            else if (state_r == S_IDLE || next_s == S_SEND_ADDR)
                refill_cnt_r <= 4'd0;

            if (state_r == S_REFILL && m_axi.rvalid &&
                refill_cnt_r == req_addr_r[5:2])
                bypass_data_r <= m_axi.rdata;

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
        instr_bus.err    = 1'b0;
        tag_wr_en      = 1'b0;
        tag_valid_in   = 1'b0;
        data_wr_en     = 1'b0;
        m_axi.arvalid  = 1'b0;

        unique case (state_r)
            S_IDLE: begin
                if (instr_bus.req && !flush_i)
                    next_s = S_LOOKUP;
            end

            S_LOOKUP: begin
                if (flush_i || redirect_w) begin
                    next_s = S_IDLE;
                end else if (!exec_ok_w) begin
                    // instruction access fault: answer with err + a NOP word
                    if (!suppress_r) begin
                        instr_bus.gnt    = 1'b1;
                        instr_bus.rvalid = 1'b1;
                        instr_bus.err    = 1'b1;
                        instr_bus.rdata  = 32'h0000_0013;
                    end
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
                m_axi.arvalid = 1'b1;
                if (m_axi.arready)
                    next_s = S_REFILL;
            end

            S_REFILL: begin
                if (m_axi.rvalid) begin
                    data_wr_en = 1'b1;
                    if (refill_cnt_r == LINE_SIZE - 1) begin
                        tag_wr_en    = 1'b1;
                        // a FENCE.I during this refill: the data may predate
                        // the D-cache write-back, keep the line invalid
                        tag_valid_in = !(inv_pending_r || invalidate_i);
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

    assign m_axi.arid    = '0;
    assign m_axi.araddr  = {req_addr_r[31:6], 6'b0};
    assign m_axi.arlen   = 8'(LINE_SIZE - 1);
    assign m_axi.arsize  = axi_pkg::AXI_SIZE_WORD;
    assign m_axi.arburst = axi_pkg::AXI_BURST_INCR;
    assign m_axi.rready  = 1'b1;

    icache_data_ram #(
        .line_amount(64),
        .line_size  (LINE_SIZE),
        .data_width (32)
    ) u_data_ram (
        .clk_i            (clk),
        .data_req         (1'b1),
        .line_index_i     (active_line_w),
        .line_reg_index_i (active_word_w),
        .data_i           (m_axi.rdata),
        .wr_i             (data_wr_en),
        .data_o           (ram_data_out)
    );

    icache_tag_ram #(
        .TAG_COUNT  (64),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_tag_ram (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .ins_addr_i     (active_tag_addr_w),
        .dirty_icache_in(1'b0),
        .valid_icache_in(tag_valid_in),
        .wr_i           (tag_wr_en),
        .inv_all_i      (invalidate_i),
        .tag_o          (tag_ram_out)
    );

endmodule
`default_nettype wire
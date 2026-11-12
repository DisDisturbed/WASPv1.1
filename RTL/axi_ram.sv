`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// axi_ram
//
// Block RAM behind an AXI4 slave port; used for both IMEM and DMEM.
//
//   * 32-bit words, word aligned: the low ADDR_WIDTH bits of the AXI address
//     select the word, AxSIZE is ignored (every beat is one full word, which
//     is all the caches issue).
//   * INCR and FIXED bursts (WRAP is treated as INCR).
//   * One read burst and one write burst at a time, independent of each other.
//   * READ_ONLY = 1: write bursts are accepted and dropped, and answered with
//     SLVERR, so a store to the memory becomes a store access fault.
//   * Contents: every word INIT_FILL, then INIT_FILE on top ($readmemh).
//
// clk and rst_n come from the bus. The memory array and the read data
// register have no reset, so the array maps to block RAM.
// =============================================================================
module axi_ram
    import axi_pkg::*;
#(
    parameter int          ADDR_WIDTH = 16,          // size = 2**ADDR_WIDTH bytes
    parameter              INIT_FILE  = "",          // $readmemh image, "" = none
    parameter logic [31:0] INIT_FILL  = 32'h0,       // value of words the image does not cover
    parameter bit          READ_ONLY  = 1'b0
)(
    axi_if.slave bus
);

    localparam int WORD_AW = ADDR_WIDTH - 2;
    localparam int DEPTH   = 2 ** WORD_AW;

    wire clk   = bus.clk;
    wire rst_n = bus.rst_n;

    logic [31:0] mem [DEPTH];

    initial begin
        for (int i = 0; i < DEPTH; i++)
            mem[i] = INIT_FILL;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // -------------------------------------------------------------------------
    // Read
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { RD_IDLE, RD_BURST, RD_LAST } rd_state_e;

    rd_state_e               rd_state_r;
    logic [AXI_ID_WIDTH-1:0] rd_id_r;
    logic [WORD_AW-1:0]      rd_addr_r;
    logic [7:0]              rd_cnt_r;      // beats still to load - 1
    logic                    rd_incr_r;
    logic                    rvalid_r, rlast_r;
    logic [31:0]             rdata_r;

    // load the next beat into the output register: it is empty or being taken
    wire rd_load_w = (rd_state_r == RD_BURST) && (!rvalid_r || bus.rready);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state_r <= RD_IDLE;
            rd_id_r    <= '0;
            rd_addr_r  <= '0;
            rd_cnt_r   <= '0;
            rd_incr_r  <= 1'b0;
            rvalid_r   <= 1'b0;
            rlast_r    <= 1'b0;
        end else begin
            unique case (rd_state_r)
                RD_IDLE: begin
                    if (bus.arvalid) begin
                        rd_id_r    <= bus.arid;
                        rd_addr_r  <= bus.araddr[ADDR_WIDTH-1:2];
                        rd_cnt_r   <= bus.arlen;
                        rd_incr_r  <= (bus.arburst != AXI_BURST_FIXED);
                        rd_state_r <= RD_BURST;
                    end
                end

                RD_BURST: begin
                    if (rd_load_w) begin
                        rvalid_r <= 1'b1;
                        rlast_r  <= (rd_cnt_r == 8'd0);
                        rd_cnt_r <= rd_cnt_r - 8'd1;
                        if (rd_incr_r)
                            rd_addr_r <= rd_addr_r + 1'b1;
                        if (rd_cnt_r == 8'd0)
                            rd_state_r <= RD_LAST;
                    end
                end

                RD_LAST: begin               // last beat is in the output register
                    if (bus.rready) begin
                        rvalid_r   <= 1'b0;
                        rlast_r    <= 1'b0;
                        rd_state_r <= RD_IDLE;
                    end
                end

                default: rd_state_r <= RD_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rd_load_w)
            rdata_r <= mem[rd_addr_r];
    end

    assign bus.arready = (rd_state_r == RD_IDLE);
    assign bus.rid     = rd_id_r;
    assign bus.rdata   = rdata_r;
    assign bus.rresp   = AXI_RESP_OKAY;
    assign bus.rlast   = rlast_r;
    assign bus.rvalid  = rvalid_r;

    // -------------------------------------------------------------------------
    // Write
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { WR_IDLE, WR_DATA, WR_RESP } wr_state_e;

    wr_state_e               wr_state_r;
    logic [AXI_ID_WIDTH-1:0] wr_id_r;
    logic [WORD_AW-1:0]      wr_addr_r;
    logic                    wr_incr_r;

    wire wr_beat_w = (wr_state_r == WR_DATA) && bus.wvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state_r <= WR_IDLE;
            wr_id_r    <= '0;
            wr_addr_r  <= '0;
            wr_incr_r  <= 1'b0;
        end else begin
            unique case (wr_state_r)
                WR_IDLE: begin
                    if (bus.awvalid) begin
                        wr_id_r    <= bus.awid;
                        wr_addr_r  <= bus.awaddr[ADDR_WIDTH-1:2];
                        wr_incr_r  <= (bus.awburst != AXI_BURST_FIXED);
                        wr_state_r <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (bus.wvalid) begin
                        if (wr_incr_r)
                            wr_addr_r <= wr_addr_r + 1'b1;
                        if (bus.wlast)
                            wr_state_r <= WR_RESP;
                    end
                end

                WR_RESP: begin
                    if (bus.bready)
                        wr_state_r <= WR_IDLE;
                end

                default: wr_state_r <= WR_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (wr_beat_w && !READ_ONLY) begin
            for (int b = 0; b < 4; b++)
                if (bus.wstrb[b])
                    mem[wr_addr_r][8*b +: 8] <= bus.wdata[8*b +: 8];
        end
    end

    assign bus.awready = (wr_state_r == WR_IDLE);
    assign bus.wready  = (wr_state_r == WR_DATA);
    assign bus.bid     = wr_id_r;
    assign bus.bresp   = READ_ONLY ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
    assign bus.bvalid  = (wr_state_r == WR_RESP);

endmodule

`default_nettype wire

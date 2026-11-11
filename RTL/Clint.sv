`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
//  clint  -  Core-Local Interruptor (compact wasp layout, single hart)
//
//  Memory map (offset from CLINT_BASE, one 4 KB page; cache_system_top
//  subtracts the base before it reaches this module). The registers are
//  the SiFive CLINT ones, packed into the first 32 bytes so the whole
//  device fits a 4 KB slot -- the offsets are NOT SiFive/OpenSBI-standard.
//  ─────────────────────────────────────────────────────────────
//  0x000  msip         [0]     software interrupt pending (R/W)  -> mip.MSIP
//  0x008  mtimecmp_lo  [31:0]  (R/W)
//  0x00C  mtimecmp_hi  [31:0]  (R/W)
//  0x010  mtime_lo     [31:0]  (R/W)
//  0x014  mtime_hi     [31:0]  (R/W)
//  0x018  clk_freq     [31:0]  core clock in Hz this bitstream was built for (R)
//  0x01C  prescaler    [31:0]  mtime += 1 every (prescaler+1) clocks (R/W)
//  everything else in the page reads 0, writes are ignored
//
//  timer_irq_o is high whenever mtime >= mtimecmp (unsigned 64-bit compare)
//  and drops the same cycle software writes a larger mtimecmp.
//  soft_irq_o  is msip[0].
//
//  prescaler resets to CLK_FREQ_HZ/DEFAULT_TICK_HZ - 1 (1 us ticks by
//  default) so mtime is usable without any driver call; clint_init() in
//  sw/hal/wasp/clint.c checks clk_freq against what software expects and then
//  reprograms prescaler for the tick rate it wants.
//  mcycle (CSR) is NOT affected by this prescaler - it always counts clocks.
//
//  Bus interface: obi_data_if.slave, same timing as plic:
//    gnt = req, rvalid two cycles after the granted request.
// ============================================================================

module clint #(
    parameter int DATA_WIDTH       = 32,
    parameter int CLK_FREQ_HZ      = 50_000_000,
    parameter int DEFAULT_TICK_HZ  = 1_000_000
)(
    input  wire clk,
    input  wire rst_n,

    obi_data_if.slave             bus,

    output logic                  timer_irq_o,
    output logic                  soft_irq_o,
    output logic [63:0]           mtime_o
);

    // ---- elaboration-time sanity check of the build parameters ----------
    localparam int DEFAULT_PRESCALER = CLK_FREQ_HZ / DEFAULT_TICK_HZ - 1;
    if (CLK_FREQ_HZ <= 0 || DEFAULT_TICK_HZ <= 0 || DEFAULT_TICK_HZ > CLK_FREQ_HZ)
        $error("clint: invalid CLK_FREQ_HZ=%0d / DEFAULT_TICK_HZ=%0d", CLK_FREQ_HZ, DEFAULT_TICK_HZ);
    if (CLK_FREQ_HZ % DEFAULT_TICK_HZ != 0)
        $error("clint: CLK_FREQ_HZ=%0d is not a multiple of DEFAULT_TICK_HZ=%0d",
               CLK_FREQ_HZ, DEFAULT_TICK_HZ);

    localparam logic [11:0]
        OFF_MSIP        = 12'h000,
        OFF_MTIMECMP_LO = 12'h008,
        OFF_MTIMECMP_HI = 12'h00C,
        OFF_MTIME_LO    = 12'h010,
        OFF_MTIME_HI    = 12'h014,
        OFF_CLK_FREQ    = 12'h018,
        OFF_PRESCALER   = 12'h01C;

    logic [63:0] mtime_r;
    logic [63:0] mtimecmp_r;
    logic        msip_r;
    logic [31:0] prescaler_r;
    logic [31:0] presc_cnt_r;

    // ---- bus address phase capture (identical scheme to plic) -----------
    assign bus.gnt = bus.req;

    logic                  req_r;
    logic [11:0]           off_r;
    logic                  we_r;
    logic [DATA_WIDTH-1:0] wdata_r;
    logic [3:0]            strb_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_r   <= 1'b0;
            off_r   <= '0;
            we_r    <= 1'b0;
            wdata_r <= '0;
            strb_r  <= '0;
        end else begin
            req_r   <= bus.req & bus.gnt;
            off_r   <= bus.addr[11:0];
            we_r    <= bus.we;
            wdata_r <= bus.wdata;
            strb_r  <= bus.be;
        end
    end

    function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] nw,
                                          input logic [3:0] be);
        for (int b = 0; b < 4; b++)
            merge[b*8 +: 8] = be[b] ? nw[b*8 +: 8] : old[b*8 +: 8];
    endfunction

    logic wr_w;
    assign wr_w = req_r && we_r;

    // ---- prescaler / mtime ---------------------------------------------
    logic tick_w;
    assign tick_w = (presc_cnt_r >= prescaler_r);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prescaler_r <= 32'(DEFAULT_PRESCALER);
            presc_cnt_r <= '0;
            mtime_r     <= '0;
        end else begin
            // prescaler counter: restarts whenever software changes the rate
            if (wr_w && off_r == OFF_PRESCALER) begin
                prescaler_r <= merge(prescaler_r, wdata_r, strb_r);
                presc_cnt_r <= '0;
            end else if (tick_w) begin
                presc_cnt_r <= '0;
            end else begin
                presc_cnt_r <= presc_cnt_r + 32'd1;
            end

            // mtime: software write wins over the tick
            if (wr_w && off_r == OFF_MTIME_LO)
                mtime_r[31:0]  <= merge(mtime_r[31:0],  wdata_r, strb_r);
            else if (wr_w && off_r == OFF_MTIME_HI)
                mtime_r[63:32] <= merge(mtime_r[63:32], wdata_r, strb_r);
            else if (tick_w)
                mtime_r <= mtime_r + 64'd1;
        end
    end

    // ---- msip / mtimecmp -------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtimecmp_r <= '1;           // all-ones so the timer doesn't fire at boot
            msip_r     <= 1'b0;
        end else if (wr_w) begin
            case (off_r)
                OFF_MSIP:        if (strb_r[0]) msip_r <= wdata_r[0];
                OFF_MTIMECMP_LO: mtimecmp_r[31:0]  <= merge(mtimecmp_r[31:0],  wdata_r, strb_r);
                OFF_MTIMECMP_HI: mtimecmp_r[63:32] <= merge(mtimecmp_r[63:32], wdata_r, strb_r);
                default: ;
            endcase
        end
    end

    assign timer_irq_o = (mtime_r >= mtimecmp_r);
    assign soft_irq_o  = msip_r;
    assign mtime_o     = mtime_r;

    // ---- read data phase -------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus.rvalid <= 1'b0;
            bus.rdata  <= '0;
        end else begin
            bus.rvalid <= req_r;
            if (req_r && !we_r) begin
                case (off_r)
                    OFF_MSIP:        bus.rdata <= {31'b0, msip_r};
                    OFF_MTIMECMP_LO: bus.rdata <= mtimecmp_r[31:0];
                    OFF_MTIMECMP_HI: bus.rdata <= mtimecmp_r[63:32];
                    OFF_MTIME_LO:    bus.rdata <= mtime_r[31:0];
                    OFF_MTIME_HI:    bus.rdata <= mtime_r[63:32];
                    OFF_CLK_FREQ:    bus.rdata <= 32'(CLK_FREQ_HZ);
                    OFF_PRESCALER:   bus.rdata <= prescaler_r;
                    default:         bus.rdata <= '0;
                endcase
            end else begin
                bus.rdata <= '0;
            end
        end
    end

    // =========================================================================
    //  Simulation helpers
    // =========================================================================
    // synthesis translate_off
`ifndef CSR_QUIET
    logic timer_irq_q;
    always_ff @(posedge clk) begin
        timer_irq_q <= timer_irq_o;
        if (rst_n) begin
            if (wr_w && (off_r == OFF_MTIMECMP_LO || off_r == OFF_MTIMECMP_HI))
                $display("[CLINT @%0t] mtimecmp write off=%h wdata=%h", $time, off_r, wdata_r);
            if (timer_irq_o && !timer_irq_q)
                $display("[CLINT @%0t] timer_irq ASSERTED  mtime=%0d mtimecmp=%0d",
                         $time, mtime_r, mtimecmp_r);
        end
    end
`endif
    // synthesis translate_on

endmodule

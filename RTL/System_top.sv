`timescale 1ns / 1ps
`default_nettype none

`include "axi_macros.svh"

module system_top #(
    parameter int DATA_WIDTH    = 32,
    parameter int RF_ADDR_WIDTH = 5,
    parameter int N_SRC         = 5,

    // Memory map (sw/hal/include/memmap.h must match)
    //   0x4000_0000  IMEM (boot)         64 KB   crossbar slave 0, read-only
    //   0x8000_0000  DMEM (D-cacheable)  64 KB   crossbar slave 1
    //   0xC000_0000  peripherals, one 4 KB page each:
    //     0xC000_0000  UART16550        (crossbar slave 2)
    //     0xC000_1000  CLINT            (core data bus, compact layout)
    //     0xC000_2000  PLIC             (core data bus, compact layout)
    //     0xC000_3000  D-cache flush control register
    //     0xC000_4000  spare AXI slot 0 (crossbar slave 3)
    //     0xC000_5000  spare AXI slot 1 (crossbar slave 4)
    //     0xC000_6000  spare AXI slot 2 (crossbar slave 5)
    //   A data access to anything else gets a decode error from the crossbar
    //   and becomes a load/store access fault (mcause 5/7); so does an access
    //   to a spare slot whose SLOT_PRESENT bit is 0. A store to IMEM gets a
    //   slave error from the read-only RAM (mcause 7). Instruction fetch
    //   outside IMEM/DMEM: instruction access fault (mcause 1), see icache.sv.
    parameter     IMEM_BASE     = 32'h40000000,
    parameter     DMEM_BASE     = 32'h80000000,
    parameter     BOOT_ADDR     = IMEM_BASE,        // drive boot_addr_in with this
    parameter     PERIPH_BASE   = 32'hC0000000,
    parameter     UART_BASE     = PERIPH_BASE + 32'h0000,
    parameter     CLINT_BASE    = PERIPH_BASE + 32'h1000,
    parameter     PLIC_BASE     = PERIPH_BASE + 32'h2000,
    parameter     DCACHE_FLUSH_ADDR = PERIPH_BASE + 32'h3000,

    // Spare AXI slots: N_SPARE (>= 1) pages of 4 KB starting at SPARE_BASE.
    // Slot n is crossbar slave 3+n (slv_axi[SLV_SPARE0 + n] below). Set
    // SLOT_PRESENT[n] when a slave is connected to it.
    parameter int N_SPARE       = 3,
    parameter     SPARE_BASE    = PERIPH_BASE + 32'h4000,
    parameter logic [N_SPARE-1:0] SLOT_PRESENT = '0,

    // System clock produced by clk_wiz_0 (clk_out1). Exposed to software through
    // the CLINT clk_freq register; Constrait/check_clk_freq.tcl compares it
    // against the clk_wiz_0 IP configuration before synthesis.
    parameter int CLK_FREQ_HZ   = 50_000_000,

    // Memory sizes
    parameter int IMEM_ADDR_WIDTH = 16,  // 64KB instruction memory
    parameter int DMEM_ADDR_WIDTH = 16   // 64KB data memory
)(
    input wire clk_100mhz_in,
    input wire rst_in_n,

    input wire [DATA_WIDTH-1:0] boot_addr_in,
    input wire [N_SRC-1:0] plic_irq_i,

    input  wire uart_rx_i,
    output wire uart_tx_o,

    output logic mie_o_tb
);

    // =========================================================================
    // Clock and reset
    // clk_wiz_0 makes the system clock from the board clock; the system is
    // held in reset (active low, asynchronous) until it has locked.
    // =========================================================================
    logic clk, locked, rst_n;

`ifdef VERILATOR
    // simulation: no Xilinx PLL primitives, the board clock is the system clock
    assign clk    = clk_100mhz_in;
    assign locked = 1'b1;
`else
    clk_wiz_0 clkwiz0 (
        .clk_out1 (clk),
        .reset    (~rst_in_n),
        .locked   (locked),
        .clk_in1  (clk_100mhz_in)
    );
`endif

    assign rst_n = rst_in_n & locked;

    // =========================================================================
    // AXI buses
    //   mst_axi[i]: master i -> crossbar      slv_axi[j]: crossbar -> slave j
    // The index is the crossbar port number; for masters it is also the
    // priority (0 = highest).
    // =========================================================================
    localparam int N_MST      = 2;
    localparam int MST_ICACHE = 0;
    localparam int MST_DCACHE = 1;

    localparam int N_SLV      = 3 + N_SPARE;
    localparam int SLV_IMEM   = 0;
    localparam int SLV_DMEM   = 1;
    localparam int SLV_UART   = 2;
    localparam int SLV_SPARE0 = 3;

    axi_if mst_axi [N_MST] (.clk(clk), .rst_n(rst_n));
    axi_if slv_axi [N_SLV] (.clk(clk), .rst_n(rst_n));

    // crossbar address map, one entry per slave port
    function automatic logic [N_SLV-1:0][31:0] slv_base_addr();
        slv_base_addr[SLV_IMEM] = IMEM_BASE;
        slv_base_addr[SLV_DMEM] = DMEM_BASE;
        slv_base_addr[SLV_UART] = UART_BASE;
        for (int n = 0; n < N_SPARE; n++)
            slv_base_addr[SLV_SPARE0 + n] = SPARE_BASE + n * 32'h1000;
    endfunction

    function automatic logic [N_SLV-1:0][31:0] slv_addr_width();
        slv_addr_width[SLV_IMEM] = IMEM_ADDR_WIDTH;
        slv_addr_width[SLV_DMEM] = DMEM_ADDR_WIDTH;
        slv_addr_width[SLV_UART] = 12;
        for (int n = 0; n < N_SPARE; n++)
            slv_addr_width[SLV_SPARE0 + n] = 12;
    endfunction

    localparam logic [N_SLV-1:0][31:0] SLV_BASE_ADDR  = slv_base_addr();
    localparam logic [N_SLV-1:0][31:0] SLV_ADDR_WIDTH = slv_addr_width();
    localparam logic [N_SLV-1:0]       SLV_PRESENT    = {SLOT_PRESENT, 3'b111};

    // =========================================================================
    // Core, caches, PLIC, CLINT
    // =========================================================================
    cache_system_top #(
        .DATA_WIDTH    (DATA_WIDTH),
        .RF_ADDR_WIDTH (RF_ADDR_WIDTH),
        .N_SRC         (N_SRC),
        .PLIC_BASE     (PLIC_BASE),
        .CLINT_BASE    (CLINT_BASE),
        .DCACHE_FLUSH_ADDR (DCACHE_FLUSH_ADDR),
        .DMEM_BASE     (DMEM_BASE),
        .DMEM_ADDR_WIDTH (DMEM_ADDR_WIDTH),
        .IMEM_BASE     (IMEM_BASE),
        .IMEM_ADDR_WIDTH (IMEM_ADDR_WIDTH),
        .CLK_FREQ_HZ   (CLK_FREQ_HZ)
    ) u_cache_system (
        .clk           (clk),
        .rst_n         (rst_n),
        .boot_addr_in  (boot_addr_in),
        .plic_irq_i    (plic_irq_i),
        .icache_axi    (mst_axi[MST_ICACHE]),
        .dcache_axi    (mst_axi[MST_DCACHE]),
        .mie_o_tb      (mie_o_tb)
    );

    // the I-cache only reads: its write channels are idle
    `AXI_TIE_OFF_MASTER_WR(mst_axi[MST_ICACHE])

    // =========================================================================
    // Crossbar
    // =========================================================================
    axi_xbar #(
        .S_COUNT      (N_MST),
        .M_COUNT      (N_SLV),
        .M_BASE_ADDR  (SLV_BASE_ADDR),
        .M_ADDR_WIDTH (SLV_ADDR_WIDTH),
        .M_PRESENT    (SLV_PRESENT)
    ) u_xbar (
        .s_axi (mst_axi),
        .m_axi (slv_axi)
    );

    // =========================================================================
    // Memories
    // =========================================================================
    axi_ram #(
        .ADDR_WIDTH (IMEM_ADDR_WIDTH),
        .INIT_FILE  ("imem.mem"),
        .INIT_FILL  (32'h0000_0013),     // NOP
        .READ_ONLY  (1'b1)
    ) u_ins_ram (
        .bus (slv_axi[SLV_IMEM])
    );

    axi_ram #(
        .ADDR_WIDTH (DMEM_ADDR_WIDTH),
        .INIT_FILE  ("dmem.mem"),
        .INIT_FILL  (32'h0),
        .READ_ONLY  (1'b0)
    ) u_data_ram (
        .bus (slv_axi[SLV_DMEM])
    );

    // =========================================================================
    // UART16550 (Xilinx IP, AXI4-Lite) behind the AXI4 -> AXI4-Lite bridge
    // =========================================================================
    logic [31:0] uart_awaddr, uart_araddr, uart_wdata, uart_rdata;
    logic [3:0]  uart_wstrb;
    logic [1:0]  uart_bresp, uart_rresp;
    logic        uart_awvalid, uart_awready, uart_wvalid, uart_wready;
    logic        uart_bvalid, uart_bready;
    logic        uart_arvalid, uart_arready, uart_rvalid, uart_rready;

    axi_axil_bridge u_uart_bridge (
        .bus            (slv_axi[SLV_UART]),
        .m_axil_awaddr  (uart_awaddr),
        .m_axil_awvalid (uart_awvalid),
        .m_axil_awready (uart_awready),
        .m_axil_wdata   (uart_wdata),
        .m_axil_wstrb   (uart_wstrb),
        .m_axil_wvalid  (uart_wvalid),
        .m_axil_wready  (uart_wready),
        .m_axil_bresp   (uart_bresp),
        .m_axil_bvalid  (uart_bvalid),
        .m_axil_bready  (uart_bready),
        .m_axil_araddr  (uart_araddr),
        .m_axil_arvalid (uart_arvalid),
        .m_axil_arready (uart_arready),
        .m_axil_rdata   (uart_rdata),
        .m_axil_rresp   (uart_rresp),
        .m_axil_rvalid  (uart_rvalid),
        .m_axil_rready  (uart_rready)
    );

    axi_uart16550_0 u_uart_ip (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (rst_n),
        .ip2intc_irpt  (),
        .freeze        (1'b0),

        .s_axi_awaddr  ({1'b1, uart_awaddr[11:0]}),
        .s_axi_awvalid (uart_awvalid),
        .s_axi_awready (uart_awready),

        .s_axi_wdata   (uart_wdata),
        .s_axi_wstrb   (uart_wstrb),
        .s_axi_wvalid  (uart_wvalid),
        .s_axi_wready  (uart_wready),

        .s_axi_bresp   (uart_bresp),
        .s_axi_bvalid  (uart_bvalid),
        .s_axi_bready  (uart_bready),

        .s_axi_araddr  ({1'b1, uart_araddr[11:0]}),
        .s_axi_arvalid (uart_arvalid),
        .s_axi_arready (uart_arready),

        .s_axi_rdata   (uart_rdata),
        .s_axi_rresp   (uart_rresp),
        .s_axi_rvalid  (uart_rvalid),
        .s_axi_rready  (uart_rready),

        .baudoutn      (),
        .ctsn          (1'b0),
        .dcdn          (1'b0),
        .ddis          (),
        .dsrn          (1'b0),
        .dtrn          (),
        .out1n         (),
        .out2n         (),
        .rin           (1'b1),
        .rtsn          (),
        .rxrdyn        (),
        .sin           (uart_rx_i),
        .sout          (uart_tx_o),
        .txrdyn        ()
    );

    // =========================================================================
    // Spare AXI slots
    //
    // To add a peripheral: give it an axi_if.slave port, connect that port to
    // slv_axi[SLV_SPARE0 + n] here and set SLOT_PRESENT[n]. A slot without a
    // slave is tied off; the crossbar answers accesses to it with DECERR.
    // =========================================================================
    for (genvar n = 0; n < N_SPARE; n++) begin : gen_spare_slot
        if (!SLOT_PRESENT[n]) begin : gen_empty
            `AXI_TIE_OFF_SLAVE(slv_axi[SLV_SPARE0 + n])
        end
    end

endmodule

`default_nettype wire

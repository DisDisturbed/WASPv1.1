`timescale 1ns / 1ps
`default_nettype none
// author yusuf mirac gocen 3rd year ee student @ itu
// this is an complex system that require knowledge of both irq management and axi4full understanding
// if you have question you can send email goceny22@itu.edu.tr
// this system tested on basic bare metal codes
// IT DOES NOT TESTED ON FORMAL VERIFICATION
// there could be errors please send an email if you ever encounter one

`include "obi_macros.svh"

module cache_system_top #(
    parameter int DATA_WIDTH    = 32,
    parameter int RF_ADDR_WIDTH = 5,
    parameter int N_SRC = 32,
    parameter     PLIC_BASE  = 32'hC0002000,   // 4 KB page, compact layout (Plic.sv)
    parameter     CLINT_BASE = 32'hC0001000,   // 4 KB page, compact layout (Clint.sv)
    parameter     DCACHE_FLUSH_ADDR = 32'hC0003000, // D-cache flush control register
    parameter     DMEM_BASE  = 32'h80000000,   // only DMEM is D-cacheable
    parameter int DMEM_ADDR_WIDTH = 16,        // DMEM size = 2**DMEM_ADDR_WIDTH bytes
    parameter int CLK_FREQ_HZ = 50_000_000     // core clock (clk_wiz_0 clk_out1)
)(
    input wire clk_100mhz_in,
    input wire rst_in_n,
    output logic clk_o,
    output logic rst_o,

    input wire [DATA_WIDTH-1:0] boot_addr_in,
    input wire [N_SRC-1:0] plic_irq_i,

    // Instruction Cache AXI4 Read Interface (to external I-memory)
    output logic        icache_m_axi_arvalid,
    input  wire         icache_m_axi_arready,
    output logic [31:0] icache_m_axi_araddr,
    output logic [1:0]  icache_m_axi_arburst,
    input  wire         icache_m_axi_rvalid,
    input  wire  [31:0] icache_m_axi_rdata,

    // Data Cache AXI4 Full Interface (to external interconnect/memory)
    // Write Address Channel
    output logic        dcache_m_axi_awvalid,
    input  wire         dcache_m_axi_awready,
    output logic [31:0] dcache_m_axi_awaddr,
    output logic [3:0]  dcache_m_axi_awid,
    output logic [7:0]  dcache_m_axi_awlen,
    output logic [2:0]  dcache_m_axi_awsize,
    output logic [1:0]  dcache_m_axi_awburst,
    // Write Data Channel
    output logic        dcache_m_axi_wvalid,
    input  wire         dcache_m_axi_wready,
    output logic [31:0] dcache_m_axi_wdata,
    output logic [3:0]  dcache_m_axi_wstrb,
    output logic        dcache_m_axi_wlast,
    // Write Response Channel
    input  wire         dcache_m_axi_bvalid,
    output logic        dcache_m_axi_bready,
    input  wire  [1:0]  dcache_m_axi_bresp,
    input  wire  [3:0]  dcache_m_axi_bid,
    // Read Address Channel
    output logic        dcache_m_axi_arvalid,
    input  wire         dcache_m_axi_arready,
    output logic [31:0] dcache_m_axi_araddr,
    output logic [3:0]  dcache_m_axi_arid,
    output logic [7:0]  dcache_m_axi_arlen,
    output logic [2:0]  dcache_m_axi_arsize,
    output logic [1:0]  dcache_m_axi_arburst,
    // Read Data Channel
    input  wire         dcache_m_axi_rvalid,
    output logic        dcache_m_axi_rready,
    input  wire  [31:0] dcache_m_axi_rdata,
    input  wire         dcache_m_axi_rlast,
    input  wire  [1:0]  dcache_m_axi_rresp,
    input  wire  [3:0]  dcache_m_axi_rid,

    // Debug/monitoring outputs
    output logic mie_o_tb
);


    logic rst_n;
    assign rst_o = rst_n;

    // Flush redirect signal for dropping inline request
    // Current caches don't request that so this version is safe
    logic        core_pipeline_flush;
    assign       core_pipeline_flush = 1'b0;

    logic plic_ext_irq;
    logic clint_timer_irq;
    logic clint_soft_irq;
    logic [63:0] clint_mtime;

    // =========================================================================
    // Core <-> instruction cache: plain 1:1 OBI link, one shared interface
    // instance, zero glue.
    // =========================================================================
    obi_instr_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) instr_bus();

    // =========================================================================
    // Core <-> data bus: one master interface from the core, arbitrated
    // between two slave legs (dcache, PLIC). See obi_macros.svh.
    // =========================================================================
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) core_data_bus();
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) dcache_bus();
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) plic_bus();
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) clint_bus();

    // CORE native OBI
    Core_Top #(
        .DATA_WIDTH(DATA_WIDTH),
        .RF_ADDR_WIDTH(RF_ADDR_WIDTH)
    ) u_core (
        .clk_in         (clk_100mhz_in),
        .ext_rst_n      (rst_in_n),
        .clk_o          (clk_o),
        .rst_o          (rst_n),
        .boot_addr_i    (boot_addr_in),
        .external_irq_i (plic_ext_irq),
        .timer_irq_i    (clint_timer_irq),
        .soft_irq_i     (clint_soft_irq),
        .mtime_i        (clint_mtime),

        // I mem / I cache interface
        .instr_bus      (instr_bus),

        // D mem / D cache interface
        .data_bus       (core_data_bus),
        .csr_mie_reg_o  (mie_o_tb)
    );

    // =========================================================================
    // PLIC Address Decoder and Arbitration (OBI interface)
    // PLIC is accessed before D-cache, so it stays in this module.
    //
    // Outstanding-transaction tracking is unchanged design logic: it stops
    // an in-flight transaction from being reassigned to the other slave if
    // the requested address changes mid-flight. Only the field-level
    // wiring below it is now expressed via the OBI_DATA_* macros.
    // =========================================================================
    // Range decode: PLIC and CLINT each own one 4 KB page. Anything else
    // goes to the D-cache (which bypasses non-DMEM addresses straight to
    // the AXI crossbar).
    localparam logic [31:0] PLIC_SIZE  = 32'h0000_1000;
    localparam logic [31:0] CLINT_SIZE = 32'h0000_1000;

    logic sel_plic, sel_clint;
    assign sel_plic  = (core_data_bus.addr >= PLIC_BASE)  && (core_data_bus.addr < PLIC_BASE  + PLIC_SIZE);
    assign sel_clint = (core_data_bus.addr >= CLINT_BASE) && (core_data_bus.addr < CLINT_BASE + CLINT_SIZE);

    typedef enum logic [1:0] { SLAVE_DCACHE, SLAVE_PLIC, SLAVE_CLINT } slave_e;
    slave_e active_slave, req_slave;
    logic [3:0] outstanding_tx;

    assign req_slave = sel_plic  ? SLAVE_PLIC  :
                       sel_clint ? SLAVE_CLINT : SLAVE_DCACHE;

    always_ff @(posedge clk_o or negedge rst_n) begin
        if (!rst_n) begin
            outstanding_tx <= '0;
            active_slave   <= SLAVE_DCACHE;
        end else begin
            if ((core_data_bus.req && core_data_bus.gnt) && !core_data_bus.rvalid)
                outstanding_tx <= outstanding_tx + 1;
            else if (!(core_data_bus.req && core_data_bus.gnt) && core_data_bus.rvalid)
                outstanding_tx <= outstanding_tx - 1;

            if (outstanding_tx == 0 && core_data_bus.req)
                active_slave <= req_slave;
        end
    end

    logic allow_req;
    assign allow_req = (outstanding_tx == 0) || (active_slave == req_slave);

    // dcache leg: pure broadcast + gate, fully mechanical -> macros.
    `OBI_DATA_BROADCAST_AP(dcache_bus, core_data_bus)
    `OBI_DATA_GATE_REQ(dcache_bus, core_data_bus, (~sel_plic & ~sel_clint & allow_req))

    // plic leg: we/be/wdata are a plain broadcast (macro-able), but addr
    // needs the PLIC_BASE offset subtracted -- that's real per-leg
    // address-decode logic, not mechanical wiring, so it's written out
    // instead of forced through OBI_DATA_BROADCAST_AP.
    assign plic_bus.we    = core_data_bus.we;
    assign plic_bus.be    = core_data_bus.be;
    assign plic_bus.wdata = core_data_bus.wdata;
    assign plic_bus.addr  = core_data_bus.addr - PLIC_BASE; // PLIC expects offset from base
    `OBI_DATA_GATE_REQ(plic_bus, core_data_bus, (sel_plic & allow_req))

    // clint leg: same shape as the plic leg
    assign clint_bus.we    = core_data_bus.we;
    assign clint_bus.be    = core_data_bus.be;
    assign clint_bus.wdata = core_data_bus.wdata;
    assign clint_bus.addr  = core_data_bus.addr - CLINT_BASE; // CLINT expects offset from base
    `OBI_DATA_GATE_REQ(clint_bus, core_data_bus, (sel_clint & allow_req))

    assign core_data_bus.gnt    = allow_req ? (sel_plic  ? plic_bus.gnt  :
                                               sel_clint ? clint_bus.gnt : dcache_bus.gnt) : 1'b0;
    assign core_data_bus.rvalid = plic_bus.rvalid | clint_bus.rvalid | dcache_bus.rvalid;
    assign core_data_bus.rdata  = plic_bus.rvalid  ? plic_bus.rdata  :
                                  clint_bus.rvalid ? clint_bus.rdata : dcache_bus.rdata;

    // =========================================================================
    // CLINT Instance (mtime/mtimecmp/msip + clk_freq/prescaler, see Clint.sv)
    // =========================================================================
    clint #(
        .DATA_WIDTH  (DATA_WIDTH),
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
    ) u_clint (
        .clk         (clk_o),
        .rst_n       (rst_n),
        .bus         (clint_bus),
        .timer_irq_o (clint_timer_irq),
        .soft_irq_o  (clint_soft_irq),
        .mtime_o     (clint_mtime)
    );

    // =========================================================================
    // PLIC Instance
    //
    // Each interrupt source gets its own irq_if instance; which array slot
    // a given peripheral lands in is fixed at elaboration time (this
    // generate loop), so -- unlike the OBI data-bus arbitration above --
    // an interface array is exactly the right tool here, no macro needed.
    // plic_irq_i itself stays a flat vector: it's this module's own
    // outward-facing chip/SoC-level boundary, same reasoning as keeping
    // Core_Top's board-level ports flat one level up.
    // =========================================================================
    irq_if irq_lines [N_SRC-1:0] ();

    for (genvar s = 0; s < N_SRC; s++) begin : gen_irq_bridge
        assign irq_lines[s].pending = plic_irq_i[s];
    end

    plic #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_SRC(N_SRC),
        .PLIC_BASE(PLIC_BASE)
    ) u_plic (
        .clk            (clk_o),
        .rst_n          (rst_n),
        .irq_lines      (irq_lines),

        .bus            (plic_bus),

        .external_irq_o (plic_ext_irq)
    );

    // =========================================================================
    // Instruction Cache (OBI on core side, AXI4 Read on memory side)
    // =========================================================================
    icache #(
        .ADDR_WIDTH(32),
        .LINE_SIZE (16)
    ) u_icache (
        .clk            (clk_o),
        .rst            (!rst_n),   // icache expects active-high reset

        // Core OBI -- same interface instance Core_Top drives as master
        .instr_bus      (instr_bus),
        .flush_i        (core_pipeline_flush),

        // AXI4 Read only (exposed to top level)
        .m_axi_arvalid  (icache_m_axi_arvalid),
        .m_axi_arready  (icache_m_axi_arready),
        .m_axi_araddr   (icache_m_axi_araddr),
        .m_axi_arburst  (icache_m_axi_arburst),
        .m_axi_rdata    (icache_m_axi_rdata),
        .m_axi_rvalid   (icache_m_axi_rvalid)
    );

    // =========================================================================
    // Data Cache (OBI on core side, AXI4 Full on memory side)
    // =========================================================================
    dcache #(
        .ADDR_WIDTH        (32),
        .DATA_WIDTH        (32),
        .LINE_SIZE         (16),
        // flush register has its own 4 KB page in the peripheral region
        .FLUSH_CTRL_ADDR   (DCACHE_FLUSH_ADDR),
        // only DMEM is cached; IMEM-as-data, UART and the other AXI
        // peripherals go straight to the crossbar
        .CACHE_RANGE_LOWER (DMEM_BASE),
        .CACHE_RANGE_UPPER (DMEM_BASE + (32'd1 << DMEM_ADDR_WIDTH) - 32'd1)
    ) u_dcache (
        .clk            (clk_o),
        .rst            (!rst_n),

        // Core side OBI -- this leg of the arbiter
        .core_bus       (dcache_bus),

        // AXI4 Full interface (exposed to top level)
        // Write Address Channel
        .m_axi_awvalid  (dcache_m_axi_awvalid),
        .m_axi_awready  (dcache_m_axi_awready),
        .m_axi_awaddr   (dcache_m_axi_awaddr),
        .m_axi_awid     (dcache_m_axi_awid),
        .m_axi_awlen    (dcache_m_axi_awlen),
        .m_axi_awsize   (dcache_m_axi_awsize),
        .m_axi_awburst  (dcache_m_axi_awburst),
        // Write Data Channel
        .m_axi_wvalid   (dcache_m_axi_wvalid),
        .m_axi_wready   (dcache_m_axi_wready),
        .m_axi_wdata    (dcache_m_axi_wdata),
        .m_axi_wstrb    (dcache_m_axi_wstrb),
        .m_axi_wlast    (dcache_m_axi_wlast),
        // Write Response Channel
        .m_axi_bvalid   (dcache_m_axi_bvalid),
        .m_axi_bready   (dcache_m_axi_bready),
        .m_axi_bresp    (dcache_m_axi_bresp),
        .m_axi_bid      (dcache_m_axi_bid),
        // Read Address Channel
        .m_axi_arvalid  (dcache_m_axi_arvalid),
        .m_axi_arready  (dcache_m_axi_arready),
        .m_axi_araddr   (dcache_m_axi_araddr),
        .m_axi_arid     (dcache_m_axi_arid),
        .m_axi_arlen    (dcache_m_axi_arlen),
        .m_axi_arsize   (dcache_m_axi_arsize),
        .m_axi_arburst  (dcache_m_axi_arburst),
        // Read Data Channel
        .m_axi_rvalid   (dcache_m_axi_rvalid),
        .m_axi_rready   (dcache_m_axi_rready),
        .m_axi_rdata    (dcache_m_axi_rdata),
        .m_axi_rlast    (dcache_m_axi_rlast),
        .m_axi_rresp    (dcache_m_axi_rresp),
        .m_axi_rid      (dcache_m_axi_rid)
    );

endmodule
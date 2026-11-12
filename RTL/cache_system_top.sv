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
    parameter     IMEM_BASE  = 32'h40000000,   // executable, together with DMEM
    parameter int IMEM_ADDR_WIDTH = 16,
    parameter int CLK_FREQ_HZ = 50_000_000     // frequency of clk (clk_wiz_0 clk_out1)
)(
    input wire clk,
    input wire rst_n,     // active low, asynchronous

    input wire [DATA_WIDTH-1:0] boot_addr_in,
    input wire [N_SRC-1:0] plic_irq_i,

    // AXI4 masters towards the crossbar
    axi_if.master_rd icache_axi,   // I-cache refills (read only)
    axi_if.master    dcache_axi,   // D-cache refill / write-back / bypass

    // Debug/monitoring outputs
    output logic mie_o_tb
);

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
    // Core <-> data bus: one master interface from the core, split over
    // three slave legs (D-cache, PLIC, CLINT). See obi_macros.svh.
    // =========================================================================
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) core_data_bus();
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) dcache_bus();
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) plic_bus();
    obi_data_if #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(DATA_WIDTH)) clint_bus();

    // FENCE.I handshake: core -> D-cache flush-all -> I-cache invalidate -> core
    logic fencei_req, fencei_done;

    // CORE native OBI
    Core_Top #(
        .DATA_WIDTH(DATA_WIDTH),
        .RF_ADDR_WIDTH(RF_ADDR_WIDTH)
    ) u_core (
        .clk            (clk),
        .rst_n          (rst_n),
        .boot_addr_i    (boot_addr_in),
        .external_irq_i (plic_ext_irq),
        .timer_irq_i    (clint_timer_irq),
        .soft_irq_i     (clint_soft_irq),
        .mtime_i        (clint_mtime),

        // I mem / I cache interface
        .instr_bus      (instr_bus),

        // D mem / D cache interface
        .data_bus       (core_data_bus),
        .fencei_req_o   (fencei_req),
        .fencei_done_i  (fencei_done),
        .csr_mie_reg_o  (mie_o_tb)
    );

    // =========================================================================
    // Core data bus decode: PLIC, CLINT, or the D-cache.
    //
    // PLIC and CLINT each own one 4 KB page and are answered here, before
    // the D-cache. Everything else goes to the D-cache, which caches DMEM
    // and passes all other addresses on to the AXI crossbar. Accesses the
    // bus cannot serve (no slave at the address, a store to the read-only
    // IMEM, an empty spare slot) come back from there as an AXI error
    // response, which the D-cache reports as err (load/store access fault).
    //
    // outstanding_tx / active_slave keep a transaction on the leg it started
    // on if the requested address changes while it is in flight.
    // =========================================================================
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

    always_ff @(posedge clk or negedge rst_n) begin
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

    // dcache leg: broadcast + gated request
    `OBI_DATA_BROADCAST_AP(dcache_bus, core_data_bus)
    `OBI_DATA_GATE_REQ(dcache_bus, core_data_bus, (~sel_plic & ~sel_clint & allow_req))

    // plic leg: the PLIC expects the offset from PLIC_BASE, so addr is
    // written out instead of using OBI_DATA_BROADCAST_AP
    assign plic_bus.we    = core_data_bus.we;
    assign plic_bus.be    = core_data_bus.be;
    assign plic_bus.wdata = core_data_bus.wdata;
    assign plic_bus.addr  = core_data_bus.addr - PLIC_BASE;
    `OBI_DATA_GATE_REQ(plic_bus, core_data_bus, (sel_plic & allow_req))

    // clint leg: same shape as the plic leg
    assign clint_bus.we    = core_data_bus.we;
    assign clint_bus.be    = core_data_bus.be;
    assign clint_bus.wdata = core_data_bus.wdata;
    assign clint_bus.addr  = core_data_bus.addr - CLINT_BASE;
    `OBI_DATA_GATE_REQ(clint_bus, core_data_bus, (sel_clint & allow_req))

    assign core_data_bus.gnt    = allow_req ? (sel_plic  ? plic_bus.gnt  :
                                               sel_clint ? clint_bus.gnt : dcache_bus.gnt) : 1'b0;
    assign core_data_bus.rvalid = plic_bus.rvalid | clint_bus.rvalid | dcache_bus.rvalid;
    assign core_data_bus.rdata  = plic_bus.rvalid  ? plic_bus.rdata  :
                                  clint_bus.rvalid ? clint_bus.rdata : dcache_bus.rdata;
    assign core_data_bus.err    = dcache_bus.rvalid & dcache_bus.err;

    // =========================================================================
    // CLINT Instance (mtime/mtimecmp/msip + clk_freq/prescaler, see Clint.sv)
    // =========================================================================
    clint #(
        .DATA_WIDTH  (DATA_WIDTH),
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
    ) u_clint (
        .clk         (clk),
        .rst_n       (rst_n),
        .bus         (clint_bus),
        .timer_irq_o (clint_timer_irq),
        .soft_irq_o  (clint_soft_irq),
        .mtime_o     (clint_mtime)
    );

    // =========================================================================
    // PLIC Instance
    //
    // One irq_if instance per interrupt source. Which array slot a source
    // lands in is fixed at elaboration time, so a plain interface array
    // fits. plic_irq_i stays a flat vector: it is this module's boundary
    // towards the board.
    // =========================================================================
    irq_if irq_lines [N_SRC-1:0] ();

    for (genvar s = 0; s < N_SRC; s++) begin : gen_irq_bridge
        assign irq_lines[s].pending = plic_irq_i[s];
    end

    plic #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_SRC(N_SRC)
    ) u_plic (
        .clk            (clk),
        .rst_n          (rst_n),
        .irq_lines      (irq_lines),

        .bus            (plic_bus),

        .external_irq_o (plic_ext_irq)
    );

    // =========================================================================
    // Instruction Cache (OBI on core side, AXI4 Read on memory side)
    // =========================================================================
    icache #(
        .ADDR_WIDTH       (32),
        .LINE_SIZE        (16),
        .EXEC0_BASE       (IMEM_BASE),
        .EXEC0_ADDR_WIDTH (IMEM_ADDR_WIDTH),
        .EXEC1_BASE       (DMEM_BASE),
        .EXEC1_ADDR_WIDTH (DMEM_ADDR_WIDTH)
    ) u_icache (
        .clk            (clk),
        .rst_n          (rst_n),

        // Core OBI -- same interface instance Core_Top drives as master
        .instr_bus      (instr_bus),
        // FENCE.I: once the D-cache write-back is done (fencei_done), drop
        // the in-flight fetch and invalidate every line in the same cycle
        // the core redirects to pc+4
        .flush_i        (fencei_done),
        .invalidate_i   (fencei_done),

        .m_axi          (icache_axi)
    );

    // =========================================================================
    // Data Cache (OBI on core side, AXI4 on memory side)
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
        .clk            (clk),
        .rst_n          (rst_n),

        // Core side OBI -- the D-cache leg of the core data bus
        .core_bus       (dcache_bus),
        .flush_all_req_i  (fencei_req),
        .flush_all_done_o (fencei_done),

        .m_axi          (dcache_axi)
    );

endmodule

`default_nettype wire

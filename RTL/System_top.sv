`timescale 1ns / 1ps
`default_nettype none


module system_top #(
    parameter int DATA_WIDTH    = 32,
    parameter int RF_ADDR_WIDTH = 5,
    parameter int N_SRC         = 5,

    // Memory map (sw/hal/include/memmap.h must match)
    //   0x4000_0000  IMEM (boot)         64 KB
    //   0x8000_0000  DMEM (D-cacheable)  64 KB
    //   0xC000_0000  peripherals, one 4 KB page each:
    //     0xC000_0000  UART16550        (AXI crossbar M02)
    //     0xC000_1000  CLINT            (core data bus, compact layout)
    //     0xC000_2000  PLIC             (core data bus, compact layout)
    //     0xC000_3000  D-cache flush control register
    //     0xC000_4000  spare AXI slot   (crossbar M03)
    //     0xC000_5000  spare AXI slot   (crossbar M04)
    //     0xC000_6000  spare AXI slot   (crossbar M05)
    //   anything else is unmapped (AXI DECERR)
    parameter     IMEM_BASE     = 32'h40000000,
    parameter     DMEM_BASE     = 32'h80000000,
    parameter     BOOT_ADDR     = IMEM_BASE,        // drive boot_addr_in with this
    parameter     PERIPH_BASE   = 32'hC0000000,
    parameter     UART_BASE     = PERIPH_BASE + 32'h0000,
    parameter     CLINT_BASE    = PERIPH_BASE + 32'h1000,
    parameter     PLIC_BASE     = PERIPH_BASE + 32'h2000,
    parameter     DCACHE_FLUSH_ADDR = PERIPH_BASE + 32'h3000,
    parameter     SLOT3_BASE    = PERIPH_BASE + 32'h4000,
    parameter     SLOT4_BASE    = PERIPH_BASE + 32'h5000,
    parameter     SLOT5_BASE    = PERIPH_BASE + 32'h6000,

    // Core clock produced by clk_wiz_0 (clk_out1). Exposed to software through
    // the CLINT clk_freq register; Constrait/check_clk_freq.tcl compares it
    // against the clk_wiz_0 IP configuration before synthesis.
    parameter int CLK_FREQ_HZ   = 50_000_000,
    
    // Memory sizes
    parameter int IMEM_ADDR_WIDTH = 16,  // 64KB instruction memory
    parameter int DMEM_ADDR_WIDTH = 16,  // 64KB data memory
    
    // Interconnect configuration
    parameter int NUM_PERIPHERALS = 5    // Slaves 1-5 exposed (Slave 0 is data memory)
)(
    input wire clk_100mhz_in,
    input wire rst_in_n,
    
    input wire [DATA_WIDTH-1:0] boot_addr_in,
    input wire [N_SRC-1:0] plic_irq_i,
    
    input  wire uart_rx_i,
    output wire uart_tx_o,
    
    input wire physical_button_pin,
    output logic dont_opt,
    output logic mie_o_tb
);
    logic irq_pulse;
 //   logic [N_SRC-1:0] plic_irq_i;
 //   assign plic_irq_i = {2'b0 , irq_pulse ,2'b0};
    button_pulse_generator u_btn_irq (
        .clk(clk_o), 
        .btn_in(physical_button_pin), 
        .irq_pulse_out(irq_pulse) 
    );
    
    
    
    
   // logic[DATA_WIDTH-1:0]   boot_addr_in;
  //  assign boot_addr_in = 32'b0;
  
    logic clk_o, rst_n;
    
    logic        icache_arvalid;
    logic        icache_arready;
    logic [31:0] icache_araddr;
    logic [1:0]  icache_arburst;
    logic        icache_rvalid;
    logic [31:0] icache_rdata;
    
    logic        dcache_awvalid, dcache_awready;
    logic [31:0] dcache_awaddr;
    logic [3:0]  dcache_awid;
    logic [7:0]  dcache_awlen;
    logic [2:0]  dcache_awsize;
    logic [1:0]  dcache_awburst;
    logic        dcache_wvalid, dcache_wready;
    logic [31:0] dcache_wdata;
    logic [3:0]  dcache_wstrb;
    logic        dcache_wlast;
    logic        dcache_bvalid, dcache_bready;
    logic [1:0]  dcache_bresp;
    logic [3:0]  dcache_bid;
    logic        dcache_arvalid, dcache_arready;
    logic [31:0] dcache_araddr;
    logic [3:0]  dcache_arid;
    logic [7:0]  dcache_arlen;
    logic [2:0]  dcache_arsize;
    logic [1:0]  dcache_arburst;
    logic        dcache_rvalid, dcache_rready;
    logic [31:0] dcache_rdata;
    logic        dcache_rlast;
    logic [1:0]  dcache_rresp;
    logic [3:0]  dcache_rid;
    
    logic        dmem_awvalid, dmem_awready;
    logic [31:0] dmem_awaddr;
    logic [4:0]  dmem_awid;     
    logic [7:0]  dmem_awlen;
    logic [2:0]  dmem_awsize;
    logic [1:0]  dmem_awburst;
    logic        dmem_awlock;
    logic [3:0]  dmem_awcache;
    logic [2:0]  dmem_awprot;
    logic [3:0]  dmem_awqos;
    logic        dmem_wvalid, dmem_wready;
    logic [31:0] dmem_wdata;
    logic [3:0]  dmem_wstrb;
    logic        dmem_wlast;
    logic        dmem_bvalid, dmem_bready;
    logic [1:0]  dmem_bresp;
    logic [4:0]  dmem_bid;       
    logic        dmem_arvalid, dmem_arready;
    logic [31:0] dmem_araddr;
    logic [4:0]  dmem_arid;       
    logic [7:0]  dmem_arlen;
    logic [2:0]  dmem_arsize;
    logic [1:0]  dmem_arburst;
    logic        dmem_arlock;
    logic [3:0]  dmem_arcache;
    logic [2:0]  dmem_arprot;
    logic [3:0]  dmem_arqos;
    logic        dmem_rvalid, dmem_rready;
    logic [31:0] dmem_rdata;
    logic [1:0]  dmem_rresp;
    logic        dmem_rlast;
    logic [4:0]  dmem_rid;        
    
    
    logic [31:0] periph2_awaddr;
    logic [4:0]  periph2_awid;
    logic [7:0]  periph2_awlen;
    logic [2:0]  periph2_awsize;
    logic [1:0]  periph2_awburst;
    logic        periph2_awlock;
    logic [3:0]  periph2_awcache;
    logic [2:0]  periph2_awprot;
    logic [3:0]  periph2_awqos;
    logic        periph2_awvalid, periph2_awready;
    logic [31:0] periph2_wdata;
    logic [3:0]  periph2_wstrb;
    logic        periph2_wlast, periph2_wvalid, periph2_wready;
    logic [4:0]  periph2_bid;
    logic [1:0]  periph2_bresp;
    logic        periph2_bvalid, periph2_bready;
    logic [31:0] periph2_araddr;
    logic [4:0]  periph2_arid;
    logic [7:0]  periph2_arlen;
    logic [2:0]  periph2_arsize;
    logic [1:0]  periph2_arburst;
    logic        periph2_arlock;
    logic [3:0]  periph2_arcache;
    logic [2:0]  periph2_arprot;
    logic [3:0]  periph2_arqos;
    logic        periph2_arvalid, periph2_arready;
    logic [4:0]  periph2_rid;
    logic [31:0] periph2_rdata;
    logic [1:0]  periph2_rresp;
    logic        periph2_rlast, periph2_rvalid, periph2_rready;
    
    
    
    
    
    logic [31:0] periph3_awaddr;
    logic [4:0]  periph3_awid;
    logic [7:0]  periph3_awlen;
    logic [2:0]  periph3_awsize;
    logic [1:0]  periph3_awburst;
    logic        periph3_awlock;
    logic [3:0]  periph3_awcache;
    logic [2:0]  periph3_awprot;
    logic [3:0]  periph3_awqos;
    logic        periph3_awvalid, periph3_awready;
    logic [31:0] periph3_wdata;
    logic [3:0]  periph3_wstrb;
    logic        periph3_wlast, periph3_wvalid, periph3_wready;
    logic [4:0]  periph3_bid;
    logic [1:0]  periph3_bresp;
    logic        periph3_bvalid, periph3_bready;
    logic [31:0] periph3_araddr;
    logic [4:0]  periph3_arid;
    logic [7:0]  periph3_arlen;
    logic [2:0]  periph3_arsize;
    logic [1:0]  periph3_arburst;
    logic        periph3_arlock;
    logic [3:0]  periph3_arcache;
    logic [2:0]  periph3_arprot;
    logic [3:0]  periph3_arqos;
    logic        periph3_arvalid, periph3_arready;
    logic [4:0]  periph3_rid;
    logic [31:0] periph3_rdata;
    logic [1:0]  periph3_rresp;
    logic        periph3_rlast, periph3_rvalid, periph3_rready;
    
    
    
    
    
    logic [31:0] periph4_awaddr;
    logic [4:0]  periph4_awid;
    logic [7:0]  periph4_awlen;
    logic [2:0]  periph4_awsize;
    logic [1:0]  periph4_awburst;
    logic        periph4_awlock;
    logic [3:0]  periph4_awcache;
    logic [2:0]  periph4_awprot;
    logic [3:0]  periph4_awqos;
    logic        periph4_awvalid, periph4_awready;
    logic [31:0] periph4_wdata;
    logic [3:0]  periph4_wstrb;
    logic        periph4_wlast, periph4_wvalid, periph4_wready;
    logic [4:0]  periph4_bid;
    logic [1:0]  periph4_bresp;
    logic        periph4_bvalid, periph4_bready;
    logic [31:0] periph4_araddr;
    logic [4:0]  periph4_arid;
    logic [7:0]  periph4_arlen;
    logic [2:0]  periph4_arsize;
    logic [1:0]  periph4_arburst;
    logic        periph4_arlock;
    logic [3:0]  periph4_arcache;
    logic [2:0]  periph4_arprot;
    logic [3:0]  periph4_arqos;
    logic        periph4_arvalid, periph4_arready;
    logic [4:0]  periph4_rid;
    logic [31:0] periph4_rdata;
    logic [1:0]  periph4_rresp;
    logic        periph4_rlast, periph4_rvalid, periph4_rready;
    
 
    cache_system_top #(
        .DATA_WIDTH    (DATA_WIDTH),
        .RF_ADDR_WIDTH (RF_ADDR_WIDTH),
        .N_SRC         (N_SRC),
        .PLIC_BASE     (PLIC_BASE),
        .CLINT_BASE    (CLINT_BASE),
        .DCACHE_FLUSH_ADDR (DCACHE_FLUSH_ADDR),
        .DMEM_BASE     (DMEM_BASE),
        .DMEM_ADDR_WIDTH (DMEM_ADDR_WIDTH),
        .CLK_FREQ_HZ   (CLK_FREQ_HZ)
    ) u_cache_system (
        .clk_100mhz_in (clk_100mhz_in),
        .rst_in_n      (rst_in_n),
        .clk_o         (clk_o),
        .rst_o         (rst_n),
        .boot_addr_in  (boot_addr_in),
        .plic_irq_i    (plic_irq_i),
        
     
        .icache_m_axi_arvalid (icache_arvalid),
        .icache_m_axi_arready (icache_arready),
        .icache_m_axi_araddr  (icache_araddr),
        .icache_m_axi_arburst (icache_arburst),
        .icache_m_axi_rvalid  (icache_rvalid),
        .icache_m_axi_rdata   (icache_rdata),
        
       
        .dcache_m_axi_awvalid (dcache_awvalid),
        .dcache_m_axi_awready (dcache_awready),
        .dcache_m_axi_awaddr  (dcache_awaddr),
        .dcache_m_axi_awid    (dcache_awid),
        .dcache_m_axi_awlen   (dcache_awlen),
        .dcache_m_axi_awsize  (dcache_awsize),
        .dcache_m_axi_awburst (dcache_awburst),
        .dcache_m_axi_wvalid  (dcache_wvalid),
        .dcache_m_axi_wready  (dcache_wready),
        .dcache_m_axi_wdata   (dcache_wdata),
        .dcache_m_axi_wstrb   (dcache_wstrb),
        .dcache_m_axi_wlast   (dcache_wlast),
        .dcache_m_axi_bvalid  (dcache_bvalid),
        .dcache_m_axi_bready  (dcache_bready),
        .dcache_m_axi_bresp   (dcache_bresp),
        .dcache_m_axi_bid     (dcache_bid),
        .dcache_m_axi_arvalid (dcache_arvalid),
        .dcache_m_axi_arready (dcache_arready),
        .dcache_m_axi_araddr  (dcache_araddr),
        .dcache_m_axi_arid    (dcache_arid),
        .dcache_m_axi_arlen   (dcache_arlen),
        .dcache_m_axi_arsize  (dcache_arsize),
        .dcache_m_axi_arburst (dcache_arburst),
        .dcache_m_axi_rvalid  (dcache_rvalid),
        .dcache_m_axi_rready  (dcache_rready),
        .dcache_m_axi_rdata   (dcache_rdata),
        .dcache_m_axi_rlast   (dcache_rlast),
        .dcache_m_axi_rresp   (dcache_rresp),
        .dcache_m_axi_rid     (dcache_rid),
        
        .mie_o_tb      (mie_o_tb)
    );
    

    logic iram_awready_nc, iram_wready_nc, iram_bvalid_nc;
    logic [4:0] iram_bid_nc, iram_rid_nc; 
    logic [1:0] iram_bresp_nc, iram_rresp_nc;
    logic iram_rlast_nc;
    logic [4:0]  iram_arid;               
    logic [31:0] iram_araddr;
    logic [7:0]  iram_arlen;
    logic [2:0]  iram_arsize;
    logic [1:0]  iram_arburst;
    logic        iram_arvalid, iram_arready;
    logic [4:0]  iram_rid;                 
    logic [31:0] iram_rdata;
    logic [1:0]  iram_rresp;
    logic        iram_rlast, iram_rvalid, iram_rready;
    
    icache_test_ins_mem #(
        .DATA_WIDTH      (32),
        .ADDR_WIDTH      (IMEM_ADDR_WIDTH),
        .ID_WIDTH        (5),             
        .PIPELINE_OUTPUT (0)
    ) u_ins_ram (
        .clk            (clk_o),
        .rst            (!rst_n),
        
        .s_axi_awid     (5'd0),            
        .s_axi_awaddr   ({IMEM_ADDR_WIDTH{1'b0}}),
        .s_axi_awlen    (8'd0),
        .s_axi_awsize   (3'd0),
        .s_axi_awburst  (2'd0),
        .s_axi_awlock   (1'b0),
        .s_axi_awcache  (4'd0),
        .s_axi_awprot   (3'd0),
        .s_axi_awvalid  (1'b0),
        .s_axi_awready  (iram_awready_nc),
        .s_axi_wdata    (32'd0),
        .s_axi_wstrb    (4'd0),
        .s_axi_wlast    (1'b0),
        .s_axi_wvalid   (1'b0),
        .s_axi_wready   (iram_wready_nc),
        .s_axi_bid      (iram_bid_nc),
        .s_axi_bresp    (iram_bresp_nc),
        .s_axi_bvalid   (iram_bvalid_nc),
        .s_axi_bready   (1'b1),
        
        
        .s_axi_arid     (iram_arid),
        .s_axi_araddr   (iram_araddr[IMEM_ADDR_WIDTH-1:0]),
        .s_axi_arlen    (iram_arlen),         
        .s_axi_arsize   (iram_arsize),            
        .s_axi_arburst  (iram_arburst),
        .s_axi_arlock   (1'b0),
        .s_axi_arcache  (4'd0),
        .s_axi_arprot   (3'd0),
        .s_axi_arvalid  (iram_arvalid),
        .s_axi_arready  (iram_arready),
        .s_axi_rid      (iram_rid),
        .s_axi_rdata    (iram_rdata),
        .s_axi_rresp    (iram_rresp),
        .s_axi_rlast    (iram_rlast),
        .s_axi_rvalid   (iram_rvalid),
        .s_axi_rready   (iram_rready)
    );
    dcache_test_data_mem #(
        .DATA_WIDTH      (32),
        .ADDR_WIDTH      (DMEM_ADDR_WIDTH),
        // addresses arrive already offset into the 64 KB window; the old
        // 0x8000 default only "worked" because it wrapped away at 16 KB
        .ACTIVE_ADDR     (32'h0),
        .ID_WIDTH        (5),             
        .PIPELINE_OUTPUT (0)
    ) u_data_ram (
        .clk            (clk_o),
        .rst            (!rst_n),
        
        // Write Address Channel
        .s_axi_awid     (dmem_awid),
        .s_axi_awaddr   (dmem_awaddr[DMEM_ADDR_WIDTH-1:0]),
        .s_axi_awlen    (dmem_awlen),
        .s_axi_awsize   (dmem_awsize),
        .s_axi_awburst  (dmem_awburst),
        .s_axi_awlock   (dmem_awlock),
        .s_axi_awcache  (dmem_awcache),
        .s_axi_awprot   (dmem_awprot),
        .s_axi_awvalid  (dmem_awvalid),
        .s_axi_awready  (dmem_awready),
        
        // Write Data Channel
        .s_axi_wdata    (dmem_wdata),
        .s_axi_wstrb    (dmem_wstrb),
        .s_axi_wlast    (dmem_wlast),
        .s_axi_wvalid   (dmem_wvalid),
        .s_axi_wready   (dmem_wready),
        
        // Write Response Channel
        .s_axi_bid      (dmem_bid),
        .s_axi_bresp    (dmem_bresp),
        .s_axi_bvalid   (dmem_bvalid),
        .s_axi_bready   (dmem_bready),
        
        // Read Address Channel
        .s_axi_arid     (dmem_arid),
        .s_axi_araddr   (dmem_araddr[DMEM_ADDR_WIDTH-1:0]),
        .s_axi_arlen    (dmem_arlen),
        .s_axi_arsize   (dmem_arsize),
        .s_axi_arburst  (dmem_arburst),
        .s_axi_arlock   (dmem_arlock),
        .s_axi_arcache  (dmem_arcache),
        .s_axi_arprot   (dmem_arprot),
        .s_axi_arvalid  (dmem_arvalid),
        .s_axi_arready  (dmem_arready),
        
        // Read Data Channel
        .s_axi_rid      (dmem_rid),
        .s_axi_rdata    (dmem_rdata),
        .s_axi_rresp    (dmem_rresp),
        .s_axi_rlast    (dmem_rlast),
        .s_axi_rvalid   (dmem_rvalid),
        .s_axi_rready   (dmem_rready)
    );


    logic [31:0] periph1_awaddr;
    logic [4:0]  periph1_awid;
    logic [7:0]  periph1_awlen;
    logic [2:0]  periph1_awsize;
    logic [1:0]  periph1_awburst;
    logic        periph1_awlock;
    logic [3:0]  periph1_awcache;
    logic [2:0]  periph1_awprot;
    logic [3:0]  periph1_awqos;
    logic        periph1_awvalid, periph1_awready;
    logic [31:0] periph1_wdata;
    logic [3:0]  periph1_wstrb;
    logic        periph1_wlast, periph1_wvalid, periph1_wready;
    logic [4:0]  periph1_bid;
    logic [1:0]  periph1_bresp;
    logic        periph1_bvalid, periph1_bready;
    logic [31:0] periph1_araddr;
    logic [4:0]  periph1_arid;
    logic [7:0]  periph1_arlen;
    logic [2:0]  periph1_arsize;
    logic [1:0]  periph1_arburst;
    logic        periph1_arlock;
    logic [3:0]  periph1_arcache;
    logic [2:0]  periph1_arprot;
    logic [3:0]  periph1_arqos;
    logic        periph1_arvalid, periph1_arready;
    logic [4:0]  periph1_rid;
    logic [31:0] periph1_rdata;
    logic [1:0]  periph1_rresp;
    logic        periph1_rlast, periph1_rvalid, periph1_rready;
    
    logic        uart_irq;
    
    
    
    
   logic [31:0]       m_axil_awaddr;  
   logic [2:0]                  m_axil_awprot;   
   logic                        m_axil_awvalid;  
   logic                        m_axil_awready;  
   logic [31:0]  m_axil_wdata;    
   logic [3:0]  m_axil_wstrb;    
   logic                         m_axil_wvalid;   
   logic                        m_axil_wready;   
   logic [1:0]                  m_axil_bresp;    
   logic                        m_axil_bvalid;   
   logic                        m_axil_bready;   
   logic [31:0]       m_axil_araddr;   
   logic [2:0]                  m_axil_arprot;   
   logic                        m_axil_arvalid;  
   logic                        m_axil_arready;  
   logic [31:0]            m_axil_rdata;    
   logic [1:0]                  m_axil_rresp;    
   logic                        m_axil_rvalid;   
   logic                        m_axil_rready;    
   logic uart_irq_o;
    axi_axil_adapter #(
        .AXI_ID_WIDTH (5) 
    ) axi_axil (
        .clk           (clk_o),
        .rst         (!rst_n),
        
        .s_axi_awid    (periph1_awid),
        .s_axi_awaddr  (periph1_awaddr),
        .s_axi_awlen   (periph1_awlen),
        .s_axi_awsize  (periph1_awsize),
        .s_axi_awburst (periph1_awburst),
        .s_axi_awvalid (periph1_awvalid),
        .s_axi_awready (periph1_awready),
        .s_axi_awlock(1'b0),
        .s_axi_awcache(4'b0),
        .s_axi_awprot(3'b0),
        .s_axi_arlock(1'b0),
        .s_axi_arcache(4'b0),
        .s_axi_arprot(3'b0),
        
        
        
        .s_axi_wdata   (periph1_wdata),
        .s_axi_wstrb   (periph1_wstrb),
        .s_axi_wlast   (periph1_wlast),
        .s_axi_wvalid  (periph1_wvalid),
        .s_axi_wready  (periph1_wready),
        
        .s_axi_bid     (periph1_bid),
        .s_axi_bresp   (periph1_bresp),
        .s_axi_bvalid  (periph1_bvalid),
        .s_axi_bready  (periph1_bready),
         
        .s_axi_arid    (periph1_arid),
        .s_axi_araddr  (periph1_araddr),
        .s_axi_arlen   (periph1_arlen),
        .s_axi_arsize  (periph1_arsize),
        .s_axi_arburst (periph1_arburst),
        .s_axi_arvalid (periph1_arvalid),
        .s_axi_arready (periph1_arready),
        
        .s_axi_rid     (periph1_rid),
        .s_axi_rdata   (periph1_rdata),
        .s_axi_rresp   (periph1_rresp),
        .s_axi_rlast   (periph1_rlast),
        .s_axi_rvalid  (periph1_rvalid),
        .s_axi_rready  (periph1_rready),
         
         
        .m_axil_awaddr(m_axil_awaddr),
        .m_axil_awprot(m_axil_awprot),
        .m_axil_awvalid(m_axil_awvalid),
        .m_axil_awready(m_axil_awready),
        .m_axil_wdata(m_axil_wdata),
        .m_axil_wstrb(m_axil_wstrb),
        .m_axil_wvalid(m_axil_wvalid),
        .m_axil_wready(m_axil_wready),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_bvalid(m_axil_bvalid),
        .m_axil_bready(m_axil_bready),
        .m_axil_araddr(m_axil_araddr),
        .m_axil_arprot(m_axil_arprot),
        .m_axil_arvalid(m_axil_arvalid),
        .m_axil_arready(m_axil_arready),
        .m_axil_rdata(m_axil_rdata),
        .m_axil_rresp(m_axil_rresp),
        .m_axil_rvalid(m_axil_rvalid),
        .m_axil_rready(m_axil_rready)
               
    );
    
    
    
    axi_uart16550_0 u_uart_ip (
        .s_axi_aclk    (clk_o),
        .s_axi_aresetn (rst_n),
        .ip2intc_irpt  (uart_irq_o),
        .freeze        (1'b0),
        
        .s_axi_awaddr  ({1'b1, m_axil_awaddr[11:0]}),
        .s_axi_awvalid (m_axil_awvalid),
        .s_axi_awready (m_axil_awready),
        
        .s_axi_wdata   (m_axil_wdata),
        .s_axi_wstrb   (m_axil_wstrb),
        .s_axi_wvalid  (m_axil_wvalid),
        .s_axi_wready  (m_axil_wready),
        
        .s_axi_bresp   (m_axil_bresp),
        .s_axi_bvalid  (m_axil_bvalid),
        .s_axi_bready  (m_axil_bready),
        
        .s_axi_araddr  ({1'b1, m_axil_araddr[11:0]}),
        .s_axi_arvalid (m_axil_arvalid),
        .s_axi_arready (m_axil_arready),
        
        .s_axi_rdata   (m_axil_rdata),
        .s_axi_rresp   (m_axil_rresp),
        .s_axi_rvalid  (m_axil_rvalid),
        .s_axi_rready  (m_axil_rready),
        
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




    axi_crossbar_2x6 #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (32),
        .S_ID_WIDTH (4), 
        
        .M00_BASE_ADDR (IMEM_BASE), .M00_ADDR_WIDTH (IMEM_ADDR_WIDTH),
        .M01_BASE_ADDR (DMEM_BASE), .M01_ADDR_WIDTH (DMEM_ADDR_WIDTH),
        .M02_BASE_ADDR (UART_BASE),  .M02_ADDR_WIDTH (12),
        .M03_BASE_ADDR (SLOT3_BASE), .M03_ADDR_WIDTH (12),
        .M04_BASE_ADDR (SLOT4_BASE), .M04_ADDR_WIDTH (12),
        .M05_BASE_ADDR (SLOT5_BASE), .M05_ADDR_WIDTH (12)
    ) axi_crossbar (
        .clk (clk_o),
        .rst (!rst_n),

        .s00_axi_awid    (4'b0),
        .s00_axi_awaddr  (32'b0),
        .s00_axi_awlen   (8'b0),
        .s00_axi_awsize  (3'b0),
        .s00_axi_awburst (2'b0),
        .s00_axi_awlock  (1'b0),
        .s00_axi_awcache (4'b0),
        .s00_axi_awprot  (3'b0),
        .s00_axi_awqos   (4'b0),
        .s00_axi_awuser  (1'b0),
        .s00_axi_awvalid (1'b0),
        .s00_axi_awready (),
        .s00_axi_wdata   (32'b0),
        .s00_axi_wstrb   (4'b0),
        .s00_axi_wlast   (1'b0),
        .s00_axi_wuser   (1'b0),
        .s00_axi_wvalid  (1'b0),
        .s00_axi_wready  (),
        .s00_axi_bid     (),
        .s00_axi_bresp   (),
        .s00_axi_buser   (),
        .s00_axi_bvalid  (),
        .s00_axi_bready  (1'b0),
        
        .s00_axi_arid    (4'b0), 
        .s00_axi_araddr  (icache_araddr),
        .s00_axi_arlen   (8'd15),        
        .s00_axi_arsize  (3'b010), 
        .s00_axi_arburst (icache_arburst),
        .s00_axi_arlock  (1'b0),
        .s00_axi_arcache (4'b0),
        .s00_axi_arprot  (3'b0),
        .s00_axi_arqos   (4'b0),
        .s00_axi_aruser  (1'b0),
        .s00_axi_arvalid (icache_arvalid),
        .s00_axi_arready (icache_arready),
        .s00_axi_rid     (),
        .s00_axi_rdata   (icache_rdata),
        .s00_axi_rresp   (),
        .s00_axi_rlast   (),
        .s00_axi_ruser   (),
        .s00_axi_rvalid  (icache_rvalid),
        .s00_axi_rready  (1'b1), 

        .s01_axi_awid    (dcache_awid),
        .s01_axi_awaddr  (dcache_awaddr),
        .s01_axi_awlen   (dcache_awlen),
        .s01_axi_awsize  (dcache_awsize),
        .s01_axi_awburst (dcache_awburst),
        .s01_axi_awlock  (1'b0),
        .s01_axi_awcache (4'b0),
        .s01_axi_awprot  (3'b0),
        .s01_axi_awqos   (4'b0),
        .s01_axi_awuser  (1'b0),
        .s01_axi_awvalid (dcache_awvalid),
        .s01_axi_awready (dcache_awready),
        .s01_axi_wdata   (dcache_wdata),
        .s01_axi_wstrb   (dcache_wstrb),
        .s01_axi_wlast   (dcache_wlast),
        .s01_axi_wuser   (1'b0),
        .s01_axi_wvalid  (dcache_wvalid),
        .s01_axi_wready  (dcache_wready),
        .s01_axi_bid     (dcache_bid),
        .s01_axi_bresp   (dcache_bresp),
        .s01_axi_buser   (),
        .s01_axi_bvalid  (dcache_bvalid),
        .s01_axi_bready  (dcache_bready),
        .s01_axi_arid    (dcache_arid),
        .s01_axi_araddr  (dcache_araddr),
        .s01_axi_arlen   (dcache_arlen),
        .s01_axi_arsize  (dcache_arsize),
        .s01_axi_arburst (dcache_arburst),
        .s01_axi_arlock  (1'b0),
        .s01_axi_arcache (4'b0),
        .s01_axi_arprot  (3'b0),
        .s01_axi_arqos   (4'b0),
        .s01_axi_aruser  (1'b0),
        .s01_axi_arvalid (dcache_arvalid),
        .s01_axi_arready (dcache_arready),
        .s01_axi_rid     (dcache_rid),
        .s01_axi_rdata   (dcache_rdata),
        .s01_axi_rresp   (dcache_rresp),
        .s01_axi_rlast   (dcache_rlast),
        .s01_axi_ruser   (),
        .s01_axi_rvalid  (dcache_rvalid),
        .s01_axi_rready  (dcache_rready),

        .m00_axi_awid    (), 
        .m00_axi_awaddr  (),
        .m00_axi_awlen   (),
        .m00_axi_awsize  (),
        .m00_axi_awburst (),
        .m00_axi_awlock  (),
        .m00_axi_awcache (),
        .m00_axi_awprot  (),
        .m00_axi_awqos   (),
        .m00_axi_awregion(),
        .m00_axi_awuser  (),
        .m00_axi_awvalid (),
        .m00_axi_awready (1'b0), 
        .m00_axi_wdata   (),
        .m00_axi_wstrb   (),
        .m00_axi_wlast   (),
        .m00_axi_wuser   (),
        .m00_axi_wvalid  (),
        .m00_axi_wready  (1'b0),
        .m00_axi_bid     (5'b0),
        .m00_axi_bresp   (2'b0),
        .m00_axi_buser   (1'b0),
        .m00_axi_bvalid  (1'b0),
        .m00_axi_bready  (),
        
        .m00_axi_arid    (iram_arid), 
        .m00_axi_araddr  (iram_araddr),
        .m00_axi_arlen   (iram_arlen),
        .m00_axi_arsize  (iram_arsize),
        .m00_axi_arburst (iram_arburst),
        .m00_axi_arlock  (),
        .m00_axi_arcache (),
        .m00_axi_arprot  (),
        .m00_axi_arqos   (),
        .m00_axi_arregion(),
        .m00_axi_aruser  (),
        .m00_axi_arvalid (iram_arvalid),
        .m00_axi_arready (iram_arready),
        .m00_axi_rid     (iram_rid),
        .m00_axi_rdata   (iram_rdata),
        .m00_axi_rresp   (iram_rresp),
        .m00_axi_rlast   (iram_rlast),
        .m00_axi_ruser   (1'b0),
        .m00_axi_rvalid  (iram_rvalid),
        .m00_axi_rready  (iram_rready),

        .m01_axi_awid    (dmem_awid),
        .m01_axi_awaddr  (dmem_awaddr),
        .m01_axi_awlen   (dmem_awlen),
        .m01_axi_awsize  (dmem_awsize),
        .m01_axi_awburst (dmem_awburst),
        .m01_axi_awlock  (dmem_awlock),
        .m01_axi_awcache (dmem_awcache),
        .m01_axi_awprot  (dmem_awprot),
        .m01_axi_awqos   (dmem_awqos),
        .m01_axi_awregion(),
        .m01_axi_awuser  (),
        .m01_axi_awvalid (dmem_awvalid),
        .m01_axi_awready (dmem_awready),
        .m01_axi_wdata   (dmem_wdata),
        .m01_axi_wstrb   (dmem_wstrb),
        .m01_axi_wlast   (dmem_wlast),
        .m01_axi_wuser   (),
        .m01_axi_wvalid  (dmem_wvalid),
        .m01_axi_wready  (dmem_wready),
        .m01_axi_bid     (dmem_bid),
        .m01_axi_bresp   (dmem_bresp),
        .m01_axi_buser   (1'b0),
        .m01_axi_bvalid  (dmem_bvalid),
        .m01_axi_bready  (dmem_bready),
        .m01_axi_arid    (dmem_arid),
        .m01_axi_araddr  (dmem_araddr),
        .m01_axi_arlen   (dmem_arlen),
        .m01_axi_arsize  (dmem_arsize),
        .m01_axi_arburst (dmem_arburst),
        .m01_axi_arlock  (dmem_arlock),
        .m01_axi_arcache (dmem_arcache),
        .m01_axi_arprot  (dmem_arprot),
        .m01_axi_arqos   (dmem_arqos),
        .m01_axi_arregion(),
        .m01_axi_aruser  (),
        .m01_axi_arvalid (dmem_arvalid),
        .m01_axi_arready (dmem_arready),
        .m01_axi_rid     (dmem_rid),
        .m01_axi_rdata   (dmem_rdata),
        .m01_axi_rresp   (dmem_rresp),
        .m01_axi_rlast   (dmem_rlast),
        .m01_axi_ruser   (1'b0),
        .m01_axi_rvalid  (dmem_rvalid),
        .m01_axi_rready  (dmem_rready),

        .m02_axi_awid    (periph1_awid),
        .m02_axi_awaddr  (periph1_awaddr),
        .m02_axi_awlen   (periph1_awlen),
        .m02_axi_awsize  (periph1_awsize),
        .m02_axi_awburst (periph1_awburst),
        .m02_axi_awlock  (periph1_awlock),
        .m02_axi_awcache (periph1_awcache),
        .m02_axi_awprot  (periph1_awprot),
        .m02_axi_awqos   (periph1_awqos),
        .m02_axi_awregion(),
        .m02_axi_awuser  (),
        .m02_axi_awvalid (periph1_awvalid),
        .m02_axi_awready (periph1_awready),
        .m02_axi_wdata   (periph1_wdata),
        .m02_axi_wstrb   (periph1_wstrb),
        .m02_axi_wlast   (periph1_wlast),
        .m02_axi_wuser   (),
        .m02_axi_wvalid  (periph1_wvalid),
        .m02_axi_wready  (periph1_wready),
        .m02_axi_bid     (periph1_bid),
        .m02_axi_bresp   (periph1_bresp),
        .m02_axi_buser   (1'b0),
        .m02_axi_bvalid  (periph1_bvalid),
        .m02_axi_bready  (periph1_bready),
        .m02_axi_arid    (periph1_arid),
        .m02_axi_araddr  (periph1_araddr),
        .m02_axi_arlen   (periph1_arlen),
        .m02_axi_arsize  (periph1_arsize),
        .m02_axi_arburst (periph1_arburst),
        .m02_axi_arlock  (periph1_arlock),
        .m02_axi_arcache (periph1_arcache),
        .m02_axi_arprot  (periph1_arprot),
        .m02_axi_arqos   (periph1_arqos),
        .m02_axi_arregion(),
        .m02_axi_aruser  (),
        .m02_axi_arvalid (periph1_arvalid),
        .m02_axi_arready (periph1_arready),
        .m02_axi_rid     (periph1_rid),
        .m02_axi_rdata   (periph1_rdata),
        .m02_axi_rresp   (periph1_rresp),
        .m02_axi_rlast   (periph1_rlast),
        .m02_axi_ruser   (1'b0),
        .m02_axi_rvalid  (periph1_rvalid),
        .m02_axi_rready  (periph1_rready),

        .m03_axi_awid    (periph2_awid),
        .m03_axi_awaddr  (periph2_awaddr),
        .m03_axi_awlen   (periph2_awlen),
        .m03_axi_awsize  (periph2_awsize),
        .m03_axi_awburst (periph2_awburst),
        .m03_axi_awlock  (periph2_awlock),
        .m03_axi_awcache (periph2_awcache),
        .m03_axi_awprot  (periph2_awprot),
        .m03_axi_awqos   (periph2_awqos),
        .m03_axi_awregion(),
        .m03_axi_awuser  (),
        .m03_axi_awvalid (periph2_awvalid),
        .m03_axi_awready (periph2_awready),
        .m03_axi_wdata   (periph2_wdata),
        .m03_axi_wstrb   (periph2_wstrb),
        .m03_axi_wlast   (periph2_wlast),
        .m03_axi_wuser   (),
        .m03_axi_wvalid  (periph2_wvalid),
        .m03_axi_wready  (periph2_wready),
        .m03_axi_bid     (periph2_bid),
        .m03_axi_bresp   (periph2_bresp),
        .m03_axi_buser   (1'b0),
        .m03_axi_bvalid  (periph2_bvalid),
        .m03_axi_bready  (periph2_bready),
        .m03_axi_arid    (periph2_arid),
        .m03_axi_araddr  (periph2_araddr),
        .m03_axi_arlen   (periph2_arlen),
        .m03_axi_arsize  (periph2_arsize),
        .m03_axi_arburst (periph2_arburst),
        .m03_axi_arlock  (periph2_arlock),
        .m03_axi_arcache (periph2_arcache),
        .m03_axi_arprot  (periph2_arprot),
        .m03_axi_arqos   (periph2_arqos),
        .m03_axi_arregion(),
        .m03_axi_aruser  (),
        .m03_axi_arvalid (periph2_arvalid),
        .m03_axi_arready (periph2_arready),
        .m03_axi_rid     (periph2_rid),
        .m03_axi_rdata   (periph2_rdata),
        .m03_axi_rresp   (periph2_rresp),
        .m03_axi_rlast   (periph2_rlast),
        .m03_axi_ruser   (1'b0),
        .m03_axi_rvalid  (periph2_rvalid),
        .m03_axi_rready  (periph2_rready),

        .m04_axi_awid    (periph3_awid),
        .m04_axi_awaddr  (periph3_awaddr),
        .m04_axi_awlen   (periph3_awlen),
        .m04_axi_awsize  (periph3_awsize),
        .m04_axi_awburst (periph3_awburst),
        .m04_axi_awlock  (periph3_awlock),
        .m04_axi_awcache (periph3_awcache),
        .m04_axi_awprot  (periph3_awprot),
        .m04_axi_awqos   (periph3_awqos),
        .m04_axi_awregion(),
        .m04_axi_awuser  (),
        .m04_axi_awvalid (periph3_awvalid),
        .m04_axi_awready (periph3_awready),
        .m04_axi_wdata   (periph3_wdata),
        .m04_axi_wstrb   (periph3_wstrb),
        .m04_axi_wlast   (periph3_wlast),
        .m04_axi_wuser   (),
        .m04_axi_wvalid  (periph3_wvalid),
        .m04_axi_wready  (periph3_wready),
        .m04_axi_bid     (periph3_bid),
        .m04_axi_bresp   (periph3_bresp),
        .m04_axi_buser   (1'b0),
        .m04_axi_bvalid  (periph3_bvalid),
        .m04_axi_bready  (periph3_bready),
        .m04_axi_arid    (periph3_arid),
        .m04_axi_araddr  (periph3_araddr),
        .m04_axi_arlen   (periph3_arlen),
        .m04_axi_arsize  (periph3_arsize),
        .m04_axi_arburst (periph3_arburst),
        .m04_axi_arlock  (periph3_arlock),
        .m04_axi_arcache (periph3_arcache),
        .m04_axi_arprot  (periph3_arprot),
        .m04_axi_arqos   (periph3_arqos),
        .m04_axi_arregion(),
        .m04_axi_aruser  (),
        .m04_axi_arvalid (periph3_arvalid),
        .m04_axi_arready (periph3_arready),
        .m04_axi_rid     (periph3_rid),
        .m04_axi_rdata   (periph3_rdata),
        .m04_axi_rresp   (periph3_rresp),
        .m04_axi_rlast   (periph3_rlast),
        .m04_axi_ruser   (1'b0),
        .m04_axi_rvalid  (periph3_rvalid),
        .m04_axi_rready  (periph3_rready),

        .m05_axi_awid    (periph4_awid),
        .m05_axi_awaddr  (periph4_awaddr),
        .m05_axi_awlen   (periph4_awlen),
        .m05_axi_awsize  (periph4_awsize),
        .m05_axi_awburst (periph4_awburst),
        .m05_axi_awlock  (periph4_awlock),
        .m05_axi_awcache (periph4_awcache),
        .m05_axi_awprot  (periph4_awprot),
        .m05_axi_awqos   (periph4_awqos),
        .m05_axi_awregion(),
        .m05_axi_awuser  (),
        .m05_axi_awvalid (periph4_awvalid),
        .m05_axi_awready (periph4_awready),
        .m05_axi_wdata   (periph4_wdata),
        .m05_axi_wstrb   (periph4_wstrb),
        .m05_axi_wlast   (periph4_wlast),
        .m05_axi_wuser   (),
        .m05_axi_wvalid  (periph4_wvalid),
        .m05_axi_wready  (periph4_wready),
        .m05_axi_bid     (periph4_bid),
        .m05_axi_bresp   (periph4_bresp),
        .m05_axi_buser   (1'b0),
        .m05_axi_bvalid  (periph4_bvalid),
        .m05_axi_bready  (periph4_bready),
        .m05_axi_arid    (periph4_arid),
        .m05_axi_araddr  (periph4_araddr),
        .m05_axi_arlen   (periph4_arlen),
        .m05_axi_arsize  (periph4_arsize),
        .m05_axi_arburst (periph4_arburst),
        .m05_axi_arlock  (periph4_arlock),
        .m05_axi_arcache (periph4_arcache),
        .m05_axi_arprot  (periph4_arprot),
        .m05_axi_arqos   (periph4_arqos),
        .m05_axi_arregion(),
        .m05_axi_aruser  (),
        .m05_axi_arvalid (periph4_arvalid),
        .m05_axi_arready (periph4_arready),
        .m05_axi_rid     (periph4_rid),
        .m05_axi_rdata   (periph4_rdata),
        .m05_axi_rresp   (periph4_rresp),
        .m05_axi_rlast   (periph4_rlast),
        .m05_axi_ruser   (1'b0),
        .m05_axi_rvalid  (periph4_rvalid),
        .m05_axi_rready  (periph4_rready)
    );
    assign dont_opt = icache_rdata[0] ^ dcache_wdata[0] ^ dmem_rdata[0];

endmodule

`default_nettype wire
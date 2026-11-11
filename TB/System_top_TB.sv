`timescale 1ns / 1ps
`default_nettype none

module riscv_top_tb;

    localparam int CLK_PERIOD  = 10;  // ns
    localparam int IMEM_WORDS  = 1024;
    localparam int DMEM_WORDS  = 10000;
    localparam int SIM_TIMEOUT = 2000;

    logic        clk;
    logic        rst_n;
    logic [31:0] boot_addr;
    logic [31:0] external_irq;
    logic        timer_irq;

    logic        instr_en;
    logic [31:0] instr_addr;
    logic [31:0] instr_rdata;
    logic        instr_gnt;
    logic        instr_rvalid;

    logic        data_req;
    logic        data_gnt;
    logic        data_rvalid;
    logic [31:0] data_addr;
    logic        data_we;
    logic [3:0]  data_strb;
    logic [31:0] data_wdata;
    logic [31:0] data_rdata;
    logic external_irq_i;
    logic mie;
    logic RX_i;
    logic TX_o;
    system_top #(
        .DATA_WIDTH    (32),
        .RF_ADDR_WIDTH (5)
    ) dut (
        .clk_100mhz_in     (clk),
        .rst_in_n          (rst_n),
        .boot_addr_in       (boot_addr),
        .plic_irq_i    (external_irq),
        .mie_o_tb(mie),
        .uart_rx_i(RX_i),
        .uart_tx_o (TX_o)
        
        
    );
    task automatic uart_send();
         RX_i = 0;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1;
         repeat (868) @(posedge clk);
         RX_i = 1; 
         repeat (868) @(posedge clk);
    
    endtask
    

    initial clk = 1'b0;
    always  #(CLK_PERIOD/2) clk = ~clk;

  
       initial begin
        boot_addr    = 32'h4000_0000;   // IMEM base (System_top BOOT_ADDR)
        external_irq = 32'b0;
        timer_irq    = 1'b0;
        rst_n        = 1'b0;
        RX_i = 1'b1;

        repeat (4) @(posedge clk);
        #1;
        rst_n = 1'b1;

        $display("\n[TB] Reset de-asserted at t=%0t\n", $time);
 
        wait(mie == 1'b1);
        repeat(4000) @(posedge clk);
        
        repeat(16) uart_send();
        
        repeat(4000) @(posedge clk);
//        wait(mie == 1'b0);

        #200;
        $display("--- [TB] ecall trap started (MIE=0). Asserting external_irq_i at %0t ---", $time);
        external_irq = 32'd4;
        #400;
        external_irq = 32'b0;
       wait(mie == 1'b1);
       wait(mie == 1'b0);
       #400;
       
       wait(mie == 1'b1);
        
        #200;
        #1000;
        $display("--- [TB] CPU took the async IRQ! De-asserting external_irq_i at %0t ---", $time);
        external_irq = 32'b0;
    end

endmodule
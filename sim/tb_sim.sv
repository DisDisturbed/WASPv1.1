`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
//  Testbench (Verilator) for system_top (simulation only).
//
//  plusargs:
//    +max_cycles=<n>  stop after n clocks           (default 50_000_000)
//    +tx_bytes=<n>    stop once the UART has sent n bytes (default: never)
//    +eot             stop when the UART sends 0x04
//    (default)        stop when the program is finished: all of uart_rx.bin
//                     has been read and the program sits in its UART receive
//                     loop waiting for more (see "Done" in axi_uart16550_0.sv).
//                     Off with +no_auto_stop, and while +plic_irq_at is used
//                     (that test idles on an empty input until the IRQ).
//    +plic_irq_at=<n> raise PLIC source 2 (the board button) at cycle n,
//                     for 16 clocks (level, like the debounced button)
//    +uart_rx=<file> / +uart_tx=<file>  see sim/axi_uart16550_0.sv
//  waveform model only (make -C sim wave, built with +define+WAVES):
//    +wave=<file>       FST file name                 (default wave.fst)
//    +wave_start=<n>    start dumping at cycle n      (default 0)
//  Memory images: imem.mem / dmem.mem in the working directory.
// ============================================================================
module tb_sim #(parameter logic [31:0] BOOT = 32'h4000_0000);  // IMEM base
    logic clk = 0;
    logic rst_n = 0;
    logic [4:0] plic_irq = '0;
    logic mie, tx;

    always #5 clk = ~clk;

    system_top dut (
        .clk_100mhz_in      (clk),
        .rst_in_n           (rst_n),
        .boot_addr_in       (BOOT),
        .plic_irq_i         (plic_irq),
        .uart_rx_i          (1'b1),
        .uart_tx_o          (tx),
        .mie_o_tb           (mie)
    );

    longint max_cycles, tx_bytes, cyc, irq_at;
    bit     eot, auto_stop;
    localparam int DONE_POLLS = 8;   // consecutive idle LSR polls = waiting for input
    initial begin
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 50_000_000;
        if (!$value$plusargs("tx_bytes=%d",   tx_bytes))   tx_bytes   = -1;
        if (!$value$plusargs("plic_irq_at=%d", irq_at)) irq_at = -1;
        eot = $test$plusargs("eot");
        auto_stop = !$test$plusargs("no_auto_stop") && irq_at < 0;
        cyc = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
    end

`ifdef WAVES
    string  wave_file;
    longint wave_start;
    initial begin
        if (!$value$plusargs("wave=%s", wave_file))        wave_file  = "wave.fst";
        if (!$value$plusargs("wave_start=%d", wave_start)) wave_start = 0;
        // $dumpoff/$dumpon are no-ops here, so open the dump at the start cycle
        if (wave_start > 0) wait (cyc >= wave_start);
        $dumpfile(wave_file);
        $dumpvars(0, tb_sim);
        $display("[TB] dumping waveform to %s from cycle %0d", wave_file, wave_start);
    end
`endif

    always @(posedge clk) begin
        cyc <= cyc + 1;
        plic_irq[2] <= (irq_at >= 0) && (cyc >= irq_at) && (cyc < irq_at + 16);
        if (cyc >= max_cycles) begin
            $display("[TB] max_cycles (%0d) reached, %0d UART bytes sent", max_cycles, dut.u_uart_ip.tx_count);
            $finish;
        end
        if (eot && dut.u_uart_ip.last_tx == 8'h04) begin
            $display("[TB] EOT received after %0d cycles", cyc);
            $finish;
        end
        if (auto_stop && dut.u_uart_ip.rx_wait_polls >= DONE_POLLS) begin
            $display("[TB] program finished (all UART input read, waiting for more): %0d UART bytes sent after %0d cycles",
                     dut.u_uart_ip.tx_count, cyc);
            $finish;
        end
        if (tx_bytes >= 0 && dut.u_uart_ip.tx_count >= tx_bytes) begin
            $display("[TB] %0d UART bytes sent after %0d cycles", dut.u_uart_ip.tx_count, cyc);
            $finish;
        end
    end
endmodule
`default_nettype wire

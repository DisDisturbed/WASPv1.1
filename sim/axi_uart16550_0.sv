`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
//  SIMULATION-ONLY stand-in for the Xilinx axi_uart16550_0 IP.
//  Never add this file to the Vivado project -- the real IP is used there.
//
//  Port list matches the instantiation in System_top.sv. Register map is the
//  standard 16550 one at (addr[4:2]), same as the IP (IP base offset 0x1000
//  is ignored):  0 RBR/THR (DLL when LCR.DLAB)  1 IER (DLM)  2 IIR/FCR
//                3 LCR  4 MCR  5 LSR  6 MSR  7 SCR
//
//  Bytes are not serialised on sin/sout. Instead:
//    TX : every THR write is appended to the file given by +uart_tx=<file>
//         (default uart_tx.bin) and echoed to stdout as hex.
//    RX : bytes are read from +uart_rx=<file> (default uart_rx.bin). A new
//         byte becomes visible (LSR.DR) RX_GAP clocks after the previous one
//         was read, to mimic a real line.
//    Done : rx_wait_polls counts LSR reads made after the RX file has run
//         out, with no THR write in between. A program blocked in its UART
//         receive loop (all input consumed = finished) drives it up fast;
//         sending a byte (one LSR read, then a THR write) resets it. Used by
//         tb_sim to stop the simulation when the program is done.
// ============================================================================
module axi_uart16550_0 #(
    parameter int RX_GAP = 64
)(
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    output logic       ip2intc_irpt,
    input  wire        freeze,

    input  wire [12:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output logic       s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output logic       s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic       s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [12:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output logic       s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic       s_axi_rvalid,
    input  wire        s_axi_rready,

    output logic       baudoutn,
    input  wire        ctsn,
    input  wire        dcdn,
    output logic       ddis,
    input  wire        dsrn,
    output logic       dtrn,
    output logic       out1n,
    output logic       out2n,
    input  wire        rin,
    output logic       rtsn,
    output logic       rxrdyn,
    input  wire        sin,
    output logic       sout,
    output logic       txrdyn
);
    assign ip2intc_irpt = 1'b0;
    assign baudoutn = 1'b1; assign ddis = 1'b0; assign dtrn = 1'b1;
    assign out1n = 1'b1; assign out2n = 1'b1; assign rtsn = 1'b1;
    assign rxrdyn = 1'b1; assign sout = 1'b1; assign txrdyn = 1'b0;
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    logic [7:0] lcr, ier, mcr, scr, dll, dlm;

    // ---------------- RX byte source ----------------
    integer rx_fd, tx_fd;
    string  rx_name, tx_name;
    logic       rx_valid;
    logic [7:0] rx_byte;
    int         rx_gap_cnt;
    longint     tx_count;
    logic [7:0] last_tx = 8'h00;
    logic       rx_eof;          // RX file exhausted (or missing)
    longint     rx_wait_polls;   // see "Done" above

    initial begin
        if (!$value$plusargs("uart_rx=%s", rx_name)) rx_name = "uart_rx.bin";
        if (!$value$plusargs("uart_tx=%s", tx_name)) tx_name = "uart_tx.bin";
        rx_fd = $fopen(rx_name, "rb");
        tx_fd = $fopen(tx_name, "wb");
        if (rx_fd == 0) $display("[UART-SIM] no RX file '%s' (RX stays empty)", rx_name);
        tx_count = 0;
    end

    // ---------------- AXI-lite write ----------------
    logic aw_hold, w_hold;
    logic [12:0] aw_addr_r;
    logic [31:0] w_data_r;

    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold  && !s_axi_bvalid;

    logic do_read_rbr;   // set by the read channel

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_hold <= 0; w_hold <= 0; s_axi_bvalid <= 0;
            lcr <= 8'h03; ier <= 0; mcr <= 0; scr <= 0; dll <= 0; dlm <= 0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin aw_hold <= 1; aw_addr_r <= s_axi_awaddr; end
            if (s_axi_wvalid  && s_axi_wready)  begin w_hold  <= 1; w_data_r  <= s_axi_wdata;  end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;

            if (aw_hold && w_hold) begin
                aw_hold <= 0; w_hold <= 0; s_axi_bvalid <= 1;
                case (aw_addr_r[4:2])
                    3'd0: if (lcr[7]) dll <= w_data_r[7:0];
                          else begin
                              $fwrite(tx_fd, "%c", w_data_r[7:0]);
                              $fflush(tx_fd);
                              tx_count <= tx_count + 1;
                              last_tx  <= w_data_r[7:0];
                          end
                    3'd1: if (lcr[7]) dlm <= w_data_r[7:0]; else ier <= w_data_r[7:0];
                    3'd3: lcr <= w_data_r[7:0];
                    3'd4: mcr <= w_data_r[7:0];
                    3'd7: scr <= w_data_r[7:0];
                    default: ;
                endcase
            end
        end
    end

    // ---------------- AXI-lite read ----------------
    logic [7:0] rd_val;
    always_comb begin
        case (s_axi_araddr[4:2])
            3'd0: rd_val = lcr[7] ? dll : rx_byte;
            3'd1: rd_val = lcr[7] ? dlm : ier;
            3'd2: rd_val = 8'hC1;                       // FIFOs enabled, no irq
            3'd3: rd_val = lcr;
            3'd4: rd_val = mcr;
            3'd5: rd_val = {1'b0, 1'b1, 1'b1, 4'b0, rx_valid}; // TEMT THRE .. DR
            3'd6: rd_val = 8'hB0;
            default: rd_val = scr;
        endcase
    end

    assign s_axi_arready = !s_axi_rvalid;
    assign do_read_rbr = s_axi_arvalid && s_axi_arready && (s_axi_araddr[4:2] == 3'd0) && !lcr[7];

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 0; s_axi_rdata <= 0;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rdata  <= {24'b0, rd_val};
            end
        end
    end

    // ---------------- end-of-program detection ----------------
    wire thr_write = aw_hold && w_hold && (aw_addr_r[4:2] == 3'd0) && !lcr[7];
    wire lsr_read  = s_axi_arvalid && s_axi_arready && (s_axi_araddr[4:2] == 3'd5);
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn)                      rx_wait_polls <= 0;
        else if (thr_write)                      rx_wait_polls <= 0;
        else if (lsr_read && rx_eof && !rx_valid) rx_wait_polls <= rx_wait_polls + 1;
    end

    // ---------------- RX sequencing ----------------
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            rx_valid <= 0; rx_gap_cnt <= RX_GAP; rx_byte <= 0; rx_eof <= (rx_fd == 0);
        end else begin
            if (do_read_rbr && rx_valid) begin
                rx_valid   <= 0;
                rx_gap_cnt <= RX_GAP;
            end else if (!rx_valid) begin
                if (rx_gap_cnt != 0) rx_gap_cnt <= rx_gap_cnt - 1;
                else if (rx_fd != 0) begin
                    automatic int c = $fgetc(rx_fd);
                    if (c >= 0) begin
                        rx_byte  <= c[7:0];
                        rx_valid <= 1;
                    end else begin
                        rx_gap_cnt <= 1000;     // EOF: poll again later
                        rx_eof     <= 1;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire

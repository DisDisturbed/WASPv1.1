`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
//  riscv-tests testbench for system_top (Verilator, simulation only).
//
//  Runs one riscv-tests program (imem.mem / dmem.mem in the working
//  directory, built with env/wasp) and decides pass/fail from the tohost
//  protocol:
//      tohost == 1               PASS
//      tohost == (n << 1) | 1    FAIL, test case n
//      no tohost write in time   TIMEOUT (hang / runaway)
//
//  tohost lives in DMEM, which sits behind a write-back D-cache, so the
//  store may never reach the RAM model.  The testbench therefore snoops the
//  core's OBI data port (cache_system_top.core_data_bus) instead of memory:
//  the first granted word store to +tohost ends the run.
//
//  plusargs:
//    +tohost=<hex>      tohost address               (default 80000000)
//    +max_cycles=<n>    timeout                      (default 200000)
//    +test=<name>       name used in the verdict line
//  Output: verdict on stdout and in result.txt (one line, parsed by the
//  Makefile), cpu_trace.log (per-commit trace from Core_Top) unless the
//  model was built with WASP_NO_TRACE.
// ============================================================================
module tb_rvtest #(parameter logic [31:0] BOOT = 32'h4000_0000);
    logic clk = 0;
    logic rst_n = 0;
    logic mie, tx;

    always #5 clk = ~clk;

    system_top dut (
        .clk_100mhz_in      (clk),
        .rst_in_n           (rst_n),
        .boot_addr_in       (BOOT),
        .plic_irq_i         ('0),
        .uart_rx_i          (1'b1),
        .uart_tx_o          (tx),
        .mie_o_tb           (mie)
    );

`ifdef WAVES
    string wave_file;
    initial begin
        if (!$value$plusargs("wave=%s", wave_file)) wave_file = "wave.fst";
        $dumpfile(wave_file);
        $dumpvars(0, tb_rvtest);
    end
`endif

    // ---- probes into the design (read-only) -------------------------------
    wire        d_req   = dut.u_cache_system.core_data_bus.req;
    wire        d_gnt   = dut.u_cache_system.core_data_bus.gnt;
    wire        d_we    = dut.u_cache_system.core_data_bus.we;
    wire [31:0] d_addr  = dut.u_cache_system.core_data_bus.addr;
    wire [31:0] d_wdata = dut.u_cache_system.core_data_bus.wdata;
    wire [3:0]  d_be    = dut.u_cache_system.core_data_bus.be;

    wire        c_trap   = dut.u_cache_system.u_core.wb_commit_trap;
    wire [5:0]  c_cause  = dut.u_cache_system.u_core.wb_commit_trap_cause;
    wire        c_retire = dut.u_cache_system.u_core.wb_commit_retire;
    wire [31:0] wb_pc    = dut.u_cache_system.u_core.mem_wb_bus.pc;
    wire [31:0] if_pc    = dut.u_cache_system.u_core.pc_if;
    wire [31:0] mcause   = dut.u_cache_system.u_core.csr_inst.mcause_r;
    wire [31:0] mepc     = dut.u_cache_system.u_core.csr_inst.mepc_r;
    wire [31:0] gp       = dut.u_cache_system.u_core.id_stage_inst.rf_inst.reg_file_mem[3];

    // ---- random interrupt injection (riscv-dv flow, off by default) --------
    //   +irq_rate=N   an idle injector starts an interrupt with probability
    //                 1/N per cycle: the external (PLIC output) or software
    //                 (CLINT msip) line of the core, chosen at random, held
    //                 until the core commits an interrupt trap, then dropped
    //                 (like an interrupt the handler acknowledged).
    //   +irq_seed=S   seed (default 1)
    // The lines are forced at the core boundary inside cache_system_top, so
    // no PLIC/CLINT programming is needed. A program that never enables an
    // interrupt simply keeps the line pending until it ends.
    int unsigned irq_rate, irq_seed, irq_injected, irq_taken;
    logic        inj_ext, inj_sw;
    initial begin
        inj_ext = 0; inj_sw = 0; irq_injected = 0; irq_taken = 0;
        if (!$value$plusargs("irq_rate=%d", irq_rate)) irq_rate = 0;
        if (!$value$plusargs("irq_seed=%d", irq_seed)) irq_seed = 1;
        if (irq_rate != 0) begin
            void'($urandom(irq_seed));
            force dut.u_cache_system.plic_ext_irq   = inj_ext;
            force dut.u_cache_system.clint_soft_irq = inj_sw;
        end
    end
    always @(posedge clk) begin
        if (rst_n && irq_rate != 0) begin
            if ((inj_ext || inj_sw) && c_trap && c_cause[5]) begin
                inj_ext   <= 1'b0;
                inj_sw    <= 1'b0;
                irq_taken <= irq_taken + 1;
            end else if (!inj_ext && !inj_sw && ($urandom % irq_rate) == 0) begin
                if ($urandom % 2) inj_ext <= 1'b1; else inj_sw <= 1'b1;
                irq_injected <= irq_injected + 1;
            end
        end
    end

    // ---- run control ------------------------------------------------------
    longint     max_cycles, cyc, retired, traps;
    logic [31:0] tohost;
    string      test_name;
    logic [31:0] last_pc;
    int         fd;

    initial begin
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 200_000;
        if (!$value$plusargs("tohost=%h", tohost))         tohost     = 32'h8000_0000;
        if (!$value$plusargs("test=%s", test_name))        test_name  = "test";
        cyc = 0; retired = 0; traps = 0; last_pc = '0;
        repeat (4) @(posedge clk);
        rst_n = 1;
    end

    task automatic finish_run(input string verdict, input string detail);
        $display("[RVTEST] %-28s %-7s %s | cycles=%0d instret=%0d traps=%0d irqs=%0d",
                 test_name, verdict, detail, cyc, retired, traps, irq_taken);
        fd = $fopen("result.txt", "w");
        $fdisplay(fd, "%s %s %s | cycles=%0d instret=%0d traps=%0d irqs=%0d",
                  verdict, test_name, detail, cyc, retired, traps, irq_taken);
        $fclose(fd);
        $finish;
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            cyc <= cyc + 1;
            if (c_retire) begin
                retired <= retired + 1;
                last_pc <= wb_pc;
            end
            if (c_trap) begin
                traps <= traps + 1;
                $display("[RVTEST] trap #%0d at cycle %0d: cause=%s%0d pc=%h",
                         traps + 1, cyc, c_cause[5] ? "irq " : "", c_cause[4:0], wb_pc);
            end

            if (d_req && d_gnt && d_we && d_addr == tohost) begin
                if (d_wdata == 32'd1)
                    finish_run("PASS", "");
                else if ((d_wdata & 32'd1337) == 32'd1337)
                    // env other_exception: TESTNUM | 1337 (exact TESTNUM is lost in the OR)
                    finish_run("FAIL", $sformatf("unexpected trap: mcause=0x%08h mepc=0x%08h (tohost=0x%08h = TESTNUM|1337)",
                                                 mcause, mepc, d_wdata));
                else if (d_wdata[0])
                    finish_run("FAIL", $sformatf("test case %0d failed (tohost=0x%08h, mcause=0x%08h mepc=0x%08h)",
                                                 d_wdata >> 1, d_wdata, mcause, mepc));
                else
                    finish_run("FAIL", $sformatf("unexpected tohost value 0x%08h (mcause=0x%08h mepc=0x%08h)",
                                                 d_wdata, mcause, mepc));
            end

            if (cyc >= max_cycles)
                finish_run("TIMEOUT", $sformatf("no tohost write after %0d cycles: IF pc=%h, last retired pc=%h, gp(TESTNUM)=%0d, mcause=0x%08h mepc=0x%08h",
                                                max_cycles, if_pc, last_pc, gp, mcause, mepc));
        end
    end
endmodule
`default_nettype wire

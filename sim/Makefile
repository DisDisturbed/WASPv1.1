# Verilator build of the whole SoC (system_top) for simulation.
# Run from Windows via:  sim/msys.sh "make -C sim"
#   make -C sim            -> builds obj_dir/Vtb_sim
#   sim/run.sh <prog> [plusargs]   (see run.sh; SIM=obj_fast for the quiet model)
#   make -C sim wave       -> FST waveform run in sim/active_test/ (see bottom)

RTL  := ../RTL
PKG  := $(RTL)/PGK_IF/core_pgk.sv $(RTL)/PGK_IF/obi_if.sv $(RTL)/PGK_IF/Irq_if.sv
SRCS := $(PKG) \
        $(wildcard $(RTL)/*.sv) \
        $(wildcard $(RTL)/*.v) \
        axi_uart16550_0.sv tb_sim.sv

VFLAGS := --binary --timing -j 0 -O3 --top-module tb_sim \
          -I$(RTL) -I$(RTL)/PGK_IF \
          -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-MULTIDRIVEN \
          -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
          -Wno-INITIALDLY -Wno-COMBDLY -Wno-LATCH -Wno-SELRANGE \
          +define+VERILATOR $(EXTRA)

obj_dir/Vtb_sim: $(SRCS)
	verilator $(VFLAGS) $(SRCS)

clean:
	rm -rf obj_fast obj_dir obj_wave obj_spike work
.PHONY: clean

# Same model without the per-commit trace / CSR prints: for long runs
# (SPHINCS+ is billions of cycles of trace otherwise).
obj_fast/Vtb_sim: $(SRCS)
	verilator $(VFLAGS) --Mdir obj_fast +define+WASP_NO_TRACE +define+CSR_QUIET $(SRCS)
fast: obj_fast/Vtb_sim
.PHONY: fast

# ---------------------------------------------------------------------------
# Runs in sim/active_test/ (normally driven from the top-level Makefile:
# make build|run|wave PROG=<name>, see ../Makefile)
#
#   make -C sim load PROG=aes   build sw/ (TARGET=wasp) and copy imem.mem/dmem.mem here
#   make -C sim wave            run active_test/*.mem, FST -> active_test/wave.fst
#   make -C sim run             same on the quiet fast model, no waveform
#   make -C sim spike           run active_test/main.elf on Spike (ISA reference)
#   make -C sim view            open wave.fst in Surfer (VIEWER=gtkwave for GTKWave)
#
# Knobs:
#   (the run also stops by itself once all RX input is read and the program
#    waits for more; ARGS=+no_auto_stop turns that off)
#   MAX_CYCLES  stop after this many clocks          (default 1000000)
#   WAVE_START  start dumping at this cycle          (wave only, default 0)
#   RX          file fed to the UART RX              (default: active_test/uart_rx.bin or empty;
#               `load` deletes uart_rx.bin, so give RX on every run that needs input)
#   TX_BYTES    stop after this many UART TX bytes   (default: off)
#   PLIC_IRQ_AT pulse PLIC source 2 at this cycle    (default: off)
#   ARGS        any other tb_sim plusargs, e.g. ARGS=+eot
#   EOT=1       stop when the program sends 0x04     (same as ARGS=+eot)
#   spike only: MAX_CYCLES / PLIC_IRQ_AT count *instructions* (Spike has no
#               clock; CPI = 1), SPIKE_LOG=0 turns off spike_trace.log,
#               SPIKE=<path to spike>
# Outputs in active_test/: wave.fst, uart_tx.bin, sim.log (console),
# cpu_trace.log (wave only: one line per committed instruction),
# spike_trace.log (spike: one line per committed instruction).
# FST of the whole SoC is ~3-4 MB per 100k cycles; use WAVE_START /
# MAX_CYCLES to window long programs.
# ---------------------------------------------------------------------------
ACTIVE      := active_test
MAX_CYCLES  ?= 1000000
WAVE_START  ?= 0
PROG        ?= aes
# sw/build/wasp/<dir> for this PROG (sphincs builds go to sphincs_<SPX>[_hwrng])
BUILD_DIR    = ../sw/build/wasp/$(PROG)$(if $(filter sphincs,$(PROG)),_$(or $(SPX),128s)$(if $(filter hw,$(RNG)),_hwrng))

obj_wave/Vtb_sim: $(SRCS)
	verilator $(VFLAGS) --Mdir obj_wave --trace-fst --trace-structs --trace-threads 2 \
	          +define+WAVES $(SRCS)
wave-build: obj_wave/Vtb_sim

# $(call run_active,<model dir>,<extra plusargs>)
define run_active
	@test -f $(ACTIVE)/imem.mem -a -f $(ACTIVE)/dmem.mem || \
	  { echo "no imem.mem/dmem.mem in sim/$(ACTIVE)/ (use: make build PROG=<name>)"; exit 1; }
	@if [ -n "$(RX)" ]; then cp "$(RX)" $(ACTIVE)/uart_rx.bin; fi
	@[ -f $(ACTIVE)/uart_rx.bin ] || : > $(ACTIVE)/uart_rx.bin
	@echo "[sim] $(1) in sim/$(ACTIVE)/, max_cycles=$(MAX_CYCLES)"
	@cd $(ACTIVE) && ../$(1)/Vtb_sim +max_cycles=$(MAX_CYCLES) $(2) \
	  $(if $(TX_BYTES),+tx_bytes=$(TX_BYTES)) $(if $(PLIC_IRQ_AT),+plic_irq_at=$(PLIC_IRQ_AT)) \
	  $(if $(filter 1,$(EOT)),+eot) $(ARGS) > sim.log 2>&1 || true
	@grep -E "^\[TB\]|Error|FATAL" $(ACTIVE)/sim.log || true
	@echo "[sim] UART TX: $$(wc -c < $(ACTIVE)/uart_tx.bin) bytes in sim/$(ACTIVE)/uart_tx.bin"
endef

wave: obj_wave/Vtb_sim
	@rm -f $(ACTIVE)/wave.fst
	$(call run_active,obj_wave,+wave_start=$(WAVE_START))
	@echo "[sim] waveform: sim/$(ACTIVE)/wave.fst ($$(du -h $(ACTIVE)/wave.fst | cut -f1))"

run: obj_fast/Vtb_sim
	@rm -f $(ACTIVE)/cpu_trace.log
	$(call run_active,obj_fast,)

# ---- Spike: same ELF, wasp peripherals from the spike/wasp_periph.cc plugin
SPIKE      ?= $(or $(shell command -v spike 2>/dev/null),/home/yusuf/spike/bin/spike)
SPIKE_INC  ?= $(abspath $(dir $(SPIKE))../include)
SPIKE_LOG  ?= 1
SPIKE_ISA  ?= rv32im_zicsr_zicntr
SPIKE_MEM   = -m0x40000000:0x10000,0x80000000:0x10000 --pc=0x40000000

obj_spike/libwasp_periph.so: spike/wasp_periph.cc
	@mkdir -p obj_spike
	g++ -std=c++20 -O2 -fPIC -shared -I$(SPIKE_INC) -o $@ $<
spike-build: obj_spike/libwasp_periph.so

spike: obj_spike/libwasp_periph.so
	@test -f $(ACTIVE)/main.elf || \
	  { echo "no main.elf in sim/$(ACTIVE)/ (use: make build PROG=<name>)"; exit 1; }
	@if [ -n "$(RX)" ]; then cp "$(RX)" $(ACTIVE)/uart_rx.bin; fi
	@[ -f $(ACTIVE)/uart_rx.bin ] || : > $(ACTIVE)/uart_rx.bin
	@rm -f $(ACTIVE)/spike_trace.log
	@echo "[spike] main.elf in sim/$(ACTIVE)/, max_instructions=$(MAX_CYCLES)"
	@cd $(ACTIVE) && $(SPIKE) --isa=$(SPIKE_ISA) $(SPIKE_MEM) --instructions=$(MAX_CYCLES) \
	  $(if $(filter 1,$(SPIKE_LOG)),-l --log-commits --log=spike_trace.log) \
	  --extlib=$(abspath obj_spike/libwasp_periph.so) \
	  --device=wasp_periph$(if $(TX_BYTES),$(COMMA)tx_bytes=$(TX_BYTES))$(if $(PLIC_IRQ_AT),$(COMMA)plic_irq_at=$(PLIC_IRQ_AT))$(if $(filter 1,$(EOT)),$(COMMA)eot) \
	  main.elf > sim.log 2>&1 || true
	@grep -E "^\[SPIKE\]|rror|xception|trap" $(ACTIVE)/sim.log || true
	@echo "[spike] UART TX: $$(wc -c < $(ACTIVE)/uart_tx.bin) bytes in sim/$(ACTIVE)/uart_tx.bin"
COMMA := ,

# build sw/ firmware (TARGET=wasp) and copy its memory images, ELF and disassembly here
load:
	$(MAKE) -C ../sw TARGET=wasp PROG=$(PROG) $(if $(SPX),SPX=$(SPX)) $(if $(RNG),RNG=$(RNG))
	cp $(BUILD_DIR)/imem.mem $(BUILD_DIR)/dmem.mem $(BUILD_DIR)/main.elf $(BUILD_DIR)/dump.txt $(ACTIVE)/
	@rm -f $(ACTIVE)/uart_rx.bin   # new program: drop the previous program's UART input
	@echo "[build] $(PROG) -> sim/$(ACTIVE)/{imem,dmem}.mem, main.elf, dump.txt"

VIEWER ?= surfer
view:
	$(VIEWER) $(ACTIVE)/wave.fst > /dev/null 2>&1 &

clean-active:
	cd $(ACTIVE) && rm -f wave.fst sim.log cpu_trace.log spike_trace.log uart_tx.bin uart_rx.bin host_tx.bin \
	  imem.mem dmem.mem main.elf dump.txt

.PHONY: wave-build wave run spike-build spike load view clean-active

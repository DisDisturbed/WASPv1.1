# wasp top-level: build firmware and run it on the Verilator model or the PC.
#
#   make <build|run|wave|spike|view> PROG=<app> [SPX=128f|128s] [RNG=det|hw] [TARGET=wasp|host]
#
#   PROG    aes | counters | sphincs                    (see sw/Makefile)
#   SPX     SPHINCS+ set: 128s (default) | 128f
#   RNG     det (default)  fixed seed: Verilator, FPGA and PC give the same bytes
#           hw             real randomness from mcycle jitter (FPGA builds)
#   TARGET  wasp (default) RISC-V image: Verilator now, same imem/dmem.mem on the FPGA
#           host           same app compiled with the PC's gcc (UART = stdin/stdout,
#                          cycle counters read 0; no counters app, no RNG=hw)
#
#   make build   compile; wasp: copy imem.mem/dmem.mem (+ main.elf, dump.txt) into
#                sim/active_test/ (also the files for the FPGA), host: sw/build/host/
#   make run     build + run. wasp: fast Verilator model (no waveform).
#                host: run the PC build on the same UART input -> host_tx.bin and
#                compare with the last Verilator uart_tx.bin (cycle fields skipped)
#   make wave    build + Verilator with an FST waveform -> sim/active_test/wave.fst (wasp)
#   make spike   build + same ELF on Spike (ISA reference, wasp peripherals via plugin)
#   make view    open sim/active_test/wave.fst in Surfer (VIEWER=gtkwave for GTKWave)
#   make test    regression (AES, PLIC IRQ, counters; Verilator == PC); test-spx adds SPHINCS+
#   make clean   remove firmware builds, Verilator models, active_test outputs
#
# Leave PROG out of wave/run/spike to simulate whatever is already in sim/active_test/.
# Outputs of every run are in sim/active_test/ (uart_rx.bin in, uart_tx.bin /
# host_tx.bin out, sim.log, wave.fst).
#
# Verilator stops by itself when the program is finished (all of the RX input
# read and the program waiting for more); MAX_CYCLES is only a safety limit,
# so raise it for long runs (SPHINCS+-128f K + S needs ~12000000000).
# Simulation knobs (see sim/Makefile): MAX_CYCLES (default 1000000),
# WAVE_START, RX=<uart input: .txt command list (see rx.txt) or raw .bin>, TX_BYTES, PLIC_IRQ_AT, EOT=1, ARGS=<plusargs>.
# On Spike, MAX_CYCLES and PLIC_IRQ_AT count instructions; SPIKE_LOG=0 skips
# the commit log (sim/active_test/spike_trace.log).
#   make wave PROG=aes RX=sim/host/vectors/aes_rx.bin TX_BYTES=16
#   make run  PROG=aes RX=sim/host/vectors/aes_rx.txt TARGET=host
#   make run  PROG=sphincs SPX=128f RX=rx.txt TARGET=host      (edit rx.txt)
#   make run  PROG=counters EOT=1 MAX_CYCLES=50000000
#   make run  PROG=sphincs SPX=128f RX=rx.bin TX_BYTES=100 MAX_CYCLES=3000000000
#   make run  PROG=sphincs SPX=128f RX=rx.bin TARGET=host
#   make build PROG=sphincs SPX=128f RNG=hw          FPGA image with real randomness

# make passes command-line variables (PROG, SPX, MAX_CYCLES, ...) down to
# the sub-makes automatically. RX is re-passed as an absolute path because
# sim/Makefile runs in sim/.
# RX=<file>.txt is an editable command list (see rx.txt, sim/host/rxgen.py):
# it is converted to sim/work/rx_txt.bin first; any other RX is used as is.
RX_BIN  = $(if $(filter %.txt,$(RX)),$(abspath sim/work/rx_txt.bin),$(if $(RX),$(abspath $(RX))))
RX_CONV = $(if $(filter %.txt,$(RX)),@mkdir -p sim/work && python3 sim/host/rxgen.py $(RX) $(RX_BIN))
SIM_RX  = $(if $(RX),RX=$(RX_BIN))

all:
	@sed -n '2,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

TARGET ?= wasp
ifeq ($(filter $(TARGET),wasp host),)
  $(error unknown TARGET=$(TARGET) (wasp | host))
endif
ACTIVE   = sim/active_test
HOST_DIR = sw/build/host/$(PROG)$(if $(filter sphincs,$(PROG)),_$(or $(SPX),128s))

ifeq ($(TARGET),wasp)
build:
	@test -n "$(PROG)" || { echo "usage: make build PROG=<aes|counters|sphincs|...>"; exit 1; }
	$(MAKE) -C sim load

wave run spike: $(if $(PROG),build)
	$(RX_CONV)
	$(MAKE) -C sim $@ $(SIM_RX)
else
build:
	@test -n "$(PROG)" || { echo "usage: make build PROG=<aes|sphincs> TARGET=host"; exit 1; }
	$(MAKE) -C sw TARGET=host PROG=$(PROG)

# input = RX or sim/active_test/uart_rx.bin (what the last Verilator run got)
run: build
	$(RX_CONV)
	@if [ -n "$(RX)" ]; then cp "$(RX_BIN)" $(ACTIVE)/uart_rx.bin; fi
	@[ -f $(ACTIVE)/uart_rx.bin ] || : > $(ACTIVE)/uart_rx.bin
	$(HOST_DIR)/main < $(ACTIVE)/uart_rx.bin > $(ACTIVE)/host_tx.bin
	@echo "[host] UART TX: $$(wc -c < $(ACTIVE)/host_tx.bin) bytes in $(ACTIVE)/host_tx.bin"
	@if [ -s $(ACTIVE)/uart_tx.bin ]; then \
	  python3 sim/host/uart_cmp.py $(PROG) $(if $(filter sphincs,$(PROG)),--spx $(or $(SPX),128s)) \
	    $(ACTIVE)/uart_tx.bin $(ACTIVE)/host_tx.bin || true; \
	else echo "[host] no Verilator uart_tx.bin in $(ACTIVE)/ to compare with"; fi

wave spike:
	@echo "make $@ needs the RISC-V model: use TARGET=wasp"; exit 1
endif

view:
	$(MAKE) -C sim view $(if $(VIEWER),VIEWER=$(VIEWER))

test:
	sim/regress.sh
test-spx:
	sim/regress.sh spx

clean:
	$(MAKE) -C sw clean
	$(MAKE) -C sim clean clean-active

.PHONY: all build wave run spike view test test-spx clean

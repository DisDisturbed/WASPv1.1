# riscv-tests (riscv-software-src/riscv-tests) on the WASP RTL.
#
#   make                 build every test, run it on Verilator and Spike, print the summary
#   make run             same as `make` (use -j for parallel runs: make -j8)
#   make SUITES=rv32um   only one suite (rv32ui rv32um rv32mi wasp)
#                        wasp = tests/wasp/*.S; a source containing WASP-ONLY
#                        is not run on Spike (relies on the WASP memory map)
#   make T=rv32ui-add    one test (name = <suite>-<test>), verbose
#   make compare T=...   lock-step compare of the register writes, RTL vs Spike,
#                        prints the first instruction where they differ
#   make wave T=...      re-run one test with an FST waveform (build/<test>/wave.fst)
#   make clean
#
# Knobs:
#   MAX_CYCLES=200000    per-test timeout (cycles)
#   FENCE=0              build the env without `fence` in RVTEST_PASS/FAIL
#                        (only for triaging an RTL that cannot execute FENCE)
#   SPIKE=<path>         Spike binary (reference run; SPIKE= disables it)
#   CROSS=<prefix>       RISC-V GCC prefix
#
# Layout:
#   upstream/            vendored riscv-tests subset, unmodified (COMMIT = upstream hash)
#   tests/wasp/          extra WASP-specific directed tests (suite "wasp")
#   env/wasp/            riscv_test.h + link.ld for the WASP memory map
#   tb_rvtest.sv         testbench top (tohost snooping on the core data bus)
#   waivers.txt          tests that cannot pass by design, with the reason
#   tools/               summary + RTL/Spike commit-log compare scripts
#   build/tests/<test>/  main.elf dump.txt imem.mem dmem.mem sim.log result.txt
#                        cpu_trace.log spike.log spike_result.txt
#                        (FENCE=0: build/tests_nofence/<test>/)
# See docs/riscv_tests.md.

ROOT       := $(abspath ../..)
RTL        := $(ROOT)/RTL
UP         := upstream
MAX_CYCLES ?= 200000
FENCE      ?= 1
OUT        := build
# per-test outputs; FENCE=0 builds different ELFs, so they get their own tree
B          := $(OUT)/$(if $(filter 0,$(FENCE)),tests_nofence,tests)
MODEL      := $(OUT)/obj/Vtb_rvtest
WMODEL     := $(OUT)/obj_wave/Vtb_rvtest
TOHOST     := 80000000

# ---- test lists (straight from the upstream Makefrags) --------------------
include $(UP)/isa/rv32ui/Makefrag
include $(UP)/isa/rv32um/Makefrag
include $(UP)/isa/rv32mi/Makefrag
# WASP-specific directed tests (tests/wasp/*.S, same env and macros)
wasp_sc_tests := $(basename $(notdir $(wildcard tests/wasp/*.S)))
SUITES ?= rv32ui rv32um rv32mi wasp
ALL_TESTS := $(foreach s,$(SUITES),$(addprefix $(s)-,$($(s)_sc_tests)))
TESTS     := $(if $(T),$(T),$(ALL_TESTS))

# ---- toolchain -------------------------------------------------------------
CROSS   ?= $(if $(shell command -v riscv32-unknown-elf-gcc 2>/dev/null),riscv32-unknown-elf-,riscv64-unknown-elf-)
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
ARCH    := $(shell echo | $(CC) -march=rv32im_zicsr_zifencei_zicntr -mabi=ilp32 -E -x c - >/dev/null 2>&1 \
              && echo rv32im_zicsr_zifencei_zicntr || echo rv32im)
TFLAGS  := -march=$(ARCH) -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden \
           -nostdlib -nostartfiles -Ienv/wasp -I$(UP)/isa/macros/scalar \
           -T env/wasp/link.ld $(if $(filter 0,$(FENCE)),-DWASP_RVTEST_NO_FENCE)

SPIKE   ?= $(or $(shell command -v spike 2>/dev/null),$(wildcard /home/yusuf/spike/bin/spike))
SPIKE_ARGS := --isa=rv32im_zicsr_zicntr --priv=m --triggers=0 -m0x40000000:0x10000,0x80000000:0x10000 --pc=0x40000000

# ---- Verilator model (same RTL list / flags as sim/Makefile) --------------
PKG  := $(RTL)/PGK_IF/core_pgk.sv $(RTL)/PGK_IF/obi_if.sv $(RTL)/PGK_IF/Irq_if.sv
SRCS := $(PKG) $(wildcard $(RTL)/*.sv) $(wildcard $(RTL)/*.v) \
        $(ROOT)/sim/axi_uart16550_0.sv $(abspath tb_rvtest.sv)
VFLAGS := --binary --timing -j 0 -O3 --top-module tb_rvtest \
          -I$(RTL) -I$(RTL)/PGK_IF \
          -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-MULTIDRIVEN \
          -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
          -Wno-INITIALDLY -Wno-COMBDLY -Wno-LATCH -Wno-SELRANGE \
          +define+VERILATOR +define+CSR_QUIET

.DEFAULT_GOAL := run
.SECONDEXPANSION:
.SECONDARY:

$(MODEL): $(SRCS)
	@mkdir -p $(OUT)
	verilator $(VFLAGS) --Mdir $(OUT)/obj $(SRCS) > $(OUT)/verilator.log 2>&1 || { tail -30 $(OUT)/verilator.log; exit 1; }
$(WMODEL): $(SRCS)
	@mkdir -p $(OUT)
	verilator $(VFLAGS) --Mdir $(OUT)/obj_wave --trace-fst --trace-structs +define+WAVES $(SRCS) \
	  > $(OUT)/verilator_wave.log 2>&1 || { tail -30 $(OUT)/verilator_wave.log; exit 1; }
model: $(MODEL)

# ---- per-test build: <suite>-<name> -> upstream/isa/<suite>/<name>.S --------
suite_of = $(word 1,$(subst -, ,$(1)))
src_of = $(if $(filter wasp,$(call suite_of,$(1))),tests/wasp,$(UP)/isa/$(call suite_of,$(1)))/$(patsubst $(call suite_of,$(1))-%,%,$(1)).S
ENV_DEPS := env/wasp/riscv_test.h env/wasp/link.ld $(UP)/isa/macros/scalar/test_macros.h Makefile

BIN2MEM = od -An -v -tx4 -w4 $(1) | tr -d ' ' > $(2)

$(B)/%/main.elf: $$(call src_of,$$*) $(ENV_DEPS)
	@mkdir -p $(@D)
	$(CC) $(TFLAGS) $< -o $@
	$(OBJDUMP) -d -M no-aliases $@ > $(@D)/dump.txt

$(B)/%/imem.mem: $(B)/%/main.elf
	$(OBJCOPY) -O binary -j .text.init -j .text $< $(@D)/imem.bin
	$(OBJCOPY) -O binary -j .tohost -j .data $< $(@D)/dmem.bin
	$(call BIN2MEM,$(@D)/imem.bin,$@)
	$(call BIN2MEM,$(@D)/dmem.bin,$(@D)/dmem.mem)

# RTL run: always yields result.txt (PASS / FAIL / TIMEOUT / ERROR)
$(B)/%/result.txt: $(B)/%/imem.mem $(MODEL)
	@cd $(@D) && rm -f result.txt && \
	  $(abspath $(MODEL)) +test=$* +max_cycles=$(MAX_CYCLES) +tohost=$(TOHOST) > sim.log 2>&1 ; \
	  [ -s result.txt ] || echo "ERROR $* simulator exited without a verdict (see sim.log)" > result.txt
	@cat $@

# Spike reference run of the same ELF (checks the test + env, not the RTL).
# Tests whose source says WASP-ONLY rely on WASP's memory map and are not
# run on Spike (no lock-step comparison either).
$(B)/%/spike_result.txt: $(B)/%/main.elf $$(call src_of,$$*)
	@cd $(@D) && rm -f spike.log && if [ -z "$(SPIKE)" ]; then echo "SKIP no spike" > spike_result.txt; \
	elif grep -q 'WASP-ONLY' $(abspath $(word 2,$^)); then echo "SKIP wasp-only test" > spike_result.txt; else \
	  timeout 60 $(SPIKE) $(SPIKE_ARGS) --instructions=$(MAX_CYCLES) -l --log-commits main.elf \
	    > spike.out 2> spike.log; rc=$$?; \
	  if [ $$rc -eq 0 ]; then echo "PASS" > spike_result.txt; \
	  else echo "FAIL rc=$$rc $$(grep -m1 -i 'failed\|error\|trap' spike.out spike.log | head -c 200)" > spike_result.txt; fi; fi

# Lock-step check: every GPR write of the RTL must equal Spike's (catches
# "passes" where the test's own checks are fooled, e.g. dropped writebacks)
$(B)/%/cmp.txt: $(B)/%/result.txt $(B)/%/spike_result.txt
	@cd $(@D) && if [ ! -s spike.log ]; then echo "SKIP no spike trace" > cmp.txt; \
	  elif [ ! -s cpu_trace.log ]; then echo "SKIP no RTL trace" > cmp.txt; \
	  else python3 $(abspath tools/commit_cmp.py) cpu_trace.log spike.log --dump dump.txt > cmp.log 2>&1; \
	    head -1 cmp.log > cmp.txt; fi

RESULTS := $(foreach t,$(TESTS),$(B)/$(t)/cmp.txt)

run: $(RESULTS)
	@python3 tools/summary.py --build $(B) --waivers waivers.txt $(TESTS)

# force re-run of the simulations (keeps the ELFs and the model)
rerun:
	rm -f $(foreach t,$(TESTS),$(B)/$(t)/result.txt $(B)/$(t)/spike_result.txt $(B)/$(t)/cmp.txt)
	$(MAKE) run

compare: $(B)/$(T)/cmp.txt
	@test -n "$(T)" || { echo "usage: make compare T=<suite>-<test>"; exit 1; }
	@cat $(B)/$(T)/cmp.log

wave: $(B)/$(T)/imem.mem $(WMODEL)
	@test -n "$(T)" || { echo "usage: make wave T=<suite>-<test>"; exit 1; }
	cd $(B)/$(T) && $(abspath $(WMODEL)) +test=$(T) +max_cycles=$(MAX_CYCLES) +tohost=$(TOHOST) +wave=wave.fst > sim_wave.log 2>&1; \
	  tail -1 sim_wave.log; echo "waveform: $(B)/$(T)/wave.fst"

list:
	@echo $(ALL_TESTS) | tr ' ' '\n'

clean:
	rm -rf $(OUT)

.PHONY: run rerun compare wave list clean model

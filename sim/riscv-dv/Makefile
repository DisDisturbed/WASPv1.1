# riscv-dv random instruction tests on the WASP RTL, checked against Spike
# instruction by instruction (see docs/riscv_dv.md).
#
#   make setup            one-time: fetch riscv-dv + uvm-verilator and build the
#                         Verilator fork riscv-dv needs (pinned versions, ~10 min)
#   make                  generate + run CONFIGS x SEEDS, print the summary (use -j)
#   make SEEDS="1 2 3"    seeds (default 1..5)
#   make CONFIGS=irq      one configuration (configs.mk)
#   make T=rand_3         one test, verbose
#   make compare T=...    first register write where RTL != Spike
#   make clean / clean-tests
#
# Each test: build/t/<config>_<seed>/
#   test.S main.elf dump.txt imem.mem dmem.mem gen.log sim.log result.txt
#   cpu_trace.log spike.log spike_result.txt cmp.log cmp.txt
#
# Verdict per test = tohost reached (riscv-dv's test_done) AND the RTL register
# trace equals Spike's. tohost alone means little here: riscv-dv's handler
# also ends the test on an unexpected exception. Configs with IRQ_<cfg> run
# the RTL with random interrupts; the trap-handler code is then filtered out
# of both traces (commit_cmp --skip).

ROOT   := $(abspath ../..)
RVT    := $(ROOT)/sim/riscv-tests
B      := build
TOOLS  := $(abspath $(B)/tools)

# ---- external tools (pinned; `make setup`) ----------------------------------
DV_ROOT      ?= $(TOOLS)/riscv-dv
UVM_HOME     ?= $(TOOLS)/uvm-verilator
DV_VERILATOR ?= $(TOOLS)/verilator/bin/verilator
RISCV_DV_REV     := f557b89ed6881a20515481a2585e9d004cd9642b
UVM_VERILATOR_REV := 578a46777ef0e0c9fa80e26d60ea4d100bb3cc84
VERILATOR_FORK_REV := 2e1f99a23e10a6f7ab40230f9fb0230cb1692a7b   # antmicro/verilator, as riscv-dv CI
# the generated UVM C++ is huge: each g++ needs 1-3 GB, so keep the job count low
DV_JOBS ?= 4
# SMT solver for Verilator's constrained randomization (std::randomize / randomize() with)
Z3      ?= $(or $(shell command -v z3 2>/dev/null),$(TOOLS)/z3venv/bin/z3)

include configs.mk
SEEDS     ?= 1 2 3 4 5
MAX_CYCLES ?= 3000000
ALL_TESTS := $(foreach c,$(CONFIGS),$(foreach s,$(SEEDS),$(c)_$(s)))
TESTS     := $(if $(T),$(T),$(ALL_TESTS))
cfg_of  = $(word 1,$(subst _, ,$(1)))
seed_of = $(word 2,$(subst _, ,$(1)))

COMMON_OPTS := +uvm_set_type_override=riscv_instr_gen_config,wasp_gen_config +boot_mode=m +disable_compressed_instr=1 +no_wfi=1 +no_dret=1

CROSS   ?= $(if $(shell command -v riscv32-unknown-elf-gcc 2>/dev/null),riscv32-unknown-elf-,riscv64-unknown-elf-)
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
NM      := $(CROSS)nm
TFLAGS  := -march=rv32im_zicsr_zifencei_zicntr -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden \
           -nostdlib -nostartfiles -Ienv -T env/link.ld

SPIKE   ?= $(or $(shell command -v spike 2>/dev/null),$(wildcard /home/yusuf/spike/bin/spike))
SPIKE_ARGS := --isa=rv32im_zicsr_zifencei_zicntr --priv=m --triggers=0 \
              -m0x40000000:0x10000,0x80000000:0x10000 --pc=0x40000000

GEN     := $(B)/gen/Vuvm
MODEL   := $(RVT)/build/obj/Vtb_rvtest
T_      := $(B)/t

.DEFAULT_GOAL := run
.SECONDARY:
.SECONDEXPANSION:

# ---- one-time setup ----------------------------------------------------------
setup: $(TOOLS)/riscv-dv/.ok $(TOOLS)/uvm-verilator/.ok $(DV_VERILATOR) $(Z3)
$(TOOLS)/z3venv/bin/z3:
	python3 -m venv $(TOOLS)/z3venv && $(TOOLS)/z3venv/bin/pip install -q z3-solver==4.13.0.0
$(TOOLS)/riscv-dv/.ok:
	rm -rf $(@D) && git clone -q https://github.com/chipsalliance/riscv-dv $(@D)
	cd $(@D) && git checkout -q $(RISCV_DV_REV) && touch .ok
$(TOOLS)/uvm-verilator/.ok:
	rm -rf $(@D) && git clone -q https://github.com/antmicro/uvm-verilator $(@D)
	cd $(@D) && git checkout -q $(UVM_VERILATOR_REV) && touch .ok
$(TOOLS)/verilator/bin/verilator:
	rm -rf $(TOOLS)/verilator-src && git clone -q https://github.com/antmicro/verilator $(TOOLS)/verilator-src
	cd $(TOOLS)/verilator-src && git checkout -q $(VERILATOR_FORK_REV) && unset VERILATOR_ROOT && \
	  autoconf && ./configure --prefix=$(TOOLS)/verilator > /dev/null && $(MAKE) -s -j$(DV_JOBS) && $(MAKE) -s install

# ---- the generator (riscv-dv compiled with Verilator, WASP core setting) -----
$(GEN): target/wasp/riscv_core_setting.sv target/wasp/user_extension.svh
	@mkdir -p $(@D)
	cd $(DV_ROOT) && RISCV_DV_ROOT=$(DV_ROOT) $(DV_VERILATOR) --binary --vpi \
	  $(UVM_HOME)/src/uvm.sv $(UVM_HOME)/src/dpi/uvm_dpi.cc -f $(DV_ROOT)/files.f \
	  +incdir+$(UVM_HOME)/src +incdir+$(abspath target/wasp) +incdir+$(DV_ROOT)/user_extension \
	  -j $(DV_JOBS) -CFLAGS -O0 --Mdir $(abspath $(B)/gen/obj) -o $(abspath $@) \
	  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SELRANGE -Wno-ENUMVALUE -Wno-COVERIGN \
	  -Wno-CASEINCOMPLETE -Wno-SYMRSVDWORD -Wno-UNSIGNED > $(abspath $(B)/gen/compile.log) 2>&1 \
	  || { tail -20 $(abspath $(B)/gen/compile.log); exit 1; }
gen: $(GEN)

$(MODEL): FORCE
	@$(MAKE) -s -C $(RVT) model
FORCE:

# ---- per test -------------------------------------------------------------
$(T_)/%/test.S: $(GEN) configs.mk tools/postproc.py
	@mkdir -p $(@D)
	@cd $(@D) && VERILATOR_SOLVER="$(Z3) --in" $(abspath $(GEN)) +UVM_TESTNAME=riscv_instr_base_test +num_of_tests=1 +start_idx=0 \
	  +asm_file_name=gen $(COMMON_OPTS) $(OPTS_$(call cfg_of,$*)) +verilator+seed+$(call seed_of,$*) \
	  > gen.log 2>&1 && test -s gen_0.S || { echo "GEN FAILED $*"; tail -5 gen.log; exit 1; }
	@python3 tools/postproc.py $(@D)/gen_0.S $@

$(T_)/%/main.elf: $(T_)/%/test.S env/link.ld env/user_define.h env/user_init.s
	@$(CC) $(TFLAGS) $< -o $@ 2> $(@D)/gcc.log || { cat $(@D)/gcc.log; exit 1; }
	@$(OBJDUMP) -d -M no-aliases $@ > $(@D)/dump.txt

$(T_)/%/imem.mem: $(T_)/%/main.elf
	@$(OBJCOPY) -O binary -j .text $< $(@D)/imem.bin
	@$(OBJCOPY) -O binary -R .text $< $(@D)/dmem.bin
	@od -An -v -tx4 -w4 $(@D)/imem.bin | tr -d ' ' > $@
	@od -An -v -tx4 -w4 $(@D)/dmem.bin | tr -d ' ' > $(@D)/dmem.mem

# RTL run (+random interrupts for configs with IRQ_<cfg>)
$(T_)/%/result.txt: $(T_)/%/imem.mem $(MODEL)
	@cd $(@D) && rm -f result.txt && \
	  $(MODEL) +test=$* +max_cycles=$(MAX_CYCLES) +tohost=$$($(NM) main.elf | awk '/ tohost$$/{print $$1}') \
	    $(if $(IRQ_$(call cfg_of,$*)),+irq_rate=$(IRQ_$(call cfg_of,$*)) +irq_seed=$(call seed_of,$*)) \
	    > sim.log 2>&1 ; \
	  [ -s result.txt ] || echo "ERROR $* simulator exited without a verdict (see sim.log)" > result.txt
	@cat $@

$(T_)/%/spike_result.txt: $(T_)/%/main.elf
	@cd $(@D) && timeout 300 $(SPIKE) $(SPIKE_ARGS) --instructions=$(MAX_CYCLES) -l --log-commits main.elf \
	    > spike.out 2> spike.log; rc=$$?; \
	  if [ $$rc -eq 0 ]; then echo PASS > spike_result.txt; else echo "FAIL rc=$$rc" > spike_result.txt; fi

# lock-step compare; with interrupts the trap handler is left out of both traces
$(T_)/%/cmp.txt: $(T_)/%/result.txt $(T_)/%/spike_result.txt
	@cd $(@D) && skip=$$(if [ -n "$(IRQ_$(call cfg_of,$*))" ]; then \
	    $(NM) main.elf | awk '/ kernel_instr_start$$/{a=$$1} / kernel_instr_end$$/{b=$$1} END{print "--skip " a ":" b}'; fi); \
	  python3 $(RVT)/tools/commit_cmp.py cpu_trace.log spike.log --dump dump.txt $$skip > cmp.log 2>&1; \
	  head -1 cmp.log > cmp.txt

run: $(foreach t,$(TESTS),$(T_)/$(t)/cmp.txt)
	@python3 $(RVT)/tools/summary.py --build $(T_) --waivers /dev/null $(TESTS)

compare: $(T_)/$(T)/cmp.txt
	@cat $(T_)/$(T)/cmp.log

rerun:
	rm -f $(foreach t,$(TESTS),$(T_)/$(t)/result.txt $(T_)/$(t)/spike_result.txt $(T_)/$(t)/cmp.txt)
	$(MAKE) run

clean-tests:
	rm -rf $(T_)
clean:
	rm -rf $(B)/gen $(T_)

.PHONY: setup gen run compare rerun clean clean-tests FORCE

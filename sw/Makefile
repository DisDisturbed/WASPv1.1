# wasp software build: the same app sources for the RISC-V core and the PC.
#
#   make PROG=<app> [TARGET=wasp|host] [SPX=128f|128s] [RNG=det|hw]
#
#   PROG    aes       apps/aes/       AES-256 over UART (+ PLIC IRQ on wasp)
#           sphincs   apps/sphincs/   SPHINCS+ keygen/sign/verify over UART
#           counters  apps/counters/  CSR/CLINT/PLIC/D-cache self-test (wasp only)
#   TARGET  wasp (default)  RISC-V cross build -> imem.mem/dmem.mem for RTL sim / FPGA
#           host            native gcc build, UART = stdin/stdout, counters read 0
#   SPX     SPHINCS+ parameter set, 128s (default) or 128f
#   RNG     det (default)   fixed-seed SHAKE256 RNG: RTL sim and host give identical bytes
#           hw              mcycle-jitter entropy (rng/randombytes_hw.c): FPGA builds only
#
# Outputs: build/<TARGET>/<PROG>[_<SPX>][_hwrng]/
#   wasp: main.elf dump.txt imem.mem dmem.mem
#         imem.mem -> instruction BRAM init (icache_test_ins_mem reads "imem.mem")
#         dmem.mem -> data BRAM init        (dcache_test_data_mem INIT_DATA)
#   host: main   (run: build/host/aes/main < uart_rx.bin > uart_tx.bin)
#
# Examples:
#   make PROG=sphincs SPX=128f                 RTL simulation image
#   make PROG=sphincs SPX=128f TARGET=host     PC build to compare against
#   make PROG=sphincs SPX=128f RNG=hw          FPGA image with the real RNG
#
# Layout:
#   apps/<prog>/main.c   application (shared by both targets)
#   lib/sphincs/         NIST round-3 SPHINCS+ reference, verbatim (+ params/<set>/)
#   rng/                 randombytes(): randombytes_hw.c / randombytes_det.c
#   hal/include/         driver APIs + register maps (uart, clint, irq, trap, cache, memmap)
#   hal/common/          target-independent driver code (uart_util.c)
#   hal/wasp/            RISC-V: crt0, linker script, csr.h, drivers, libc_min
#   hal/host/            PC stand-ins: csr.h (counters = 0), stdin/stdout UART, stubs
#   tools/               PC-side utilities (sphincs_host.py: talk to the board)
#
# Toolchain (TARGET=wasp): any riscv32/riscv64 bare-metal GCC. On Windows:
#   make CROSS=C:/riscv/bin/riscv64-unknown-elf-
# Default: riscv32-unknown-elf- if it is on PATH, else riscv64-unknown-elf-
# (the riscv64 one must ship newlib headers for PROG=sphincs).
# TARGET=host uses HOST_CC (default gcc).

TARGET  ?= wasp
PROG    ?= aes
SPX     ?= 128s
RNG     ?= det
CPU_CLK_HZ ?= 50000000

ifeq ($(filter $(TARGET),wasp host),)
  $(error unknown TARGET=$(TARGET) (wasp | host))
endif
ifeq ($(filter $(RNG),det hw),)
  $(error unknown RNG=$(RNG) (det | hw))
endif
ifeq ($(TARGET)$(RNG),hosthw)
  $(error RNG=hw needs the wasp mcycle CSR; the host build only supports RNG=det)
endif

# ---- application sources -------------------------------------------------
INC = -Ihal/include

ifeq ($(PROG),aes)
  SRCS = apps/aes/main.c
  OPT  = -O0 -fno-inline
endif
ifeq ($(PROG),counters)
  ifeq ($(TARGET),host)
    $(error PROG=counters tests the CSR/CLINT/PLIC hardware; it has no host build)
  endif
  SRCS = apps/counters/main.c
  OPT  = -O0 -fno-inline
endif
# SPHINCS+ NIST round 3 reference, sphincs-shake256-<SPX>-simple (lib/sphincs/,
# files verbatim from the NIST package; rng.c replaced by rng/randombytes_*.c)
ifeq ($(PROG),sphincs)
  SPX_DIR = lib/sphincs
  SRCS  = apps/sphincs/main.c $(addprefix $(SPX_DIR)/, \
            address.c wots.c utils.c fors.c sign.c hash_shake256.c \
            thash_shake256_simple.c fips202.c) \
          rng/randombytes_$(RNG).c
  OPT   = -O2
  INC  += -I$(SPX_DIR)/params/$(SPX) -I$(SPX_DIR) -Irng
  LDEXTRA_wasp = -Wl,--defsym=__stack_size=0x4000
endif
ifndef SRCS
  $(error unknown PROG=$(PROG) (aes | counters | sphincs))
endif

OUT = build/$(TARGET)/$(PROG)$(if $(filter sphincs,$(PROG)),_$(SPX)$(if $(filter hw,$(RNG)),_hwrng))
DEPS = $(SRCS) $(wildcard hal/include/*.h hal/$(TARGET)/* hal/common/* rng/*.h \
         lib/sphincs/*.h lib/sphincs/params/*/*.h) Makefile

# ---- TARGET=wasp ----------------------------------------------------------
ifeq ($(TARGET),wasp)
CROSS   ?= $(if $(shell command -v riscv32-unknown-elf-gcc 2>/dev/null),riscv32-unknown-elf-,riscv64-unknown-elf-)
CC       = $(CROSS)gcc
OBJDUMP  = $(CROSS)objdump
OBJCOPY  = $(CROSS)objcopy
SIZE     = $(CROSS)size
SPIKE   ?= spike

# GCC >= 12 needs _zicsr spelled out, GCC <= 11 rejects it.
ARCH := $(shell echo | $(CC) -march=rv32im_zicsr -mabi=ilp32 -E -x c - >/dev/null 2>&1 && echo rv32im_zicsr || echo rv32im)

DRIVERS  = hal/wasp/crt0.s hal/wasp/uart.c hal/wasp/irq.c hal/wasp/clint.c \
           hal/wasp/trap.c hal/wasp/libc_min.c hal/common/uart_util.c hal/common/trap_util.c

CCFLAGS = -march=$(ARCH) -mabi=ilp32 -mcmodel=medany \
          $(OPT) -Ihal/wasp $(INC) \
          -ffreestanding -fno-builtin \
          -nostdlib -nostartfiles \
          -ffunction-sections -fdata-sections -Wl,--gc-sections \
          -g -Wall -Wextra -DCPU_CLK_HZ=$(CPU_CLK_HZ)u

# one 32-bit little-endian word per line for $readmemh
BIN2MEM = od -An -v -tx4 -w4 $(1) | tr -d ' ' > $(2)

all: $(OUT)/imem.mem

$(OUT)/main.elf: $(DRIVERS) $(DEPS) hal/wasp/linksc.ld | $(OUT)
	$(CC) $(DRIVERS) $(SRCS) $(CCFLAGS) $(LDEXTRA_wasp) -T hal/wasp/linksc.ld -o $@ -lgcc
	$(SIZE) $@

$(OUT)/imem.mem: $(OUT)/main.elf
	$(OBJDUMP) -D $< > $(OUT)/dump.txt
	$(OBJCOPY) -O binary -j .text $< $(OUT)/instr.bin
	$(OBJCOPY) -O binary -j .data $< $(OUT)/data.bin
	$(call BIN2MEM,$(OUT)/instr.bin,$(OUT)/imem.mem)
	$(call BIN2MEM,$(OUT)/data.bin,$(OUT)/dmem.mem)
	@echo "--------------------------------------------------"
	@echo " [$(PROG)] $(OUT)/imem.mem (ROM @0x40000000), $(OUT)/dmem.mem (RAM @0x80000000), RNG=$(RNG)"
	@echo "--------------------------------------------------"

# Spike: same memory map as the FPGA (no UART/PLIC/CLINT here; for the
# full SoC on Spike use `make spike` at the top level / sim/Makefile).
SPIKE_MEM = -m0x40000000:0x10000,0x80000000:0x10000 --pc=0x40000000 --isa=$(ARCH)
debug: $(OUT)/main.elf
	$(SPIKE) $(SPIKE_MEM) -d $<
log: $(OUT)/main.elf
	-$(SPIKE) $(SPIKE_MEM) -l --log-commits $< 2> $(OUT)/spike_execution.log
endif

# ---- TARGET=host ----------------------------------------------------------
ifeq ($(TARGET),host)
HOST_CC ?= gcc
DRIVERS  = hal/host/uart_host.c hal/host/irq_host.c hal/host/clint_host.c \
           hal/host/trap_host.c hal/common/uart_util.c hal/common/trap_util.c
CCFLAGS  = $(OPT) -Ihal/host $(INC) -g -Wall -Wextra \
           -DWASP_HOST=1 -DCPU_CLK_HZ=$(CPU_CLK_HZ)u

all: $(OUT)/main

$(OUT)/main: $(DRIVERS) $(DEPS) | $(OUT)
	$(HOST_CC) $(DRIVERS) $(SRCS) $(CCFLAGS) -o $@
	@echo " [$(PROG)] host build: $@ (UART = stdin/stdout)"
endif

$(OUT):
	mkdir -p $@

clean:
	rm -rf build
.PHONY: all debug log clean

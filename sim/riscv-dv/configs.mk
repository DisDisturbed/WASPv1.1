# riscv-dv test configurations for WASP, adapted from riscv-dv's
# yaml/base_testlist.yaml (same generator options, the ones that do not apply
# to WASP left out). One test = <config>_<seed>.
#
#   OPTS_<config>   riscv-dv generator plusargs
#   IRQ_<config>    if set: random interrupt injection rate for the RTL run
#                   (tb_rvtest +irq_rate), compared with Spike without
#                   interrupts, the trap handler filtered out of both traces
#
# Common to every config (Makefile): wasp_gen_config (4 x 4 KB data regions), +boot_mode=m +disable_compressed_instr=1
# +no_wfi=1 +no_dret=1

# integer corner values, no branches/memory
OPTS_arith = +instr_cnt=10000 +num_of_sub_program=0 +directed_instr_0=riscv_int_numeric_corner_stream,4 \
             +no_fence=1 +no_data_page=1 +no_branch_jump=1 +no_csr_instr=1

# instr_cnt is sized so that .text fits WASP's 64 KB IMEM (directed stream
# counts scale with it): rand at 10000 -> ~74 KB, mem at 5000 -> ~88 KB.

# the main random test: calls, loads/stores, loops, hazards, jumps
OPTS_rand  = +instr_cnt=6500 +num_of_sub_program=5 \
             +directed_instr_0=riscv_load_store_rand_instr_stream,4 +directed_instr_1=riscv_loop_instr,4 \
             +directed_instr_2=riscv_hazard_instr_stream,4 +directed_instr_3=riscv_load_store_hazard_instr_stream,4 \
             +directed_instr_4=riscv_multi_page_load_store_instr_stream,4 +directed_instr_5=riscv_mem_region_stress_test,4 \
             +directed_instr_6=riscv_jal_instr,4

OPTS_jump  = +instr_cnt=5000 +num_of_sub_program=5 +directed_instr_1=riscv_jal_instr,20
OPTS_loop  = +instr_cnt=10000 +num_of_sub_program=5 +directed_instr_1=riscv_loop_instr,20
OPTS_rjump = +instr_cnt=10000 +num_of_sub_program=10 +directed_instr_0=riscv_load_store_rand_instr_stream,8

# memory heavy (riscv_mmu_stress_test: bare mode on WASP, i.e. load/store stress)
OPTS_mem   = +instr_cnt=2800 +num_of_sub_program=5 \
             +directed_instr_0=riscv_load_store_rand_instr_stream,40 +directed_instr_1=riscv_load_store_hazard_instr_stream,40 \
             +directed_instr_2=riscv_multi_page_load_store_instr_stream,10 +directed_instr_3=riscv_mem_region_stress_test,10

OPTS_illegal = +illegal_instr_ratio=5 +instr_cnt=10000 +num_of_sub_program=5
# not in CONFIGS: riscv-dv only generates compressed (16-bit) HINTs; with C
# disabled they come out as `.2byte 0x0000`, which misaligns the rest of the
# program (Spike fails too). Kept for a future C-extension WASP.
OPTS_hint    = +hint_instr_ratio=5    +instr_cnt=10000 +num_of_sub_program=5
OPTS_ebreak  = +instr_cnt=6000 +no_ebreak=0 +num_of_sub_program=5

# random interrupts (external + software) on top of the main random test
OPTS_irq   = $(OPTS_rand) +enable_interrupt=1
IRQ_irq    = 200

CONFIGS ?= arith rand jump loop rjump mem illegal ebreak irq

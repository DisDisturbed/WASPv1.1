# WASP-specific directed test (docs/riscv_tests.md, "FENCE.I").
#*****************************************************************************
# fencei_stress.S
#-----------------------------------------------------------------------------
#
# FENCE.I = D-cache write-back of every dirty line + I-cache invalidate +
# refetch. Generates `li a0, k; ret` in 8 different D-cache sets of DMEM,
# executes it, rewrites it (the old code is now in the I-cache) and executes
# it again; a whole cache worth (4 KB) of dirty data must survive the
# flush-all walk. Compared with Spike instruction by instruction.
#

#include "riscv_test.h"
#include "test_macros.h"

#define NFUNC   8
#define STRIDE  520            /* 8 lines + 8 bytes: a different set each time */
#define LI_A0   0x00000513     /* addi a0, zero, 0  (imm in [31:20]) */
#define RET     0x00008067     /* jalr zero, 0(ra) */

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # ---- write NFUNC functions "li a0, k; ret" --------------------------
  li TESTNUM, 2
  li s4, 0                      # bias added to k
gen_and_run:
  la s0, code_buf
  li s1, 0                      # k
1:
  add t0, s1, s4
  slli t0, t0, 20
  li t1, LI_A0
  or t0, t0, t1
  sw t0, 0(s0)
  li t1, RET
  sw t1, 4(s0)
  addi s0, s0, STRIDE
  addi s1, s1, 1
  li t2, NFUNC
  blt s1, t2, 1b

  fence.i

  # ---- call them, a0 must be k + bias ---------------------------------
  la s0, code_buf
  li s1, 0
2:
  li a0, -1
  jalr ra, 0(s0)
  add t0, s1, s4
  bne a0, t0, fail
  addi s0, s0, STRIDE
  addi s1, s1, 1
  li t2, NFUNC
  blt s1, t2, 2b

  # second round: rewrite the code that is now in the I-cache
  bnez s4, 3f
  li TESTNUM, 3
  li s4, 100
  j gen_and_run
3:

  # ---- 4 KB of dirty lines survive the flush-all ----------------------
  li TESTNUM, 4
  la s0, data_buf
  li s1, 1024                   # words
  li t1, 0x9e3779b9
4:
  mul t0, s1, t1
  sw t0, 0(s0)
  addi s0, s0, 4
  addi s1, s1, -1
  bnez s1, 4b

  fence.i

  la s0, data_buf
  li s1, 1024
5:
  mul t0, s1, t1
  lw t3, 0(s0)
  bne t0, t3, fail
  addi s0, s0, 4
  addi s1, s1, -1
  bnez s1, 5b

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

  .align 6
code_buf: .skip NFUNC * STRIDE
  .align 6
data_buf: .skip 4096

RVTEST_DATA_END

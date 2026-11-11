# See ../../upstream/LICENSE (macros) -- WASP-specific directed test.
#*****************************************************************************
# mret_csr.S
#-----------------------------------------------------------------------------
#
# The first instruction after MRET reads mstatus. MRET updates mstatus
# (MIE <- MPIE, MPIE <- 1) when it commits in WB, while CSRs are read in ID,
# so the read has to wait for the in-flight MRET (docs/riscv_tests.md,
# finding 3). Not covered by the upstream suite.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # mstatus: MIE=0, MPIE=0, MPP=M -> after mret: MIE=0, MPIE=1
  li t0, MSTATUS_MPP
  csrw mstatus, t0
  la t0, 1f
  csrw mepc, t0
  la sp, sp_val
  lw sp, 0(sp)
  mret
1:
  csrr a0, mstatus
  li TESTNUM, 2
  li t1, (MSTATUS_MPP | MSTATUS_MPIE)
  bne a0, t1, fail

  # same with MPIE=1: after mret MIE=1 (interrupts stay masked in mie)
  csrwi mie, 0
  li t0, (MSTATUS_MPP | MSTATUS_MPIE)
  csrw mstatus, t0
  la t0, 2f
  csrw mepc, t0
  mret
2:
  csrr a0, mstatus
  li TESTNUM, 3
  li t1, (MSTATUS_MPP | MSTATUS_MPIE | MSTATUS_MIE)
  bne a0, t1, fail
  csrci mstatus, MSTATUS_MIE

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
sp_val: .word 0x12345678

RVTEST_DATA_END

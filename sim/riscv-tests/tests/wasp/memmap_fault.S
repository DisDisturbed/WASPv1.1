# WASP-ONLY: no Spike comparison (Spike's RAM at 0x4000_0000 is writable and
# it has no D-cache flush register).
#*****************************************************************************
# memmap_fault.S
#-----------------------------------------------------------------------------
#
# WASP memory-map rules (RTL/cache_system_top.sv, access check):
#   IMEM is read-only for data accesses        -> store access fault
#   the D-cache flush register is write-only   -> load access fault
#   only offset 0 of the flush page exists     -> store access fault
# A legal flush-register write must still work.
#

#include "riscv_test.h"
#include "test_macros.h"

#define FLUSH_REG 0xC0003000

#define FAULT(testnum, cause, addr, ...) \
  li TESTNUM, testnum; li s1, cause; li s2, addr; \
  la t2, 1f; la s3, 2f; li t1, 0x5a5a5a5a; \
2: __VA_ARGS__; \
  j fail; \
1: li t3, 0x5a5a5a5a; bne t1, t3, fail;

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # store into IMEM (our own code): must fault, code must be unchanged
  la a0, _start
  lw a1, 0(a0)
  li TESTNUM, 2
  li s1, CAUSE_STORE_ACCESS
  mv s2, a0
  la t2, 1f
  la s3, 2f
2: sw zero, 0(a0)
  j fail
1: lw a2, 0(a0)
  bne a1, a2, fail

  FAULT(3, CAUSE_LOAD_ACCESS,  FLUSH_REG,     lw t1, 0(s2))
  FAULT(4, CAUSE_STORE_ACCESS, FLUSH_REG + 4, sw zero, 0(s2))
  FAULT(5, CAUSE_STORE_ACCESS, 0x40010000,    sw zero, 0(s2))

  # legal flush: write back + invalidate the line holding tdat
  li TESTNUM, 6
  la t0, tdat
  li t1, 0x600df00d
  sw t1, 0(t0)
  li t3, FLUSH_REG
  sw t0, 0(t3)
  lw t4, 0(t0)
  bne t1, t4, fail

  TEST_PASSFAIL

  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr t0, mcause
  bne t0, s1, fail
  csrr t0, mtval
  bne t0, s2, fail
  csrr t0, mepc
  bne t0, s3, fail
  csrw mepc, t2
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
tdat: .word 0

RVTEST_DATA_END

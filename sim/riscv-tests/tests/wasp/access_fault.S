# WASP-specific directed test (docs/riscv_tests.md, "Access faults").
#*****************************************************************************
# access_fault.S
#-----------------------------------------------------------------------------
#
# Loads/stores to unmapped addresses or to a spare crossbar slot with no
# slave, and instruction fetches outside IMEM/DMEM, must raise precise access
# faults (mcause 5 / 7 / 1, mtval = address) without writing rd, and the bus
# must keep working afterwards. Spike behaves the same for these addresses,
# so the run is also compared with Spike instruction by instruction.
#

#include "riscv_test.h"
#include "test_macros.h"

#define UNMAPPED_A 0x30000000
#define UNMAPPED_B 0x60000000
#define SPARE_SLOT 0xC0004000

# s1 = expected mcause, s2 = expected mtval, s3 = expected mepc, t2 = resume
#define FAULT_LOAD(testnum, insn, addr) \
  li TESTNUM, testnum; li s1, CAUSE_LOAD_ACCESS; li s2, addr; \
  la t2, 1f; la s3, 2f; li t1, 0x5a5a5a5a; \
2: insn t1, 0(s2); \
  j fail; \
1: li t3, 0x5a5a5a5a; bne t1, t3, fail;

#define FAULT_STORE(testnum, insn, addr) \
  li TESTNUM, testnum; li s1, CAUSE_STORE_ACCESS; li s2, addr; \
  la t2, 1f; la s3, 2f; \
2: insn zero, 0(s2); \
  j fail; \
1:

#define FAULT_FETCH(testnum, addr) \
  li TESTNUM, testnum; li s1, CAUSE_FETCH_ACCESS; li s2, addr; mv s3, s2; \
  la t2, 1f; li ra, 0; \
  jalr ra, 0(s2); \
  j fail; \
1: la t3, 1b - 4; bne ra, t3, fail;

RVTEST_RV32M
RVTEST_CODE_BEGIN

  FAULT_LOAD ( 2, lw,  UNMAPPED_A)
  FAULT_STORE( 3, sw,  UNMAPPED_A)
  FAULT_LOAD ( 4, lw,  SPARE_SLOT)
  FAULT_STORE( 5, sw,  SPARE_SLOT + 0x1000)
  FAULT_LOAD ( 6, lbu, UNMAPPED_B + 1)
  FAULT_STORE( 7, sh,  UNMAPPED_B + 2)
  FAULT_FETCH( 8, UNMAPPED_A)
  FAULT_FETCH( 9, UNMAPPED_B + 0x100)

  # the memory system still works after all of that
  li TESTNUM, 10
  la t0, tdat
  li t1, 0x13572468
  sw t1, 4(t0)
  lw t3, 4(t0)
  bne t1, t3, fail
  lw t3, 0(t0)
  li t1, 0xcafef00d
  bne t1, t3, fail

  # IMEM is still readable as data
  li TESTNUM, 11
  la t0, _start
  lw t1, 0(t0)
  beqz t1, fail

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
tdat: .word 0xcafef00d
      .word 0

RVTEST_DATA_END

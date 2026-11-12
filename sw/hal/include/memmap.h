#ifndef MEMMAP_H
#define MEMMAP_H
/* wasp memory map. Must match the parameters of RTL/System_top.sv and the
 * MEMORY block of linksc.ld.
 *
 *   0x4000_0000  IMEM   64 KB  boot address, code (read-only for data access)
 *   0x8000_0000  DMEM   64 KB  .data/.bss/stack, the only D-cacheable range
 *   0xC000_0000  peripherals, one 4 KB page each:
 *     +0x0000  UART16550
 *     +0x1000  CLINT        (compact layout, see clint.h)
 *     +0x2000  PLIC         (compact layout, see irq.h)
 *     +0x3000  D-cache flush control register (see cache.h)
 *     +0x4000  spare AXI slot 3
 *     +0x5000  spare AXI slot 4
 *     +0x6000  spare AXI slot 5
 *
 * Access faults (RTL/axi_xbar.sv DECERR, RTL/axi_ram.sv SLVERR, RTL/icache.sv; handled with trap.h):
 *   load  access fault (mcause 5): address not mapped, read of the D-cache
 *                                  flush register (write-only), spare slot
 *                                  without a slave (System_top SLOT_PRESENT)
 *   store access fault (mcause 7): same, plus any store to IMEM (read-only
 *                                  for data) and to the flush page other
 *                                  than DCACHE_FLUSH_BASE itself
 *   instruction access fault (1):  fetch outside IMEM and DMEM
 *   mtval = the faulting address. The access never reaches the bus.
 */

#define IMEM_BASE         0x40000000u
#define IMEM_SIZE         0x00010000u
#define DMEM_BASE         0x80000000u
#define DMEM_SIZE         0x00010000u

#define PERIPH_BASE       0xC0000000u
#define PERIPH_PAGE       0x00001000u
#define UART_BASE         (PERIPH_BASE + 0x0000u)
#define CLINT_BASE        (PERIPH_BASE + 0x1000u)
#define PLIC_BASE         (PERIPH_BASE + 0x2000u)
#define DCACHE_FLUSH_BASE (PERIPH_BASE + 0x3000u)
#define SLOT3_BASE        (PERIPH_BASE + 0x4000u)
#define SLOT4_BASE        (PERIPH_BASE + 0x5000u)
#define SLOT5_BASE        (PERIPH_BASE + 0x6000u)

#ifndef REG32
#define REG32(addr) (*((volatile uint32_t *)(addr)))
#endif

#endif /* MEMMAP_H */

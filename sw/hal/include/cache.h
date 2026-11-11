#ifndef CACHE_H
#define CACHE_H
/* Cache maintenance.
 *
 * D-cache (RTL/Dcache.sv): 4 KB, direct mapped, 64 lines x 64 B, write-back,
 * caches only DMEM (0x8000_0000, 64 KB). Writing a line address to
 * DCACHE_FLUSH_CTRL writes that line back (if dirty) and invalidates it.
 * Needed before another bus master (DMA, ...) reads DMEM; the core itself
 * never needs it. The register is write-only (a read is a load access fault).
 *
 * I-cache (RTL/icache.sv): instructions are fetched straight from memory, so
 * after the program writes instructions (a loader, generated code, a patch;
 * only DMEM is writable) it must run icache_sync() before executing them.
 * icache_sync() is FENCE.I (Zifencei): the D-cache writes back every dirty
 * line, the I-cache drops every line and fetch restarts after the fence.i.
 * It costs about 2 cycles per D-cache line plus ~20 per dirty line.
 */
#include <stdint.h>
#include "memmap.h"

#define DCACHE_FLUSH_CTRL DCACHE_FLUSH_BASE
#define DCACHE_LINES      64u
#define DCACHE_LINE_BYTES 64u

/* write back + invalidate the line holding addr */
static inline void dcache_flush_line(const volatile void *addr) {
    *(volatile uint32_t *)DCACHE_FLUSH_CTRL = (uint32_t)addr;
}

/* write back + invalidate the whole D-cache */
static inline void dcache_flush_all(void) {
    for (uint32_t i = 0; i < DCACHE_LINES; i++)
        *(volatile uint32_t *)DCACHE_FLUSH_CTRL = i * DCACHE_LINE_BYTES;
}

/* make all earlier stores visible to instruction fetch (FENCE.I) */
static inline void icache_sync(void) {
#ifdef WASP_HOST
    __asm__ volatile ("" ::: "memory");
#else
    /* fence.i, spelled as a word so -march needs no _zifencei */
    __asm__ volatile (".word 0x0000100f" ::: "memory");
#endif
}

#endif

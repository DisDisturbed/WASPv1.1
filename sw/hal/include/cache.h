#ifndef CACHE_H
#define CACHE_H
/* D-cache maintenance (RTL/Dcache.sv). The cache is 4 KB, direct mapped,
 * 64 lines x 64 B, write-back, and only caches DMEM (0x8000_0000, 64 KB).
 * Writing a line address to DCACHE_FLUSH_CTRL writes that line back (if
 * dirty) and invalidates it. Needed before another bus master (DMA, ...)
 * reads DMEM; the core itself never needs it. */
#include <stdint.h>
#include "memmap.h"

#define DCACHE_FLUSH_CTRL DCACHE_FLUSH_BASE
#define DCACHE_LINES      64u
#define DCACHE_LINE_BYTES 64u

static inline void dcache_flush_all(void) {
    for (uint32_t i = 0; i < DCACHE_LINES; i++)
        *(volatile uint32_t *)DCACHE_FLUSH_CTRL = i * DCACHE_LINE_BYTES;
}
#endif

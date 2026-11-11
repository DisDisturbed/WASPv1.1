#ifndef CLINT_H
#define CLINT_H
/* CLINT driver (RTL/Clint.sv). The SiFive CLINT registers packed into one
 * 4 KB page (offsets are wasp-specific, not SiFive's), plus two wasp
 * registers:
 *   CLINT_CLK_FREQ   read-only: core clock (Hz) the bitstream was built for
 *   CLINT_PRESCALER  mtime += 1 every (PRESCALER+1) core clocks
 *
 * mtime (and therefore the `time` CSR) runs at the rate chosen in
 * clint_init(); mcycle always counts raw core clocks.
 */
#include <stdint.h>
#include "memmap.h"   /* CLINT_BASE */

#define CLINT_MSIP        (CLINT_BASE + 0x000)
#define CLINT_MTIMECMP_LO (CLINT_BASE + 0x008)
#define CLINT_MTIMECMP_HI (CLINT_BASE + 0x00C)
#define CLINT_MTIME_LO    (CLINT_BASE + 0x010)
#define CLINT_MTIME_HI    (CLINT_BASE + 0x014)
#define CLINT_CLK_FREQ    (CLINT_BASE + 0x018)
#define CLINT_PRESCALER   (CLINT_BASE + 0x01C)

/* Software's idea of the core clock. Override with -DCPU_CLK_HZ=... */
#ifndef CPU_CLK_HZ
#define CPU_CLK_HZ 50000000u
#endif

/* clint_init() return codes */
#define CLINT_OK              0
#define CLINT_ERR_CLK_MISMATCH 1  /* hardware CLK_FREQ != expected_clk_hz        */
#define CLINT_ERR_BAD_TICK     2  /* tick_hz is 0, > clock, or not a divisor of it */

/* Checks the bitstream's clock against expected_clk_hz, then programs the
 * prescaler so mtime ticks at tick_hz. On error nothing is changed. */
int      clint_init(uint32_t expected_clk_hz, uint32_t tick_hz);
uint32_t clint_clk_freq(void);   /* what the hardware reports            */
uint32_t clint_tick_hz(void);    /* current mtime rate                   */

uint64_t clint_mtime(void);
void     clint_set_mtime(uint64_t t);
void     clint_set_mtimecmp(uint64_t t);   /* glitch-free 64-bit update  */
void     clint_timer_after(uint64_t ticks);/* mtimecmp = mtime + ticks   */
void     clint_timer_off(void);            /* mtimecmp = all ones        */

static inline void clint_msip_set(void)   { REG32(CLINT_MSIP) = 1; }
static inline void clint_msip_clear(void) { REG32(CLINT_MSIP) = 0; }

/* Busy-wait helpers on mtime / mcycle. */
void delay_ticks(uint64_t ticks);
void delay_us(uint32_t us);              /* uses mcycle + CLK_FREQ  */

#endif /* CLINT_H */

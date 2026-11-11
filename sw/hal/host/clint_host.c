/* Host stand-in for the CLINT driver: the clock check passes and reports
 * CPU_CLK_HZ (what the bitstream would report), timers do nothing. */
#include "clint.h"

uint32_t clint_clk_freq(void) { return CPU_CLK_HZ; }
uint32_t clint_tick_hz(void)  { return 1000000u; }

int clint_init(uint32_t expected_clk_hz, uint32_t tick_hz) {
    if (expected_clk_hz != CPU_CLK_HZ)
        return CLINT_ERR_CLK_MISMATCH;
    if (tick_hz == 0 || tick_hz > CPU_CLK_HZ || (CPU_CLK_HZ % tick_hz) != 0)
        return CLINT_ERR_BAD_TICK;
    return CLINT_OK;
}

uint64_t clint_mtime(void)                 { return 0; }
void     clint_set_mtime(uint64_t t)       { (void)t; }
void     clint_set_mtimecmp(uint64_t t)    { (void)t; }
void     clint_timer_after(uint64_t ticks) { (void)ticks; }
void     clint_timer_off(void)             { }
void     delay_ticks(uint64_t ticks)       { (void)ticks; }
void     delay_us(uint32_t us)             { (void)us; }

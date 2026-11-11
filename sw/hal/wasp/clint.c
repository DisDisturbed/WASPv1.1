#include "clint.h"
#include "csr.h"

uint32_t clint_clk_freq(void) { return REG32(CLINT_CLK_FREQ); }

uint32_t clint_tick_hz(void) {
    return REG32(CLINT_CLK_FREQ) / (REG32(CLINT_PRESCALER) + 1u);
}

int clint_init(uint32_t expected_clk_hz, uint32_t tick_hz) {
    uint32_t hw_hz = REG32(CLINT_CLK_FREQ);
    if (hw_hz != expected_clk_hz)
        return CLINT_ERR_CLK_MISMATCH;
    if (tick_hz == 0 || tick_hz > hw_hz || (hw_hz % tick_hz) != 0)
        return CLINT_ERR_BAD_TICK;
    REG32(CLINT_PRESCALER) = hw_hz / tick_hz - 1u;
    return CLINT_OK;
}

uint64_t clint_mtime(void) {
    uint32_t hi, lo, hi2;
    do {
        hi  = REG32(CLINT_MTIME_HI);
        lo  = REG32(CLINT_MTIME_LO);
        hi2 = REG32(CLINT_MTIME_HI);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

void clint_set_mtime(uint64_t t) {
    REG32(CLINT_MTIME_LO) = 0;                 /* no carry into hi meanwhile */
    REG32(CLINT_MTIME_HI) = (uint32_t)(t >> 32);
    REG32(CLINT_MTIME_LO) = (uint32_t)t;
}

void clint_set_mtimecmp(uint64_t t) {
    /* priv spec sequence: never let mtimecmp be transiently small */
    REG32(CLINT_MTIMECMP_LO) = 0xFFFFFFFFu;
    REG32(CLINT_MTIMECMP_HI) = (uint32_t)(t >> 32);
    REG32(CLINT_MTIMECMP_LO) = (uint32_t)t;
}

void clint_timer_after(uint64_t ticks) { clint_set_mtimecmp(clint_mtime() + ticks); }

void clint_timer_off(void) {
    REG32(CLINT_MTIMECMP_HI) = 0xFFFFFFFFu;
    REG32(CLINT_MTIMECMP_LO) = 0xFFFFFFFFu;
}

void delay_ticks(uint64_t ticks) {
    uint64_t end = clint_mtime() + ticks;
    while (clint_mtime() < end) { }
}

void delay_us(uint32_t us) {
    uint64_t cycles = (uint64_t)us * (REG32(CLINT_CLK_FREQ) / 1000000u);
    uint64_t end = rdcycle64() + cycles;
    while (rdcycle64() < end) { }
}

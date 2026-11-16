/* peterson - two-hart mutual exclusion test for WASP_SoC (WASP harts on CHI)
 *
 * Both harts run this same image. Every hart:
 *   - reads mhartid (0 or 1) and prints a banner on its own UART
 *   - ITERS times: Peterson lock, then a deliberately slow, non-atomic
 *     read-modify-write of a shared counter, with an occupancy flag that
 *     catches two harts inside the critical section at once, then unlock
 *   - increments a PRIVATE global ITERS times (DMEM is translated per hart in
 *     the bridge, so each hart must see exactly ITERS, not 2*ITERS)
 *   - waits until both harts are done, checks the shared counter == 2*ITERS
 *   - prints PASS / FAIL and sends EOT (0x04)
 *
 * Shared variables live in the SHARED window (0x9000_0000, not translated,
 * preloaded with zeros), one per 64-byte cache line, so every handover is a
 * coherence transaction between the two RN-Fs.
 *
 * The WASP core is in order and the bridge only grants a store once the
 * RN-F completed it, so plain loads/stores are sequentially consistent here.
 * The fences are kept for correctness on any RVWMO implementation.
 */
#include <stdint.h>
#include "uart.h"
#include "csr.h"

#ifndef ITERS
#define ITERS 200u
#endif

#define SHARED_BASE 0x90000000u
#define LINE(n)     (*(volatile uint32_t *)(SHARED_BASE + 64u * (n)))

#define FLAG(h)     LINE(0 + (h))
#define TURN        LINE(2)
#define COUNTER     LINE(3)
#define IN_CS       LINE(4)
#define DONE(h)     LINE(5 + (h))
#define VIOLATIONS  LINE(7)

#define CSR_MHARTID 0xF14

static volatile uint32_t g_private;          /* DMEM: per hart (bridge translation) */

static inline void fence(void) { __asm__ volatile ("fence rw, rw" ::: "memory"); }

/* -DPETERSON_NOLOCK: lock() / unlock() do nothing -- negative test, the run
 * must then report violations / a lost update (proves the checks can fail) */
static void lock(uint32_t me) {
#ifdef PETERSON_NOLOCK
    (void)me; return;
#endif
    uint32_t other = 1u - me;
    FLAG(me) = 1u;
    fence();
    TURN = other;
    fence();
    while (FLAG(other) == 1u && TURN == other) { }
    fence();
}

static void unlock(uint32_t me) {
#ifdef PETERSON_NOLOCK
    (void)me; return;
#endif
    fence();
    FLAG(me) = 0u;
}

static void put_line(const char *s, uint32_t v) {
    uart_puts(s);
    uart_putdec(v);
    uart_puts("\r\n");
}

int main(void) {
    uint32_t me = read_csr(0xF14);
    uint32_t fails = 0;

    uart_init_local(CPU_CLK_HZ, 115200);
    put_line("PETERSON hart ", me);

    g_private = 0u;
    for (uint32_t i = 0; i < ITERS; i++) {
        lock(me);
        if (IN_CS != 0u) VIOLATIONS = VIOLATIONS + 1u;
        IN_CS = me + 1u;
        uint32_t c = COUNTER;
        for (volatile uint32_t d = 0; d < (i & 7u); d++) { }   /* widen the race window */
        COUNTER = c + 1u;
        if (IN_CS != me + 1u) VIOLATIONS = VIOLATIONS + 1u;
        IN_CS = 0u;
        unlock(me);
        g_private = g_private + 1u;
    }

    fence();
    DONE(me) = 1u;
    while (DONE(0) == 0u || DONE(1) == 0u) { }
    fence();

    uint32_t counter = COUNTER, viol = VIOLATIONS, priv = g_private;
    put_line("counter    ", counter);
    put_line("violations ", viol);
    put_line("private    ", priv);
    if (counter != 2u * ITERS) { uart_puts("FAIL shared counter != 2*ITERS\r\n"); fails++; }
    if (viol != 0u)            { uart_puts("FAIL mutual exclusion violated\r\n"); fails++; }
    if (priv != ITERS)         { uart_puts("FAIL private DMEM not private (segment translation)\r\n"); fails++; }
    uart_puts(fails ? "PETERSON FAIL\r\n" : "PETERSON PASS\r\n");
    uart_send_byte(0x04);
    for (;;) { }
    return 0;
}

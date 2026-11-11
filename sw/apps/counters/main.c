/* Self-test for the Zicntr CSRs, the CLINT (timer + software interrupt),
 * the memory map (PLIC register page, IMEM data reads, D-cache flush) and the
 * trap driver (access faults, ebreak, FENCE.I / generated code, x/0).
 * Prints one line per check over UART and ends with "ALL PASS" or
 * "FAILED <n>". Build: make -C sw PROG=counters (wasp only: it tests the hardware)
 */
#include <stdint.h>
#include "uart.h"
#include "irq.h"
#include "csr.h"
#include "clint.h"
#include "cache.h"
#include "memmap.h"
#include "trap.h"

static volatile uint32_t g_irq_cause;
static volatile uint32_t g_irq_count;
static int g_fail;
#ifndef STRESS_US
#define STRESS_US 20
#endif
static volatile uint32_t g_rearm;

static uint32_t mix(uint32_t h, uint32_t v) {
    h ^= v;
    h = (h << 5) | (h >> 27);
    return h * 0x9E3779B1u + 7u;
}

static uint32_t stress_work(void) {
    uint32_t h = 0x12345678u;
    for (uint32_t i = 0; i < 20000u; i++) {
        if (i & 1u)        h = mix(h, i);
        else if (i % 3u)   h ^= i * 3u;
        else               h += mix(i, h) >> 3;
        switch (h & 3u) {
            case 0:  h += 11u; break;
            case 1:  h ^= 0x55u; break;
            default: h -= i; break;
        }
    }
    return h;
}

void __attribute__((interrupt("machine"), aligned(256))) trap_handler(void) {
    uint32_t cause = read_csr(mcause);
    g_irq_cause = cause;
    g_irq_count++;
    if (cause == MCAUSE_IRQ_MTI) { if (g_rearm) clint_timer_after(STRESS_US); else clint_timer_off(); }
    else if (cause == MCAUSE_IRQ_MSI) clint_msip_clear();
}

static void check(const char *name, int ok, uint32_t info) {
    uart_puts(ok ? "PASS " : "FAIL ");
    uart_puts(name);
    uart_puts(" 0x");
    uart_puthex32(info);
    uart_puts("\n");
    if (!ok) g_fail++;
}

static volatile uint32_t g_flush_word;

/* cycles for one load of *p (the branch waits for the data) */
static uint32_t timed_load(volatile uint32_t *p, uint32_t *val) {
    uint32_t t0 = rdcycle();
    uint32_t v = *p;
    if (v == 0x5EED5EEDu) __asm__ volatile("nop");
    uint32_t t1 = rdcycle();
    *val = v;
    return t1 - t0;
}

static void memmap_checks(void) {
    /* code is fetched from IMEM_BASE: _start begins with a nop */
    check("IMEM data read @0x4000_0000", REG32(IMEM_BASE) == 0x00000013u, REG32(IMEM_BASE));

    /* PLIC page: registers at their compact offsets */
    REG32(PLIC_THRESHOLD) = 5;
    check("PLIC threshold r/w", REG32(PLIC_THRESHOLD) == 5u, REG32(PLIC_THRESHOLD));
    REG32(PLIC_THRESHOLD) = 0;
    REG32(PLIC_PRIORITY + 4 * 3) = 6;
    check("PLIC priority[3] r/w", REG32(PLIC_PRIORITY + 4 * 3) == 6u, REG32(PLIC_PRIORITY + 4 * 3));
    REG32(PLIC_PRIORITY + 4 * 7) = 7;          /* no source 7 (N_SRC = 5) */
    check("PLIC priority[7] absent", REG32(PLIC_PRIORITY + 4 * 7) == 0u, REG32(PLIC_PRIORITY + 4 * 7));
    check("PLIC priority[3] not aliased", REG32(PLIC_PRIORITY + 4 * 3) == 6u, REG32(PLIC_PRIORITY + 4 * 3));
    REG32(PLIC_PRIORITY + 4 * 3) = 1;
    REG32(PLIC_ENABLE) = 0x7u;                 /* source 0 is reserved */
    check("PLIC enable r/w", REG32(PLIC_ENABLE) == 0x6u, REG32(PLIC_ENABLE));
    REG32(PLIC_ENABLE) = 0;
    check("PLIC pending idle", REG32(PLIC_PENDING) == 0u, REG32(PLIC_PENDING));

    /* D-cache flush register: dirty line survives write-back, next load misses */
    uint32_t v, t_hit, t_miss;
    g_flush_word = 0xA5C3F00Du;
    (void)timed_load(&g_flush_word, &v);       /* warm the I-cache */
    t_hit = timed_load(&g_flush_word, &v);
    dcache_flush_all();
    t_miss = timed_load(&g_flush_word, &v);
    check("dcache flush keeps data", v == 0xA5C3F00Du, v);
    check("dcache flush invalidates", t_miss > t_hit + 8u, (t_miss << 16) | t_hit);
}

static int wait_irq(uint32_t count_before, uint32_t max_cycles) {
    uint32_t start = rdcycle();
    while (g_irq_count == count_before)
        if (rdcycle() - start > max_cycles) return 0;
    return 1;
}

/* ---- trap driver (trap.h): access faults, ebreak, FENCE.I, x/0 ------- */
static volatile uint32_t g_tcause, g_tepc, g_tval, g_tcount;
static volatile uint32_t g_resume;          /* where a fetch fault continues */

static void on_exception(trap_frame_t *f) {
    g_tcause = f->mcause; g_tepc = f->mepc; g_tval = f->mtval; g_tcount++;
    if (f->mcause == MCAUSE_INSN_ACCESS) f->mepc = g_resume;   /* back to the caller */
    else trap_skip(f);                                         /* skip the faulting insn */
}

/* single instructions with a known destination register */
static uint32_t try_load(uint32_t addr) {
    uint32_t v = 0xA5A5A5A5u;
    __asm__ volatile ("lw %0, 0(%1)" : "+r"(v) : "r"(addr) : "memory");
    return v;
}
static void try_store(uint32_t addr) {
    __asm__ volatile ("sw zero, 0(%0)" :: "r"(addr) : "memory");
}
static void try_fetch(uint32_t addr) {   /* jump there, fault, resume at 1: */
    __asm__ volatile ("la t1, 1f\n\tsw t1, %1\n\tjalr ra, 0(%0)\n1:"
                      :: "r"(addr), "m"(g_resume) : "ra", "t1", "memory");
}

static int faulted(uint32_t n, uint32_t cause, uint32_t tval) {
    return g_tcount == n + 1 && g_tcause == cause && g_tval == tval;
}

static uint32_t code_buf[16] __attribute__((aligned(64)));   /* DMEM: executable */
typedef uint32_t (*fn_t)(void);

static void trap_checks(void) {
    trap_init();
    trap_set_exception_handler(MCAUSE_INSN_ACCESS,  on_exception);
    trap_set_exception_handler(MCAUSE_LOAD_ACCESS,  on_exception);
    trap_set_exception_handler(MCAUSE_STORE_ACCESS, on_exception);
    trap_set_exception_handler(MCAUSE_BREAKPOINT,   on_exception);

    uint32_t n = g_tcount;
    uint32_t v = try_load(0x30000000u);
    check("load unmapped: access fault", faulted(n, MCAUSE_LOAD_ACCESS, 0x30000000u), g_tcause);
    check("load unmapped: rd not written", v == 0xA5A5A5A5u, v);

    uint32_t imem0 = REG32(IMEM_BASE);
    n = g_tcount; try_store(IMEM_BASE);
    check("store to IMEM: access fault", faulted(n, MCAUSE_STORE_ACCESS, IMEM_BASE), g_tcause);
    check("store to IMEM: no effect", REG32(IMEM_BASE) == imem0, REG32(IMEM_BASE));

    n = g_tcount; (void)try_load(DCACHE_FLUSH_BASE);
    check("read flush reg: access fault", faulted(n, MCAUSE_LOAD_ACCESS, DCACHE_FLUSH_BASE), g_tcause);
    n = g_tcount; (void)try_load(SLOT3_BASE);
    check("empty slot: access fault", faulted(n, MCAUSE_LOAD_ACCESS, SLOT3_BASE), g_tcause);

    n = g_tcount; try_fetch(0x30000000u);
    check("fetch unmapped: insn access fault",
          faulted(n, MCAUSE_INSN_ACCESS, 0x30000000u) && g_tepc == 0x30000000u, g_tcause);

    g_flush_word = 0x0BADC0DEu;
    check("bus usable after faults", g_flush_word == 0x0BADC0DEu, g_flush_word);

    n = g_tcount;
    __asm__ volatile ("1: ebreak\n\tla %0, 1b" : "=r"(v));
    check("ebreak: mtval = pc", faulted(n, MCAUSE_BREAKPOINT, v), g_tval);

    /* generated code in DMEM: li a0, 42; ret -> run -> li a0, 43 -> run */
    code_buf[0] = 0x02A00513u;   /* addi a0, zero, 42 */
    code_buf[1] = 0x00008067u;   /* ret */
    icache_sync();
    uint32_t r1 = ((fn_t)(uintptr_t)code_buf)();
    code_buf[0] = 0x02B00513u;   /* addi a0, zero, 43: the old one is in the I-cache now */
    icache_sync();
    uint32_t r2 = ((fn_t)(uintptr_t)code_buf)();
    check("fence.i: run generated code", r1 == 42u, r1);
    check("fence.i: run rewritten code", r2 == 43u, r2);

    /* division by zero: defined results, no trap */
    volatile int32_t a = -7, z = 0;
    volatile uint32_t ua = 7;
    n = g_tcount;
    int32_t  q  = a / z, r = a % z;
    uint32_t uq = ua / (uint32_t)z, ur = ua % (uint32_t)z;
    check("x/0 = -1, x%0 = x, no trap",
          q == -1 && r == -7 && uq == 0xFFFFFFFFu && ur == 7u && g_tcount == n, (uint32_t)q);
}

int main(void) {
    uart_init_local(CPU_CLK_HZ, 115200);
    uart_puts("wasp counters/CLINT self-test\n");

    /* --- static CSRs --- */
    check("misa", read_csr(misa) == 0x40001100u, read_csr(misa));
    check("mcounteren reset", read_csr(CSR_MCOUNTEREN) == 0xFFFFFFFFu, read_csr(CSR_MCOUNTEREN));
    check("scounteren reset", read_csr(CSR_SCOUNTEREN) == 0xFFFFFFFFu, read_csr(CSR_SCOUNTEREN));
    check("mhpmcounter3 = 0", read_csr(0xB03) == 0, read_csr(0xB03));

    /* --- mcycle --- */
    uint32_t c0 = rdcycle(); uint32_t c1 = rdcycle();
    check("mcycle advances", c1 > c0, c1 - c0);
    c0 = read_csr(CSR_CYCLE); c1 = rdcycle();
    check("cycle == mcycle shadow", (c1 - c0) < 64u, c1 - c0);

    write_csr(CSR_MCYCLEH, 0x12345678u);
    check("mcycleh write", read_csr(CSR_MCYCLEH) == 0x12345678u, read_csr(CSR_MCYCLEH));
    write_csr(CSR_MCYCLEH, 0);
    write_csr(CSR_MCYCLE, 0x1000u);
    c0 = rdcycle();
    check("mcycle write", c0 >= 0x1000u && c0 < 0x1100u, c0);

    set_csr(CSR_MCOUNTINHIBIT, MCOUNTINHIBIT_CY);
    c0 = rdcycle(); __asm__ volatile("nop; nop; nop; nop"); c1 = rdcycle();
    check("mcountinhibit.CY freezes", c0 == c1, c1 - c0);
    clear_csr(CSR_MCOUNTINHIBIT, MCOUNTINHIBIT_CY);

    /* --- minstret: 1 li + 2*100 loop instrs + csrr between the two reads.
     * CSRs are read in ID, so both reads see the same pipeline offset;
     * allow +-4 for bubbles in flight. --- */
    uint32_t i0, i1;
    __asm__ volatile(
        "csrr %0, 0xB02\n"
        "li   t0, 100\n"
        "1: addi t0, t0, -1\n"
        "bnez t0, 1b\n"
        "csrr %1, 0xB02\n"
        : "=&r"(i0), "=&r"(i1) :: "t0");
    uint32_t di = i1 - i0;
    check("minstret loop (expect ~202)", di >= 198 && di <= 206, di);

    set_csr(CSR_MCOUNTINHIBIT, MCOUNTINHIBIT_IR);
    i0 = rdinstret(); __asm__ volatile("nop; nop; nop; nop"); i1 = rdinstret();
    check("mcountinhibit.IR freezes", i0 == i1, i1 - i0);
    clear_csr(CSR_MCOUNTINHIBIT, MCOUNTINHIBIT_IR);

    /* --- CLINT clock check / prescaler --- */
    check("clint clk_freq", clint_clk_freq() == CPU_CLK_HZ, clint_clk_freq());
    check("clint_init wrong clk rejected",
          clint_init(CPU_CLK_HZ + 1u, 1000000u) == CLINT_ERR_CLK_MISMATCH, 0);
    check("clint_init bad tick rejected",
          clint_init(CPU_CLK_HZ, 3000000u) == CLINT_ERR_BAD_TICK, 0);

    int rc = clint_init(CPU_CLK_HZ, 10000000u);           /* 10 MHz -> /5 */
    check("clint_init 10MHz", rc == CLINT_OK && clint_tick_hz() == 10000000u, REG32(CLINT_PRESCALER));
    uint64_t t0 = rdtime64(); uint64_t cy0 = rdcycle64();
    while (rdcycle64() - cy0 < 5000u) { }
    uint64_t t1 = rdtime64(); uint64_t cy1 = rdcycle64();
    uint32_t ratio = (uint32_t)(cy1 - cy0) / (uint32_t)(t1 - t0);
    check("mtime rate = clk/5", ratio >= 4 && ratio <= 6, ratio);

    rc = clint_init(CPU_CLK_HZ, 1000000u);                /* back to 1 us */
    check("clint_init 1MHz", rc == CLINT_OK, REG32(CLINT_PRESCALER));
    uint64_t tm = clint_mtime(), tc = rdtime64();
    check("time CSR == CLINT mtime", (tc - tm) < 4u, (uint32_t)(tc - tm));

    clint_set_mtime(0x00000001FFFFFFF0ull);
    tm = clint_mtime();
    check("mtime 64-bit write", (tm >> 32) == 1u || (tm >> 32) == 2u, (uint32_t)(tm >> 32));

    /* --- interrupts --- */
    write_csr(mtvec, (uint32_t)trap_handler);
    set_csr(mie, MIE_MTIE | MIE_MSIE);
    set_csr(mstatus, MSTATUS_MIE);

    uint32_t n = g_irq_count;
    clint_timer_after(STRESS_US);                                /* 20 us */
    check("timer irq fires", wait_irq(n, 200000u) && g_irq_cause == MCAUSE_IRQ_MTI, g_irq_cause);
    check("mip.MTIP clear after handler", (read_csr(mip) & MIP_MTIP) == 0, read_csr(mip));

    n = g_irq_count;
    clint_msip_set();
    check("software irq fires", wait_irq(n, 100000u) && g_irq_cause == MCAUSE_IRQ_MSI, g_irq_cause);
    check("msip cleared", REG32(CLINT_MSIP) == 0, REG32(CLINT_MSIP));

    /* second timer interrupt: proves MIE/MPIE are restored correctly */
    n = g_irq_count;
    clint_timer_after(5);
    check("second timer irq", wait_irq(n, 200000u) && g_irq_cause == MCAUSE_IRQ_MTI, g_irq_count);

    clear_csr(mstatus, MSTATUS_MIE);

    /* --- interrupt stress: same branch/call-heavy computation with and
     * without a timer interrupt every few us must give the same result
     * (catches lost branches / wrong mepc under interrupts). --- */
    uint32_t ref = stress_work();
    n = g_irq_count;
    g_rearm = 1;
    clint_timer_after(STRESS_US);
    set_csr(mstatus, MSTATUS_MIE);
    uint32_t got = stress_work();
    g_rearm = 0;
    clear_csr(mstatus, MSTATUS_MIE);
    clint_timer_off();
    uint32_t taken = g_irq_count - n;
    check("irq stress: result unchanged", got == ref, got ^ ref);
    check("irq stress: >100 irqs taken", taken > 100u, taken);

    memmap_checks();
    trap_checks();

    uart_puts("mcycle=0x"); uart_puthex64(rdcycle64());
    uart_puts(" minstret=0x"); uart_puthex64(rdinstret64());
    uart_puts("\n");
    if (g_fail == 0) uart_puts("ALL PASS\n");
    else { uart_puts("FAILED "); uart_putdec((uint32_t)g_fail); uart_puts("\n"); }
    uart_send_byte(4);   /* EOT, lets the testbench stop */
    while (1) { }
    return 0;
}

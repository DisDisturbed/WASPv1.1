/* Trap dispatcher for wasp (see trap.h). */
#include "trap.h"
#include "csr.h"

static trap_handler_t exc_handlers[TRAP_N_EXC];
static trap_handler_t irq_handlers[TRAP_N_IRQ];

/* mtvec target. wasp takes every trap to {mtvec[31:8], 8'h00}, hence the
 * 256-byte alignment. The interrupt attribute saves every register the
 * dispatcher (and the handlers it calls) may clobber and returns with mret. */
void __attribute__((interrupt("machine"), aligned(256))) trap_entry(void) {
    trap_frame_t f;
    f.mcause = read_csr(mcause);
    f.mepc   = read_csr(mepc);
    f.mtval  = read_csr(mtval);

    if (f.mcause & MCAUSE_INTERRUPT) {
        uint32_t irq = f.mcause & 0x1fu;
        if (irq < TRAP_N_IRQ && irq_handlers[irq])
            irq_handlers[irq](&f);
        return;                         /* interrupts resume at mepc unchanged */
    }

    if (f.mcause < TRAP_N_EXC && exc_handlers[f.mcause])
        exc_handlers[f.mcause](&f);
    else
        trap_fatal(&f);
    write_csr(mepc, f.mepc);
}

void trap_init(void) {
    write_csr(mtvec, (uint32_t)trap_entry);
}

void trap_set_exception_handler(uint32_t cause, trap_handler_t h) {
    if (cause < TRAP_N_EXC) exc_handlers[cause] = h;
}

void trap_set_interrupt_handler(uint32_t irq, trap_handler_t h) {
    if (irq < TRAP_N_IRQ) irq_handlers[irq] = h;
}

/* Unhandled exception: report and stop (interrupts off, spin). */
void __attribute__((weak)) trap_fatal(trap_frame_t *f) {
    trap_print(f);
    clear_csr(mstatus, MSTATUS_MIE);
    for (;;)
        __asm__ volatile ("wfi");
}

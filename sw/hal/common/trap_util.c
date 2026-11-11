/* Target-independent part of the trap driver (trap.h): cause names and the
 * one-line report. Used by hal/wasp/trap.c and hal/host/trap_host.c. */
#include "trap.h"
#include "uart.h"

const char *trap_cause_name(uint32_t mcause) {
    if (mcause & MCAUSE_INTERRUPT) {
        switch (mcause & 0x1fu) {
            case IRQ_MSI: return "software interrupt";
            case IRQ_MTI: return "timer interrupt";
            case IRQ_MEI: return "external interrupt";
            default:      return "interrupt";
        }
    }
    switch (mcause) {
        case MCAUSE_INSN_MISALIGNED:  return "instruction address misaligned";
        case MCAUSE_INSN_ACCESS:      return "instruction access fault";
        case MCAUSE_ILLEGAL_INSN:     return "illegal instruction";
        case MCAUSE_BREAKPOINT:       return "breakpoint";
        case MCAUSE_LOAD_MISALIGNED:  return "load address misaligned";
        case MCAUSE_LOAD_ACCESS:      return "load access fault";
        case MCAUSE_STORE_MISALIGNED: return "store address misaligned";
        case MCAUSE_STORE_ACCESS:     return "store access fault";
        case MCAUSE_ECALL_M:          return "ecall from M-mode";
        default:                      return "unknown exception";
    }
}

void trap_print(const trap_frame_t *f) {
    uart_puts("TRAP ");
    uart_puts(trap_cause_name(f->mcause));
    uart_puts(" mcause=0x"); uart_puthex32(f->mcause);
    uart_puts(" mepc=0x");   uart_puthex32(f->mepc);
    uart_puts(" mtval=0x");  uart_puthex32(f->mtval);
    uart_puts("\n");
}

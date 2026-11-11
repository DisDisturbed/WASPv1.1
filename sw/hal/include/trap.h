#ifndef TRAP_H
#define TRAP_H
/* Trap (exception + interrupt) dispatcher for wasp, M-mode only.
 *
 *   trap_init();                                       mtvec -> trap entry
 *   trap_set_exception_handler(MCAUSE_LOAD_ACCESS, h); per synchronous cause
 *   trap_set_interrupt_handler(IRQ_MTI, h);            per interrupt
 *
 * Every trap builds a trap_frame_t and calls the registered handler.
 * Exceptions with no handler go to trap_fatal(): it prints one line on the
 * UART and stops the program:
 *
 *   TRAP load access fault mcause=0x00000005 mepc=0x40000a1c mtval=0x30000000
 *
 * (trap_fatal is weak: an app can provide its own.)
 * A handler resumes the program at f->mepc. For an exception that is the
 * faulting instruction itself, so a handler that does not fix the cause must
 * call trap_skip(f) (resume at the next instruction) or set f->mepc.
 *
 * Exceptions raised by wasp (mtval in brackets):
 *   0 instruction address misaligned   jump/branch target not 4-byte aligned  [target]
 *   1 instruction access fault         fetch outside IMEM/DMEM                 [pc]
 *   2 illegal instruction              undefined opcode/funct (unknown CSRs read 0) [instruction]
 *   3 breakpoint                       ebreak                                  [pc]
 *   4 load address misaligned          lh/lhu/lw not naturally aligned         [address]
 *   5 load access fault                see memmap.h, "access faults"           [address]
 *   6 store address misaligned         sh/sw not naturally aligned             [address]
 *   7 store access fault               see memmap.h, "access faults"           [address]
 *  11 environment call from M-mode     ecall                                   [0]
 * Division by zero is not an exception (RISC-V: x/0 = -1, x%0 = x).
 *
 * Existing code that installs its own __attribute__((interrupt)) handler with
 * hw_init_interrupts() (irq.h) keeps working; use one scheme or the other.
 */
#include <stdint.h>

/* mcause, exceptions (bit 31 = 0) */
#define MCAUSE_INSN_MISALIGNED   0u
#define MCAUSE_INSN_ACCESS       1u
#define MCAUSE_ILLEGAL_INSN      2u
#define MCAUSE_BREAKPOINT        3u
#define MCAUSE_LOAD_MISALIGNED   4u
#define MCAUSE_LOAD_ACCESS       5u
#define MCAUSE_STORE_MISALIGNED  6u
#define MCAUSE_STORE_ACCESS      7u
#define MCAUSE_ECALL_M          11u
#define MCAUSE_INTERRUPT        0x80000000u

/* interrupt numbers (mcause & 0x1f with MCAUSE_INTERRUPT set) */
#define IRQ_MSI   3u   /* CLINT software interrupt */
#define IRQ_MTI   7u   /* CLINT timer */
#define IRQ_MEI  11u   /* PLIC external */

#define TRAP_N_EXC 16u
#define TRAP_N_IRQ 16u

typedef struct {
    uint32_t mcause;   /* as read from the CSR */
    uint32_t mepc;     /* resume address: the handler may change it */
    uint32_t mtval;    /* faulting address / instruction, see above */
} trap_frame_t;

typedef void (*trap_handler_t)(trap_frame_t *f);

void trap_init(void);   /* point mtvec at the dispatcher; enables nothing */
void trap_set_exception_handler(uint32_t cause, trap_handler_t h);  /* NULL: trap_fatal */
void trap_set_interrupt_handler(uint32_t irq,   trap_handler_t h);  /* NULL: ignore */

static inline int  trap_is_interrupt(const trap_frame_t *f) { return (f->mcause & MCAUSE_INTERRUPT) != 0; }
static inline void trap_skip(trap_frame_t *f)               { f->mepc += 4; }

const char *trap_cause_name(uint32_t mcause);   /* "load access fault", ... */
void trap_print(const trap_frame_t *f);         /* the TRAP line above, on the UART */
void trap_fatal(trap_frame_t *f);               /* weak: trap_print + stop */

#endif /* TRAP_H */

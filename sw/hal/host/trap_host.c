/* Host stand-in for the trap driver: the PC build has no RISC-V traps, so
 * handlers are accepted and never called. trap_cause_name/trap_print come
 * from hal/common/trap_util.c as on the target. */
#include <stdlib.h>
#include "trap.h"

void trap_init(void) { }
void trap_set_exception_handler(uint32_t cause, trap_handler_t h) { (void)cause; (void)h; }
void trap_set_interrupt_handler(uint32_t irq,   trap_handler_t h) { (void)irq;   (void)h; }

void __attribute__((weak)) trap_fatal(trap_frame_t *f) {
    trap_print(f);
    exit(1);
}

/* Host stand-in for the PLIC/interrupt driver: no interrupts on the PC. */
#include "irq.h"

void hw_init_interrupts(void *trap_handler_addr) { (void)trap_handler_addr; }
void hw_enable_irq_sources(uint32_t mie_bits)    { (void)mie_bits; }
void hw_init_plic_button(void)                   { }
void hw_disable_button_irq(void)                 { }

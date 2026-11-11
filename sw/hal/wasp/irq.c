#include "irq.h"

void hw_init_interrupts(void *trap_handler_addr) {
    // Set 256-byte aligned vector table
    write_csr(mtvec, (uint32_t)trap_handler_addr);
    
    // Enable Core Interrupts (forced to register-variant csrs)
    set_csr(mie, MIE_MEIE);
    set_csr(mstatus, MSTATUS_MIE);
}

void hw_init_plic_button(void) {
    // Clear PLIC completely
    for (int i = 0; i < 32; i++) { 
        REG32(PLIC_PRIORITY + (i * 4)) = 0; 
    }
    REG32(PLIC_ENABLE) = 0;
    REG32(PLIC_THRESHOLD) = 0;

    // Configure for Hardware Button
    REG32(PLIC_PRIORITY + (BUTTON_IRQ_ID * 4)) = 1;
    REG32(PLIC_ENABLE) |= (1 << BUTTON_IRQ_ID);
}

void hw_disable_button_irq(void) {
    // ONE-SHOT Disable to prevent trap looping
    REG32(PLIC_ENABLE) &= ~(1 << BUTTON_IRQ_ID);
}

void hw_enable_irq_sources(uint32_t mie_bits) {
    // Timer (MTIE) / software (MSIE) / external (MEIE) enables in mie
    set_csr(mie, mie_bits);
}

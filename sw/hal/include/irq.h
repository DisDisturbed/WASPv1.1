#ifndef IRQ_H
#define IRQ_H

#include <stdint.h>
#include "csr.h"     /* read_csr/write_csr/set_csr + MSTATUS_MIE, MIE_* bits */
#include "memmap.h"  /* PLIC_BASE */

// PLIC registers, compact wasp layout (one 4 KB page, see RTL/Plic.sv;
// NOT the RISC-V PLIC spec offsets)
#define PLIC_PRIORITY   (PLIC_BASE + 0x000)   /* + 4 * source id */
#define PLIC_PENDING    (PLIC_BASE + 0x080)
#define PLIC_ENABLE     (PLIC_BASE + 0x100)
#define PLIC_THRESHOLD  (PLIC_BASE + 0x200)
#define PLIC_CLAIM      (PLIC_BASE + 0x204)

#define BUTTON_IRQ_ID   2

// API
void hw_init_interrupts(void *trap_handler_addr);   /* mtvec + MEIE + MIE      */
void hw_enable_irq_sources(uint32_t mie_bits);      /* e.g. MIE_MTIE|MIE_MSIE  */
void hw_init_plic_button(void);
void hw_disable_button_irq(void);

#endif // IRQ_H

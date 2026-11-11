/* UART16550 driver (wasp). Text/buffer helpers are in hal/common/uart_util.c. */
#include "uart.h"

void uart_init_local(uint32_t axi_clock_hz, uint32_t baud_rate) {
    uint32_t divisor = axi_clock_hz / (16 * baud_rate);
    REG32(UART_LCR) = (1 << 7); 
    REG32(UART_BASE + 0x00) = divisor & 0xFF;
    REG32(UART_BASE + 0x04) = (divisor >> 8) & 0xFF;
    REG32(UART_LCR) = 0x03; 
}

char uart_receive_byte(void) {
    while ((REG32(UART_LSR) & LSR_DR) == 0) { __asm__ volatile("nop"); }
    return (char)(REG32(UART_RBR) & 0xFF);
}

void uart_send_byte(char data) {
    while ((REG32(UART_LSR) & LSR_THRE) == 0) { __asm__ volatile("nop"); }
    REG32(UART_THR) = data;
}

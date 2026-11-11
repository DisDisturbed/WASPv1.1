#ifndef UART_H
#define UART_H

#include <stdint.h>
#include "memmap.h"   /* UART_BASE */

// UART16550 registers
#define UART_RBR        (UART_BASE + 0x00) 
#define UART_THR        (UART_BASE + 0x00) 
#define UART_LCR        (UART_BASE + 0x0C) 
#define UART_LSR        (UART_BASE + 0x14) 

#define LSR_DR          (1 << 0) 
#define LSR_THRE        (1 << 5) 

// API
void uart_init_local(uint32_t axi_clock_hz, uint32_t baud_rate);
char uart_receive_byte(void);
void uart_send_byte(char data);

// buffers / text helpers
void uart_send_buf(const uint8_t *buf, uint32_t len);
void uart_receive_buf(uint8_t *buf, uint32_t len);
void uart_puts(const char *s);
void uart_puthex32(uint32_t v);
void uart_puthex64(uint64_t v);
void uart_putdec(uint32_t v);

#endif // UART_H
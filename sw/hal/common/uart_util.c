/* UART helpers built on uart_send_byte / uart_receive_byte. Same code on
 * every target (wasp: hal/wasp/uart.c, host: hal/host/uart_host.c). */
#include "uart.h"

void uart_send_buf(const uint8_t *buf, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) uart_send_byte((char)buf[i]);
}

void uart_receive_buf(uint8_t *buf, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) buf[i] = (uint8_t)uart_receive_byte();
}

void uart_puts(const char *s) {
    while (*s) uart_send_byte(*s++);
}

void uart_puthex32(uint32_t v) {
    static const char hex[] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--) uart_send_byte(hex[(v >> (i * 4)) & 0xF]);
}

void uart_puthex64(uint64_t v) {
    uart_puthex32((uint32_t)(v >> 32));
    uart_puthex32((uint32_t)v);
}

void uart_putdec(uint32_t v) {
    char buf[10];
    int n = 0;
    do { buf[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) uart_send_byte(buf[--n]);
}

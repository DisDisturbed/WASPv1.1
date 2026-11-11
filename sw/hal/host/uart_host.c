/* Host "UART": RX = stdin, TX = stdout, both raw bytes. Run a firmware app
 * on the PC with the same input file the RTL simulation gets:
 *     build/host/<prog>/main < uart_rx.bin > uart_tx.bin
 * The firmware main loops never return; end of stdin ends the program
 * (like the testbench stopping when the input runs out). */
#include <stdio.h>
#include <stdlib.h>
#include "uart.h"
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

void uart_init_local(uint32_t axi_clock_hz, uint32_t baud_rate) {
    (void)axi_clock_hz; (void)baud_rate;
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
}

char uart_receive_byte(void) {
    int c = getchar();
    if (c == EOF) {
        fflush(stdout);
        exit(0);
    }
    return (char)c;
}

void uart_send_byte(char data) {
    putchar((unsigned char)data);
}

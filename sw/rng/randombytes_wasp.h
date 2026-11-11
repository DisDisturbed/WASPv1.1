#ifndef RANDOMBYTES_WASP_H
#define RANDOMBYTES_WASP_H
#include <stdint.h>
/* wasp RNG API, two implementations chosen at build time (sw/Makefile RNG=):
 *   randombytes_hw.c   RNG=hw   mcycle-jitter entropy, FPGA builds only
 *   randombytes_det.c  RNG=det  fixed-seed SHAKE256, RTL sim + host (default)
 * randombytes() itself is declared in lib/sphincs/rng.h (NIST prototype). */

/* hw: fold the current mcycle into the entropy pool. det: count only.
 * Call it at asynchronous events (UART byte received, button press, ...). */
void     rng_entropy_event(void);
uint32_t rng_event_count(void);

/* Next randombytes() output comes from buf (KAT reproduction). */
void     rng_inject(const uint8_t *buf, uint32_t len);

#endif

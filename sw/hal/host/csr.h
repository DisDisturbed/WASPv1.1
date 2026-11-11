#ifndef CSR_H
#define CSR_H
/* Host stand-in for hal/wasp/csr.h. The PC has no mcycle/minstret/time
 * CSRs: every counter reads 0, so cycle fields an app sends are 0 on the
 * host build (compare scripts skip them, see sim/host/spx_lite.py).
 * read_csr/write_csr are deliberately not provided: code that touches raw
 * CSRs is hardware-only and must sit under #ifndef WASP_HOST. */
#include <stdint.h>

static inline uint64_t rdcycle64(void)   { return 0; }
static inline uint64_t rdinstret64(void) { return 0; }
static inline uint64_t rdtime64(void)    { return 0; }
static inline uint32_t rdcycle(void)     { return 0; }
static inline uint32_t rdinstret(void)   { return 0; }
static inline void     counters_reset(void) { }

#endif /* CSR_H */

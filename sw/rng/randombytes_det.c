/* randombytes() for simulation and host builds (make ... RNG=det, the
 * default). Same API as randombytes_hw.c, but no mcycle/CSR/CLINT input:
 * a fixed-seed SHAKE256 generator, so the RTL simulation and the PC build
 * of the same app produce identical keys/signatures for identical UART
 * input.
 *
 *     out || new_state = SHAKE256("wasp-det" || state || calls)
 *     initial state    = SHAKE256("wasp-det-seed")
 *
 * NOT RANDOM. Never use it on hardware that generates real keys; the FPGA
 * build uses randombytes_hw.c (make ... RNG=hw).
 *
 * rng_entropy_event() only counts events (so 'I' reports the same count as
 * on hardware); rng_inject() works as in randombytes_hw.c.
 */
#include <stdint.h>
#include <string.h>
#include "rng.h"
#include "fips202.h"
#include "randombytes_wasp.h"

static uint32_t pool_events;
static uint8_t  state[32];
static int      seeded;
static uint32_t calls;

static const uint8_t *inj_buf;
static uint32_t       inj_len;

void rng_entropy_event(void) { pool_events++; }

uint32_t rng_event_count(void) { return pool_events; }

void rng_inject(const uint8_t *buf, uint32_t len) {
    inj_buf = buf;
    inj_len = len;
}

int randombytes(unsigned char *x, unsigned long long xlen) {
    /* injected (deterministic) bytes first */
    while (xlen && inj_len) {
        *x++ = *inj_buf++;
        inj_len--; xlen--;
    }
    if (!xlen) return RNG_SUCCESS;

    rng_entropy_event();      /* keep the event count identical to the hw RNG */

    if (!seeded) {
        static const uint8_t seed_tag[] = "wasp-det-seed";
        shake256(state, sizeof state, seed_tag, sizeof seed_tag - 1);
        seeded = 1;
    }

    uint8_t  in[8 + 32 + 4];
    uint32_t c = ++calls;
    memcpy(in, "wasp-det", 8);
    memcpy(in + 8, state, 32);
    for (int i = 0; i < 4; i++) in[40 + i] = (uint8_t)(c >> (8 * i));   /* LE on every host */

    uint64_t s[26];           /* incremental SHAKE256 state */
    shake256_inc_init(s);
    shake256_inc_absorb(s, in, sizeof in);
    shake256_inc_finalize(s);
    shake256_inc_squeeze(state, sizeof state, s);   /* next chaining state */
    shake256_inc_squeeze(x, (size_t)xlen, s);        /* output */
    return RNG_SUCCESS;
}

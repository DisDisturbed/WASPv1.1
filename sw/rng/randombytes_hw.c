/* randombytes() for the FPGA build (make ... RNG=hw) - replaces NIST's
 * rng.c (AES-256 CTR DRBG on OpenSSL) in the SPHINCS+ reference code.
 * Same prototype (rng.h). Simulation and host builds use
 * randombytes_det.c instead, so their outputs can be compared bit-exact.
 *
 * Entropy source: mcycle. A freshly reset core runs the same instruction
 * stream every time, so mcycle by itself is deterministic; the randomness
 * comes from WHEN asynchronous events happen relative to the core clock.
 * The application calls rng_entropy_event() at such events (every UART
 * byte that arrives, button IRQs, ...) and it folds the current mcycle
 * (and its jitter) into a 64-byte pool. This is cheap enough to run per
 * received byte without overrunning the UART FIFO.
 *
 * randombytes() conditions everything with SHAKE256:
 *     out || new_state = SHAKE256("wasp-rng" || state || pool || counters
 *                                 || mcycle || minstret || mtime)
 * and keeps a 32-byte chaining state, so two calls never repeat even if no
 * new events arrived in between.
 *
 * THIS IS NOT A CERTIFIED TRNG. It is as good as the timing jitter of the
 * events you feed it; collect a few dozen independent events (e.g. have the
 * host send random-length pauses / keystrokes) before generating a key.
 *
 * KAT / test mode: rng_inject(buf, len) makes the next randombytes() calls
 * return exactly those bytes (used to reproduce NIST KAT signatures).
 */
#include <stdint.h>
#include <string.h>
#include "rng.h"
#include "fips202.h"
#include "csr.h"
#include "clint.h"
#include "randombytes_wasp.h"

static uint32_t pool[16];
static uint32_t pool_events;
static uint8_t  state[32];
static uint32_t calls;

static const uint8_t *inj_buf;
static uint32_t       inj_len;

static inline uint32_t rotl32(uint32_t x, int r) { return (x << r) | (x >> (32 - r)); }

void rng_entropy_event(void) {
    uint32_t t = read_csr(CSR_MCYCLE);
    uint32_t i = pool_events & 15u;
    /* cheap mixing; the real conditioning is the SHAKE256 in randombytes */
    pool[i] = rotl32(pool[i], 7) ^ t ^ (pool_events * 0x9E3779B9u);
    pool[(i + 5) & 15u] += rotl32(t, 13);
    pool_events++;
}

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

    rng_entropy_event();      /* the call itself is an event too */

    uint64_t s[26];           /* incremental SHAKE256 state */
    struct {
        uint8_t  tag[8];
        uint32_t events, calls;
        uint64_t cycle, instret, mtime;
    } meta;
    memcpy(meta.tag, "wasp-rng", 8);
    meta.events  = pool_events;
    meta.calls   = ++calls;
    meta.cycle   = rdcycle64();
    meta.instret = rdinstret64();
    meta.mtime   = rdtime64();

    shake256_inc_init(s);
    shake256_inc_absorb(s, state, sizeof state);
    shake256_inc_absorb(s, (const uint8_t *)pool, sizeof pool);
    shake256_inc_absorb(s, (const uint8_t *)&meta, sizeof meta);
    shake256_inc_finalize(s);
    shake256_inc_squeeze(state, sizeof state, s);   /* next chaining state */
    shake256_inc_squeeze(x, (size_t)xlen, s);        /* output */
    return RNG_SUCCESS;
}

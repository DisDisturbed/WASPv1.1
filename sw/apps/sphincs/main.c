/* SPHINCS+ (NIST round 3, sphincs-shake256-128s-simple) on wasp.
 *
 * Binary UART protocol, all integers little-endian.
 * After reset the board sends the 8-byte banner "SPX+wsp\n" and then
 * waits for single-byte commands:
 *
 *  'K'                         keygen from the RNG (FPGA build RNG=hw: mcycle
 *                              jitter; sim/host builds RNG=det: fixed seed)
 *                              -> 'k' pk[32] cycles[u64]
 *  'Q' seed[48]                keygen from a given seed (SK.seed||SK.prf||PK.seed)
 *                              -> 'k' pk[32] cycles[u64]
 *  'S' mlen[u32] msg[mlen]     sign with the current key, then verify on-chip
 *                              -> 's' sig[7856] cycles[u64]  'v' ok[u8] cycles[u64]
 *  'D' optrand[16] mlen msg    as 'S' but with a given optrand (deterministic,
 *                              reproduces NIST KAT signatures)
 *  'V' pk[32] mlen msg sig[7856]
 *                              verify -> 'v' ok[u8] cycles[u64]
 *  'P'                         -> 'p' pk[32]
 *  'B'                         -> 'b' cycles[u64] instret[u64] out[32]
 *                              (16 x SHAKE256 32B->32B, i.e. 16 Keccak-f1600)
 *  'I'                         -> 'i' clk_hz[u32] pk_bytes[u32] sig_bytes[u32]
 *                                     max_msg[u32] entropy_events[u32]
 *
 * Errors: 'e' code[u8]  (1 = no key yet, 2 = message too long,
 *                        3 = clock check failed, 4 = unknown command)
 *
 * cycles = mcycle delta of the operation (raw core clocks, see csr.h);
 * always 0 in the host (PC) build.
 * Every received byte also feeds its arrival time (mcycle) into the RNG
 * entropy pool (rng/randombytes_hw.c, FPGA build), so a host that sends a
 * few bytes with irregular timing before 'K' improves the key's entropy.
 * Builds for both targets (sw/Makefile TARGET=wasp|host).
 */
#include <stdint.h>
#include <string.h>
#include "uart.h"
#include "csr.h"
#include "clint.h"
#include "api.h"
#include "randombytes_wasp.h"
#include "fips202.h"

#define MAX_MSG 2048u

static uint8_t  g_pk[CRYPTO_PUBLICKEYBYTES];
static uint8_t  g_sk[CRYPTO_SECRETKEYBYTES];
static int      g_have_key;
static uint8_t  g_msg[MAX_MSG];
static uint8_t  g_sig[CRYPTO_BYTES];
static uint8_t  g_inject[CRYPTO_SEEDBYTES];

/* ---- UART helpers that also feed the entropy pool ---------------------- */
static uint8_t rx8(void) {
    uint8_t b = (uint8_t)uart_receive_byte();
    rng_entropy_event();
    return b;
}
static void rx_buf(uint8_t *p, uint32_t n) { while (n--) *p++ = rx8(); }
static uint32_t rx32(void) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v |= (uint32_t)rx8() << (8 * i);
    return v;
}
static void tx8(uint8_t b) { uart_send_byte((char)b); }
static void tx32(uint32_t v) { for (int i = 0; i < 4; i++) tx8((uint8_t)(v >> (8 * i))); }
static void tx64(uint64_t v) { tx32((uint32_t)v); tx32((uint32_t)(v >> 32)); }
static void tx_err(uint8_t code) { tx8('e'); tx8(code); }

/* ---- operations --------------------------------------------------------- */
static void do_keygen(const uint8_t *seed) {
    uint64_t t0 = rdcycle64();
    if (seed) crypto_sign_seed_keypair(g_pk, g_sk, seed);
    else      crypto_sign_keypair(g_pk, g_sk);
    uint64_t t1 = rdcycle64();
    g_have_key = 1;
    tx8('k'); uart_send_buf(g_pk, sizeof g_pk); tx64(t1 - t0);
}

static void do_verify_and_report(const uint8_t *pk, uint32_t mlen) {
    uint64_t t0 = rdcycle64();
    int rc = crypto_sign_verify(g_sig, CRYPTO_BYTES, g_msg, mlen, pk);
    uint64_t t1 = rdcycle64();
    tx8('v'); tx8(rc == 0 ? 1 : 0); tx64(t1 - t0);
}

static void do_sign(int deterministic) {
    uint8_t optrand[SPX_N];
    if (deterministic) rx_buf(optrand, sizeof optrand);
    uint32_t mlen = rx32();
    if (mlen > MAX_MSG) {             /* drain so the host stays in sync */
        for (uint32_t i = 0; i < mlen; i++) (void)rx8();
        tx_err(2);
        return;
    }
    rx_buf(g_msg, mlen);
    if (!g_have_key) { tx_err(1); return; }

    if (deterministic) rng_inject(optrand, sizeof optrand);
    size_t siglen;
    uint64_t t0 = rdcycle64();
    crypto_sign_signature(g_sig, &siglen, g_msg, mlen, g_sk);
    uint64_t t1 = rdcycle64();
    tx8('s'); uart_send_buf(g_sig, CRYPTO_BYTES); tx64(t1 - t0);

    do_verify_and_report(g_pk, mlen);   /* on-chip self check */
}

static void do_verify(void) {
    uint8_t pk[CRYPTO_PUBLICKEYBYTES];
    rx_buf(pk, sizeof pk);
    uint32_t mlen = rx32();
    if (mlen > MAX_MSG) {
        for (uint32_t i = 0; i < mlen + CRYPTO_BYTES; i++) (void)rx8();
        tx_err(2);
        return;
    }
    rx_buf(g_msg, mlen);
    rx_buf(g_sig, CRYPTO_BYTES);
    do_verify_and_report(pk, mlen);
}

int main(void) {
    uart_init_local(CPU_CLK_HZ, 115200);

    /* mtime at 1 us; also proves the bitstream clock matches CPU_CLK_HZ */
    int clk_ok = clint_init(CPU_CLK_HZ, 1000000u) == CLINT_OK;

    uart_puts("SPX+wsp\n");
    if (!clk_ok) tx_err(3);

    for (;;) {
        uint8_t cmd = rx8();
        switch (cmd) {
        case 'K': do_keygen(0); break;
        case 'Q': rx_buf(g_inject, CRYPTO_SEEDBYTES); do_keygen(g_inject); break;
        case 'S': do_sign(0); break;
        case 'D': do_sign(1); break;
        case 'V': do_verify(); break;
        case 'P':
            if (!g_have_key) { tx_err(1); break; }
            tx8('p'); uart_send_buf(g_pk, sizeof g_pk);
            break;
        case 'I':
            tx8('i'); tx32(clint_clk_freq()); tx32(CRYPTO_PUBLICKEYBYTES);
            tx32(CRYPTO_BYTES); tx32(MAX_MSG); tx32(rng_event_count());
            break;
        case 'B': {             /* benchmark: 16 x SHAKE256(32B -> 32B) = 16 Keccak-f */
            uint8_t buf[32] = {0};
            uint64_t c0 = rdcycle64(), i0 = rdinstret64();
            for (int i = 0; i < 16; i++) shake256(buf, sizeof buf, buf, sizeof buf);
            uint64_t c1 = rdcycle64(), i1 = rdinstret64();
            tx8('b'); tx64(c1 - c0); tx64(i1 - i0); uart_send_buf(buf, sizeof buf);
            break;
        }
        default:
            tx_err(4);
            break;
        }
    }
    return 0;
}

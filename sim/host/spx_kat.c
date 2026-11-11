/* Host-side SPHINCS+ KAT check (gcc + OpenSSL, MSYS2/Linux).
 *
 * Builds the exact sources in sw/lib/sphincs/ together with NIST's rng.c
 * (AES-256 CTR DRBG) and, for each KAT entry asked for:
 *     randombytes_init(seed) -> crypto_sign_keypair -> crypto_sign
 * then compares pk / sk / sm with PQCsignKAT_64.rsp byte for byte.
 *
 * With -w <dir> it also writes the UART stimulus files the RTL simulation
 * uses for that entry (see sw/apps/sphincs/main.c for the protocol):
 *   <dir>/verify_rx.bin  'V' pk mlen msg sig         -> expect 'v' 1
 *   <dir>/badsig_rx.bin  same with one sig bit flipped -> expect 'v' 0
 *   <dir>/keygen_rx.bin  'Q' keypair-seed(48)         -> expect 'k' pk
 *   <dir>/sign_rx.bin    'Q' seed, 'D' optrand mlen msg -> expect KAT sig
 *   <dir>/expect_pk.bin, expect_sig.bin
 *
 * usage: spx_kat <PQCsignKAT_64.rsp> [count ...] [-w dir]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "api.h"
#include "rng.h"

#define MAXMSG 4096

typedef struct {
    int count;
    unsigned char seed[48];
    unsigned long long mlen;
    unsigned char msg[MAXMSG];
    unsigned char pk[CRYPTO_PUBLICKEYBYTES];
    unsigned char sk[CRYPTO_SECRETKEYBYTES];
    unsigned long long smlen;
    unsigned char *sm;
} kat_t;

static int hex2bin(const char *h, unsigned char *out, size_t max) {
    size_t n = 0;
    while (h[0] && h[1] && h[0] != '\n' && h[0] != '\r') {
        unsigned v;
        if (sscanf(h, "%2x", &v) != 1 || n >= max) return -1;
        out[n++] = (unsigned char)v;
        h += 2;
    }
    return (int)n;
}

/* read the entry with the given count */
static int read_kat(FILE *f, int want, kat_t *k) {
    static char line[1 << 16];
    int cur = -1;
    rewind(f);
    while (fgets(line, sizeof line, f)) {
        char *eq = strstr(line, " = ");
        if (!eq) continue;
        *eq = 0; char *v = eq + 3;
        if (!strcmp(line, "count")) { cur = atoi(v); if (cur > want) break; continue; }
        if (cur != want) continue;
        k->count = cur;
        if      (!strcmp(line, "seed"))  hex2bin(v, k->seed, sizeof k->seed);
        else if (!strcmp(line, "mlen"))  k->mlen = strtoull(v, 0, 10);
        else if (!strcmp(line, "msg"))   hex2bin(v, k->msg, MAXMSG);
        else if (!strcmp(line, "pk"))    hex2bin(v, k->pk, sizeof k->pk);
        else if (!strcmp(line, "sk"))    hex2bin(v, k->sk, sizeof k->sk);
        else if (!strcmp(line, "smlen")) { k->smlen = strtoull(v, 0, 10); k->sm = malloc(k->smlen); }
        else if (!strcmp(line, "sm"))    { hex2bin(v, k->sm, k->smlen); return 0; }
    }
    return -1;
}

static void wfile(const char *dir, const char *name, const void *parts[], const size_t lens[], int n) {
    char p[1024]; snprintf(p, sizeof p, "%s/%s", dir, name);
    FILE *f = fopen(p, "wb");
    if (!f) { perror(p); exit(2); }
    for (int i = 0; i < n; i++) fwrite(parts[i], 1, lens[i], f);
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s rsp [count...] [-w dir]\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 2; }
    const char *wdir = NULL;
    int counts[100], nc = 0, fails = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-w") && i + 1 < argc) wdir = argv[++i];
        else counts[nc++] = atoi(argv[i]);
    }
    if (!nc) counts[nc++] = 0;

    for (int c = 0; c < nc; c++) {
        kat_t k; memset(&k, 0, sizeof k);
        if (read_kat(f, counts[c], &k)) { printf("count %d: not found\n", counts[c]); return 2; }

        unsigned char pk[CRYPTO_PUBLICKEYBYTES], sk[CRYPTO_SECRETKEYBYTES];
        unsigned char *sm = malloc(k.mlen + CRYPTO_BYTES);
        unsigned long long smlen;

        randombytes_init(k.seed, NULL, 256);
        crypto_sign_keypair(pk, sk);
        unsigned char optrand[SPX_N];
        /* crypto_sign() will pull the next SPX_N bytes as optrand; peek
           them with a copy of the DRBG state is not possible through the
           NIST API, so re-run the DRBG: seed48, then optrand. */
        crypto_sign(sm, &smlen, k.msg, k.mlen, sk);
        {
            unsigned char tmp[CRYPTO_SEEDBYTES];
            randombytes_init(k.seed, NULL, 256);
            randombytes(tmp, CRYPTO_SEEDBYTES);
            randombytes(optrand, SPX_N);
        }

        int ok_pk = !memcmp(pk, k.pk, sizeof pk);
        int ok_sk = !memcmp(sk, k.sk, sizeof sk);
        int ok_sm = smlen == k.smlen && !memcmp(sm, k.sm, smlen);
        unsigned long long ml; unsigned char *m1 = malloc(smlen);
        int ok_open = crypto_sign_open(m1, &ml, sm, smlen, pk) == 0 && ml == k.mlen;
        printf("count %d: mlen=%llu pk %s, sk %s, sm %s, open %s\n", k.count, k.mlen,
               ok_pk ? "OK" : "MISMATCH", ok_sk ? "OK" : "MISMATCH",
               ok_sm ? "OK" : "MISMATCH", ok_open ? "OK" : "FAIL");
        fails += !(ok_pk && ok_sk && ok_sm && ok_open);

        if (wdir && c == 0) {
            uint32_t ml32 = (uint32_t)k.mlen;
            const unsigned char *sig = k.sm;               /* sm = sig || m */
            unsigned char V = 'V', Q = 'Q', D = 'D';
            const void *pv[] = { &V, k.pk, &ml32, k.msg, sig };
            size_t      lv[] = { 1, CRYPTO_PUBLICKEYBYTES, 4, k.mlen, CRYPTO_BYTES };
            wfile(wdir, "verify_rx.bin", pv, lv, 5);

            unsigned char *bad = malloc(CRYPTO_BYTES);
            memcpy(bad, sig, CRYPTO_BYTES); bad[CRYPTO_BYTES / 2] ^= 0x01;
            const void *pb[] = { &V, k.pk, &ml32, k.msg, bad };
            wfile(wdir, "badsig_rx.bin", pb, lv, 5);

            const void *pq[] = { &Q, k.sk };               /* sk[0:48] = keypair seed */
            size_t      lq[] = { 1, CRYPTO_SEEDBYTES };
            wfile(wdir, "keygen_rx.bin", pq, lq, 2);

            const void *ps[] = { &Q, k.sk, &D, optrand, &ml32, k.msg };
            size_t      ls[] = { 1, CRYPTO_SEEDBYTES, 1, SPX_N, 4, k.mlen };
            wfile(wdir, "sign_rx.bin", ps, ls, 6);

            const void *pe[] = { k.pk };  size_t le[] = { CRYPTO_PUBLICKEYBYTES };
            wfile(wdir, "expect_pk.bin", pe, le, 1);
            const void *pg[] = { sig };   size_t lg[] = { CRYPTO_BYTES };
            wfile(wdir, "expect_sig.bin", pg, lg, 1);
            printf("wrote RTL stimulus for count %d to %s\n", k.count, wdir);
        }
    }
    fclose(f);
    return fails ? 1 : 0;
}

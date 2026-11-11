/* Minimal freestanding libc pieces. GCC may emit calls to these even with
 * -fno-builtin (struct copies, array init), and the SPHINCS+ reference code
 * uses them directly. Word-at-a-time when both pointers are aligned. */
#include <stddef.h>
#include <stdint.h>

void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = dst;
    const uint8_t *s = src;
    if ((((uintptr_t)d | (uintptr_t)s) & 3u) == 0) {
        for (; n >= 4; n -= 4, d += 4, s += 4)
            *(uint32_t *)d = *(const uint32_t *)s;
    }
    while (n--) *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    uint8_t *d = dst;
    const uint8_t *s = src;
    if (d == s || n == 0) return dst;
    if (d < s || d >= s + n) return memcpy(dst, src, n);
    while (n--) d[n] = s[n];
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    uint8_t *d = dst;
    uint32_t w = (uint8_t)c;
    w |= w << 8; w |= w << 16;
    while (n && ((uintptr_t)d & 3u)) { *d++ = (uint8_t)c; n--; }
    for (; n >= 4; n -= 4, d += 4) *(uint32_t *)d = w;
    while (n--) *d++ = (uint8_t)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y) return (int)*x - (int)*y;
    return 0;
}

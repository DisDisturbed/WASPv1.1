#ifndef CSR_H
#define CSR_H
/* CSR access + Zicntr counter helpers for wasp (RV32IM, M-mode only).
 *
 * Counters (see RTL/CSR.sv):
 *   mcycle   0xB00 / mcycleh   0xB80   +1 every core clock
 *   minstret 0xB02 / minstreth 0xB82   +1 per retired instruction
 *   time     0xC01 / timeh     0xC81   = CLINT mtime (prescaled, see clint.h)
 *   mcountinhibit 0x320                bit0 stops mcycle, bit2 stops minstret
 *
 * Numeric CSR addresses are used so this also builds with older
 * assemblers (e.g. SiFive GCC 8.3) that don't know every CSR name.
 */
#include <stdint.h>

#define CSR_STR_(x) #x
#define CSR_STR(x)  CSR_STR_(x)

#define read_csr(reg) ({ \
    uint32_t __tmp; \
    __asm__ volatile ("csrr %0, " CSR_STR(reg) : "=r"(__tmp)); \
    __tmp; \
})

#define write_csr(reg, val) ({ \
    uint32_t __tmp = (val); \
    __asm__ volatile ("csrw " CSR_STR(reg) ", %0" :: "r"(__tmp)); \
})

#define set_csr(reg, bit) ({ \
    uint32_t __tmp = (bit); \
    __asm__ volatile ("csrs " CSR_STR(reg) ", %0" :: "r"(__tmp)); \
})

#define clear_csr(reg, bit) ({ \
    uint32_t __tmp = (bit); \
    __asm__ volatile ("csrc " CSR_STR(reg) ", %0" :: "r"(__tmp)); \
})

/* CSR numbers */
#define CSR_MCOUNTINHIBIT 0x320
#define CSR_MCOUNTEREN    0x306
#define CSR_SCOUNTEREN    0x106
#define CSR_MCYCLE        0xB00
#define CSR_MINSTRET      0xB02
#define CSR_MCYCLEH       0xB80
#define CSR_MINSTRETH     0xB82
#define CSR_CYCLE         0xC00
#define CSR_TIME          0xC01
#define CSR_INSTRET       0xC02
#define CSR_CYCLEH        0xC80
#define CSR_TIMEH         0xC81
#define CSR_INSTRETH      0xC82

/* mstatus / mie / mip bits */
#define MSTATUS_MIE  (1u << 3)
#define MIE_MSIE     (1u << 3)
#define MIE_MTIE     (1u << 7)
#define MIE_MEIE     (1u << 11)
#define MIP_MSIP     (1u << 3)
#define MIP_MTIP     (1u << 7)
#define MIP_MEIP     (1u << 11)

#define MCOUNTINHIBIT_CY (1u << 0)
#define MCOUNTINHIBIT_IR (1u << 2)

/* mcause values */
#define MCAUSE_IRQ_MSI   0x80000003u
#define MCAUSE_IRQ_MTI   0x80000007u
#define MCAUSE_IRQ_MEI   0x8000000Bu

/* 64-bit reads on RV32: hi / lo / hi again, retry if the low half wrapped. */
#define CSR_READ64(lo, hi) ({ \
    uint32_t __h, __l, __h2; \
    do { __h = read_csr(hi); __l = read_csr(lo); __h2 = read_csr(hi); } \
    while (__h != __h2); \
    ((uint64_t)__h << 32) | __l; \
})

static inline uint64_t rdcycle64(void)   { return CSR_READ64(CSR_MCYCLE,   CSR_MCYCLEH);   }
static inline uint64_t rdinstret64(void) { return CSR_READ64(CSR_MINSTRET, CSR_MINSTRETH); }
static inline uint64_t rdtime64(void)    { return CSR_READ64(CSR_TIME,     CSR_TIMEH);     }
static inline uint32_t rdcycle(void)     { return read_csr(CSR_MCYCLE); }
static inline uint32_t rdinstret(void)   { return read_csr(CSR_MINSTRET); }

static inline void counters_reset(void) {
    write_csr(CSR_MCYCLE, 0);   write_csr(CSR_MCYCLEH, 0);
    write_csr(CSR_MINSTRET, 0); write_csr(CSR_MINSTRETH, 0);
}

#endif /* CSR_H */

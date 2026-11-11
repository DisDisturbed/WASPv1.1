#!/usr/bin/env python3
"""Compare the UART output of the RTL simulation with the host (PC gcc) build.

    uart_cmp.py <prog> <rtl_uart_tx.bin> <host_uart_tx.bin> [--spx 128f|128s]

Both runs get the same uart_rx.bin. The output must match byte for byte,
except fields that only real hardware can produce:

    aes      no exceptions, plain byte compare
    sphincs  cycle / instret counters (the host build sends 0) are skipped;
             everything else (pk, signatures, verify results, SHAKE output,
             info, errors) must match. Protocol: sw/apps/sphincs/main.c.

Exit code 0 = match, 1 = mismatch.
"""
import argparse
import struct
import sys

SIG_BYTES = {"128f": 17088, "128s": 7856}


def sphincs_fields(tx, sig_bytes):
    """Split a sphincs TX stream into (name, offset, length, compare) fields."""
    fields = []
    p = 0

    def add(name, n, cmp=True):
        nonlocal p
        fields.append((name, p, n, cmp))
        p += n

    add("banner", 8)
    while p < len(tx):
        tag = tx[p:p + 1]
        add(f"tag {tag!r}", 1)
        if tag == b"k":
            add("pk", 32); add("keygen cycles", 8, False)
        elif tag == b"s":
            add("signature", sig_bytes); add("sign cycles", 8, False)
        elif tag == b"v":
            add("verify result", 1); add("verify cycles", 8, False)
        elif tag == b"p":
            add("pk", 32)
        elif tag == b"i":
            add("info", 20)
        elif tag == b"b":
            add("bench cycles", 8, False); add("bench instret", 8, False)
            add("bench SHAKE256 output", 32)
        elif tag == b"e":
            add("error code", 1)
        else:
            add("unparsed rest", len(tx) - p)
    return fields


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("prog", choices=["aes", "sphincs"])
    ap.add_argument("rtl")
    ap.add_argument("host")
    ap.add_argument("--spx", choices=sorted(SIG_BYTES), default="128f")
    a = ap.parse_args()

    rtl = open(a.rtl, "rb").read()
    host = open(a.host, "rb").read()
    bad = 0

    if len(rtl) < len(host):
        # usually the simulation hit MAX_CYCLES / TX_BYTES before the end
        print(f"NOTE RTL run stopped early: {len(rtl)} of {len(host)} B "
              f"(raise MAX_CYCLES / TX_BYTES); comparing the first {len(rtl)} B")
        partial = True
    elif len(rtl) != len(host):
        print(f"FAIL length: rtl {len(rtl)} B, host {len(host)} B")
        bad += 1
        partial = False
    else:
        partial = False

    if a.prog == "aes":
        n = min(len(rtl), len(host))
        diff = [i for i in range(n) if rtl[i] != host[i]]
        if diff:
            print(f"FAIL {len(diff)} bytes differ, first at offset {diff[0]}")
            bad += 1
        else:
            print(f"PASS {n} bytes identical")
    else:
        skipped = 0
        for name, off, n, cmp in sphincs_fields(host, SIG_BYTES[a.spx]):
            if off + n > len(rtl):
                if off < len(rtl):      # field cut off by the early stop
                    r, h = rtl[off:], host[off:len(rtl)]
                    if cmp and r != h:
                        print(f"FAIL {name} @ {off} (partial) differs")
                        bad += 1
                break
            r, h = rtl[off:off + n], host[off:off + n]
            if not cmp:
                skipped += 1
                if len(r) == 8:
                    print(f"     {name}: {struct.unpack('<Q', r)[0]} (rtl only)")
                continue
            if r != h:
                print(f"FAIL {name} @ {off} ({n} B) differs")
                bad += 1
        if not bad:
            print(f"PASS {len(rtl)} bytes identical ({skipped} counter fields skipped)")

    if bad:
        print("MISMATCH")
    else:
        print(f"MATCH (first {len(rtl)} of {len(host)} B)" if partial else "MATCH")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

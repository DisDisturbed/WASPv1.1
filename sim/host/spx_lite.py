#!/usr/bin/env python3
"""Lightweight SPHINCS+ (128f) regression for the RTL model.

    spx_lite.py gen   <uart_rx.bin>     write the command stream
    spx_lite.py check <uart_tx.bin>     check what the device sent back

Commands sent to sw/apps/sphincs/main.c (make -C sw PROG=sphincs SPX=128f):
    I                        info: CLINT clk_freq read back, sizes
    B                        16 x SHAKE256 (Keccak bench), output checked
    P                        no key yet -> must answer error 1
    V pk msg sig             NIST KAT #0 signature  -> must verify  (v 01)
    V pk msg sig^1           same, one bit flipped  -> must reject (v 00)

No keygen/sign, so it finishes in ~1.2 G cycles instead of ~12 G.
Expected TX length: TX_BYTES (pass as +tx_bytes=... to the testbench).
"""
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KAT = os.path.join(HERE, "nist", "128f", "PQCsignKAT_64.rsp")
SIG_BYTES = 17088
CLK_HZ = 50_000_000
TX_BYTES = 8 + 21 + 49 + 2 + 10 + 10


def kat0():
    kv = {}
    with open(KAT) as f:
        for line in f:
            if " = " in line:
                k, v = line.strip().split(" = ", 1)
                if k == "count" and v != "0":
                    break
                kv[k] = v
    msg = bytes.fromhex(kv["msg"])
    sm = bytes.fromhex(kv["sm"])
    assert len(msg) == int(kv["mlen"]) and len(sm) == SIG_BYTES + len(msg)
    return bytes.fromhex(kv["pk"]), msg, sm[:SIG_BYTES]


def gen(path):
    pk, msg, sig = kat0()
    bad = bytearray(sig)
    bad[100] ^= 1
    out = b"I" + b"B" + b"P"
    for s in (sig, bytes(bad)):
        out += b"V" + pk + struct.pack("<I", len(msg)) + msg + s
    with open(path, "wb") as f:
        f.write(out)


def check(path):
    rx = open(path, "rb").read()
    fails = []

    def expect(name, cond):
        print(("PASS " if cond else "FAIL ") + name)
        if not cond:
            fails.append(name)

    expect(f"length {len(rx)} == {TX_BYTES}", len(rx) == TX_BYTES)
    rx = rx.ljust(TX_BYTES, b"\0")
    p = 0

    def take(n):
        nonlocal p
        p += n
        return rx[p - n:p]

    expect("banner", take(8) == b"SPX+wsp\n")
    expect("info tag", take(1) == b"i")
    clk, pkb, sigb, maxmsg, _ev = struct.unpack("<5I", take(20))
    expect(f"clk_freq {clk}", clk == CLK_HZ)
    expect("pk/sig sizes", (pkb, sigb, maxmsg) == (32, SIG_BYTES, 2048))

    expect("bench tag", take(1) == b"b")
    cyc, ins = struct.unpack("<QQ", take(16))
    ref = bytes(32)
    for _ in range(16):
        ref = hashlib.shake_256(ref).digest(32)
    expect("bench SHAKE256 output", take(32) == ref)
    print(f"     16 Keccak-f: {cyc} cycles, {ins} instr, CPI {cyc / max(ins, 1):.2f}")

    expect("no-key error", take(2) == b"e\x01")

    for name, want in (("KAT signature verifies", 1), ("flipped signature rejected", 0)):
        tag, ok = take(1), take(1)
        (cyc,) = struct.unpack("<Q", take(8))
        expect(name, tag == b"v" and ok[0] == want)
        print(f"     verify: {cyc} cycles ({cyc / CLK_HZ:.2f} s at 50 MHz)")

    print("ALL PASS" if not fails else f"FAILED {len(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("gen", "check"):
        sys.exit(__doc__)
    if sys.argv[1] == "gen":
        gen(sys.argv[2])
    else:
        sys.exit(check(sys.argv[2]))

#!/usr/bin/env python3
"""Host side of sw/apps/sphincs/main.c (SPHINCS+ on wasp over UART).

    pip install pyserial
    python sphincs_host.py -p COM5 info
    python sphincs_host.py -p COM5 keygen                 # on-chip entropy
    python sphincs_host.py -p COM5 keygen --seed <96 hex> # deterministic
    python sphincs_host.py -p COM5 pubkey -o pk.bin
    python sphincs_host.py -p COM5 sign msg.txt -o msg.sig
    python sphincs_host.py -p COM5 verify msg.txt msg.sig --pk pk.bin

Simulation: add --emit uart_rx.bin to write the bytes that would be sent
instead of opening a port (no reply is read). Feed that file to
sim/run.sh with RX=uart_rx.bin.

Protocol details are in the header of sw/apps/sphincs/main.c.
"""
import argparse
import os
import random
import struct
import sys
import time

PK_BYTES = 32
SIG_BYTES = {"128s": 7856, "128f": 17088}
ERRORS = {1: "no key yet (run keygen)", 2: "message too long",
          3: "clock check failed (CLINT clk_freq != CPU_CLK_HZ)",
          4: "unknown command"}


class Link:
    def __init__(self, port, baud, timeout, emit):
        self.emit = open(emit, "wb") if emit else None
        if not self.emit:
            import serial  # pyserial
            self.ser = serial.Serial(port, baud, timeout=timeout)

    def send(self, data):
        if self.emit:
            self.emit.write(data)
        else:
            self.ser.write(data)
            self.ser.flush()

    def recv(self, n):
        if self.emit:
            return None
        buf = b""
        while len(buf) < n:
            chunk = self.ser.read(n - len(buf))
            if not chunk:
                raise TimeoutError(f"timeout: got {len(buf)} of {n} bytes")
            buf += chunk
        return buf

    def reply(self, expect):
        """Read one reply tag; raise on 'e'. Skips a banner if present."""
        if self.emit:
            return None
        while True:
            t = self.recv(1)
            if t == b"S":                         # "SPX+wsp\n" banner after reset
                self.recv(7)
                continue
            if t == b"e":
                code = self.recv(1)[0]
                raise RuntimeError(f"board error {code}: {ERRORS.get(code, '?')}")
            if t != expect:
                raise RuntimeError(f"unexpected reply {t!r}, wanted {expect!r}")
            return t


def u64(b):
    return struct.unpack("<Q", b)[0]


def fmt_cycles(c, hz):
    return f"{c} cycles ({c / hz:.3f} s at {hz / 1e6:.0f} MHz)"


def info(link):
    link.send(b"I")
    if not link.reply(b"i"):
        return None
    clk, pkb, sigb, maxmsg, ev = struct.unpack("<5I", link.recv(20))
    return {"clk": clk, "pk": pkb, "sig": sigb, "max_msg": maxmsg, "events": ev}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--port", default="COM5")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-t", "--timeout", type=float, default=6000.0,
                    help="seconds; 128s signing takes over an hour at 50 MHz")
    ap.add_argument("--emit", help="write the TX bytes to this file instead of a port")
    ap.add_argument("--spx", choices=SIG_BYTES, default="128s",
                    help="only used with --emit (no board to ask)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info")
    k = sub.add_parser("keygen")
    k.add_argument("--seed", help="48-byte seed as hex (SK.seed||SK.prf||PK.seed)")
    k.add_argument("--events", type=int, default=64,
                   help="entropy events to send first (random host timing)")
    pk = sub.add_parser("pubkey")
    pk.add_argument("-o", "--out")
    s = sub.add_parser("sign")
    s.add_argument("msg")
    s.add_argument("-o", "--out")
    s.add_argument("--optrand", help="16-byte hex: deterministic signing (KAT)")
    v = sub.add_parser("verify")
    v.add_argument("msg")
    v.add_argument("sig")
    v.add_argument("--pk", required=True, help="pk file (32 bytes) or 64 hex chars")
    a = ap.parse_args()

    link = Link(a.port, a.baud, a.timeout, a.emit)
    if a.emit:
        meta = {"clk": 50_000_000, "pk": PK_BYTES, "sig": SIG_BYTES[a.spx], "max_msg": 2048}
    else:
        meta = info(link)
        print(f"board: clk {meta['clk']} Hz, pk {meta['pk']} B, sig {meta['sig']} B, "
              f"max msg {meta['max_msg']} B, entropy events {meta['events']}")
    hz = meta["clk"]

    if a.cmd == "info":
        return

    if a.cmd == "keygen":
        if a.seed:
            seed = bytes.fromhex(a.seed)
            assert len(seed) == 48, "seed must be 48 bytes"
            link.send(b"Q" + seed)
        else:
            # every byte the board receives folds its arrival time (mcycle)
            # into the RNG pool; irregular host timing = more jitter
            for _ in range(a.events):
                link.send(b"I")
                link.reply(b"i") and link.recv(20)
                time.sleep(random.uniform(0.001, 0.02))
            link.send(b"K")
        if link.reply(b"k"):
            key = link.recv(PK_BYTES)
            print("pk:", key.hex())
            print("keygen:", fmt_cycles(u64(link.recv(8)), hz))
        return

    if a.cmd == "pubkey":
        link.send(b"P")
        if link.reply(b"p"):
            key = link.recv(PK_BYTES)
            print("pk:", key.hex())
            if a.out:
                open(a.out, "wb").write(key)
        return

    if a.cmd == "sign":
        msg = open(a.msg, "rb").read()
        assert len(msg) <= meta["max_msg"], "message too long for the board buffer"
        if a.optrand:
            opt = bytes.fromhex(a.optrand)
            assert len(opt) == 16
            link.send(b"D" + opt + struct.pack("<I", len(msg)) + msg)
        else:
            link.send(b"S" + struct.pack("<I", len(msg)) + msg)
        if link.reply(b"s"):
            sig = link.recv(meta["sig"])
            print("sign:", fmt_cycles(u64(link.recv(8)), hz))
            link.reply(b"v")
            ok = link.recv(1)[0]
            print("on-chip self-verify:", "OK" if ok else "FAILED",
                  "-", fmt_cycles(u64(link.recv(8)), hz))
            out = a.out or a.msg + ".sig"
            open(out, "wb").write(sig)
            print("signature ->", out)
        return

    if a.cmd == "verify":
        msg = open(a.msg, "rb").read()
        sig = open(a.sig, "rb").read()
        key = (open(a.pk, "rb").read() if os.path.exists(a.pk) else bytes.fromhex(a.pk))
        assert len(key) == PK_BYTES and len(sig) == meta["sig"]
        link.send(b"V" + key + struct.pack("<I", len(msg)) + msg + sig)
        if link.reply(b"v"):
            ok = link.recv(1)[0]
            print("verify:", "VALID" if ok else "INVALID", "-", fmt_cycles(u64(link.recv(8)), hz))
            sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

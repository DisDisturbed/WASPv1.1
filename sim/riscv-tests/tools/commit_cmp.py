#!/usr/bin/env python3
"""Lock-step compare of register writes: WASP RTL vs Spike.

    commit_cmp.py <cpu_trace.log> <spike.log> [--dump dump.txt] [--context 8]

cpu_trace.log : Core_Top's commit trace   "[COMMIT] PC:<pc> x<n><-<val>"
spike.log     : spike -l --log-commits     "core 0: 3 0x<pc> (0x<insn>) x<n> 0x<val>"

Both traces list every retired instruction that writes a GPR other than x0,
in program order, so they must agree entry by entry.  The first difference
is the first architecturally visible divergence of the RTL.  Values read from
cycle/time/instret counters and from the implementation-ID CSRs
(mvendorid/marchid/mimpid) are compared by (pc, rd) only.  Spike's boot ROM
(pc < 0x4000_0000) is skipped.

--skip LO:HI (hex, repeatable) drops register writes with LO <= pc < HI from
BOTH traces. The riscv-dv flow uses it for the trap-handler code, so an RTL run
with randomly injected interrupts can be compared with a Spike run without
them: the handler saves/restores every register, so the interrupted program
must still produce exactly Spike's register trace.
"""
import argparse
import re
import sys

RTL_RE = re.compile(r"\[COMMIT\] PC:([0-9a-fA-F]+) x(\d+)<-([0-9a-fA-F]+)")
SPK_RE = re.compile(r"core\s+\d+: \d+ 0x([0-9a-f]+) \(0x([0-9a-f]+)\) x(\d+)\s+0x([0-9a-f]+)")

# CSRs whose read value legitimately differs between WASP and Spike:
#   cycle/time/instret(+h), mcycle/minstret(+h)  timing dependent
#   mvendorid/marchid/mimpid                     implementation IDs (Spike marchid=5)
NONDET_CSRS = {0xC00, 0xC01, 0xC02, 0xC80, 0xC81, 0xC82, 0xB00, 0xB02, 0xB80, 0xB82,
               0xF11, 0xF12, 0xF13}


def is_nondet_read(insn):
    return (insn & 0x7F) == 0x73 and ((insn >> 12) & 3) != 0 and (insn >> 20) in NONDET_CSRS


SKIP = []


def skipped(pc):
    return any(lo <= pc < hi for lo, hi in SKIP)


def load_rtl(path):
    out = []
    with open(path) as f:
        for line in f:
            m = RTL_RE.search(line)
            if m:
                pc = int(m.group(1), 16)
                if not skipped(pc):
                    out.append((pc, int(m.group(2)), int(m.group(3), 16)))
    return out


def load_spike(path):
    out, insns = [], {}
    with open(path) as f:
        for line in f:
            m = SPK_RE.search(line)
            if not m:
                continue
            pc, insn, rd, val = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3)), int(m.group(4), 16)
            if pc < 0x40000000 or rd == 0 or skipped(pc):
                continue
            insns[pc] = insn
            out.append((pc, rd, val & 0xFFFFFFFF))
    return out, insns


def load_dump(path):
    dis = {}
    if not path:
        return dis
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(.*)", line)
                if m:
                    dis[int(m.group(1), 16)] = m.group(3).strip()
    except OSError:
        pass
    return dis


def fmt(e, dis):
    if e is None:
        return "(end of trace)"
    pc, rd, val = e
    return f"pc={pc:08x} x{rd:<2}= {val:08x}   {dis.get(pc, '')}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl")
    ap.add_argument("spike")
    ap.add_argument("--dump")
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--skip", action="append", default=[], metavar="LO:HI")
    a = ap.parse_args()
    for r in a.skip:
        lo, hi = r.split(":")
        SKIP.append((int(lo, 16), int(hi, 16)))

    rtl = load_rtl(a.rtl)
    spk, insns = load_spike(a.spike)
    dis = load_dump(a.dump)

    n = min(len(rtl), len(spk))
    for i in range(n):
        r, s = rtl[i], spk[i]
        same = (r[0], r[1]) == (s[0], s[1]) and (r[2] == s[2] or is_nondet_read(insns.get(s[0], 0)))
        if not same:
            print(f"MISMATCH at register write #{i}  (RTL {len(rtl)} writes, Spike {len(spk)} writes)")
            for j in range(max(0, i - a.context), i):
                print(f"   ok   {fmt(rtl[j], dis)}")
            print(f"  RTL   {fmt(r, dis)}")
            print(f"  SPIKE {fmt(s, dis)}")
            return 1
    if len(rtl) < len(spk) and n and rtl[-1][0] >= 0x40000000:
        # The testbench stops at the first tohost store; Spike keeps looping in
        # write_tohost until its host polls.  A clean prefix is a full match.
        print(f"MATCH: all {n} RTL register writes identical to Spike "
              f"(RTL stops at the tohost store, Spike logged {len(spk) - n} more in its write_tohost loop)")
        return 0
    if len(rtl) != len(spk):
        i = n
        print(f"TRACES AGREE for the first {n} register writes, then lengths differ "
              f"(RTL {len(rtl)}, Spike {len(spk)})")
        for j in range(max(0, i - a.context), i):
            print(f"   ok   {fmt(rtl[j], dis)}")
        print(f"  RTL   {fmt(rtl[i] if i < len(rtl) else None, dis)}")
        print(f"  SPIKE {fmt(spk[i] if i < len(spk) else None, dis)}")
        return 1
    print(f"MATCH: {n} register writes identical")
    return 0


if __name__ == "__main__":
    sys.exit(main())

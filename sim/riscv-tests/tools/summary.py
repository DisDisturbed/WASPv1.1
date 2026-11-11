#!/usr/bin/env python3
"""Summarise a riscv-tests run: build/<test>/result.txt (RTL tohost verdict),
build/<test>/spike_result.txt (Spike reference) and build/<test>/cmp.txt
(lock-step register-write compare RTL vs Spike), with waivers.

A test PASSes only if the RTL wrote tohost=1 AND its register writes match
Spike (or Spike is unavailable).  tohost=1 with a trace mismatch is reported
as FALSE-PASS: the test's own checks were fooled.

Exit status 0 when every non-waived test passes on the RTL.
Also writes build/summary.md (markdown table) for docs/riscv_tests.md.
"""
import argparse
import os
import sys


def read_first_line(path):
    try:
        with open(path) as f:
            return f.readline().strip()
    except OSError:
        return ""


def load_waivers(path):
    waivers = {}
    if not path or not os.path.exists(path):
        return waivers
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            name, _, reason = line.partition(" ")
            waivers[name] = reason.strip()
    return waivers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build")
    ap.add_argument("--waivers", default="waivers.txt")
    ap.add_argument("tests", nargs="+")
    a = ap.parse_args()

    waivers = load_waivers(a.waivers)
    rows, counts = [], {}
    bad = []
    for t in a.tests:
        rtl = read_first_line(os.path.join(a.build, t, "result.txt")) or "ERROR no result"
        spk = read_first_line(os.path.join(a.build, t, "spike_result.txt")) or "-"
        cmp_ = read_first_line(os.path.join(a.build, t, "cmp.txt")) or "-"
        trace = cmp_.split()[0].rstrip(":") if cmp_ != "-" else "-"
        trace = {"MATCH": "match", "MISMATCH": "DIFF", "TRACES": "DIFF", "SKIP": "-"}.get(trace, trace)
        verdict = rtl.split()[0]
        if verdict == "PASS" and trace == "DIFF":
            verdict = "FALSE-PASS"
        detail = rtl.split(" ", 2)[2] if len(rtl.split(" ", 2)) > 2 else ""
        detail = detail.split(" | ")[0].strip()
        waived = t in waivers
        if waived:
            status = "WAIVED" if verdict != "PASS" else "PASS (waived)"
        else:
            status = verdict
            if verdict != "PASS":
                bad.append(t)
        counts[status] = counts.get(status, 0) + 1
        rows.append((t, status, spk.split()[0], trace, detail, waivers.get(t, "")))

    w = max(len(r[0]) for r in rows)
    print()
    print(f"{'test':<{w}}  {'RTL':<13} {'trace':<6} {'spike':<6} detail")
    print("-" * (w + 70))
    for t, st, spk, tr, det, why in rows:
        note = det if det else ""
        if why:
            note = (note + "  " if note else "") + f"[waived: {why}]"
        print(f"{t:<{w}}  {st:<13} {tr:<6} {spk:<6} {note}")
    print("-" * (w + 70))
    total = len(rows)
    summary = ", ".join(f"{v} {k}" for k, v in sorted(counts.items()))
    print(f"{total} tests: {summary}")
    spike_bad = [r[0] for r in rows if r[2] not in ("PASS", "SKIP", "-")]
    if spike_bad:
        print("Spike reference did NOT pass (test/env problem, not RTL): " + " ".join(spike_bad))

    with open(os.path.join(a.build, "summary.md"), "w") as f:
        f.write("| test | RTL | trace vs Spike | Spike | detail |\n|---|---|---|---|---|\n")
        for t, st, spk, tr, det, why in rows:
            note = det.replace("|", "/")
            if why:
                note = (note + " " if note else "") + f"*waived: {why}*"
            f.write(f"| {t} | {st} | {tr} | {spk} | {note} |\n")
        f.write(f"\n{total} tests: {summary}\n")

    if bad:
        print("RISCV-TESTS FAIL: " + " ".join(bad))
        return 1
    print("RISCV-TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

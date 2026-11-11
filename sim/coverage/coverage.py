#!/usr/bin/env python3
"""Functional coverage matrix of the WASP verification suites.

    coverage.py [--out docs/coverage_matrix.md]

Rows: what is exercised (instructions, branch outcomes, memory access size x
alignment, pipeline hazards, CSRs, traps, interrupts). Columns: the
riscv-tests suites (sim/riscv-tests) and the riscv-dv configs (sim/riscv-dv).
Cells: dynamic counts summed over the tests of that column.

Only tests whose verdict is PASS (tohost reached AND RTL register trace ==
Spike) are counted. For those the RTL executed the same instruction stream as
Spike, so Spike's full execution log (-l --log-commits, which also contains
instructions that write no register) is used as the source, from the first
instruction in IMEM up to write_tohost. Instruction words are decoded here
(RV32IM + Zicsr + Zifencei + privileged), not taken from Spike's
pseudo-instruction disassembly. Interrupts are taken from the RTL (result.txt
irqs=), since Spike runs without them.
"""
import argparse
import collections
import glob
import os
import re
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RVT = os.path.join(ROOT, "sim", "riscv-tests", "build", "tests")
RDV = os.path.join(ROOT, "sim", "riscv-dv", "build", "t")
RVT_SUITES = ["rv32ui", "rv32um", "rv32mi", "wasp"]
RDV_CONFIGS = ["arith", "rand", "jump", "loop", "rjump", "mem", "illegal", "ebreak", "irq"]
IMEM_BASE = 0x40000000

# ---------------------------------------------------------------- decoder --
BR = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}
LD = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}
ST = {0: "sb", 1: "sh", 2: "sw"}
OPI = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
OP = {(0, 0): "add", (0, 0x20): "sub", (1, 0): "sll", (2, 0): "slt", (3, 0): "sltu",
      (4, 0): "xor", (5, 0): "srl", (5, 0x20): "sra", (6, 0): "or", (7, 0): "and"}
MD = {0: "mul", 1: "mulh", 2: "mulhsu", 3: "mulhu", 4: "div", 5: "divu", 6: "rem", 7: "remu"}
CSR = {1: "csrrw", 2: "csrrs", 3: "csrrc", 5: "csrrwi", 6: "csrrsi", 7: "csrrci"}

INSTR_ROWS = [
    ("RV32I", ["lui", "auipc", "jal", "jalr", *BR.values(), *LD.values(), *ST.values(),
               *OPI.values(), "slli", "srli", "srai", *OP.values(),
               "fence", "ecall", "ebreak"]),
    ("RV32M", list(MD.values())),
    ("Zicsr / Zifencei", [*CSR.values(), "fence.i"]),
    ("Privileged", ["mret", "wfi"]),
    ("Illegal encodings", ["illegal"]),
]


def decode(w):
    """-> (mnemonic, rd, rs1, rs2); rd/rs = None when the format has none."""
    op, rd, f3, rs1, rs2, f7 = w & 0x7F, (w >> 7) & 31, (w >> 12) & 7, (w >> 15) & 31, (w >> 20) & 31, w >> 25
    if op == 0x37: return "lui", rd, None, None
    if op == 0x17: return "auipc", rd, None, None
    if op == 0x6F: return "jal", rd, None, None
    if op == 0x67 and f3 == 0: return "jalr", rd, rs1, None
    if op == 0x63 and f3 in BR: return BR[f3], None, rs1, rs2
    if op == 0x03 and f3 in LD: return LD[f3], rd, rs1, None
    if op == 0x23 and f3 in ST: return ST[f3], None, rs1, rs2
    if op == 0x13:
        if f3 in OPI: return OPI[f3], rd, rs1, None
        if f3 == 1 and f7 == 0: return "slli", rd, rs1, None
        if f3 == 5 and f7 == 0: return "srli", rd, rs1, None
        if f3 == 5 and f7 == 0x20: return "srai", rd, rs1, None
    if op == 0x33:
        if f7 == 1: return MD[f3], rd, rs1, rs2
        if (f3, f7) in OP: return OP[(f3, f7)], rd, rs1, rs2
    if op == 0x0F:
        if f3 == 0: return "fence", None, None, None
        if f3 == 1: return "fence.i", None, None, None
    if op == 0x73:
        if f3 in CSR: return CSR[f3], rd, (rs1 if f3 < 4 else None), None
        if f3 == 0:
            if w == 0x00000073: return "ecall", None, None, None
            if w == 0x00100073: return "ebreak", None, None, None
            if w == 0x30200073: return "mret", None, None, None
            if w == 0x10500073: return "wfi", None, None, None
    return "illegal", None, None, None


CSR_NAMES = {0x300: "mstatus", 0x301: "misa", 0x304: "mie", 0x305: "mtvec", 0x306: "mcounteren",
             0x310: "mstatush", 0x320: "mcountinhibit", 0x340: "mscratch", 0x341: "mepc",
             0x342: "mcause", 0x343: "mtval", 0x344: "mip", 0xB00: "mcycle", 0xB02: "minstret",
             0xB80: "mcycleh", 0xB82: "minstreth", 0xC00: "cycle", 0xC01: "time", 0xC02: "instret",
             0xC80: "cycleh", 0xC81: "timeh", 0xC82: "instreth", 0xF11: "mvendorid",
             0xF12: "marchid", 0xF13: "mimpid", 0xF14: "mhartid", 0xF15: "mconfigptr",
             0x106: "scounteren", 0x7A0: "tselect", 0x7A1: "tdata1", 0x7A5: "tcontrol"}


def csr_row(a):
    if a in CSR_NAMES: return CSR_NAMES[a]
    if 0x3A0 <= a <= 0x3EF: return "pmp* (0x3a0-0x3ef)"
    if 0x323 <= a <= 0x33F: return "mhpmevent3-31"
    if 0xB03 <= a <= 0xB1F or 0xB83 <= a <= 0xB9F: return "mhpmcounter3-31(h)"
    return "other / non-existent (traps)"


CAUSES = ["instruction_address_misaligned", "instruction_access_fault", "illegal_instruction",
          "breakpoint", "load_address_misaligned", "load_access_fault",
          "store_address_misaligned", "store_access_fault", "machine_ecall"]

# ----------------------------------------------------------- per test --------
INSTR_RE = re.compile(r"^core\s+\d+: 0x([0-9a-f]+) \(0x([0-9a-f]+)\)")
COMMIT_MEM_RE = re.compile(r" mem 0x([0-9a-f]+)")
EXC_RE = re.compile(r"^core\s+\d+: exception trap_(\w+),")


def symbol(elf, name):
    out = subprocess.run(["riscv32-unknown-elf-nm", elf], capture_output=True, text=True).stdout
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3 and p[2] == name:
            return int(p[0], 16)
    return None


def scan(test_dir, cov):
    stop = symbol(os.path.join(test_dir, "main.elf"), "write_tohost")
    hist = collections.deque(maxlen=3)   # (rd, is_load) of the last retired instrs
    pend = None                          # (mnem, pc) waiting for the next pc / commit
    with open(os.path.join(test_dir, "spike.log"), errors="replace") as f:
        for line in f:
            m = INSTR_RE.match(line)
            if m:
                pc, w = int(m.group(1), 16), int(m.group(2), 16)
                if pc < IMEM_BASE:
                    continue
                if pend and pend[0] in BR.values():
                    cov["Branches"][pend[0] + (" taken" if pc != pend[1] + 4 else " not taken")] += 1
                pend = None
                if pc == stop:
                    break
                mn, rd, rs1, rs2 = decode(w)
                cov["Instructions"][mn] += 1
                # RAW distance to the youngest producer of each source register
                for rs in {rs1, rs2} - {None, 0}:
                    for d, (prd, pld) in enumerate(reversed(hist), 1):
                        if prd == rs:
                            cov["Pipeline hazards"][f"RAW distance {d}" + (" (load-use)" if pld and d == 1 else "")] += 1
                            break
                hist.append((rd if rd else None, mn in LD.values()))
                if mn.startswith("csrr"):
                    wr = mn in ("csrrw", "csrrwi") or ((w >> 15) & 31) != 0
                    cov["CSRs"][csr_row(w >> 20) + (" write" if wr else " read")] += 1
                pend = (mn, pc)
                continue
            e = EXC_RE.match(line)
            if e and pend:
                cov["Traps (mcause)"][e.group(1)] += 1
                if hist: hist[-1] = (None, False)   # a trapping instruction writes nothing
                continue
            c = COMMIT_MEM_RE.search(line)
            if c and pend and (pend[0] in LD.values() or pend[0] in ST.values()):
                size = {"b": 1, "h": 2, "w": 4}[pend[0][1]]
                off = int(c.group(1), 16) & 3
                kind = "load" if pend[0] in LD.values() else "store"
                cov["Memory access (size x addr[1:0])"][f"{kind} {size}B @+{off}"] += 1


def passed(test_dir):
    try:
        r = open(os.path.join(test_dir, "result.txt")).read()
        c = open(os.path.join(test_dir, "cmp.txt")).read()
    except OSError:
        return False, 0
    m = re.search(r"irqs=(\d+)", r)
    return r.startswith("PASS") and c.startswith("MATCH"), int(m.group(1)) if m else 0


def collect():
    cols = collections.OrderedDict()
    groups = [("riscv-tests", RVT_SUITES, lambda c: glob.glob(os.path.join(RVT, c + "-*"))),
              ("riscv-dv", RDV_CONFIGS, lambda c: glob.glob(os.path.join(RDV, c + "_*")))]
    for _, names, finder in groups:
        for name in names:
            cov = collections.defaultdict(collections.Counter)
            n_pass = n_all = 0
            for d in sorted(finder(name)):
                if not os.path.exists(os.path.join(d, "spike.log")):
                    continue
                n_all += 1
                ok, irqs = passed(d)
                if not ok:
                    continue
                n_pass += 1
                scan(d, cov)
                if irqs:
                    cov["Interrupts (RTL)"]["taken"] += irqs
            cols[name] = (cov, n_pass, n_all)
    return groups, cols


# ------------------------------------------------------------- report ------
def fmt(n):
    if n == 0: return "**0**"
    return f"{n / 1000:.0f}k" if n >= 10000 else str(n)


def report(groups, cols):
    names = list(cols)
    head = "| | " + " | ".join(names) + " | total |"
    sep = "|---|" + "---:|" * (len(names) + 1)
    out = ["# WASP coverage matrix", "",
           "Generated by `sim/coverage/coverage.py` (`make coverage`). Dynamic counts per suite /",
           "config, summed over its tests; only tests that PASS (tohost + register trace identical",
           "to Spike) are counted. **0** = not exercised by that column; rows marked GAP are not",
           "exercised by anything.", "",
           "Columns: " + "; ".join(f"{g}: {', '.join(n)}" for g, n, _ in groups) + ".", "",
           head, sep,
           "| *tests passed / run* | " + " | ".join(f"{cols[n][1]}/{cols[n][2]}" for n in names) + " | |"]

    def rows(section, keys):
        out.append(f"| **{section}** |" + " |" * (len(names) + 1))
        for k in keys:
            vals = [cols[n][0][section][k] for n in names]
            tot = sum(vals)
            label = k if tot else (f"{k} — n/a (traps)" if re.match(r"\w+ (2B @\+[13]|4B @\+[123])$", k) else f"{k} — GAP")
            out.append(f"| {label} | " + " | ".join(fmt(v) for v in vals) + f" | {fmt(tot)} |")

    def seen(section):
        s = set()
        for n in names: s |= set(cols[n][0][section])
        return s

    for grp, mns in INSTR_ROWS:
        out.append(f"| ***{grp}*** |" + " |" * (len(names) + 1))
        for k in mns:
            vals = [cols[n][0]["Instructions"][k] for n in names]
            tot = sum(vals)
            out.append(f"| {k if tot else k + ' — GAP'} | " + " | ".join(fmt(v) for v in vals) + f" | {fmt(tot)} |")
    rows("Branches", [f"{b} {t}" for b in BR.values() for t in ("taken", "not taken")])
    rows("Memory access (size x addr[1:0])",
         [f"{k} {s}B @+{o}" for k in ("load", "store") for s in (1, 2, 4) for o in range(4)])
    rows("Pipeline hazards", ["RAW distance 1 (load-use)", "RAW distance 1", "RAW distance 2", "RAW distance 3"])
    rows("CSRs", sorted(seen("CSRs")))
    rows("Traps (mcause)", CAUSES + sorted(seen("Traps (mcause)") - set(CAUSES)))
    rows("Interrupts (RTL)", ["taken"])

    gaps = [l.split(" — GAP")[0].strip("| ") for l in out if " — GAP" in l]
    out += ["", "## Gaps", ""]
    out += ([f"- {g}" for g in gaps] if gaps else ["None."])
    out += ["", "Notes:",
            "- Memory rows count completed accesses only. Misaligned halfword/word accesses",
            "  trap on WASP (and on Spike as configured), so they appear under Traps, and their",
            "  `@+1/+3` (2B) and `@+1/2/3` (4B) rows are expected to stay 0.",
            "- RAW distance d = the source register was written by the instruction d positions",
            "  earlier (d=1: EX->EX forwarding, d=2: MEM->EX, d=3: WB/register-file bypass).",
            "- Interrupts: number taken in the RTL run (riscv-dv irq config, random external +",
            "  software interrupts). Spike runs those tests without interrupts. The irq config",
            "  generates the same programs as rand for the same seed, hence the equal counts.",
            "- CSR rows count executed CSR instructions by address, including the ones that trap",
            "  (`other / non-existent`; `tcontrol` traps on Spike but is legal on WASP).",
            "- Not counted: rv32ui-ma_data and rv32mi-pmpaddr (waived, do not pass) and",
            "  wasp-memmap_fault (no Spike reference: Spike has no WASP access faults there).", ""]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "coverage_matrix.md"))
    a = ap.parse_args()
    groups, cols = collect()
    text = report(groups, cols)
    open(a.out, "w").write(text)
    print(f"wrote {a.out}")
    for l in text.split("\n## Gaps")[1].splitlines()[:40]:
        print(l)


if __name__ == "__main__":
    main()

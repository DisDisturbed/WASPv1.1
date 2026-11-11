#!/usr/bin/env python3
"""Adapt a riscv-dv generated program to the WASP memory map.

    postproc.py <generated.S> <out.S>

* ecall_handler dumps all GPRs to `_start` (riscv-dv's "signature" for TBs
  without a tracer). On WASP `_start` is in IMEM, which is read-only for data
  (store access fault), so the dump goes to a 256-byte area in DMEM instead.
  Nothing reads it back; the comparison uses the commit traces.
* mtvec_handler must sit on a 256-byte boundary (WASP traps to
  {mtvec[31:8], 8'h00}). riscv-dv aligns it to 2^tvec_alignment (2 for
  direct mode), and +tvec_alignment=8 cannot be used: the Verilator fork
  treats riscv-dv's `soft tvec_alignment == 2` as a hard constraint, so the
  config randomization fails. The directive is raised to .align 8 here.
* riscv-dv emits `kernel_instr_start:` before its `.text` directive, so the
  label lands in .user_stack (DMEM) and the IRQ configs' trace filter
  (commit_cmp --skip kernel_instr_start:kernel_instr_end) misses the
  handler. It is moved onto mtvec_handler, the first kernel instruction.
"""
import re
import sys


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src).read()

    text, n = re.subn(r"(ecall_handler:\s*\n\s*la\s+x\d+,\s*)_start\b", r"\1wasp_gpr_dump", text)
    if n != 1:
        sys.exit("postproc: ecall_handler register dump not found")

    text, n = re.subn(r"^kernel_instr_start:\s*\n", "", text, flags=re.M)
    if n != 1:
        sys.exit("postproc: kernel_instr_start not found")
    text = re.sub(r"^mtvec_handler:", "kernel_instr_start:\nmtvec_handler:", text, count=1, flags=re.M)

    m = re.search(r"\.align\s+(\d+)\s*\n(kernel_instr_start:\nmtvec_handler:)", text)
    if not m:
        sys.exit("postproc: no .align before mtvec_handler")
    if int(m.group(1)) < 8:
        text = text[:m.start()] + ".align 8\n" + m.group(2) + text[m.end():]

    text += ("\n.section .data\n.align 6\n.global wasp_gpr_dump\n"
             "wasp_gpr_dump: .fill 64, 4, 0\n")
    open(dst, "w").write(text)


if __name__ == "__main__":
    main()

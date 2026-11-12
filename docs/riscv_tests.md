# riscv-tests on WASP: ISA functional verification

Flow: `sim/riscv-tests/`. Upstream suite: [riscv-software-src/riscv-tests](https://github.com/riscv-software-src/riscv-tests)
(vendored subset, unmodified; commit in `sim/riscv-tests/upstream/COMMIT`), plus a small
WASP-specific suite.

```sh
make riscv-tests                                   # everything (from the repo root), ~15 s
make -C sim/riscv-tests T=rv32ui-add               # one test, verbose
make -C sim/riscv-tests SUITES=rv32um              # one suite: rv32ui | rv32um | rv32mi | wasp
make -C sim/riscv-tests compare T=rv32mi-ma_addr   # first register write where RTL != Spike
make -C sim/riscv-tests wave T=rv32mi-ma_addr      # FST waveform of one test
make -C sim/riscv-tests FENCE=0                    # env without `fence` (only for triage of old RTL)
```

The last line is `RISCV-TESTS PASS` or `RISCV-TESTS FAIL: <tests>` (exit status 0 / 1). The
table is also written to `sim/riscv-tests/build/tests/summary.md`.

**Current status (RTL in this repository): 70 tests, 68 PASS, 2 waived (by design).**
67 of the 68 have a register trace identical to Spike's; the remaining one is WASP-only.

---

## 1. How it works

| Piece | File | What it does |
|---|---|---|
| tests | `upstream/isa/rv32{ui,um,mi}/*.S` | the official self-checking tests, unmodified (66 tests) |
| extra tests | `tests/wasp/*.S` | WASP-specific directed tests, same env/macros (suite `wasp`, section 5) |
| environment | `env/wasp/riscv_test.h`, `env/wasp/link.ld` | WASP port of the upstream `p` env (below) |
| testbench | `tb_rvtest.sv` | `system_top` + tohost monitor + timeout, writes `result.txt` |
| reference | Spike | same ELF on Spike, commit log `spike.log` |
| lock-step check | `tools/commit_cmp.py` | RTL `cpu_trace.log` vs `spike.log`, register write by register write |
| report | `tools/summary.py`, `waivers.txt` | table + overall verdict |

### Environment (`env/wasp`): differences to upstream `env/p`

1. **Split memory.** `.text.init/.text` → IMEM `0x4000_0000`, `.tohost/.data/.bss` → DMEM
   `0x8000_0000` (`imem.mem` / `dmem.mem`, same format as the firmware build). Upstream
   puts everything in one RWX region at `0x8000_0000`; WASP is Harvard and only DMEM is
   writable. Test code reaches its data with `la` (auipc), which spans the two memories.
2. **`trap_vector` is 256-byte aligned.** WASP jumps to `{mtvec[31:8], 8'h00}`
   (`RTL/IF_stage.sv`), so the upstream `.align 2` would land inside `reset_vector`.
   Per-test `mtvec_handler`s are reached through `trap_vector` with a `jr` and need no
   alignment. The `mtvec` catch labels of the CSR probes (`INIT_PMP/SATP/RNMI`) are aligned
   the same way.
3. `FENCE=0` (`-DWASP_RVTEST_NO_FENCE`) drops the `fence` at the start of
   `RVTEST_PASS/FAIL`. The default is upstream behaviour. The knob was only needed to look
   at the rest of the ISA while FENCE was broken (finding 1).

### No memory-map change was needed for the flow itself

`tohost` is the first word of DMEM, which sits behind the write-back D-cache, so the store
may never reach the RAM model. Instead of adding a "test finisher" peripheral, the
testbench snoops the core's OBI data port (`cache_system_top.core_data_bus`): the first
granted word store to `0x8000_0000` ends the run.

* `1` → PASS. `(n<<1)|1` → test case *n* failed. `TESTNUM|1337` → unexpected trap.
* No tohost write within `MAX_CYCLES` (default 200 000) → TIMEOUT (hang / runaway).

### Lock-step comparison against Spike

tohost alone is not enough: the tests compare a result register with an expected value
using a branch, and a broken core can satisfy that by accident (finding 6 did exactly
that). Every ELF is therefore also run on Spike
(`--isa=rv32im_zicsr_zicntr --priv=m --triggers=0`, i.e. M-mode only and no debug
triggers, like WASP), and `commit_cmp.py` checks that the RTL's sequence of
`(pc, rd, value)` register writes is identical to Spike's. A difference is reported at
the first divergent instruction with disassembly. Values read from
`cycle/time/instret/mcycle/minstret(h)` (timing) and `mvendorid/marchid/mimpid`
(Spike's `marchid` is 5) are compared by (pc, rd) only. Tests marked `WASP-ONLY` in their
source rely on WASP's memory map and skip Spike.

| RTL column | meaning |
|---|---|
| `PASS` | tohost = 1 **and** register trace identical to Spike (or WASP-only test) |
| `FALSE-PASS` | tohost = 1 but the trace differs: the test's own checks were fooled (counts as a failure) |
| `FAIL` / `TIMEOUT` / `ERROR` | test failed / hung / simulator gave no verdict |
| `WAIVED` | in `waivers.txt`: cannot pass by design (section 6) |

---

## 2. Results

| RTL | env | PASS | FALSE-PASS | FAIL | TIMEOUT | WAIVED |
|---|---|---|---|---|---|---|
| original `RTL/` (e9d4ef6), 66 upstream + `wasp-mret_csr` | upstream | 1 | 0 | 50 | 13 | 3 |
| original `RTL/` (e9d4ef6), same 67 tests | `FENCE=0` | 41 | 4 | 19 | 0 | 3 |
| after fixes 1–7, same 67 tests | upstream | 64 | 0 | 0 | 0 | 3 |
| **current: + access faults + FENCE.I, 70 tests** | upstream | **68** | 0 | 0 | 0 | **2** |

Other regressions on the current RTL: `make test` (AES vs host, PLIC IRQ, counters
self-test incl. the new trap/FENCE.I checks) **PASS**, `make test-spx` (SPHINCS+-128f: KAT
signature verifies, flipped signature rejected, RTL == host) **PASS** (also passed with
fixes 1–7 alone).

---

## 3. Bugs found and fixed

All seven were applied after review (they were prototyped and validated on a copy first).

| # | Bug | Severity | Caught by | Fix (files) |
|---|---|---|---|---|
| 1 | FENCE was an illegal instruction | high | all 66 (every pass/fail path starts with `fence`) | decode MISC-MEM (`control_unit.sv`) |
| 2 | Operand forwarding into LUI/AUIPC through a fake rs1 | **high, silent data corruption** | and, or, xor, sra, srai, sw, ld_st, st_ld | forward only real source registers (`ID_stage.sv`) |
| 3 | CSR read not interlocked against an in-flight trap/MRET | high | illegal, sbreak, shamt, wasp-mret_csr | stall CSR reads while a trap/MRET is in EX/MEM/WB (`Hazard_unit.sv`) |
| 4 | `minstret` read missed older in-flight instructions | low | instret_overflow | drain before reading instret (`Hazard_unit.sv`, `Core_Top.sv`) |
| 5 | Exceptions raised in EX/MEM never redirected the PC | **high** | ma_fetch, ma_addr, {lw,lh,sh,sw}-misaligned | redirect from MEM, flush younger stages (`mem_stage.sv`, `EX_stage.sv`, `Hazard_unit.sv`, `core_pgk.sv`) |
| 6 | Sticky divide-by-zero "trap" dropped all later writebacks | **high, silent** | div, divu, rem, remu (false passes) | removed: not an exception in RISC-V (`EX_stage.sv`) |
| 7 | `mtval` always 0 | spec-legal; improvement | ma_fetch, ma_addr (trace only) | `tval` carried through the pipeline (`ID/EX/mem/wb_stage.sv`, `CSR.sv`) |

### 1. FENCE decoded as illegal instruction

Every test reported `unexpected trap: mcause=2` at the `fence` in `RVTEST_PASS`:
`control_unit.sv` had no case for opcode `0001111` (MISC-MEM). FENCE is part of RV32I, and
GCC emits it for `__sync_synchronize()`, C11 atomics and `asm("fence")`. FENCE (incl.
FENCE.TSO/PAUSE) is now a NOP: on this single in-order hart every load/store completes
before the next one issues. FENCE.I: see section 4.

### 2. Forwarding into LUI / AUIPC (silent wrong results)

`lui sp, 0xf0f0f` wrote `0x00e0fff0` instead of `0xf0f0f000`. Bits [19:15] of a U-type
instruction are immediate bits; ID passed them on as `rs1_addr` and `hazard_unit` forwarded
whenever a recent `rd` matched, without knowing that LUI uses 0 (AUIPC: pc) as operand A.
Any C program could hit this: it only needs a `lui`/`auipc` whose immediate bits [7:3]
equal the destination of one of the two preceding instructions. ID now hands EX `x0` for
sources the instruction does not read (rs1: operand A not from the register file, or
CSRxI; rs2: anything but R-type, stores and branches).

### 3. CSR read races an in-flight trap / MRET

In a trap handler, `csrr t5, mcause` read the cause of the *previous* trap. The handler
was already in the I-cache, so its first instruction reached ID (where CSRs are read)
before the trap had written mcause in WB. The CSR RAW interlock only waited for CSR
*instructions*. The MRET form is the same race: the instruction at `mepc` reading `mstatus`
saw MPIE/MIE from before the MRET (`0x1800` instead of `0x1880`, `tests/wasp/mret_csr.S`).
Traps and MRETs in ID/EX, EX/MEM and MEM/WB now count as in-flight CSR writes (a handler's
first CSR read waits up to 3 cycles).

### 4. `minstret` read was not precise

`csrw minstreth,-1; nop; csrr a0, minstret` returned `0xffffffff` instead of `0`: the
older `nop` was still in the pipeline when ID read the counter. A CSR instruction reading
`minstret/minstreth/instret/instreth` now waits until EX/MEM/WB hold no valid instruction.

### 5. Exceptions raised in EX/MEM did not redirect the PC

A misaligned `lw` committed `mcause=4` but execution simply continued; a `jalr` to a
misaligned target committed `mcause=0` and still jumped there. Only ID-stage traps
redirected the PC. Now MEM_stage raises `mem_exc` for a trap that was not redirected yet
(misaligned/faulting load/store, or a trap raised in EX, marked `trap_late` in the EX/MEM
bundle). hazard_unit redirects to `mtvec` (after the memory freeze, ahead of ID traps and
branches) and flushes IF/ID/EX. The excepting instruction commits mepc/mcause in WB, and no
younger store or CSR write escapes.

### 6. Divide by zero silently dropped later results

After the first `x/0`, the register writes of `div` and of every following instruction
disappeared, and a cause-7 "trap" was logged every cycle. `EX_stage` turned
`MulDiv.div_by_zero_o` into an exception, but that output is sticky until the next
MUL/DIV and was not qualified with `is_muldiv`. `rv32um-div/divu/rem/remu` reported PASS
only because stale registers happened to be equal, which the lock-step check exposed. The
M extension says division by zero does not trap (DIV/DIVU → all ones, REM/REMU → dividend,
which `MulDiv` already computes), so the trap was removed. Cause 7 is now the standard
store access fault.

### 7. `mtval`

mtval used to be written 0 on every trap (spec-legal). It now holds the misaligned fetch
target, the misaligned or faulting load/store address, the fetch address of an instruction
access fault, the illegal instruction word, or the ebreak pc; otherwise 0. This makes the
traces identical to Spike's (tests branch on mtval) and gives firmware the faulting
address. About 96 flip-flops.

### Not a bug: duplicate commits in `cpu_trace.log`

While MEM stalls, WB keeps re-asserting the same register write so that forwarding to the
stalled EX stage stays alive. Writing the same value to the same register again is
harmless, but `Core_Top`'s tracer logged it twice. The tracer now logs on retirement
(`wb_commit_retire`); this is debug-only code with no functional change.

---

## 4. Added features: access faults and FENCE.I

Requested after the first review ("access-fault traps and FENCE.I with the trap handler
driver"). Design details: `docs/memory_map.md`.

### Access faults (mcause 1 / 5 / 7)

* **OBI `err`** response signal added to both buses (`obi_if.sv`, valid with `rvalid`).
* **Data side** (as built for this change; the check has since moved onto the bus, see
  section 7 and docs/memory_map.md). `cache_system_top` checks every core access against the memory map before
  it reaches the D-cache. Anything the map cannot serve gets an immediate `gnt+rvalid+err`
  from an error leg: unmapped, store to IMEM (read-only for data), read of the write-only
  flush register, other offsets of the flush page, or a spare slot without a slave
  (`System_top` parameter `SLOT_PRESENT`, default none). Such an access never reaches the
  crossbar. The D-cache additionally reports `rresp/bresp != OKAY` from real slaves on
  `err`; a refill that errors is not cached.
* **Core.** MEM turns `err` on its own access into a load/store access fault (precise, via
  fix 5; `rd` not written; mtval = address).
* **Fetch side.** The I-cache refuses fetches outside IMEM and DMEM with `err` (no AXI
  request). IF carries the flag to ID, which raises an instruction access fault
  (mepc = mtval = fetch address).
* **Side effect.** The hangs listed in the first report are gone: a store to IMEM or an
  access to an empty slot used to hang the core forever, and an unmapped load used to wedge
  the crossbar (its decode-error path under-counts transactions). These now trap instead.

### FENCE.I (Zifencei)

* Decoded in `control_unit`; `fencei` rides the ID/EX and EX/MEM bundles.
* In MEM it holds `fencei_req` (new `Core_Top` port) and stalls like a memory access. The
  D-cache walks all 64 lines through the existing per-line write-back+invalidate path
  (`flush_all_req_i` / `flush_all_done_o`, about 2 cycles per line plus ~20 per dirty
  line).
* On `done`, the I-cache invalidates every line in one cycle; a refill in flight is not
  validated. The core redirects to `pc+4` like a jump, so everything fetched after the
  fence.i is refetched.
* The I-cache can fetch from DMEM, so code written there (loader, generated code) runs after
  `fence.i`.

### Firmware drivers

* `sw/hal/include/trap.h` + `sw/hal/wasp/trap.c` + `sw/hal/common/trap_util.c`: trap
  dispatcher (`trap_init`, per-cause exception handlers, per-IRQ handlers, `trap_skip`,
  `trap_cause_name`, `trap_print`). An unhandled exception prints
  `TRAP load access fault mcause=... mepc=... mtval=...` and stops (`trap_fatal`, weak).
  Host build: `sw/hal/host/trap_host.c`.
* `sw/hal/include/cache.h`: `icache_sync()` (fence.i) and `dcache_flush_line()`.
* `sw/hal/include/memmap.h`: the access-fault rules.
* `sw/apps/counters`: new self-checks through the driver (access faults incl. fetch,
  ebreak mtval, generated code + rewrite with `icache_sync()`, x/0), part of `make test`.
* `sim/spike/wasp_periph.cc`: the same access check, so `make spike` matches WASP (except
  "store to IMEM": Spike's IMEM is plain RAM).

---

## 5. WASP-specific tests (`tests/wasp/`)

| Test | Checks | Spike |
|---|---|---|
| `mret_csr` | instruction at `mepc` reads `mstatus` right after MRET (finding 3) | lock-step |
| `access_fault` | load/store to unmapped + empty slot, fetch from unmapped: cause, mtval, mepc, rd untouched, bus usable afterwards | lock-step |
| `memmap_fault` | store to IMEM, read of / bad offset in the flush page, legal flush still works | WASP-only |
| `fencei_stress` | generated code in 8 cache sets, rewritten while in the I-cache; 4 KB of dirty data survives the flush-all | lock-step |

The new tests fail on the RTL before the features (two hangs and an illegal fence.i), so
they do detect the problems.

---

## 6. Waived tests (`sim/riscv-tests/waivers.txt`)

| Test | Why it cannot pass | Could be enabled by |
|---|---|---|
| `rv32ui-ma_data` | Requires misaligned loads/stores done in hardware. WASP traps them (cause 4/6), which the ISA allows; Spike traps too, and the RTL trace equals Spike's. | misaligned-access support in the LSU/D-cache |
| `rv32mi-pmpaddr` | Requires PMP. WASP has no PMP; `pmpaddr0` reads 0 (allowed: PMP is optional). | a PMP unit |

(`rv32ui-fence_i` was waived until FENCE.I was implemented; it now passes in lock-step.)
A waived test that starts passing shows up as `PASS (waived)`, so the waiver can be removed.

---

## 7. Still open (not changed)

* (Closed.) The verilog-axi crossbar, whose decode-error path under-counted transactions,
  has been replaced by `RTL/axi_xbar.sv`. Unmapped addresses, empty slots and stores to
  IMEM now reach the bus and come back as `DECERR` / `SLVERR`; the early access check in
  `cache_system_top` is gone (docs/memory_map.md).
* D-cache write-back (eviction) errors are ignored. That is unreachable today because DMEM
  never errors, and any error would be imprecise.
* `mtvec` reads back the written value, but traps go to `{mtvec[31:8], 8'h00}`. BASE is WARL,
  so it should read back the address actually used. `rv32mi-breakpoint` depends on this
  indirectly: it only passes because `tcontrol` is a legal CSR on WASP (see
  `docs/riscv_dv.md`, unimplemented-CSR trap).
* Load-use detection compares the raw rs1/rs2 instruction fields, so it also stalls when
  those are immediate bits (performance only).

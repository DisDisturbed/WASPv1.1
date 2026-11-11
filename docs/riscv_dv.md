# riscv-dv random tests on WASP

Random instruction programs from [riscv-dv](https://github.com/chipsalliance/riscv-dv),
run on the WASP RTL (the `sim/riscv-tests` testbench) and compared with Spike register
write by register write. Flow: `sim/riscv-dv/`.

```
cd sim/riscv-dv
make setup            # once: riscv-dv, uvm-verilator, Verilator fork, z3 (pinned)
make -j6              # CONFIGS x SEEDS (default 9 configs x seeds 1..5)
make T=rand_3         # one test
make compare T=rand_3 # first register write where RTL != Spike
```

## How it works

1. **Generate**: riscv-dv's generator, compiled with the antmicro Verilator fork
   (`build/gen/Vuvm`), writes `gen_0.S` per `<config>_<seed>`. Options per config are
   in `configs.mk` (adapted from riscv-dv's `base_testlist.yaml`).
2. **Post-process** (`tools/postproc.py`): GPR dump moved from IMEM to DMEM, the trap
   handler aligned to 256 bytes (WASP traps to `{mtvec[31:8], 8'h00}`),
   `kernel_instr_start` moved onto `mtvec_handler`.
3. **Link** with `env/link.ld` (IMEM 64 KB @ 0x4000_0000, DMEM 64 KB @ 0x8000_0000), run
   on the RTL (`Vtb_rvtest`, optional random interrupts) and on Spike.
4. **Compare** the commit traces (`sim/riscv-tests/tools/commit_cmp.py`). A test passes
   only if tohost is reached AND the traces match; for IRQ configs the handler range
   `kernel_instr_start..kernel_instr_end` is left out of both traces.

WASP-specific generator settings: `target/wasp/riscv_core_setting.sv` (RV32IM, M-mode,
direct mtvec, no PMP / debug) and `target/wasp/user_extension.svh` (`wasp_gen_config`:
4 x 4 KB data regions instead of riscv-dv's 4 KB + 64 KB, so that regions + stacks
fit in DMEM; selected with `+uvm_set_type_override`).

### Tooling notes

- **Memory**: the generated UVM C++ is huge (each `g++` 1-3 GB). The generator is built
  with `DV_JOBS ?= 4` and `-O0`; `-j$(nproc)` (20) ran the machine out of RAM.
- **z3** is required at generation time (Verilator's constraint solver,
  `VERILATOR_SOLVER`). Without it every `randomize()` fails and the generator
  dereferences null objects. `make setup` installs it into `build/tools/z3venv`.
- **`+tvec_alignment` cannot be used**: the Verilator fork treats riscv-dv's
  `soft tvec_alignment == 2` as hard, so any other value makes the config
  randomization unsatisfiable (confirmed with a z3 unsat core). `postproc.py` sets
  the alignment instead.
- `instr_cnt` of `rand`/`irq` (6500) and `mem` (2800) is sized so `.text` fits 64 KB IMEM.
- The `hint` config is not run: riscv-dv only generates compressed HINTs, which become
  `.2byte 0x0000` without the C extension and misalign the program (Spike fails too).

## Results (2026-11-11, seeds 1..5)

| config | result |
|---|---|
| arith, rand, jump, loop, rjump, mem, illegal, ebreak, irq | 45/45 PASS, traces identical to Spike |

What the 45 programs exercise (per config, together with riscv-tests):
`docs/coverage_matrix.md` (`make coverage`).

## Bug found and fixed: accesses to unimplemented CSRs did not trap

riscv-dv's illegal-instruction stream uses CSR address `0x006` (e.g. `csrrs a2, 0x006, ra`
= `0x0060a673`). Spike raises an illegal-instruction exception (mcause 2); WASP wrote
`rd = 0` and continued, so 4 of the 5 `illegal` seeds diverged at that instruction
(illegal_1/3 timed out, illegal_4/5 reached tohost with a different trace).

That was the documented behaviour of `RTL/CSR.sv`, but the privileged spec requires an
illegal-instruction exception for an access to a non-existent CSR, and for a write to a
read-only CSR (`csr[11:10] == 2'b11`).

Fix (`RTL/control_unit.sv`, `csr_legal()`): the CSR address is checked at decode. A
non-existent CSR, or a CSR instruction that writes (`CSRRW/CSRRWI`, or `CSRRS/CSRRC[I]`
with `rs1/uimm != 0`) a read-only address, is decoded as an illegal instruction
(mcause 2, mtval = instruction word) through the existing ID exception path, with no CSR
or register side effects. The legal set is Spike's for
`rv32im_zicsr_zifencei_zicntr --priv=m`, plus:

- `mcounteren` / `scounteren`, which WASP keeps for `sw/apps/counters`;
- `tcontrol` (0x7A5, reads 0 like the other trigger CSRs). Spike traps on it, but
  `rv32mi-breakpoint` probes it with `mtvec` pointing at the next, unaligned instruction,
  and WASP traps to `{mtvec[31:8], 8'h00}`, so trapping there made the test loop forever.
  With `tcontrol` legal the test passes and its register trace still equals Spike's.

CSRs that exist without state (`mstatush`, `mhpmevent*`, `mhpmcounter*`, PMP, trigger CSRs,
ID registers) still read 0 and ignore writes.

After the fix: this flow 45/45, `make riscv-tests` 70 tests (68 PASS, 2 WAIVED),
`make test` REGRESSION PASS. `make test-spx` (~17 min) was not rerun.

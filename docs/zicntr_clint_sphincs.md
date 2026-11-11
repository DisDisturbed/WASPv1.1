# Zicntr CSRs, CLINT, new memory map, SPHINCS+ — what changed

Branch `feat/zicntr-clint-sphincs`. Everything below was checked in Verilator
(5.048) on the full `system_top` (caches, AXI crossbar, PLIC, CLINT, UART
model); see "Verification" at the end.

## 1. Memory map (all regions 4 KB aligned)

> **Superseded** — the map was moved again (IMEM `0x4000_0000`, DMEM
> `0x8000_0000`, peripherals in 4 KB pages from `0xC000_0000`, compact
> CLINT/PLIC). See [`memory_map.md`](memory_map.md). The table below is the
> map this branch introduced, kept for history.

| Address | Size | What | Notes |
|---|---|---|---|
| `0x0000_F000` | — | D-cache flush control | was `0xFF00`; write a line address to write it back + invalidate (`cache.h`) |
| `0x0002_0000` | 8 KB | UART16550 (AXI) | unchanged; slots `0x2_2000/0x2_4000/0x2_6000` unchanged |
| `0x00F0_0000` | 4 MB | PLIC | unchanged base; decode is now a range (was `addr >= PLIC_BASE`) |
| `0x0200_0000` | 64 KB | **CLINT** | new on the bus (SiFive layout) |
| `0x1000_0000` | 64 KB | **IMEM** (boot) | was `0x0`, 16 KB |
| `0x4000_0000` | 64 KB | **DMEM** | was `0x1_0000`, 16 KB; only this range is D-cacheable |

* `System_top` parameters: `IMEM_BASE`, `DMEM_BASE`, `BOOT_ADDR (=IMEM_BASE)`,
  `CLINT_BASE`, `CLK_FREQ_HZ`, `IMEM/DMEM_ADDR_WIDTH = 16`.
* **`boot_addr_in` must now be driven with `0x1000_0000`** (it is still a
  top-level port; `TB/System_top_TB.sv` was updated, check your board wrapper).
* `dcache_test_data_mem` gets `.ACTIVE_ADDR(0)`: its default `0x8000` offset
  only "worked" because it wrapped away at 16 KB; at 64 KB it moved word 0 to
  the middle of the array.
* D-cache bypass is now `[0, DMEM_BASE-1]` (everything except DMEM bypasses).
* `RTL/imem.mem` / `RTL/dmem.mem` were regenerated from `sw/apps/aes/main.c` (AES
  demo) for the new map.

## 2. CLINT (`RTL/Clint.sv`)

OBI slave, same 2-cycle timing as the PLIC, third leg of the data-bus
arbiter in `cache_system_top`. (Offsets below are the original SiFive ones;
the current compact layout is in [`memory_map.md`](memory_map.md).)

| Offset | Register | |
|---|---|---|
| `0x0000` | `msip` | bit0 → `mip.MSIP` (software interrupt) |
| `0x4000/4004` | `mtimecmp` lo/hi | `mtime >= mtimecmp` → `mip.MTIP` |
| `0xBFF8/BFFC` | `mtime` lo/hi | R/W, 64 bit |
| `0xC000` | `clk_freq` | **RO**: `CLK_FREQ_HZ` the bitstream was built with |
| `0xC004` | `prescaler` | mtime += 1 every `prescaler+1` clocks; reset = 1 µs ticks |

* `clint_init(expected_clk_hz, tick_hz)` (`sw/hal/wasp/clint.c`) returns an error if
  `clk_freq` ≠ what software expects, then programs `prescaler`.
* `Constrait/check_clk_freq.tcl` fails the build if clk_wiz_0 `clk_out1` ≠
  `CLK_FREQ_HZ` (use as `STEPS.SYNTH_DESIGN.TCL.PRE` or source it manually).
  Unit-tested with stubbed Vivado commands only — not run inside Vivado here.
* Elaboration `$error` if `CLK_FREQ_HZ` is not a multiple of the 1 MHz
  default tick.
* `mcycle` is **not** prescaled — it always counts core clocks.

## 3. CSRs (`RTL/CSR.sv`)

New: `mcycle(h)`, `minstret(h)` (R/W, 64 bit), `cycle/time/instret(h)`
(RO shadows; `time` = CLINT `mtime`), `mcountinhibit` (CY, IR),
`mcounteren` / `scounteren` (R/W registers, reset all-ones, exported on
`mcounteren_o/scounteren_o` for the future U/S-mode access check — not
enforced yet), `mhpmcounter3-31(h)`, `hpmcounter3-31(h)`, `mhpmevent3-31`,
`mstatush`, `mconfigptr` (all read 0), `mip.MSIP` / `mie.MSIE`.
Interrupt priority in ID is MEI > MSI > MTI (priv spec).

* `minstret` is exact: a new `valid` bit in the `id_ex/ex_mem/mem_wb`
  bundles (set for real fetched instructions, cleared for IF/ID bubbles,
  trapped instructions, and when MEM stalls so a held WB slot isn't counted
  twice). IF exports `instr_valid_id_o`; WB exports `wb_retire_o`.
* Unknown / read-only CSRs still read 0 and ignore writes without an
  illegal-instruction trap (same as before).

## 4. Pipeline fixes (pre-existing bugs, found by the new tests)

All in `Hazard_unit.sv` / `ID_stage.sv` / `IF_stage.sv`. They only showed up
once timer interrupts actually fire; each was reproduced in simulation first.

1. **Wrong-path trap**: an instruction in ID behind a taken branch/jump
   (redirect from EX/MEM) could still trap — `trap_take` had priority over
   the redirect. A wrong-path `0x00000000` after a `ret` raised
   illegal-instruction; an IRQ in that cycle saved the wrong-path PC in
   `mepc` and the branch was lost. → new `id_kill`: on a redirect the ID
   slot becomes a plain bubble (no trap/irq/mret).
2. **Bubble PC on redirect**: the NOP bubble IF inserts on a redirect carried
   the old (wrong-path) `pc_r`; an IRQ taken on that bubble returned to the
   wrong place. → bubble now carries the redirect target.
3. **Trap lost behind an unresolved branch**: an IRQ taken in ID while an
   older branch was still in EX got flushed by that branch one cycle later,
   its redirect overridden, and `trap_in_flight` never cleared →
   **interrupts masked forever**. → ID holds a trap/mret one cycle while a
   branch/jump is in EX (`trap_hold`).
4. **Trap during MUL/DIV**: trap priority beat the `ex_busy` stall, the trap
   bubble overwrote `id_ex` while Mul_Div was working → result lost.
   → `trap_hold` also while `ex_busy`.
5. **CSR read-after-write**: CSRs are read in ID, written in WB, no
   interlock (`csrw x; csrr x` read the old value; `csrw mepc; mret` used
   the old mepc). → ID stalls (bubble, like load-use) while an older CSR
   write is in EX/MEM/WB.

The linker script also fills `.text` alignment gaps with NOPs again
(`-ffunction-sections` had made them zeros).

## 5. Software (`sw/`)

The same application sources build for the wasp core (`TARGET=wasp`, the
default) and for the PC (`TARGET=host`, native gcc, UART = stdin/stdout,
counters read 0), so RTL output can be compared with a host run.

| Path | |
|---|---|
| `apps/aes/main.c` | AES-256 over UART + PLIC button IRQ (trap handler wasp-only) |
| `apps/sphincs/main.c` | UART keygen/sign/verify demo (protocol in its header) |
| `apps/counters/main.c` | CSR/CLINT/PLIC/D-cache self-test + interrupt stress (wasp only) |
| `lib/sphincs/` | SPHINCS+ NIST reference, verbatim (see below) |
| `rng/randombytes_hw.c` | mcycle-jitter RNG, **FPGA builds only** (`RNG=hw`) |
| `rng/randombytes_det.c` | fixed-seed SHAKE256 RNG, RTL sim + host (`RNG=det`, default) |
| `hal/include/` | `memmap.h` (all base addresses), `uart.h`, `clint.h`, `irq.h`, `cache.h` |
| `hal/common/uart_util.c` | `uart_send_buf/receive_buf/puts/puthex/putdec` |
| `hal/wasp/` | `crt0.s`, `linksc.ld` (ROM/RAM 64 KB, stack assert), `csr.h` (numeric CSR macros, `rdcycle64`...), `uart.c`, `clint.c`, `irq.c`, `libc_min.c` |
| `hal/host/` | `csr.h` (counters = 0), `uart_host.c` (stdin/stdout), CLINT/IRQ stubs |
| `tools/sphincs_host.py` | PC client for the board (pyserial) |

Build: `make -C sw PROG=aes|counters|sphincs [TARGET=wasp|host] [SPX=128s|128f] [RNG=det|hw] [CROSS=C:/riscv/bin/riscv64-unknown-elf-]`
→ `sw/build/<target>/<prog>[_<spx>][_hwrng]/` (wasp: `imem.mem, dmem.mem`;
host: `main`). The Makefile picks `rv32im` or `rv32im_zicsr` depending on
the GCC version. FPGA image with the real RNG:
`make -C sw PROG=sphincs SPX=128f RNG=hw`.

## 6. SPHINCS+

* Source: NIST PQC round-3 package `SPHINCS-Round3.zip` from
  csrc.nist.gov (submission 2020-10-01 = SPHINCS+ **v3.0**; v3.1 is not on
  the NIST page), `Reference_Implementation/crypto_sign/
  sphincs-shake256-{128s,128f}-simple`. Files in `sw/lib/sphincs/` are
  **verbatim**; only `params.h` differs between the sets
  (`lib/sphincs/params/<set>/`). `rng.c` (OpenSSL AES DRBG) is replaced by
  `sw/rng/randombytes_{hw,det}.c` with the same `randombytes()` prototype.
* Randomness (FPGA build, `RNG=hw`): `mcycle` sampled at asynchronous events (every UART byte's
  arrival time) into a pool, conditioned with SHAKE256 + chaining state.
  A freshly reset core is deterministic, so the entropy is only as good as
  the external timing jitter — not a certified TRNG. `rng_inject()` feeds
  exact bytes for KAT reproduction. RTL simulation and host builds use
  `RNG=det` instead (fixed seed, NOT random) so both give identical bytes.
* Measured on the RTL: one Keccak-f1600 ≈ 98 k cycles (28 k instructions,
  CPI ≈ 3.5). At 50 MHz:

  | | 128s | 128f |
  |---|---|---|
  | public key / signature | 32 B / 7 856 B | 32 B / 17 088 B |
  | keygen | ~10 min (est.) | **9.0 s (measured, 448 M cycles)** |
  | sign | ~73 min (est.) | **3.7 min (measured, 11.14 G cycles)** |
  | verify | **4.2 s (measured)** | **12.1 s (measured, 607 M cycles)** |

  A looped Keccak-f (1 KB instead of 8.8 KB of code, to fit the 4 KB
  I-cache) was tried and was *slower* (twice the instructions, same CPI), so
  the NIST code stays as is.

## Verification

* `sim/` — Verilator model of `system_top` (`sim/axi_uart16550_0.sv` stands in
  for the Xilinx UART IP, simulation only; never add it to Vivado).
  `make -C sim` (trace) / `make -C sim fast` (quiet), `sim/run.sh <prog>`.
* AES (`sw/apps/aes`): RTL output == host build of the same source
  (`sim/host/uart_cmp.py`), before and after every change.
* `counters`: all CSR/CLINT checks pass; interrupt stress (same
  computation with and without a timer IRQ every 9/13/20/31 µs, up to
  11 436 IRQs) gives identical results.
* SPHINCS+: `sim/host/spx_kat.c` reproduces NIST KAT 0–2 bit-exact for both
  sets on the host (same sources). On the RTL (KAT count 0):
  * 128s: KAT signature verifies (`v 01`), bit-flipped signature is
    rejected (`v 00`).
  * 128f: KAT signature verifies; seeded keygen (`Q`) gives the KAT pk
    bit-exact; deterministic sign (`D`, KAT optrand) gives the KAT signature
    bit-exact (17 088 B) and the device re-verifies it (`v 01`).
  * Not run on the RTL: 128s keygen/sign (~10 h / ~59 h of simulation).
  * Host build (`TARGET=host`) of `apps/sphincs`: `Q` + `D` with KAT #0
    reproduces the KAT pk and signature bit-exact for 128f and 128s; RTL
    lite run == host run except the cycle fields (`make test-spx`).
    They share every source file with 128f except `params.h`.

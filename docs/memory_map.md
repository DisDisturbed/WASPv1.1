# wasp memory map

Source of truth: `RTL/System_top.sv` parameters. Software copy: `sw/hal/include/memmap.h`
(+ `sw/hal/wasp/linksc.ld` for IMEM/DMEM). Keep the three in sync.

| Address | Size | Device | Reached via |
|---|---|---|---|
| `0x4000_0000` | 64 KB | **IMEM** (boot, `BOOT_ADDR`) | I-cache → AXI crossbar M00 (data reads: D-cache bypass → M00, read-only) |
| `0x8000_0000` | 64 KB | **DMEM** | D-cache (the only cacheable range) → crossbar M01 |
| `0xC000_0000` | 4 KB | UART16550 | D-cache bypass → crossbar M02 → AXI-Lite |
| `0xC000_1000` | 4 KB | CLINT | core data bus decode in `cache_system_top` |
| `0xC000_2000` | 4 KB | PLIC | core data bus decode in `cache_system_top` |
| `0xC000_3000` | 4 KB | D-cache flush control | intercepted inside `Dcache.sv` (write only) |
| `0xC000_4000` | 4 KB | spare AXI slot | crossbar M03 |
| `0xC000_5000` | 4 KB | spare AXI slot | crossbar M04 |
| `0xC000_6000` | 4 KB | spare AXI slot | crossbar M05 |

Everything else is unmapped. `boot_addr_in` must be driven with
`0x4000_0000` (tb_sim and `TB/System_top_TB.sv` do).

## Access faults

Data accesses are checked against this map in `cache_system_top` before they
reach the D-cache/crossbar. An access that cannot be served is answered at once
with an OBI error and raises a **precise** exception (mtval = address, the
destination register is not written, a store has no effect):

| Access | mcause |
|---|---|
| load from an unmapped address, the flush register (write-only), or a spare slot with no slave | 5 load access fault |
| store to an unmapped address, **IMEM** (read-only for data), the flush page other than `+0x000`, or a spare slot with no slave | 7 store access fault |
| instruction fetch outside IMEM and DMEM (checked in `icache.sv`) | 1 instruction access fault |
| AXI `SLVERR`/`DECERR` on a D-cache bypass access or refill | 5 / 7 |

Spare slots: set `System_top` parameter `SLOT_PRESENT` bit *n*-3 when a slave is
attached to crossbar port M0*n*; until then the slot faults (without a slave it
would never answer and the core would hang). Firmware side: `sw/hal/include/trap.h`
(dispatcher, cause names, default "TRAP ..." report).

## FENCE.I (Zifencei)

`fence.i` (driver: `icache_sync()` in `cache.h`) makes earlier stores visible to
instruction fetch: in MEM the core holds `fencei_req`, the D-cache writes back
and invalidates all 64 lines (`flush_all_req_i`, ~2 cycles/line + ~20 per dirty
line), then the I-cache invalidates every line (1 cycle) and fetch restarts at
the next instruction. Code can be executed from DMEM (the I-cache fetches it
through the crossbar), so loaders / generated code go: write to DMEM →
`icache_sync()` → jump.

New peripheral: take the next free 4 KB page above `0xC000_6000`, add a
crossbar port (or a decode leg in `cache_system_top`) and a `*_BASE` in
`memmap.h`.

## CLINT (compact layout, `RTL/Clint.sv`, `sw/hal/include/clint.h`)

The SiFive CLINT registers, packed into one page. **Offsets are not
SiFive/OpenSBI-compatible.**

| Offset | Register | |
|---|---|---|
| `0x000` | `msip` | bit 0 → `mip.MSIP` |
| `0x008` / `0x00C` | `mtimecmp` lo / hi | `mtime >= mtimecmp` → `mip.MTIP` |
| `0x010` / `0x014` | `mtime` lo / hi | R/W |
| `0x018` | `clk_freq` | RO, `CLK_FREQ_HZ` of the bitstream |
| `0x01C` | `prescaler` | mtime += 1 every `prescaler+1` clocks |

## PLIC (compact layout, `RTL/Plic.sv`, `sw/hal/include/irq.h`)

Same registers as the RISC-V PLIC, packed into one page (max 32 sources).
**Offsets are not spec-compatible** (spec: enable `+0x2000`, threshold/claim
`+0x20_0000`).

| Offset | Register | |
|---|---|---|
| `0x000 + 4*id` | `priority[id]` | id 1 … N_SRC-1; other slots read 0 |
| `0x080` | `pending` | RO bitmap |
| `0x100` | `enable` | bitmap, bit 0 forced 0 |
| `0x200` | `threshold` | |
| `0x204` | `claim / complete` | |

## D-cache flush (`sw/hal/include/cache.h`)

Write a DMEM line address to `0xC000_3000`: line `addr[11:6]` is written back
(if dirty) and invalidated (`dcache_flush_line()`). `dcache_flush_all()` does
all 64 lines. The register is write-only: reading it is a load access fault.
(Fixed in this change: flushing a *dirty* line used to hang the AXI bus,
because the flush request was treated as a single-beat bypass access.)

## Testing

ISA compliance: `make riscv-tests` (docs/riscv_tests.md).

`sim/regress.sh` (AES: RTL == host build, PLIC interrupt, counters/CLINT/
memory-map self-test) and `sim/regress.sh spx` (+ SPHINCS+-128f: Keccak
bench, NIST KAT #0 signature verify, flipped-signature reject, RTL == host build).
`tb_sim` plusarg `+plic_irq_at=<cycle>` pulses PLIC source 2.

From the repo root: `make build PROG=<name>` (firmware → `sim/active_test/`),
`make wave PROG=<name>` (build + FST waveform → `sim/active_test/wave.fst`),
`make run PROG=<name>` (build + fast model, no waveform),
`make spike PROG=<name>` (build + same ELF on Spike),
`make host PROG=<name>` (PC gcc build on the same UART input, compared
with the last RTL run), `make view` (Surfer),
`make test`. Run `make` with no target for the full help text.

### Spike

`sim/spike/wasp_periph.cc` is a Spike MMIO plugin modelling the peripheral
block at `0xC000_0000` (UART with RX/TX files, compact CLINT, compact PLIC,
flush register), so the firmware ELF runs unchanged on Spike. Spike has no
clock: 1 instruction = 1 cycle, `MAX_CYCLES`/`PLIC_IRQ_AT` count
instructions, timer IRQs are taken at Spike's 5000-instruction tick.
The plugin applies the same access check as the RTL (flush register
write-only, spare slots fault). Known differences on `PROG=counters`
(everything else passes): `misa` (Spike reports S/U), `mcounteren`/`scounteren`
reset (wasp-specific all-ones), `dcache flush invalidates` (Spike has no
D-cache), `store to IMEM` (Spike's IMEM is ordinary RAM, so the store succeeds).

# WASP

RV32IM (+ Zicsr, Zicntr, Zifencei) RISC-V SoC: 5-stage core, I-/D-cache, AXI crossbar,
UART16550, CLINT, PLIC. The same C programs run on three platforms and give
the same output:

| Platform | How | Used for |
|---|---|---|
| **Verilator** | cycle-accurate model of `RTL/System_top.sv` | functional + cycle-count verification |
| **FPGA** | Vivado project with `RTL/` + the same `imem.mem`/`dmem.mem` | the real board |
| **PC (gcc)** | the same `main.c` compiled natively, UART = stdin/stdout | golden reference to compare against |

Applications: **AES-256** over UART, **SPHINCS+** (NIST round-3,
SHAKE256-128f/128s-simple) key generation / signing / verification, and a
**counters** hardware self-test (CSRs, CLINT, PLIC, D-cache).

---

## 1. Repository layout

```
WASP/
├── Makefile            top level: build / run / wave / spike / view / test   ← start here
├── rx.txt              editable UART input (commands for the SPHINCS+ app)
├── RTL/                SystemVerilog/Verilog of the SoC (System_top.sv = top)
│   └── imem.mem, dmem.mem   memory images the FPGA bitstream is built with
├── TB/                 Vivado testbench (System_top_TB.sv)
├── Constrait/          FPGA constraints (.xdc) + clock check script
├── sw/                 all C code (one source tree for Verilator, FPGA and PC)
│   ├── Makefile        software build: PROG / TARGET / SPX / RNG
│   ├── apps/           aes/  sphincs/  counters/     (main.c each)
│   ├── lib/sphincs/    NIST SPHINCS+ reference code, verbatim (+ params/128f|128s)
│   ├── rng/            randombytes_det.c (fixed seed)  randombytes_hw.c (mcycle)
│   ├── hal/include/    driver APIs + register maps: memmap.h uart.h clint.h irq.h trap.h cache.h
│   ├── hal/common/     target-independent driver code (uart_util.c, trap_util.c)
│   ├── hal/wasp/       RISC-V only: crt0.s, linksc.ld, csr.h, uart.c, clint.c, irq.c, trap.c, libc_min.c
│   ├── hal/host/       PC stand-ins: csr.h (counters = 0), UART on stdin/stdout, stubs
│   ├── tools/          sphincs_host.py: talk to the real board over a serial port
│   └── build/          (generated) build/<wasp|host>/<prog>/
├── sim/                Verilator flow
│   ├── Makefile        Verilator models + run/wave/spike/view
│   ├── tb_sim.sv       simulation testbench (stop conditions, PLIC IRQ injection)
│   ├── axi_uart16550_0.sv   UART model (files instead of serial pins; sim only!)
│   ├── run.sh, regress.sh   single run / regression
│   ├── spike/          Spike plugin with the wasp peripherals
│   ├── riscv-tests/    ISA compliance: upstream riscv-tests + WASP env, RTL vs Spike lock-step
│   ├── riscv-dv/       random instruction tests (riscv-dv) vs Spike, same testbench
│   ├── coverage/       coverage.py: functional coverage matrix of both flows
│   ├── host/           PC-side tools: rxgen.py, uart_cmp.py, spx_lite.py, spx_kat.c,
│   │                   NIST KAT files (nist/), test vectors (vectors/)
│   └── active_test/    (generated) where every `make run/wave` happens
└── docs/               memory_map.md, zicntr_clint_sphincs.md (design notes, measurements)
```

---

## 2. Opening the project

* **Editing / running**: open the `WASP/` folder (the one with the top-level
  `Makefile`) in VS Code or a terminal. Every command below is run **from this
  folder**.
* **Vivado**: create/open the project with all files in `RTL/` (and
  `RTL/PGK_IF/`), constraints from `Constrait/`, testbench `TB/System_top_TB.sv`.
  Top module: `system_top`. **Never** add `sim/axi_uart16550_0.sv` to Vivado:
  it is a simulation stand-in for the Xilinx UART IP.

### Tools

| Tool | Needed for | Checked with |
|---|---|---|
| `make`, `gcc`, `python3` | everything | gcc 13, Python 3.12 |
| `riscv32-unknown-elf-gcc` (or `riscv64-unknown-elf-`) | RISC-V builds | GCC 15.1 (any ≥ 8 works) |
| `verilator` ≥ 5 | simulation | 5.048 |
| `surfer` or `gtkwave` | viewing waveforms | |
| `spike` (optional) | ISA reference runs | |
| OpenSSL dev headers (optional) | `sim/host/spx_kat.c` only | |

Windows: run commands inside MSYS2 UCRT64 (`sim/msys.sh "make ..."`), and give
the cross compiler with `CROSS=C:/riscv/bin/riscv64-unknown-elf-`.

---

## 3. Quick start

```sh
make                                              # prints the help text
make run PROG=aes RX=sim/host/vectors/aes_rx.txt  # AES on Verilator
make run PROG=aes RX=sim/host/vectors/aes_rx.txt TARGET=host   # same on the PC, compared
make test                                         # regression (~30 s)
```

Expected end of the two `run` commands:
```
[TB] program finished (all UART input read, waiting for more): 32 UART bytes sent after 533293 cycles
...
PASS 32 bytes identical
MATCH
```

---

## 4. The top-level command

```
make <build|run|wave|spike|view> PROG=<app> [SPX=128f|128s] [RNG=det|hw] [TARGET=wasp|host] [knobs]
```

### Actions

| Action | `TARGET=wasp` (default) | `TARGET=host` |
|---|---|---|
| `build` | cross-compile, copy `imem.mem`, `dmem.mem`, `main.elf`, `dump.txt` to `sim/active_test/` | gcc build → `sw/build/host/<prog>/main` |
| `run` | build + **fast** Verilator model (no waveform) | build + run on the PC, output compared with the last Verilator run |
| `wave` | build + Verilator with an **FST waveform** + per-instruction trace | – (error) |
| `spike` | build + same ELF on Spike (instruction-set reference) | – (error) |
| `view` | open `sim/active_test/wave.fst` in Surfer (`VIEWER=gtkwave`) | |
| `test` / `test-spx` | regression, see §6 | |
| `clean` | remove all builds, Verilator models, `active_test` outputs | |

Leave `PROG` out of `run`/`wave`/`spike` to re-run whatever is already in
`sim/active_test/` without rebuilding.

### Variables

| Variable | Values | Meaning |
|---|---|---|
| `PROG` | `aes`, `sphincs`, `counters` | which `sw/apps/<prog>/main.c` |
| `TARGET` | `wasp` (default), `host` | RISC-V image (Verilator + FPGA) or PC build |
| `SPX` | `128s` (default), `128f` | SPHINCS+ parameter set (f = fast signing, big signature; s = small signature, slow signing) |
| `RNG` | `det` (default), `hw` | random numbers, see §5 |
| `RX` | `file.txt` or `file.bin` | UART input. `.txt` = editable command list (§7), anything else = raw bytes |
| `MAX_CYCLES` | default `1000000` | safety limit; Verilator stops earlier by itself (§8) |
| `TX_BYTES` | number | stop after the UART has sent this many bytes |
| `EOT=1` | | stop when the program sends `0x04` (counters does) |
| `PLIC_IRQ_AT` | cycle | pulse PLIC source 2 (the board button) at this cycle |
| `WAVE_START` | cycle | `wave` only: start dumping at this cycle (long runs) |
| `ARGS` | plusargs | anything else for the testbench, e.g. `ARGS=+no_auto_stop` |

### Outputs (all in `sim/active_test/`)

| File | Written by | Content |
|---|---|---|
| `uart_rx.bin` | `run`/`wave` | the binary UART input the program got |
| `uart_tx.bin` | Verilator / Spike | everything the program sent over the UART |
| `host_tx.bin` | `TARGET=host` | the same, from the PC build |
| `sim.log` | Verilator | testbench messages (`[TB] ...`) |
| `wave.fst` | `wave` | waveform (~3–4 MB per 100 k cycles!) |
| `cpu_trace.log` | `wave` | one line per committed instruction |
| `main.elf`, `dump.txt` | `build` | program + disassembly |

UART output is **binary** (keys, signatures, cycle counts), so it is written to
files instead of the console. Look at it with `xxd sim/active_test/uart_tx.bin | less`.

---

## 5. Same results everywhere, real randomness only on the FPGA

SPHINCS+ needs random bytes (key generation, signing). Two implementations
of `randombytes()` exist, picked with `RNG=`:

| `RNG=` | File | Source | Use |
|---|---|---|---|
| `det` (default) | `sw/rng/randombytes_det.c` | fixed-seed SHAKE256, **not random** | Verilator, PC, FPGA debugging: identical bytes on all three |
| `hw` | `sw/rng/randombytes_hw.c` | `mcycle` jitter at every received UART byte, SHAKE256-conditioned | FPGA when you need real keys |

`RNG=hw` builds go to their own folder (`sw/build/wasp/sphincs_128f_hwrng/`)
so they cannot be mixed up with simulation images. The PC build refuses
`RNG=hw` (a PC has no `mcycle`).

Other differences of the PC build (`sw/hal/host/`): cycle/instret counters
read 0 (the compare skips those fields), the CLINT clock check reports
`CPU_CLK_HZ` (50 MHz), interrupts do not exist (the AES trap handler is
compiled only for the RISC-V target, `#ifndef WASP_HOST`), and the program
ends when stdin ends.

---

## 6. Verifying

### 6.1 Regression

```sh
make test       # AES, PLIC IRQ, counters                      ~30 s
make test-spx   # + SPHINCS+-128f "lite" (verify only)        ~17 min
```

What each test checks:

| Test | Input | Pass condition |
|---|---|---|
| AES | 16 B vector + 1 KB fresh random data | Verilator output == PC build output, all 1040 bytes |
| PLIC IRQ | button IRQ at cycle 20 000, no UART input | trap handler's 16 bytes == PC build encrypting DEADBEEF×4 |
| counters | – | firmware self-test prints `ALL PASS` (CSRs, CLINT timer/soft IRQ, PLIC regs, IMEM data reads, D-cache flush, IRQ stress, access faults via trap.h, FENCE.I with generated code, x/0) |
| SPHINCS+ lite | info, Keccak bench, NIST KAT #0 verify, bit-flipped signature | decoded by `spx_lite.py` (SHAKE256 vs Python `hashlib`, KAT verifies, flipped one rejected) **and** Verilator == PC build (cycle fields skipped) |

Expected last line: `REGRESSION PASS`. Reference numbers (128f, 50 MHz):
16 Keccak-f ≈ 1.21 M cycles (CPI 3.15), KAT verify ≈ 469 M cycles (9.4 s).

### 6.2 Your own run: Verilator vs PC

```sh
make run PROG=sphincs SPX=128f RX=rx.txt MAX_CYCLES=12000000000   # Verilator
make run PROG=sphincs SPX=128f RX=rx.txt TARGET=host              # PC + compare
```

The second command prints `MATCH`/`MISMATCH`. Run Verilator first: the
compare uses the `uart_tx.bin` the last Verilator run left. If Verilator was
stopped early (`MAX_CYCLES`) the compare says so and checks only the bytes
both have:
```
NOTE RTL run stopped early: 29 of 17259 B (raise MAX_CYCLES / TX_BYTES); comparing the first 29 B
MATCH (first 29 of 17259 B)
```
Manual compare: `python3 sim/host/uart_cmp.py <aes|sphincs> [--spx 128f] rtl_tx.bin host_tx.bin`.

### 6.3 Against the official NIST test vectors

The PC build can reproduce NIST KAT signatures bit-exact: `Q` (keygen from a
seed) + `D` (sign with a given optrand). `sim/host/spx_kat.c` (needs OpenSSL)
checks the library against `sim/host/nist/<set>/PQCsignKAT_64.rsp` and writes
the matching UART inputs:

```sh
L=sw/lib/sphincs; SET=128f
gcc -O2 -I$L/params/$SET -I$L -o spx_kat sim/host/spx_kat.c sim/host/nist/rng.c \
    $L/address.c $L/wots.c $L/utils.c $L/fors.c $L/sign.c $L/hash_shake256.c \
    $L/thash_shake256_simple.c $L/fips202.c -lcrypto
mkdir -p kat && ./spx_kat sim/host/nist/$SET/PQCsignKAT_64.rsp 0 -w kat
#   kat/sign_rx.bin    Q seed + D optrand msg     kat/expect_pk.bin  kat/expect_sig.bin
make run PROG=sphincs SPX=$SET RX=kat/sign_rx.bin TARGET=host
```
`host_tx.bin` then contains the KAT public key and signature (checked for 128f and 128s).

### 6.4 Debugging with waveforms

```sh
make wave PROG=aes RX=sim/host/vectors/aes_rx.txt
make view
```
For long programs dump only a window: `make wave PROG=sphincs SPX=128f RX=rx.txt
WAVE_START=1000000 MAX_CYCLES=1200000`. A full SPHINCS+ run would be tens of GB.
`sim/active_test/cpu_trace.log` lists every committed instruction;
`make spike PROG=...` gives the reference trace (`spike_trace.log`) to diff against.

### 6.5 ISA compliance: riscv-tests

```sh
make riscv-tests                              # rv32ui / rv32um / rv32mi + WASP directed tests, ~15 s
make -C sim/riscv-tests T=rv32ui-add          # one test
make -C sim/riscv-tests compare T=rv32ui-add  # first instruction where RTL and Spike differ
```
The unmodified upstream tests run on the Verilator model with a WASP
environment (`sim/riscv-tests/env/wasp/`: code in IMEM, `tohost` = first word
of DMEM). A test passes only if it reports pass via `tohost` **and** every
register write matches Spike running the same ELF. Expected last line:
`RISCV-TESTS PASS` (70 tests, 2 waived by design). Results, waivers and the
bugs this found: `docs/riscv_tests.md`.

### 6.6 Random tests (riscv-dv) and coverage matrix

```sh
make -C sim/riscv-dv setup   # once: riscv-dv, UVM, Verilator fork, z3
make riscv-dv                # 9 configs x 5 seeds, RTL vs Spike lock-step
make coverage                # after both flows -> docs/coverage_matrix.md
```
Expected: `45 tests: 45 PASS`. Details: `docs/riscv_dv.md`. The coverage matrix
lists, per suite / config, how often each instruction, branch outcome, memory
access size/alignment, forwarding distance, CSR, trap cause and interrupt was
exercised by passing tests, and flags rows nothing exercises.

---

## 7. UART input files (`rx.txt`)

Edit `rx.txt` (or any `.txt`) and pass it as `RX=`; it is converted to binary
automatically (`sim/host/rxgen.py`). One command per line, `#` = comment:

```
I                   # info: clock, key/signature sizes, entropy events
B                   # Keccak benchmark (16 x SHAKE256)
K                   # key pair from the RNG
P                   # send the public key
S "hello wasp"      # sign, then the device verifies its own signature
Q <48-byte seed>    # key pair from a seed
D <16-byte optrand> "msg"        # deterministic sign
V <32-byte pk> "msg" @sig.bin    # verify
raw 00112233...     # bytes exactly as written (AES: every 16 bytes = 1 block)
```
Values: `"text"`, hex (`0011aabb`), or `@file`. Message lengths are added
automatically. The SPHINCS+ protocol (requests and replies) is documented at
the top of `sw/apps/sphincs/main.c`.

---

## 8. When does a simulation stop?

The firmware never exits; it loops waiting for the next UART command. The
testbench (`sim/tb_sim.sv`) stops on the first of:

1. **Program finished** (default): all of `uart_rx.bin` was read and the
   program sits in its UART receive loop asking for more. Long computations
   (SPHINCS+ sign: ~11 G cycles without UART traffic) are not affected.
   Off with `ARGS=+no_auto_stop`; automatically off when `PLIC_IRQ_AT` is set
   (that test idles on empty input until the IRQ, use `TX_BYTES=16`).
2. `TX_BYTES=n` bytes sent.
3. `EOT=1` and the program sent `0x04`.
4. `MAX_CYCLES` reached (safety limit, default 1 M). Raise it for long runs.

Simulation speed: fast model ≈ 1 M cycles/s; the waveform model is much slower.

| SPHINCS+ operation | 128f cycles | 128f @ 50 MHz | Verilator time |
|---|---|---|---|
| keygen `K` | 448 M | 9.0 s | ~8 min |
| sign `S` | 11.14 G | 3.7 min | ~3 h |
| verify `V` | 469 M | 9.4 s | ~8 min |

128s: keygen ~10 min, sign ~73 min at 50 MHz (estimates), verify 4.2 s.

---

## 9. Running on the FPGA

1. Build the image (simulation-identical `RNG=det`, or real randomness `RNG=hw`):
   ```sh
   make -C sw PROG=sphincs SPX=128f RNG=hw
   ```
2. Copy the memory images over the ones the bitstream uses:
   ```sh
   cp sw/build/wasp/sphincs_128f_hwrng/imem.mem sw/build/wasp/sphincs_128f_hwrng/dmem.mem RTL/
   ```
   (`RTL/imem.mem` → instruction BRAM `icache_test_ins_mem`, `RTL/dmem.mem` →
   data BRAM `dcache_test_data_mem`.)
3. Re-run synthesis/implementation in Vivado and program the board.
4. Talk to it over the serial port (115200 8N1, needs `pip install pyserial`):
   ```sh
   python sw/tools/sphincs_host.py -p /dev/ttyUSB0 info
   python sw/tools/sphincs_host.py -p /dev/ttyUSB0 keygen
   python sw/tools/sphincs_host.py -p /dev/ttyUSB0 sign msg.txt -o msg.sig
   python sw/tools/sphincs_host.py -p /dev/ttyUSB0 verify msg.txt msg.sig --pk pk.bin
   ```
   `CPU_CLK_HZ` (default 50 MHz, `make ... CPU_CLK_HZ=...`) must match the
   bitstream; the app reports error `3` otherwise.

---

## 10. How the Makefiles fit together

```
Makefile (top)                     decides TARGET, converts RX=*.txt, dispatches
 ├─ TARGET=wasp ─► sim/Makefile    load  → make -C sw TARGET=wasp ..., copy images to active_test/
 │                                 run   → obj_fast/Vtb_sim (Verilator, quiet)
 │                                 wave  → obj_wave/Vtb_sim (Verilator, FST + trace)
 │                                 spike → spike + obj_spike/libwasp_periph.so
 └─ TARGET=host ─► sw/Makefile     TARGET=host → sw/build/host/<prog>/main
                                   then: main < uart_rx.bin > host_tx.bin ; uart_cmp.py
sw/Makefile                        PROG → sources, TARGET → hal/wasp or hal/host,
                                   RNG → rng/randombytes_<RNG>.c, SPX → lib/sphincs/params/<SPX>
sim/regress.sh                     make test / test-spx: builds both targets, runs, compares
```

* The Verilator models are rebuilt automatically when any RTL or sim file
  changes (`sim/Makefile` depends on all of `RTL/*.sv|v`).
* Software is rebuilt when any source, header or the Makefile changes.
* The top-level Makefile passes all variables down to the sub-makes, so the
  same `PROG=... SPX=... RNG=...` works at every level.
* Software only, no simulation: `make -C sw PROG=<app> [TARGET=...] [SPX=...] [RNG=...]`.
* Verilator models only: `make -C sim fast` (quiet), `make -C sim wave-build`, `make -C sim` (with trace).

### Adding a new program

1. `sw/apps/<name>/main.c`, using the APIs in `sw/hal/include/`.
2. Add a block to `sw/Makefile`:
   ```make
   ifeq ($(PROG),<name>)
     SRCS = apps/<name>/main.c
     OPT  = -O2
   endif
   ```
3. Keep hardware-only code (raw CSRs, trap handlers, MMIO registers) inside
   `#ifndef WASP_HOST` so the PC build still compiles.
4. `make run PROG=<name> RX=...` and `make run PROG=<name> RX=... TARGET=host`.

---

## 11. Memory map (short)

| Address | Size | |
|---|---|---|
| `0x4000_0000` | 64 KB | IMEM (boot, code) |
| `0x8000_0000` | 64 KB | DMEM (data, stack; only D-cacheable range) |
| `0xC000_0000` | 4 KB | UART16550 |
| `0xC000_1000` | 4 KB | CLINT (compact layout) |
| `0xC000_2000` | 4 KB | PLIC (compact layout) |
| `0xC000_3000` | 4 KB | D-cache flush register |

Everything else, a store to IMEM, a read of the flush register or an access to
an empty spare slot is a precise access fault (mcause 5/7, mtval = address);
fetching outside IMEM/DMEM is an instruction access fault (1). Firmware can
catch them with `sw/hal/include/trap.h`; code written to DMEM runs after
`icache_sync()` (FENCE.I, `cache.h`).

Details: `docs/memory_map.md`. Keep `RTL/System_top.sv`,
`sw/hal/include/memmap.h` and `sw/hal/wasp/linksc.ld` in sync.

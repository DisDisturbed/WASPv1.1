#!/bin/sh
# Regression on the Verilator model of system_top. Every app is also built
# for the PC (sw/ TARGET=host) and run on the same UART input; RTL and host
# output must match (sim/host/uart_cmp.py; hardware cycle counters skipped).
#   sim/regress.sh          AES (16 B KAT + 1 KB random), PLIC IRQ, counters/CLINT/memmap
#   sim/regress.sh spx      + SPHINCS+-128f lite (KAT verify, ~17 min)
# Needs: verilator, gcc, python3, a riscv32/64 bare-metal GCC (see sw/Makefile).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
sw="$root/sw"
t="$here/work/regress"
mkdir -p "$t"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

make -s -C "$here" fast
for p in aes counters; do make -s -C "$sw" TARGET=wasp PROG=$p >/dev/null; done
make -s -C "$sw" TARGET=host PROG=aes >/dev/null
export SIM=obj_fast

# AES: RTL output == host build of the same apps/aes/main.c
cp "$here/host/vectors/aes_rx.bin" "$t/aes_rx.bin"
head -c 1024 /dev/urandom >> "$t/aes_rx.bin"
"$sw/build/host/aes/main" < "$t/aes_rx.bin" > "$t/aes_host.bin"
TAG=regress RX="$t/aes_rx.bin" "$here/run.sh" aes +tx_bytes=1040 +max_cycles=100000000
python3 "$here/host/uart_cmp.py" aes "$here/work/aes-regress/uart_tx.bin" "$t/aes_host.bin" \
    && ok "AES (RTL == host)" || bad "AES (RTL == host)"

# PLIC: source 2 -> trap handler claims it and encrypts DEADBEEF x4.
# The host has no interrupts: feeding DEADBEEF x4 over its UART gives the
# same 16 bytes.
printf '\336\255\276\357\336\255\276\357\336\255\276\357\336\255\276\357' \
    | "$sw/build/host/aes/main" > "$t/irq_host.bin"
TAG=irq RX=/dev/null "$here/run.sh" aes +plic_irq_at=20000 +tx_bytes=16 +max_cycles=5000000
python3 "$here/host/uart_cmp.py" aes "$here/work/aes-irq/uart_tx.bin" "$t/irq_host.bin" \
    && ok "PLIC IRQ (RTL == host)" || bad "PLIC IRQ (RTL == host)"

# CSRs, CLINT, PLIC registers, IMEM data reads, D-cache flush (hardware
# self-test: no host build, the firmware grades itself)
TAG=regress "$here/run.sh" counters +eot +max_cycles=50000000
grep -aq "^ALL PASS" "$here/work/counters-regress/uart_tx.bin" && ok "counters" || {
    grep -a "^FAIL" "$here/work/counters-regress/uart_tx.bin" || true; bad "counters"; }

if [ "$1" = spx ]; then
    make -s -C "$sw" TARGET=wasp PROG=sphincs SPX=128f >/dev/null
    make -s -C "$sw" TARGET=host PROG=sphincs SPX=128f >/dev/null
    python3 "$here/host/spx_lite.py" gen "$t/spx_rx.bin"
    "$sw/build/host/sphincs_128f/main" < "$t/spx_rx.bin" > "$t/spx_host.bin"
    TAG=regress RX="$t/spx_rx.bin" "$here/run.sh" sphincs_128f +tx_bytes=100 +max_cycles=3000000000
    python3 "$here/host/spx_lite.py" check "$here/work/sphincs_128f-regress/uart_tx.bin" \
        && ok "SPHINCS+ lite" || bad "SPHINCS+ lite"
    python3 "$here/host/uart_cmp.py" sphincs --spx 128f \
        "$here/work/sphincs_128f-regress/uart_tx.bin" "$t/spx_host.bin" \
        && ok "SPHINCS+ lite (RTL == host)" || bad "SPHINCS+ lite (RTL == host)"
fi

[ $fail -eq 0 ] && echo "REGRESSION PASS" || { echo "REGRESSION FAILED"; exit 1; }

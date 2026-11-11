#!/bin/sh
# Run one firmware image on the Verilator model of system_top.
#   sim/run.sh <prog> [extra plusargs...]
# Uses sw/build/wasp/<prog>/{imem,dmem}.mem and works in sim/work/<prog>[-<TAG>]/.
# Environment knobs:
#   SIM=obj_fast   use the quiet model (make -C sim fast), default obj_dir
#   TAG=<name>     separate work dir, so several runs can go in parallel
#   RX=<file>      UART input (copied to uart_rx.bin); default: keep/empty
# UART output lands in <workdir>/uart_tx.bin, console in sim.log.
set -e
here=$(cd "$(dirname "$0")" && pwd)
prog=$1; shift
sim=${SIM:-obj_dir}
w="$here/work/$prog${TAG:+-$TAG}"
mkdir -p "$w"
cp "$here/../sw/build/wasp/$prog/imem.mem" "$here/../sw/build/wasp/$prog/dmem.mem" "$w/"
if [ -n "$RX" ]; then cp "$RX" "$w/uart_rx.bin"; fi
[ -f "$w/uart_rx.bin" ] || : > "$w/uart_rx.bin"
cd "$w"
start=$(date +%s)
"$here/$sim/Vtb_sim" "$@" > sim.log 2>&1 || true
echo "[$prog${TAG:+-$TAG}] wall $(( $(date +%s) - start )) s"
grep -E "^\[TB\]|Error|FATAL" sim.log || true

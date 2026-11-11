#!/bin/sh
# Run a command inside the MSYS2 UCRT64 environment (verilator, gcc, make).
# usage: sim/msys.sh "<command>"   (cwd is preserved)
M="${LOCALAPPDATA:-/c/Users/$USERNAME/AppData/Local}/msys64"
MSYSTEM=UCRT64 CHERE_INVOKING=1 "$M/usr/bin/bash.exe" -lc "cd '$PWD' && $*"

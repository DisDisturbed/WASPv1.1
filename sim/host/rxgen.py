#!/usr/bin/env python3
"""Turn an editable text file into the binary UART input (uart_rx.bin).

    rxgen.py <in.txt> <out.bin>

`make run/wave/spike RX=<file>.txt` calls this automatically.

One command per line, '#' starts a comment. Values:
    "text"          ASCII bytes (\\n, \\x41 escapes work)
    0011aabb        hex bytes (spaces inside a value are not allowed)
    @path           bytes of a file (path relative to the .txt file)

SPHINCS+ commands (protocol: sw/apps/sphincs/main.c). Message lengths are
added for you:
    I                           info
    B                           Keccak benchmark
    P                           print the public key
    K                           keygen from the RNG (RNG=det: fixed seed)
    Q <seed 48 B>               keygen from a seed
    S <msg>                     sign msg, then verify it on the device
    D <optrand 16 B> <msg>      sign with a given optrand (deterministic)
    V <pk 32 B> <msg> <sig>     verify a signature

Any app (AES: every 16 bytes are one block):
    raw <value> [<value> ...]   send the bytes exactly as given
"""
import ast
import os
import shlex
import struct
import sys


def value(tok, base):
    if tok.startswith("@"):
        with open(os.path.join(base, tok[1:]), "rb") as f:
            return f.read()
    if tok[:1] in "\"'":
        return ast.literal_eval(tok).encode("latin-1")
    try:
        return bytes.fromhex(tok)
    except ValueError:
        raise ValueError(f"not hex, \"text\" or @file: {tok}")


def need(name, data, n):
    if len(data) != n:
        raise ValueError(f"{name} must be {n} bytes, got {len(data)}")
    return data


def msg(data):
    return struct.pack("<I", len(data)) + data


def convert(path):
    base = os.path.dirname(os.path.abspath(path))
    out = b""
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            try:
                toks = shlex.split(line, comments=True, posix=False)
                if not toks:
                    continue
                cmd, args = toks[0], [value(t, base) for t in toks[1:]]
                n = {"I": 0, "B": 0, "P": 0, "K": 0, "Q": 1, "S": 1, "D": 2, "V": 3}
                if cmd == "raw":
                    out += b"".join(args)
                    continue
                if cmd not in n:
                    raise ValueError(f"unknown command {cmd!r}")
                if len(args) != n[cmd]:
                    raise ValueError(f"{cmd} takes {n[cmd]} value(s), got {len(args)}")
                if cmd == "Q":
                    out += b"Q" + need("seed", args[0], 48)
                elif cmd == "S":
                    out += b"S" + msg(args[0])
                elif cmd == "D":
                    out += b"D" + need("optrand", args[0], 16) + msg(args[1])
                elif cmd == "V":
                    out += b"V" + need("pk", args[0], 32) + msg(args[1]) + args[2]
                else:
                    out += cmd.encode()
            except (ValueError, OSError, SyntaxError) as e:
                sys.exit(f"{path}:{lineno}: {e}")
    return out


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = convert(sys.argv[1])
    with open(sys.argv[2], "wb") as f:
        f.write(data)
    print(f"[rx] {sys.argv[1]} -> {sys.argv[2]} ({len(data)} bytes)")

#!/usr/bin/env python3
"""Condense a decode.py text trace for reading: merge consecutive PHY table accesses into one line, drop MMIO reads.

Runs anywhere (workstation); offline analysis.
  condense.py wl-5g.txt <first-line> <last-line>
"""
import re
import sys

L = re.compile(r"^(PHY|RADIO) ([RW]) 0x([0-9a-f]+) (?:=|->) 0x([0-9a-f]+)")


def main(path, lo, hi):
    tab = None  # [line no, R/W, table, offset, [values]]
    hiw = None

    def flush():
        nonlocal tab
        if tab:
            ln, rw, t, o, vals = tab
            vs = " ".join(f"{v:x}" for v in vals[:16]) + (" …" if len(vals) > 16 else "")
            print(f"{ln:6d} TAB{rw} {t:2d}:{o:03x} x{len(vals)}  {vs}")
        tab = None

    for ln, line in enumerate(open(path), 1):
        if ln < lo:
            continue
        if ln > hi:
            break
        m = L.match(line)
        if not m:
            continue
        kind, rw, reg, val = m.group(1), m.group(2), int(m.group(3), 16), int(m.group(4), 16)
        if kind == "PHY" and reg == 0x72 and rw == "W":
            flush()
            tab = [ln, "?", val >> 10, val & 0x3FF, []]
            continue
        if kind == "PHY" and reg == 0x74 and rw == "W":
            hiw = val
            continue
        if kind == "PHY" and reg == 0x73 and tab:
            if tab[1] == "?":
                tab[1] = rw
            tab[4].append((hiw << 16 | val) if (hiw is not None and rw == "W") else val)
            hiw = None
            continue
        flush()
        print(f"{ln:6d} {kind[0]}{rw} {reg:04x} {val:04x}")
    flush()


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))

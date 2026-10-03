#!/usr/bin/env python3
"""Compare the hardware state (PHY / radio / PHY tables) of two decode.py outputs at a phase marker.

Runs anywhere (workstation); offline analysis.

Usage: regdiff.py wl.txt b43.txt [PHASE]     (default: linked)
       A file may be given as file@line: state up to that line (so two points of the
       same trace can be compared, e.g. before/after a 20/40 MHz switch).

State = last value read or written at each address up to the marker. MMIO is keyed by
BAR0 offset, SHM by routing:byte offset. PHY tables are reconstructed with the semantics
of b43's tables_phy_ht.c: writing 0x072 sets the address (table<<10 | offset), writing
0x074 latches the high 16 bits, and reading/writing 0x073 completes an access and
auto-increments the address. Counters and status registers add noise; filter by hand.
"""

import re
import sys

TADDR, TLO, THI = 0x072, 0x073, 0x074
LINE = re.compile(r"(PHY|RADIO) ([RW]) 0x([0-9a-f]+) (?:=|->) 0x([0-9a-f]+)")
MMIO = re.compile(r"MMIO ([RW]) w(\d) \+0x([0-9a-f]+) (?:=|->) 0x([0-9a-f]+)")
SHM = re.compile(r"SHM ([RW]) r(\d+):0x([0-9a-f]+)(\+hi)? w\d (?:=|->) 0x([0-9a-f]+)")


def snapshot(path, phase):
    st = {}
    ptr, hi = None, None
    path, _, stop = path.partition("@")
    for n, line in enumerate(open(path), 1):
        if stop and n > int(stop):
            break
        if line.startswith("== "):
            if stop:
                continue
            if line.split()[-1] == phase:
                break
            continue
        m = SHM.match(line)
        if m:
            st[("SHM", int(m.group(2)), int(m.group(3), 16) * 2 + (2 if m.group(4) else 0))] = int(m.group(5), 16)
            continue
        m = MMIO.match(line)
        if m:
            st[("MMIO", int(m.group(3), 16))] = int(m.group(4), 16)
            continue
        m = LINE.match(line)
        if not m:
            continue
        kind, op, a, v = m.group(1), m.group(2), int(m.group(3), 16), int(m.group(4), 16)
        if kind == "PHY" and a == TADDR and op == "W":
            ptr, hi = v, None
        elif kind == "PHY" and a == THI:
            hi = v
        elif kind == "PHY" and a == TLO and ptr is not None:
            val = v if hi is None else (hi << 16) | v
            st[("TAB", ptr >> 10, ptr & 0x3FF)] = val
            ptr, hi = ptr + 1, None
        else:
            st[(kind, a)] = v
    return st


def key_str(k):
    if k[0] == "TAB":
        return f"TAB {k[1]:3d}[{k[2]:3d}]"
    if k[0] == "SHM":
        return f"SHM r{k[1]}:0x{k[2]:04x}"
    return f"{k[0]:5s} 0x{k[1]:04x}"


def main():
    phase = sys.argv[3] if len(sys.argv) > 3 else "linked"
    a, b = snapshot(sys.argv[1], phase), snapshot(sys.argv[2], phase)
    only_a = sorted(k for k in a if k not in b)
    diff = sorted(k for k in a if k in b and a[k] != b[k])
    print(f"# {len(a)} vs {len(b)} addresses; {len(diff)} differ, {len(only_a)} touched only by the first")
    print("## Different values (first / second)")
    for k in diff:
        print(f"{key_str(k)}  0x{a[k]:x} / 0x{b[k]:x}")
    print("## Touched only by the first")
    for k in only_a:
        print(f"{key_str(k)}  0x{a[k]:x}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Extract per-channel 2059 radio register values from decode.py output and emit b43 channel table entries.

Runs anywhere (workstation); offline analysis of a decoded wl trace.

Usage: chantab.py wl-5g.txt [radio_2059.c]
  With radio_2059.c, compare the 2.4 GHz results field by field against b43's
  existing table (validates the extraction method).

Detection: on a channel switch wl first writes SHM shared word 0x0028 (b43's
B43_SHM_SH_CHAN; low 8 bits = channel number, 0x100 set for 5 GHz), then writes
the synthesizer / RX-TX registers in the order of b43_radio_2059_channel_setup(),
then PHY BW1..BW6 (0x1ce..0x1d3).
"""

import re
import sys
from collections import defaultdict

SYN = [0x16, 0x17, 0x22, 0x25, 0x27, 0x28, 0x29, 0x2C, 0x2D, 0x37, 0x41, 0x43, 0x47]
RXTX = [0x4A, 0x58, 0x5A, 0x6A, 0x6D, 0x6E, 0x92, 0x98]
CORES = [0x000, 0x400, 0x800]
BW = list(range(0x1CE, 0x1D4))


def chan_freq(ch, five):
    if not five:
        return 2484 if ch == 14 else 2407 + 5 * ch
    return 5000 + 5 * ch


def extract(path):
    seen = defaultdict(list)  # freq -> [entry tuple, ...]
    cur = None  # (ch, five)
    radio, phy = {}, {}
    for line in open(path):
        m = re.match(r"SHM W r1:0x0028 w2 = 0x([0-9a-f]+)", line)
        if m:
            v = int(m.group(1), 16)
            cur = (v & 0xFF, bool(v & 0x100))
            radio, phy = {}, {}
            continue
        if cur is None:
            continue
        m = re.match(r"RADIO W 0x([0-9a-f]+) = 0x([0-9a-f]+)", line)
        if m:
            radio.setdefault(int(m.group(1), 16), int(m.group(2), 16))
            continue
        m = re.match(r"PHY W 0x([0-9a-f]+) = 0x([0-9a-f]+)", line)
        if m:
            a = int(m.group(1), 16)
            if a in BW:
                phy[a] = int(m.group(2), 16)
            if a == BW[-1] and all(r in radio for r in SYN):
                rx = []
                for r in RXTX:
                    vals = {radio.get(c | r) for c in CORES}
                    if len(vals) != 1 or None in vals:
                        print(f"# ch{cur[0]}: rxtx 0x{r:02x} differs across the three cores {vals}", file=sys.stderr)
                    rx.append(radio.get(r))
                ent = tuple(radio[r] for r in SYN) + tuple(rx) + tuple(phy[b] for b in BW)
                seen[chan_freq(*cur)].append(ent)
                cur = None
    return seen


def parse_b43(path):
    src = open(path).read()
    tab = {}
    for m in re.finditer(r"\.freq\s*=\s*(\d+),\s*RADIOREGS\(([^)]*)\),\s*PHYREGS\(([^)]*)\)", src):
        vals = [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", m.group(2) + "," + m.group(3))]
        tab[int(m.group(1))] = tuple(vals)
    return tab


def fmt(freq, e):
    r = ", ".join(f"0x{v:02x}" for v in e[:21])
    r = re.sub(r"((?:0x[0-9a-f]{2}, ){8})", r"\1\n\t\t\t  ", r, count=2)
    p = ", ".join(f"0x{v:04x}" for v in e[21:])
    return f"\t{{\n\t\t.freq\t\t\t= {freq},\n\t\tRADIOREGS({r}),\n\t\tPHYREGS({p}),\n\t}},"


def main():
    seen = extract(sys.argv[1])
    b43 = parse_b43(sys.argv[2]) if len(sys.argv) > 2 else {}
    for freq in sorted(seen):
        variants = set(seen[freq])
        note = f"{len(seen[freq])}x" + ("" if len(variants) == 1 else f", {len(variants)} different values!")
        if freq in b43:
            e = seen[freq][0]
            diff = [i for i, (a, b) in enumerate(zip(e, b43[freq])) if a != b]
            print(f"# {freq} MHz {note}: " + ("matches b43" if not diff else f"differs from b43, fields {diff}"))
        else:
            print(f"# {freq} MHz {note}: new")
            print(fmt(freq, seen[freq][0]))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""List, per band, the values written to selected PHY table entries in a trace.

Runs anywhere (workstation); offline analysis.
The band is inferred from the version of the most recently written TX gain table
(table 26 offset 0xc0); the version -> band mapping comes from /tmp/gaintabs.json
(produced with tabdump.py).
  tabhist.py wl-5g.txt 0:008-00b 0:010-013 47:003-015
"""
import collections
import json
import re
import sys

L = re.compile(r"^PHY W 0x([0-9a-f]+) = 0x([0-9a-f]+)")
BAND = {"8e8b62": "5G", "0bca24": "2G"}


def main(path, specs):
    gt = json.load(open("/tmp/gaintabs.json"))
    first = {v[0]: h for h, v in gt.items()}
    want = {}
    for sp in specs:
        t, r = sp.split(":")
        lo, _, hi = r.partition("-")
        for o in range(int(lo, 16), int(hi or lo, 16) + 1):
            want[int(t) << 10 | o] = sp
    seen = collections.OrderedDict()
    addr = hi = None
    band = "?"
    for line in open(path):
        m = L.match(line)
        if not m:
            continue
        r, v = int(m.group(1), 16), int(m.group(2), 16)
        if r == 0x72:
            addr, hi = v, None
        elif r == 0x74:
            hi = v
        elif r == 0x73 and addr is not None:
            val = (hi << 16 | v) if hi is not None else v
            if addr == (26 << 10 | 0xC0):
                band = BAND.get(first.get(val), band)
            if addr in want:
                seen.setdefault((addr, band), collections.Counter())[val] += 1
            addr += 1
            hi = None
    for (a, b), c in sorted(seen.items()):
        print(f"tab{a >> 10}:{a & 0x3ff:03x} {b}  " + "  ".join(f"{v:x}×{n}" for v, n in c.most_common()))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])

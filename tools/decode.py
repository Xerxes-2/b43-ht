#!/usr/bin/env python3
"""Decode wl's register accesses captured with mmiotrace into b43 terms: PHY / radio / SHM reads and writes.

Runs anywhere (workstation); input is an mmiotrace log taken on the DUT.

Usage: decode.py wl-5g.mmio > wl-5g.txt

Only recognises the indirect-access registers b43 knows in the D11 core window
(BAR0 +0x000..0xfff); offsets match drivers/net/wireless/broadcom/b43/b43.h:
  0x3fc PHY_CONTROL  w32 write = addr | data<<16 (complete PHY write); w16 write = select address
  0x3fe PHY_DATA     read/write after a w16 address select above
  0x3d8 RADIO24_CONTROL / 0x3da RADIO24_DATA (the HT PHY's 2059 radio uses this pair)
  0x160 SHM_CONTROL = routing<<16 | offset; 0x164/0x166 SHM_DATA low/high half
Everything else is printed as-is as MMIO lines. Note: BAR0 core switching goes
through PCI config space (0x80), which mmiotrace cannot see, so +0x000..0xfff is
always interpreted as the D11 core.
"""

import sys

PHY_CTL, PHY_DATA = 0x3FC, 0x3FE
RADIO_CTL, RADIO_DATA = 0x3D8, 0x3DA
SHM_CTL, SHM_DATA, SHM_DATA_HI = 0x160, 0x164, 0x166


def main(path):
    base = None
    phy_addr = radio_addr = shm_ctl = None
    last = None  # fold consecutive repeated polling reads
    repeat = 0

    def emit(line):
        nonlocal last, repeat
        if line == last and line.startswith(("PHY R", "RADIO R", "MMIO R")):
            repeat += 1
            return
        if repeat:
            print(f"  (x{repeat + 1})")
        repeat = 0
        last = line
        print(line)

    for raw in open(path):
        f = raw.split()
        if not f:
            continue
        if f[0] == "MAP" and base is None:
            base = int(f[3], 16)
            continue
        if f[0] == "MARK":
            emit("== " + " ".join(f[2:]))
            continue
        if f[0] not in ("R", "W") or base is None:
            continue
        op, width, val = f[0], int(f[1]), int(f[5], 16)
        off = int(f[4], 16) - base

        if off == PHY_CTL and op == "W" and width == 4:
            emit(f"PHY W 0x{val & 0xFFFF:04x} = 0x{val >> 16:04x}")
        elif off == PHY_CTL and op == "W" and width == 2:
            phy_addr = val
        elif off == PHY_DATA and phy_addr is not None:
            emit(f"PHY {op} 0x{phy_addr:04x} {'=' if op == 'W' else '->'} 0x{val:04x}")
        elif off == RADIO_CTL and op == "W":
            radio_addr = val
        elif off == RADIO_DATA and radio_addr is not None:
            emit(f"RADIO {op} 0x{radio_addr:04x} {'=' if op == 'W' else '->'} 0x{val:04x}")
        elif off == SHM_CTL and op == "W" and width == 4:
            shm_ctl = val
        elif off in (SHM_DATA, SHM_DATA_HI) and shm_ctl is not None:
            routing, word = shm_ctl >> 16, shm_ctl & 0xFFFF
            half = "+hi" if off == SHM_DATA_HI else ""
            emit(f"SHM {op} r{routing}:0x{word:04x}{half} w{width} {'=' if op == 'W' else '->'} 0x{val:x}")
        else:
            emit(f"MMIO {op} w{width} +0x{off:04x} {'=' if op == 'W' else '->'} 0x{val:x}")
    if repeat:
        print(f"  (x{repeat + 1})")


if __name__ == "__main__":
    main(sys.argv[1])

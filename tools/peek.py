#!/usr/bin/env python3
"""Read/write the BCM4331 BAR0 (D11 core window) via /dev/mem, bypassing the driver. Works while wl is loaded too.

Runs on the DUT as root. Standalone: copy it over (e.g. to /tmp/peek.py, as try.sh expects).
Needs the kernel parameter iomem=relaxed. BAR0 is the physical address of the
card's BAR0 (default 0xa0600000; override with BAR0=0x... from lspci -v).
BAR0 core switching uses PCI config space 0x80, which is left alone here, so
reads hit whatever core the driver has selected (normally D11).

  peek.py r16 0x688 [0x69c ...]        read 16 bits
  peek.py w16 0x688 0x1f07             write 16 bits (dangerous, experiments only)
  peek.py ifs                          print the IFS register bank: for IFSCTL selector 0..3 read
                                       0x680-0x69e, then restore the original value
  peek.py banks                        read 0x680/682/684/69c for selectors 0..3, restore selector
  peek.py wlinit [aifsn]               write AIFSN to all four slots in wl's order (default 2),
                                       restore selector
  peek.py phyr 0x424 [...]             read PHY registers indirectly via 0x3fc/0x3fe
  peek.py phyw 0x424 0x158 [...]       write PHY registers indirectly (races the driver; experiments only)
  peek.py tabr 27 0 64                 read a PHY table (16-bit; races the driver)
  peek.py dump > x.txt                 scan all PHY/radio registers
  peek.py rate [addr] [n]              counter increments per second (sampled every 50 ms, handles 16-bit wrap)
  peek.py watch 0x692 [seconds]        read every 0.1 s to watch a counter move
"""

import mmap
import os
import struct
import sys
import time

BAR0 = int(os.environ.get("BAR0", "0xa0600000"), 16)
SIZE = 0x4000
IFS = [0x680, 0x682, 0x684, 0x686, 0x688, 0x68A, 0x68C, 0x68E, 0x690,
       0x692, 0x694, 0x696, 0x698, 0x69A, 0x69C, 0x69E]


def open_bar():
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    return mmap.mmap(fd, SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BAR0)


def r16(m, a):
    return struct.unpack_from("<H", m, a)[0]


def w16(m, a, v):
    struct.pack_into("<H", m, a, v)


def main():
    m = open_bar()
    cmd, args = sys.argv[1], [int(x, 0) for x in sys.argv[2:]]
    if cmd == "r16":
        print(" ".join(f"0x{a:03x}=0x{r16(m, a):04x}" for a in args))
    elif cmd == "w16":
        w16(m, args[0], args[1])
        print(f"0x{args[0]:03x}=0x{r16(m, args[0]):04x}")
    elif cmd == "ifs":
        orig = r16(m, 0x688)
        print("sel    " + " ".join(f"{a:03x} " for a in IFS))
        for sel in range(4):
            w16(m, 0x688, (orig & ~0x3000) | (sel << 12))
            print(f"{sel}      " + " ".join(f"{r16(m, a):04x}" for a in IFS))
        w16(m, 0x688, orig)
        print(f"restored 0x688=0x{r16(m, 0x688):04x}")
    elif cmd == "banks":
        orig = r16(m, 0x688)
        for sel in range(4):
            w16(m, 0x688, (orig & ~0x3000) | (sel << 12))
            print(sel, " ".join(f"{a:03x}={r16(m, a):04x}" for a in (0x680, 0x682, 0x684, 0x69C)))
        w16(m, 0x688, orig)
    elif cmd == "wlinit":
        aifsn = args[0] if args else 2
        orig = r16(m, 0x688)
        for sel in range(4):
            w16(m, 0x688, (orig & ~0x3000) | (sel << 12))
            w16(m, 0x69C, aifsn)
        w16(m, 0x688, orig)
        print(f"0x688=0x{r16(m, 0x688):04x} 0x69c=0x{r16(m, 0x69C):04x}")
    elif cmd == "phyr":
        out = []
        for a in args:
            w16(m, 0x3FC, a)
            out.append(f"p{a:03x}=0x{r16(m, 0x3FE):04x}")
        print(" ".join(out))
    elif cmd == "phyw":
        # phyw addr val [addr val ...]; races the driver's own PHY accesses, experiments only
        for a, v in zip(args[::2], args[1::2]):
            w16(m, 0x3FC, a)
            w16(m, 0x3FE, v)
        print("ok")
    elif cmd == "tabr":
        # tabr table offset count: read 16-bit entries via 0x72/0x73 (offset auto-increments after reading 0x73)
        t, off, n = args[0], args[1], (args[2] if len(args) > 2 else 1)
        w16(m, 0x3FC, 0x72)
        w16(m, 0x3FE, (t << 10) | off)
        out = []
        for _ in range(n):
            w16(m, 0x3FC, 0x73)
            out.append(r16(m, 0x3FE))
        print(" ".join(f"{v:04x}" for v in out))
    elif cmd == "dump":
        # scan all of PHY (0x000-0xfff) and radio (0x000-0xfff), skipping the table access ports (side effects)
        skip = {0x72, 0x73, 0x74}
        for a in range(0x1000):
            if a in skip:
                continue
            w16(m, 0x3FC, a)
            print(f"PHY {a:04x} {r16(m, 0x3FE):04x}")
        for a in range(0x1000):
            w16(m, 0x3D8, a | 0x200)
            print(f"RADIO {a:04x} {r16(m, 0x3DA):04x}")
    elif cmd == "rate":
        # per-second increment of a 16-bit counter (handles wrap); default 0x692 = channel busy
        a = args[0] if args else 0x692
        n = args[1] if len(args) > 1 else 20
        tot, prev = 0, r16(m, a)
        for _ in range(n):
            time.sleep(0.05)
            cur = r16(m, a)
            tot += (cur - prev) & 0xFFFF
            prev = cur
        print(f"0x{a:03x} +{tot / (n * 0.05):.0f}/s")
    elif cmd == "watch":
        a, secs = args[0], (args[1] if len(args) > 1 else 2)
        for _ in range(int(secs * 10)):
            print(f"0x{r16(m, a):04x}", end=" ", flush=True)
            time.sleep(0.1)
        print()


if __name__ == "__main__":
    main()

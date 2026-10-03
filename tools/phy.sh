#!/usr/bin/env bash
# Runs on the DUT (root, b43 loaded, debugfs mounted). Standalone: copy it over.
# Indirect PHY/radio register access through b43's debugfs mmio16 interface
# (does not need iomem=relaxed).
#   phy.sh r 0x1e7 0x222 ...      read PHY registers
#   phy.sh w 0x1e7 0x20 ...       write PHY registers (addr value pairs)
#   phy.sh rr 0x159 ...           read radio registers (0x3d8/0x3da; reads OR in 0x200)
#   phy.sh rw 0x159 0x11 ...      write radio registers
#   phy.sh tr 47 0x0 22 [32]      read PHY table (table offset count [width])
# Races with the driver's own PHY accesses; for experiments only.
set -eu
D=$(ls -d /sys/kernel/debug/b43/phy* | head -1)
mw() { echo "$1 0x0 $2" > "$D/mmio16write"; }
# Exactly one read(): every debugfs read() hits the hardware, and cat's second
# read() would auto-increment the table address once more.
mr() { echo "$1" > "$D/mmio16read"; dd if="$D/mmio16read" bs=64 count=1 status=none; }
cmd=$1; shift
case $cmd in
r)  for a; do mw 0x3fc "$a"; printf "%s=%s " "$a" "$(mr 0x3fe)"; done; echo ;;
w)  while [ $# -ge 2 ]; do mw 0x3fc "$1"; mw 0x3fe "$2"; shift 2; done ;;
rr) for a; do mw 0x3d8 "$(printf 0x%x $((a | 0x200)))"; printf "%s=%s " "$a" "$(mr 0x3da)"; done; echo ;;
rw) while [ $# -ge 2 ]; do mw 0x3d8 "$1"; mw 0x3da "$2"; shift 2; done ;;
tr) t=$1 o=$2 n=$3 wd=${4:-16}
    mw 0x3fc 0x72; mw 0x3fe "$(printf 0x%x $(( (t << 10) | o )))"
    for _ in $(seq "$n"); do
        mw 0x3fc 0x73; lo=$(mr 0x3fe)
        if [ "$wd" = 32 ]; then mw 0x3fc 0x74; printf "%x " $(( ($(mr 0x3fe) << 16) | lo )); else printf "%x " $((lo)); fi
    done; echo ;;
esac

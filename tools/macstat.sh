#!/usr/bin/env bash
# Dumps the microcode's MAC statistics (SHM 0xE0-0x11E, 32 words) in one line.
# Runs on the DUT (root, CONFIG_B43_DEBUG build). Fields (1-based, as in
# brcmsmac's struct macstat): 1 txallfrm, 8 txfunfl[BE] (TX FIFO underflow),
# 16 txphyerr.
D=$(ls -d /sys/kernel/debug/b43/phy* | head -1)
out=""
for o in $(seq $((0xE0)) 2 $((0xE0 + 0x3e))); do
  echo "0x1 $(printf 0x%x $o)" > "$D/shm16read"
  out+="$(dd if="$D/shm16read" bs=64 count=1 status=none | tr -d '\n') "
done
echo $out

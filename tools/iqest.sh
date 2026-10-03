#!/usr/bin/env bash
# Receiver I/Q imbalance estimate on live traffic, per core: iq/p1 and (p0-p1)/p1 in 1/1000.
# Runs on the DUT (root, CONFIG_B43_DEBUG build); needs phy.sh next to it.
# Usage: iqest.sh [N samples, default 5]
PHY="$(dirname "${BASH_SOURCE[0]}")/phy.sh"
rd(){ bash "$PHY" r $1 | sed 's/.*=//'; }
for n in $(seq 1 ${1:-5}); do
 bash "$PHY" w 0x12b 0x4000; bash "$PHY" w 0x12a 0x0020; bash "$PHY" w 0x129 0x0000; bash "$PHY" w 0x129 0x0001; sleep 0.05
 line=""
 for b in 0x12c 0x134 0x13a; do
  v=(); for o in 0 1 2 3 4 5; do v+=($(( $(rd $(printf 0x%x $((b+o)))) ))); done
  iq=$(( (v[1]<<16)|v[0] )); ((iq>=2**31)) && iq=$((iq-2**32)); p0=$(( (v[3]<<16)|v[2] )); p1=$(( (v[5]<<16)|v[4] ))
  line+=" $((iq*1000/(p1?p1:1)))/$(((p0-p1)*1000/(p1?p1:1)))"
 done; echo "$line"
done

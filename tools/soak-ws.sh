#!/usr/bin/env bash
# Runs on the workstation, companion to soak-mini.sh: pings the DUT's Wi-Fi
# address once per second, and every 10 minutes runs 30 s of TCP each way.
# Settings come from env.sh via air.sh; logs go to $OUT.
#   soak-ws.sh
. "$(dirname "${BASH_SOURCE[0]}")/air.sh"
OUT=${OUT:-.}
L=$OUT/soak-ws.log
ping -D -i 1 -W 1 $W > "$OUT/soak-ping.log" 2>&1 &
while :; do
  sleep 600
  a=$($P -c $W -t 30 2>/dev/null | awk '/receiver/{print $7}'); b=$($P -c $W -t 30 -R 2>/dev/null | awk '/receiver/{print $7}')
  echo "$(date +%T) TCP RX ${a:-FAIL} TCP TX ${b:-FAIL}" >> $L
done

#!/usr/bin/env bash
# Runs on the DUT (root). Standalone: copy it over; configure via environment.
# Pings the gateway every 20 ms while running a scan (3 rounds) and reports
# scan duration and packet loss.
#   GW=<gateway-ip> scanping.sh
I=$(ls /sys/class/ieee80211/*/device/net/ | head -1); GW=${GW:?set GW to the AP/gateway IP}
for n in 1 2 3; do
  ping -D -i 0.02 -W 0.5 -I $I $GW > /tmp/sp.txt 2>&1 & p=$!
  sleep 1; t0=$(date +%s.%N); iw dev $I scan >/dev/null 2>&1; t1=$(date +%s.%N); sleep 1; kill -INT $p; wait $p 2>/dev/null
  echo "$t0 $t1 $(grep -c 'bytes from' /tmp/sp.txt) $(tail -2 /tmp/sp.txt | head -1)" | awk '{printf "scan %.1fs  ", $2-$1; $1=$2=$3=""; print}'
done

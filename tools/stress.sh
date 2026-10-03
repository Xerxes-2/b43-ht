#!/usr/bin/env bash
# Runs on the DUT (root). Standalone: copy it over; configure via environment.
# b43 stability stress test: repeats an event N times and records, for each
# round, the time until the gateway is pingable again (plus freq/signal).
#   GW=<gateway-ip> [IF=wlp3s0b1] [CON=MyWiFi] stress.sh reconnect|linkflap|restart|scan [count]
#   GW=... BSSID5=<5GHz-bssid> BSSID2=<2.4GHz-bssid> stress.sh band [count]
I=${IF:-wlp3s0b1}; GW=${GW:?set GW to the AP/gateway IP}; N=${2:-10}
CON=${CON:-MyWiFi}
B5=${BSSID5:-}; B2=${BSSID2:-}
[ "$1" = band ] && { : "${BSSID5:?set BSSID5}" "${BSSID2:?set BSSID2}"; }
D=$(ls -d /sys/kernel/debug/b43/phy* 2>/dev/null | head -1)
up() { # wait until the gateway answers; print seconds, FAIL after 60 s
  local t0=$(date +%s.%N)
  for i in $(seq 600); do ping -c1 -W1 -I $I $GW >/dev/null 2>&1 && { echo "$(date +%s.%N) $t0" | awk '{printf "%.1f", $1-$2}'; return 0; }; sleep 0.1; done
  echo FAIL; return 1; }
freq() { iw dev $I link | awk '/freq/{printf "%s", $2} /signal/{printf "/%s", $2}'; }
bg_traffic() { ping -q -i 0.01 -s 1400 -I $I $GW >/dev/null 2>&1 & }
r=()
for n in $(seq $N); do
  case $1 in
    reconnect) nmcli con down "$CON" >/dev/null; nmcli con up "$CON" ifname $I >/dev/null 2>&1 & ;;
    linkflap)  bg_traffic; ip link set $I down; sleep 1; ip link set $I up ;;
    restart)   bg_traffic; echo 1 > $D/restart ;;
    band)      if [ $((n%2)) = 1 ]; then b=$B2; bd=bg; else b=$B5; bd=a; fi
               nmcli con modify "$CON" 802-11-wireless.bssid $b 802-11-wireless.band $bd
               nmcli con up "$CON" ifname $I >/dev/null 2>&1 & ;;
    scan)      bg_traffic; iw dev $I scan trigger >/dev/null 2>&1; sleep 4 ;;
  esac
  sleep 0.5; t=$(up); kill %1 %2 2>/dev/null; wait 2>/dev/null
  # NM may have given up: bring it back before continuing, so one failure doesn't spoil all later rounds
  [ "$t" = FAIL ] && { timeout 60 nmcli con up "$CON" ifname $I >/dev/null 2>&1; up >/dev/null; }
  r+=("$t@$(freq)"); case $t in 0.0|0.[0-9]|1.[0-9]) ;; *) echo "slow $t at $(cut -d" " -f1 /proc/uptime)";; esac
done
[ $1 = band ] && { nmcli con modify "$CON" 802-11-wireless.bssid "" 802-11-wireless.band a; nmcli con up "$CON" ifname $I >/dev/null 2>&1; }
echo "$1: ${r[*]}"

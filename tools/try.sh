#!/usr/bin/env bash
# Runs on the workstation: on the DUT, sets a group of registers with peek.py,
# measures UDP TX throughput (DUT -> workstation) and retries per packet, then
# restores the old values. Settings come from env.sh (see env.example.sh);
# H, W, IPERF, IF and NET can still be overridden from the environment.
#   try.sh <label> [addr=val ...]      e.g. try.sh aifsn1 0x69c=1
# Needs on the DUT: /tmp/peek.py, an iperf3 server on the Wi-Fi address, b43 loaded.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
H=${H:-$M}
IPERF=${IPERF:-$P}
label=$1
shift
remote() { ssh $O "$H" "sudo bash -c '$1'"; }
st() { remote "iw dev $IF station dump | awk \"/tx packets|tx retries/{print \\\$3}\" | paste -sd\" \""; }
saved=()
for kv in "$@"; do
  a=${kv%%=*}
  old=$(remote "python3 /tmp/peek.py r16 $a" | cut -d= -f2)
  saved+=("$a=$old")
  remote "python3 /tmp/peek.py w16 $a ${kv#*=}" >/dev/null
done
now=$(remote "python3 /tmp/peek.py r16 ${*%%=*} 2>/dev/null" 2>/dev/null || true)
# Reconnecting wipes the table 200 route; re-add it every time, otherwise replies go via Ethernet and the numbers are bogus
remote "ip route replace $NET dev $IF src $W table 200; ip rule show | grep -q \"from $W lookup 200\" || ip rule add from $W table 200"
read -r p0 r0 <<<"$(st)"
tx=$($IPERF -c "$W" -t 5 -R -u -b 40M | awk '/receiver/{print $7}')
read -r p1 r1 <<<"$(st)"
after=$(remote "python3 /tmp/peek.py r16 ${*%%=*} 2>/dev/null" 2>/dev/null || true)
for kv in "${saved[@]}"; do remote "python3 /tmp/peek.py w16 ${kv%%=*} ${kv#*=}" >/dev/null; done
# Packets sent should be ~40 Mbit/s * 5 s / 1470 B ~= 17000; far fewer means traffic didn't go over Wi-Fi or the link died
awk -v l="$label" -v t="$tx" -v p=$((p1 - p0)) -v r=$((r1 - r0)) -v n="$now" -v a="$after" \
  'BEGIN{printf "%-14s tx %5s Mbit/s  retry/pkt %.2f  pkts %6d | set: %s | after: %s\n", l, t, (p ? r / p : 0), p, n, a}'

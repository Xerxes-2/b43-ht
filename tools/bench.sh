#!/usr/bin/env bash
# Runs on the workstation: measures ping and TCP throughput in both directions
# by ssh-ing to the DUT over its Wi-Fi address, then prints iw station stats.
# Settings come from env.sh (see env.example.sh); the ssh user is taken from $M.
#   bench.sh [wifi-ip (default $W)] [MiB (default 40)]
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
A=${1:-$W}
case $M in *@*) T="${M%%@*}@$A" ;; *) T=$A ;; esac
N=${2:-40}
mbit() { awk -v n="$N" -v t="$1" 'BEGIN{printf "%.1f", n*8*1.048576/t}'; }
ping -q -c 50 -i 0.2 "$A" | tail -2 | tr '\n' ' '
echo
t0=$(date +%s.%N); ssh $O "$T" "head -c ${N}M /dev/zero" >/dev/null; t1=$(date +%s.%N)
echo "TX(mini->) $(mbit "$(echo "$t1 - $t0" | bc)") Mbit/s"
t0=$(date +%s.%N); head -c ${N}M /dev/zero | ssh $O "$T" 'cat >/dev/null'; t1=$(date +%s.%N)
echo "RX(->mini) $(mbit "$(echo "$t1 - $t0" | bc)") Mbit/s"
ssh $O "$T" bash -s <<'R'
IF=$(ls /sys/class/net | grep ^wl | head -1)
iw dev $IF station dump | grep -E "tx (packets|retries|failed)|bitrate|signal:" | tr -s '\t ' ' ' | paste -sd' '
R

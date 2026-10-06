#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Workstation regression for the BCM4331 non-BE TX blackhole.
# Requires an iperf3 server bound to DUT Wi-Fi and reachable SSH there.
# env.sh supplies M (wired SSH), W, IF, O and P. Optional SOURCE binds
# the workstation's wired IPv4 address; DURATION defaults to 5 seconds.
# Does not switch drivers or modify routing/firewall/sshd configuration.
set -euo pipefail
# Older private env.sh copies use unconditional assignments. Preserve
# caller overrides as documented, even when that local copy is stale.
declare -A overrides=()
for key in M W IF O P; do
	[[ ! -v $key ]] || overrides[$key]=${!key}
done
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
for key in "${!overrides[@]}"; do
	printf -v "$key" '%s' "${overrides[$key]}"
done
: "${M:?}" "${W:?}" "${IF:?}"
DURATION=${DURATION:-5}
[[ $DURATION =~ ^[1-9][0-9]*$ ]] || exit 2
bind_ssh=()
bind_iperf=()
if [[ -n ${SOURCE:-} ]]; then
	bind_ssh=(-b "$SOURCE")
	bind_iperf=(-B "$SOURCE")
fi
source_ip=${SOURCE:-$(ip -4 route get "$W" | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')}
# A stale source-policy rule with an empty table can silently fall back
# to Ethernet after NM reconnects. Reject that invalid test topology.
ssh $O "$M" bash -s -- "$source_ip" "$W" "$IF" <<'REMOTE'
set -eu
route=$(ip -4 route get "$1" from "$2")
case " $route " in
	*" dev $3 "*) ;;
	*) echo 'FAIL: DUT Wi-Fi replies would not use Wi-Fi' >&2; exit 1 ;;
esac
REMOTE
case $M in *@*) target="${M%%@*}@$W" ;; *) target=$W ;; esac
for n in 1 2 3; do
	# Client IPQoS cannot repair the server's EF classification. Keep
	# the server's normal policy so the actual SSH failure is tested.
	out=$(timeout 10 ssh $O "${bind_ssh[@]}" "$target" 'printf SSH_PASS')
	[[ $out == SSH_PASS ]] || { echo 'FAIL: SSH command' >&2; exit 1; }
	echo "SSH attempt=$n PASS"
done
json=$(mktemp)
trap 'rm -f "$json"' EXIT
# RFC 8325 default mapping: CS0 -> BE, CS1 -> BK, CS4 -> VI,
# EF -> VO (not VI). Custom AP QoS maps can override this mapping.
for spec in 'BE 0' 'BK 32' 'VI 128' 'VO 184'; do
	read -r label tos <<< "$spec"
	timeout "$((DURATION + 12))" "$P" -c "$W" "${bind_iperf[@]}" \
		-p "${PORT:-5201}" -S "$tos" -R -t "$DURATION" -J > "$json"
	python3 - "$label" "$json" <<'PY'
import json
import sys

label, path = sys.argv[1:]
with open(path) as stream:
    result = json.load(stream)
if result.get("error"):
    raise SystemExit(f"{label} FAIL: {result['error']}")
received = result["end"]["sum_received"]
if received["bytes"] <= 0:
    raise SystemExit(f"{label} FAIL: no payload received")
print(f"{label} PASS: {received['bits_per_second'] / 1e6:.1f} Mbps")
PY
done

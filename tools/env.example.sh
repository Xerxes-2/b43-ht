# Workstation-side settings for the helper scripts in this directory.
# Copy to env.sh (gitignored) and edit:  cp env.example.sh env.sh
# Each value is a default; a variable already set in the environment wins.
# Sourced by air.sh, bench.sh, soak-ws.sh (via air.sh) and try.sh; not needed by the
# scripts that run on the DUT (those take plain environment variables).
# GW, BSSID5, BSSID2 and CON are also what the DUT scripts expect; pass them
# along, e.g.  ssh $O $M "sudo GW=$GW CON=$CON ./stress.sh reconnect 10"
# All values below are placeholders (RFC 5737 / RFC 3849 / locally administered).

# ssh options used for every connection to the DUT (throwaway host keys, no prompts).
O="${O:--o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=8}"

# ssh target of the DUT, ideally over its wired port so it survives Wi-Fi
# outages. An IPv6 link-local address with a zone works too: user@<addr>%<wired-if>
M="${M:-user@2001:db8::2}"

# iperf3 binary on the workstation (an iperf3 server must run on the DUT's Wi-Fi address).
P="${P:-iperf3}"

# DUT Wi-Fi IPv4 address, AP/gateway IP, and the Wi-Fi subnet (used by try.sh's policy route).
W="${W:-192.0.2.10}"
GW="${GW:-192.0.2.1}"
NET="${NET:-192.0.2.0/24}"

# DUT Wi-Fi MAC address (frame filter for monitor-mode captures).
MAC="${MAC:-02:00:00:00:00:01}"

# AP BSSIDs for the 5 GHz and 2.4 GHz radios. GW and the BSSIDs are only used by
# DUT scripts; pass them along, e.g. ssh $O "$M" "sudo GW=$GW BSSID5=$BSSID5 ...".
BSSID5="${BSSID5:-02:00:00:00:00:05}"
BSSID2="${BSSID2:-02:00:00:00:00:02}"

# NetworkManager connection name (same name on workstation and DUT).
CON="${CON:-MyWiFi}"

# Workstation Wi-Fi interface that air.sh turns into a monitor interface.
MONIF="${MONIF:-wlan0}"

# b43 interface name on the DUT.
IF="${IF:-wlp3s0b1}"

# Directory for workstation-side logs (soak-ws.sh).
OUT="${OUT:-.}"

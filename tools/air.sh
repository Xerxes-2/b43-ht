# Over-the-air measurement helpers. Runs on the workstation; source it in bash.
# Assumes the workstation is online via Ethernet, the DUT's wired port is
# reachable from the workstation (ssh target $M), and the workstation's Wi-Fi
# card ($MONIF) is free to be used as a monitor. mon_on/mon_off need
# passwordless sudo for iw and ip. Settings come from env.sh (see env.example.sh).
#   . air.sh; mon_on ["<freq> HT20"]; sig <label> [seconds]; mon_off
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# Argument e.g. "2457 HT20"; an 80 MHz monitor barely decodes our 20 MHz HT frames.
mon_on(){ nmcli dev disconnect $MONIF >/dev/null 2>&1; sudo -n ip link set $MONIF down; sudo -n iw dev $MONIF set type monitor; sudo -n ip link set $MONIF up; sudo -n iw dev $MONIF set freq ${1:-5220 HT20}; }
mon_off(){ sudo -n ip link set $MONIF down; sudo -n iw dev $MONIF set type managed; sudo -n ip link set $MONIF up; sleep 3; nmcli dev wifi rescan >/dev/null 2>&1; sleep 4; nmcli con up "$CON" ifname $MONIF >/dev/null; }
# Capture frames sent by the DUT: median signal, decoded data frames, ACKs from the AP.
sig(){ timeout $((${2:-3}+2)) tcpdump -i $MONIF -s 120 -w /tmp/sig.pcap "wlan addr1 $MAC or wlan addr2 $MAC" 2>/dev/null & sleep 1
  x=$($P -c $W -t ${2:-3} -R -u -b 60M | awk '/receiver/{print $7}'); wait
  d=$(tshark -r /tmp/sig.pcap -Y "wlan.ta==$MAC && wlan.fc.type==2" -T fields -e radiotap.dbm_antsignal 2>/dev/null | sort -n)
  a=$(tshark -r /tmp/sig.pcap -Y "wlan.ra==$MAC && wlan.fc.type==1" 2>/dev/null | wc -l)
  n=$(echo "$d" | grep -c .); med=$(echo "$d" | sed -n "$(( (n+1)/2 ))p")
  echo "$1: ${x} Mbit/s  data frames $n  median signal ${med} dBm  ACK $a"; }

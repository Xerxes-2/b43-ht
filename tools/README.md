# tools

Helper scripts used while reverse-engineering and testing the patched b43
driver on a BCM4331 (Mac mini, the DUT). "Workstation" is the machine you
drive the tests from; "DUT" is the Mac mini running b43 (or wl).

| Tool | Runs on | Purpose |
|------|---------|---------|
| `env.example.sh` | workstation | Template for `env.sh`: ssh target, IPs, MACs, BSSIDs, interface names |
| `air.sh` | workstation (sourced) | Monitor-mode helpers: `mon_on`, `mon_off`, `sig` (iperf3 + capture of DUT frames, signal and ACK counts) |
| `bench.sh` | workstation | Ping and TCP throughput both ways over the DUT's Wi-Fi address, plus `iw` station stats |
| `try.sh` | workstation | Poke DUT registers with `peek.py`, measure UDP TX throughput and retries per packet, restore |
| `soak-ws.sh` | workstation | Soak test companion: 1 Hz ping plus 30 s TCP each way every 10 min |
| `swap.sh` | DUT (root) | Switch between b43 and wl (PCI remove/rescan), connect NM profile, add Wi-Fi policy route |
| `stress.sh` | DUT (root) | Stability stress: reconnect / link flap / restart / band switch / scan, time to recover |
| `scanping.sh` | DUT (root) | Ping the gateway every 20 ms during a scan; report scan time and loss |
| `soak-mini.sh` | DUT (root) | Soak logger: one line per minute of link, error, memory and reconnect stats |
| `phy.sh` | DUT (root) | Read/write PHY, radio and PHY table registers through b43 debugfs |
| `iqest.sh` | DUT (root) | Live RX I/Q imbalance estimate per core (uses `phy.sh` next to it) |
| `macstat.sh` | DUT (root) | One-line dump of the microcode MAC counters (SHM 0xE0..); field 8 = TX FIFO underflow, 16 = TX PHY error |
| `peek.py` | DUT (root) | Read/write BAR0 registers via `/dev/mem` (needs `iomem=relaxed`); works under wl too |
| `decode.py` | anywhere | Decode an mmiotrace of wl into PHY / radio / SHM accesses |
| `condense.py` | anywhere | Compact a decoded trace (merge PHY table runs, drop MMIO reads) |
| `regdiff.py` | anywhere | Diff hardware state of two decoded traces at a phase marker or line |
| `tabdump.py` | anywhere | Reconstruct / diff final PHY table contents from a decoded trace |
| `tabhist.py` | anywhere | Per-band history of values written to selected PHY table entries |
| `chantab.py` | anywhere | Extract 2059 radio per-channel values and emit b43 channel table entries |

## Setup

1. Workstation scripts read their settings from `tools/env.sh`, which is
   gitignored:

   ```sh
   cp tools/env.example.sh tools/env.sh
   $EDITOR tools/env.sh
   ```

   Variables already set in the environment take precedence over `env.sh`.
2. DUT scripts are standalone. Copy them to the DUT and configure them
   with environment variables (defaults and required variables are listed
   in each script's header):

   ```sh
   . tools/env.sh
   scp $O tools/stress.sh tools/peek.py "$M:/tmp/"   # IPv6: scp needs user@[addr%if]:/tmp/
   ssh $O "$M" "sudo GW=$GW CON=$CON bash /tmp/stress.sh reconnect 10"
   ```

   `try.sh` expects `peek.py` at `/tmp/peek.py` on the DUT and passwordless
   sudo there. `soak-mini.sh` uses `macstat.sh` from its own directory for MAC counters.
3. Throughput tests need an `iperf3` server on the DUT, reached at its Wi-Fi
   address, and the DUT on a wired link as well (so ssh survives Wi-Fi
   outages); `swap.sh` adds the policy route that keeps Wi-Fi-sourced
   traffic on Wi-Fi.
4. `air.sh`'s monitor-mode helpers (`mon_on` / `mon_off`) need passwordless
   sudo for `iw` and `ip` on the workstation, plus `tcpdump` and `tshark`.

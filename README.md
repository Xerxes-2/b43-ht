# b43-ht

A patch for the Linux `b43` driver that makes the Broadcom **BCM4331**
(HT-PHY rev 1, radio 2059) usable as a modern Wi-Fi card. The card is found
in 2011–2012 Macs, e.g. the Mac mini 5,x and MacBook Pro 8,x/9,x. In-tree b43
supports only 2.4 GHz legacy rates on it (`5 GHz band is unsupported on this
PHY`), so the usual answer has been the proprietary `wl` (broadcom-sta). `wl`
is unmaintained and has known remote heap overflows (CVE-2019-9501/9502).

## Results

Near-router tests against a TP-Link Deco on 5 GHz channel 44 HT40+, signal
about −20 dBm (Linux 6.18.55, Turbo Boost off, Mbit/s received by iperf3,
TX/RX relative to the card, 20-second runs):

| | UDP TX | TCP TX | UDP RX | TCP RX |
|---|---|---|---|---|
| b43-ht, patches 1–19, `htphy_napi=1` | 176–195 | **187–190** | **246–250** | **224–232** |
| wl | **192–199** | 162–163 | 234–235 | 191–193 |

Both rows come from the same machine and AP on the same day; wl was booted
from its own entry, with the same PCIe MRRS (512). In this setup b43-ht is
faster than wl except for saturated UDP TX. In longer TCP RX runs, wl gave
193 over 120 s; b43-ht 230–237 over 120–600 s. With Turbo Boost on, wl
reached 207–212 on TCP RX; b43-ht was within ~1% either way.

UDP was offered at 300 Mbit/s, so the RX figures are capacity, with loss
under overload. None of this says anything about other boards, APs, signal
levels or workloads.

Where the numbers come from:

- **TCP RX** needs `htphy_napi=1`: RX is delivered through NAPI with GRO and
  a 125 µs GRO flush timeout. Without NAPI, TCP RX is 199–206; an A/B/A of
  the flush timeout alone gave 237 / 199 / 236.
- **TCP TX** gains about 20 Mbit/s from keeping one A-MPDU in flight
  instead of two (patch 19): retransmissions drop from ~20 to 0 per 20 s.
  The cost is ~25 Mbit/s of saturated UDP TX, which is why that column
  trails wl.
- **TX** depends on PCIe MRRS 512 (set by the driver). At the default 128,
  large aggregates underflow the TX FIFO and TCP TX falls to 72–87.

### Stability

A 6-hour soak of patches 1–19 (alternating 10-minute TCP RX / TCP TX /
paced bidirectional blocks, a scan every 5 minutes, SSH every minute) had
no outage, disconnect, warning or controller restart: TCP RX 193–226,
TCP TX 145–183, bidirectional 80/80 Mbit/s, SSH 379/380 (the one miss
during a scan), scans 69/69. Earlier soaks had lost all traffic for
10–17 minutes every few hours; that was a BAR delivered too late
(patch 18, NOTES.md round 25). TX FIFO underflows and PHY errors still
occur at a low rate.

Also passed: cold boot, reconnects, a forced controller restart, s2idle
and S3 resume, and stopping/restarting the TX BA session up to 1000 times
under load.

Latency under load (ping, 0.2 s interval): saturated TCP TX adds ~10 ms
(wl ~5 ms). During saturated TCP RX both drivers see ~100–120 ms; that
queue is in the AP's downlink, not in the station.

A full scan during saturated TCP TX takes 13.7 s and keeps ~90 Mbit/s,
thanks to the flush operation (patch 17). Without it: 17 s, ~55 Mbit/s
and seconds without TCP progress. About one scan in six still stalls for
~5 s as it ends.

On the test machine (a Mac mini 5,3) a single busy core at full Wi-Fi
load drew ~20 W and reached 100 °C with Turbo Boost on; that most likely
explains one unexplained power-off. With Turbo Boost off it draws ~12 W and stays below
90 °C at the same throughput. That is a property of the machine, not the
driver, but it explains why the figures above are taken with it off.

## What it adds

- **5 GHz**: channel tables, the TX gain table, RX gain tables per sub-band,
  closed-loop TX power control on both bands, and the slot time.
- **Calibration**: TX I/Q + LO and RX I/Q on both bands, cached per channel,
  redone every 2 minutes, and done before authenticating on passive channels.
- **802.11n**:
  - HT rates with short GI.
  - RX A-MPDU, plus driver-built TX A-MPDU with BlockAck-bitmap retries, its
    own BAR handling, one aggregate in flight, and stale BARs dropped.
  - 40 MHz (5 GHz only, as wl).
  - LDPC receive.
- **BCM4331 HT queue workaround**: retain four mac80211 access categories,
  but share the working BE transmit FIFO with coordinated backpressure.
  Non-BE FIFOs can silently discard EF SSH traffic (upstream `09795bded2e7`).
- **BCM4331 PCIe read-request sizing**: HT TX aggregation requests MRRS
  512 through the PCI API, avoiding the severe FIFO underflows observed at
  128 on the tested board. Platform restrictions are respected and adaptive
  aggregate limiting remains a fallback.
- **NAPI/GRO delivery** (`htphy_napi=1`) of RX and TX status, and the
  mac80211 flush operation.
- **Per-channel PHY settings** taken from the proprietary driver: CRS
  thresholds, TX filter, and the primary-channel selection bits.

The behaviour was derived only from MMIO traces (mmiotrace) of `wl`, compared
against b43 and the open `brcmsmac` driver; no disassembly. The whole story,
with every dead end, is in [NOTES.md](NOTES.md).

### Generic b43 fixes in the patch

These fixes are not specific to 5 GHz. Each is a candidate for a separate
upstream patch; the ones already split out are listed in
[DEVELOPMENT.md](DEVELOPMENT.md#upstream-status):

- 32-bit HT-PHY table reads must read the low word first.
- `stop_playback` restored the BB multiplier to the wrong slot.
- TX power control: an inverted `maskset` mask, and the saved index read from
  the wrong field.
- TX gain values were truncated to u8 (`regval`).
- Slot time is lost on band switch and after scans.
- Controller restart re-initialised the chip but never re-uploaded keys, so
  with WPA the link stayed "up" but was dead. It now goes through
  `ieee80211_restart_hw()`.
- MFP: hardware-encrypted management frames were wrong (`SW_MGMT_TX`).
- `set_key` warned on unknown ciphers instead of returning `-EOPNOTSUPP`.
- HT-PHY can't send coding rate 2/3 flagged in `phy_ctl1` (48 Mbit/s, MCS
  5/13/21).
- The PM bit of frames sent by the microcode follows `MACCTL_HWPS`, which b43
  never set. As a result the AP kept sending to us during every scan.
- An inverted mask on PHY register 0x424.
- The BlockAck template's transmitter address was never written.

## Use

All new behaviour is behind module parameters and off by default:

| parameter | values |
|---|---|
| `htphy_5ghz` | 0 = off, 1 = receive only, 2 = full |
| `htphy_11n` | 0 = off, 1 = HT + RX A-MPDU, 2 = also TX A-MPDU, 3 = also 40 MHz |
| `htphy_txcal`, `htphy_rxcal` | calibrations, default on |
| `htphy_napi` | 1 = deliver RX/TX status through NAPI with GRO (BCM4331 HT, PCIe DMA, shared BE queue only); default 0 |
| `qos4331`, `txant` | experiments |

The microcode is the usual b43 firmware 666.2 (`b43-fwcutter` from
broadcom-wl 5.100.138).

### NixOS

```nix
# flake.nix
inputs.b43-ht = {
  url = "github:Xerxes-2/b43-ht";
  inputs.nixpkgs.follows = "nixpkgs";
};

# configuration
imports = [ inputs.b43-ht.nixosModules.default ];
hardware.b43-ht.enable = true;   # htphy_5ghz=2 htphy_11n=3
hardware.b43-ht.extraOptions = [ "htphy_napi=1" ];
# The firmware is unfree: allow "b43-firmware".
```

The module builds only `b43.ko`, against `boot.kernelPackages`, and installs it
to `updates/`, where it takes precedence over the in-tree module. Options:
`debug`, `band5GHz`, `ht`, `extraOptions`. The module also turns off
NetworkManager's scan MAC randomisation: mac80211 can't change the address of
a running interface, and the down/up cycles that this causes delay
connections.

### Elsewhere

Apply the patches listed in `patches/series`, in order, to a kernel tree
(wireless-next; they also apply to 6.18) and build
`drivers/net/wireless/broadcom/b43`:

```sh
for p in $(grep -v '^#' patches/series); do patch -p1 < patches/$p; done
make M=drivers/net/wireless/broadcom/b43 modules
```

Then load it with `htphy_5ghz=2 htphy_11n=3 htphy_napi=1`.

## Limitations

- **Tested hardware.** Tested on one card, a Mac mini 5,3, at close range.
  - Long-range behaviour is unverified.
  - The 40 MHz centre frequencies other than 5230 MHz are interpolated and
    untested.
- **HT queue sharing.** With HT enabled, all TIDs use BE hardware contention;
  classification is preserved, but there is no hardware priority isolation.
  AP/mesh are rejected in this mode because their CAB FIFO has independent
  backpressure. `qos4331=1` opts back into the unreliable separate FIFOs for
  experiments; `htphy_11n=0` retains upstream legacy behaviour.
  PIO is compile-tested only. The idle EF/SSH blackhole is fixed, but mixed
  saturated bidirectional traffic can still delay SSH until load subsides.
  VO does not automatically aggregate under mac80211's default BA policy;
  its lower bulk throughput is not itself evidence of this FIFO bug.
- **PCIe validation.** MRRS 512 is verified on the tested BCM4331; other
  boards and host bridges are untested. PIO and non-PCI hosts are excluded,
  and an existing larger MRRS is preserved.
- **TX power table.** Part of a TX power table is only known for this board's
  `pdet_range`.
- **Not implemented:**
  - STBC (not advertised by `wl` either), greenfield, and TX LDPC;
  - TX aggregation in AP mode;
  - partial or staggered calibration;
  - firmware-offloaded scanning, so scans pause traffic like other mac80211
    soft-scan drivers;
  - DFS.
- **2.4 GHz.** 40 MHz on 2.4 GHz loses CCK frames and is not advertised (wl
  doesn't use it either).

## Repository

- `patches/` holds the driver patch series, exported from a kernel tree
  (`patches/series` gives the order and the base commit). Patches 1–7 are
  self-contained fixes meant for upstream; patch 8 holds the 5 GHz/802.11n
  work not yet split out, and the later ones build on it. See
  [DEVELOPMENT.md](DEVELOPMENT.md).
- `nix/` holds the package and the NixOS module.
- `NOTES.md` is the reverse-engineering log.
- `tools/` holds the trace decoders, register-diff and measurement scripts
  (see `tools/README.md`).

## License

GPL-2.0-only, like the kernel code it modifies.

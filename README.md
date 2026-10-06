# b43-ht

A patch for the Linux `b43` driver that makes the Broadcom **BCM4331**
(HT-PHY rev 1, radio 2059) usable as a modern Wi-Fi card. The card is found
in 2011–2012 Macs, e.g. the Mac mini 5,x and MacBook Pro 8,x/9,x. In-tree b43
supports only 2.4 GHz legacy rates on it (`5 GHz band is unsupported on this
PHY`), so the usual answer has been the proprietary `wl` (broadcom-sta). `wl`
is unmaintained and has known remote heap overflows (CVE-2019-9501/9502).

Latest near-router tests against a TP-Link Deco on 5 GHz channel 44 HT40+
(Linux 6.18.54, Mbit/s received by iperf3; TX/RX relative to the card):

| | UDP TX | TCP TX | UDP RX | TCP RX |
|---|---|---|---|---|
| b43-ht, MRRS 512 + adaptive fallback | 213–216 | 167–170 | 244–249 | 182–192 |
| wl, MRRS 512 | 195–200 | 159–165 | 241–246 | 204–205 |

These are 12-second runs on the same card/AP with physical Wi-Fi-path
checks; b43 ranges include runs before and after deployment. TX is modestly
faster than wl in this setup, UDP RX is comparable, and TCP RX remains slower.
UDP was offered at 300 Mbit/s: the RX figures represent capacity, with loss
under overload, not loss-free delivery at the offered rate. They do not
establish superiority across other boards, APs, signal levels or workloads.

With automatic MRRS initialization and adaptive fallback retained, a
600-second TCP TX run averages 168 Mbit/s with zero observed FIFO underflows
and zero MAC `txphyerr`. Cold boot sets MRRS 512 without prior wl initialization;
reconnect and a forced controller restart also pass. One BE underflow occurred
during the short post-boot TCP RX run, so these results are not a claim of
universally error-free operation. System suspend/resume remains untested.

A historical 3-hour test of an earlier revision produced no disconnects,
controller restarts or observed PHY errors; it is not a long soak of the
current MRRS fix. Historical reconnects took 1.1 s, band switches 1.1–2.6 s.
See [NOTES.md](NOTES.md) rounds 20–21 for controls and remaining limitations.

## What it adds

- **5 GHz**: channel tables, the TX gain table, RX gain tables per sub-band,
  closed-loop TX power control on both bands, and the slot time.
- **Calibration**: TX I/Q + LO and RX I/Q on both bands, cached per channel,
  redone every 2 minutes, and done before authenticating on passive channels.
- **802.11n**:
  - HT rates with short GI.
  - RX A-MPDU, plus driver-built TX A-MPDU with BlockAck-bitmap retries and its
    own BAR handling.
  - 40 MHz (5 GHz only, as wl).
  - LDPC receive.
- **BCM4331 HT queue workaround**: retain four mac80211 access categories,
  but share the working BE transmit FIFO with coordinated backpressure.
  Non-BE FIFOs can silently discard EF SSH traffic (upstream `09795bded2e7`).
- **BCM4331 PCIe read-request sizing**: HT TX aggregation requests MRRS
  512 through the PCI API, avoiding the severe FIFO underflows observed at
  128 on the tested board. Platform restrictions are respected and adaptive
  aggregate limiting remains a fallback.
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

Then load it with `htphy_5ghz=2 htphy_11n=3`.

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
  Scanning while driver queues are stopped also needs a flush-path review.
  VO does not automatically aggregate under mac80211's default BA policy;
  its lower bulk throughput is not itself evidence of this FIFO bug.
- **PCIe validation.** MRRS 512 is verified on the tested BCM4331; other
  boards/host bridges and system suspend/resume remain untested. PIO and
  non-PCI hosts are excluded, and an existing larger MRRS is preserved.
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
  (`patches/series` gives the order and the base commit). The first patches
  are self-contained fixes meant for upstream; the last one holds everything
  not yet split out. See [DEVELOPMENT.md](DEVELOPMENT.md).
- `nix/` holds the package and the NixOS module.
- `NOTES.md` is the reverse-engineering log.
- `tools/` holds the trace decoders, register-diff and measurement scripts
  (see `tools/README.md`).

## License

GPL-2.0-only, like the kernel code it modifies.

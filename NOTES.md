# b43 HT PHY: adding 5GHz for BCM4331

Goal: make mainline `b43` support 5GHz on the Mac mini's BCM4331 (HT PHY rev 1, radio 2059),
and eventually replace the proprietary `wl`. Currently b43 supports only 2.4GHz on this card, with b/g rates only (no 802.11n)
(dmesg: `5 GHz band is unsupported on this PHY`).

## Capture

1. Pick "NixOS (mmiotrace)" in systemd-boot, or set it one-shot on the machine:
   `sudo bootctl set-oneshot <entry>.conf && sudo systemctl reboot` (see `bootctl list` for the entry).
   This boot entry uses a kernel with `CONFIG_MMIOTRACE` enabled and does not load `wl` at boot (see `../wifi-re.nix`).
2. During capture Wi‑Fi is down and only one CPU is online, so **plug in Ethernet** and work over ssh. Steps are in the header comment of `wifi-re.nix`;
   use `trace_marker` to tag each phase with `PHASE xxx`, which becomes `== PHASE xxx` after decoding.
3. Traces are not committed: on the machine they are in `/var/lib/b43-re/`, locally copied to `<workdir>/traces/`.
4. `tools/decode.py x.mmio > x.txt` decodes into PHY / RADIO / SHM read/write sequences; `tools/chantab.py x.txt [radio_2059.c]` extracts the channel table.

## Existing traces

`wl-5g.mmio` (2026-10-03, kernel 6.18.54, wl 6.30.223.271): modprobe → full-band scan
→ connect to DECO 5GHz channel 44 (5220MHz) → ping. No lost events.

| Phase | PHY W | PHY R | RADIO W | RADIO R | SHM W |
|---|---|---|---|---|---|
| modprobe | 28636 | 5022 | 1640 | 662 | 13569 |
| scan | 40969 | 9814 | 3698 | 1357 | 3668 |
| connect | 13903 | 2148 | 422 | 173 | 1452 |

The scan phase writes 84 distinct radio registers; the 0x400/0x800 prefix in the addresses is the 2059's
radio core select (consistent with the addressing in b43 `radio_2059.c`).

## Known limitations

- BAR0 window core switching (PCI config space 0x80) does not go through MMIO and is invisible in the trace;
  `+0x000..0xfff` is interpreted as the D11 core, so occasional accesses to other cores are decoded wrongly.
- Clean-room: b43 has historically been "one group reverse-engineers and writes specs, another writes code from the specs". Here we only
  derive patterns from register access sequences (hardware behaviour) and do not read `wl.ko` disassembly; this line must be held to go upstream.

## Channel table: b43's existing one is already correct

`tools/chantab.py wl-5g.txt radio_2059.c` splits the trace on `SHM 0x0028` (current channel number) to extract the radio/PHY values
written on each channel switch, and compares them entry by entry against b43 `radio_2059.c`: 2.4GHz and 5GHz all match,
except rxtx5a/rxtx92 for channels 12/13 (the b43 source itself marks these TODO "outdated").
5230 is the center frequency wl uses for HT40 (44+48); b43 does not do HT40, so it is not needed.
Conclusion: what's missing for 5GHz is not the channel table; main.c simply rejects 5GHz on HT PHY.

## Patch (now the series in `patches/`)

- Module parameter `htphy_5ghz`: 0 off (default, same as mainline), 1 RX only, 2 full.
- Only registers the 24 5GHz channels present in the 2059 table.
- RX-only mode: all 5GHz channels marked NO_IR, beacon hints disabled (otherwise a received beacon lifts NO_IR),
  and `b43_op_tx` drops frames on 5GHz outright: triple guarantee of no transmission.
- `op_switch_channel` in `phy_ht.c` allows 36–165.

`module.nix` builds only `b43.ko` into `updates/`; normally b43 is blacklisted and does not autoload.

## Measurements (2026-10-03, DECO channel 44, -47 dBm)

| | Result |
|---|---|
| RX only (=1) | All 24 channels registered as no IR; passive scan sees 9 APs on 36/40/44/48/116/149, signal matches wl; tx_packets=0 |
| Full (=2) | Auth, association, WPA, DHCP succeed first try, rate 54 Mbit/s (11a) |

(The table below is from before the slot-time fix; see "Round 2".)

60 MiB transfer over ssh, with policy routing pinning both directions to Wi‑Fi:

| Driver | TX (mini→out) | RX (out→mini) | Notes |
|---|---|---|---|
| b43 patched | 48.5 s ≈ 10 Mbit/s | 38 s ≈ 13 Mbit/s | tx retries 19%, ping from the mini loses 20% |
| wl | 5.4 s ≈ 93 Mbit/s | 4.2 s ≈ 120 Mbit/s | 11n |

The practical 11a ceiling is about 25 Mbit/s; b43 gets only half, mostly lost to TX retransmissions.

## Driver switching pitfalls

- Switch to b43: `rmmod wl; modprobe bcma; modprobe b43 htphy_5ghz=2`.
- Before switching back to wl you **must reset the PCI device**, otherwise every wl scan fails with `Scan_results error (-22)`:
  `rmmod b43 bcma wl; echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove; echo 1 > /sys/bus/pci/rescan`
  (rescan binds wl automatically).
- When benchmarking, the Mac mini's wired and Wi‑Fi interfaces are on the same subnet and replies go over wired by default (lower metric); add
  `ip rule add from <wifi-ip> table N` + `ip route add <lan-subnet>/24 dev <wifi> table N`.
- `nmcli con modify DECO 802-11-wireless.band a` locks to 5GHz; set it back to `""` after testing.

## Round 2: why b43 is slow (2026-10-03)

Tools: `swap.sh` (switch drivers + policy routing on the machine), `bench.sh` (benchmark from the local host), `regdiff.py`
(diff PHY/radio/PHY table/MMIO/SHM state between two traces at a given phase). The module is built with `debug = true`,
which provides b43 debugfs: `/sys/kernel/debug/b43/phyN/mmio16{read,write}`; the write format is
`addr mask set`, new value = (old & mask) | set, **not** "addr value".

Ruled out:
- Not 5GHz-specific: b43 is equally slow on 2.4GHz (42% retries; wl gets 58 Mbit/s on the same channel).
- Not signal quality: at fixed rates 6/12/24 Mbps the retry rate is about 0.13 per packet in all cases, independent of rate.
- Not TX core selection: the new `txant` parameter changes the 0x3c0 bits in the TX header; no difference across combinations.
- Not host side: CPU idle; AQL in-flight time is 0, disabling it changes nothing; the TX ring is full and one frame is refilled per completion,
  so the bottleneck is the hardware transmit itself. Working back from fixed-rate data, each frame has about 1 ms of rate-independent fixed overhead.
- Not QoS: the new `qos4331=1` bypasses upstream's 2023 QoS disable for 4331; EDCF turns on and
  all four ACs can transmit (the upstream issue of non-BE queues not transmitting did not reproduce here), but throughput is unchanged.

Confirmed problems and fixes:
- **5GHz slot time**: `b43_set_slot_time` returns early on 5GHz, leaving IFSSLOT at 0x212 (20 µs);
  wl writes 0x207 (9 µs). After the patch allows it for HT PHY: UDP TX 12.1→16.3, TCP TX 10.5→14.9 Mbit/s.

Main leads (unresolved):
- IFSCTL (0x688) bits 12–13 are a selector: the firmware init values write 0x0000/0x1000/0x2000/0x3000 in turn,
  each followed by a write to 0x69c (AIFSN). Changing the selector from 0 to 1 at runtime raises TX 14→29 Mbit/s,
  **and retries drop from 0.15 to 0.06**, so it's not bypassing carrier sense.
- Across groups, only 0x68a/0x68c/0x68e read back differently, looking like live backoff state (group 0 0x68c=0x38,
  group 1 0x04, group 2 0x800e, group 3 0x16).
- After the init values, wl also does things b43 doesn't: writes 1 to 0x69c; on every channel switch sets bit 3 `IFS_CTL1_EDCRS`
  of 0x69e (brcmsmac calls it `ifs_ctl1`) (0x7→0xf, 0x3f for HT40). Writing
  0x69e via debugfs under b43 doesn't stick; the MAC may need to be suspended first.
- SHM can't be compared directly: wl uses its own newer firmware, whose SHM layout differs from b43's 666.2 firmware.

## Round 3: hardware register comparison (2026-10-03)

New tool `peek.py`: reads/writes BAR0 (0xa0600000) directly via `/dev/mem`, works even while wl is running; needs
`iomem=relaxed` (only enabled in the mmiotrace boot entry). Supports MMIO r16/w16 and indirect PHY read/write
(0x3fc/0x3fe, racing with the driver). `try.sh` changes a register → benchmarks → restores.

**The truth about the IFS registers** (overturns the "selector" lead from Round 2):
- **Any write to 0x688 (IFSCTL), even writing back the same value, resets 0x680/0x682/0x684/0x69c to their
  defaults** 0x3535/0x0235/0x0212/0x0000. This is why wl follows every write to 0x688 with a write to 0x69c.
- With AIFSN (0x69c) = 0, TX stops completely; writing back 2 resumes it immediately.
- Round 2's "selector 1 doubles TX" was an artefact: IFS was actually reset to a shorter SIFS and AIFSN=0,
  grabbing the medium for a while, after which the link stalled.
- In steady state, wl and b43 IFS registers differ only in AIFSN (1 vs 2, changing it has little effect) and the
  EDCRS bit in 0x69e (wl 0x3f / b43 0x7; under b43 it can't be written via /dev/mem either).

**Benchmarking trap**: nmcli disconnect/reconnect deletes the table 200 routes attached to the device, so replies silently go over wired,
yielding a neat 40.0 Mbit/s. `try.sh` rebuilds the routes every time and prints the number of packets actually sent over Wi‑Fi as a cross-check.

**Ruled out (no change in all cases)**:
- Porting wl's PHY register values: the 5 groups with differing values (0x424/464/4a4, 0x848–0x888, 0x911–0x919,
  0x0b0/0x0c6, 0x280/0x283), and **porting all 148 PHY registers that only wl sets, all at once**.
- SHM slot time SLOTT (0x10) 20→9; synthesizer wakeup SPUWKUP (0x94) 0–2048 µs.
- Contention window: scratch MINCONT can't be written; the EDCF parameters (SHM from 0x240, 16 words per queue) status bit
  stays at 0x100, the firmware appears never to read them, changes have no effect.
- Firmware swap: 666.2 → 784.2 (`b43Firmware_6_30_163_46`, loaded with `fwpostfix=-new` + temporarily changing
  `/sys/module/firmware_class/parameters/path`), throughput exactly the same.
- txstat: no RTS, about 16% of frames retried once, all eventually acked.

**Quantitative conclusion** (later found to be a test methodology problem, see Round 4): large packets (1470 B) take about 828 µs per frame, small packets (100 B) about 526 µs per frame; solving the two together gives
an effective rate of about 36 Mbps and a fixed per-frame overhead of about 490 µs; by 11a timing (preamble + SIFS + ACK + AIFS +
mean backoff) it should only be about 190 µs, **so each frame has about 300 µs of unexplained overhead**, independent of frame length and rate.

## Round 4: over-the-air capture (2026-10-03)

Changed setup: the workstation now uses its Intel wired port for internet, and the Mac mini's wired port is connected directly to the workstation's Realtek port (both
sides use an NM connection with `ipv6.method link-local`; the one on the Mac mini is called `direct`), freeing the workstation's ath12k
for monitor mode: `iw dev wlan0 set type monitor` + `iw dev wlan0 set freq 5220 80 5210`,
then `tcpdump -i wlan0 -s 160 'wlan addr1 <sta-mac> or wlan addr2 <sta-mac>'`, analysed by radiotap
`mactime`. Captures are kept in `<workdir>/air/`.

**Round 3's 300 µs "mystery overhead" is not a b43 problem**: previously the workstation was itself on Wi‑Fi, on the same channel as the Mac
mini, so every packet crossed the air twice (workstation → AP → Mac mini), halving the airtime.
With the workstation on wired, b43 re-measured:

| | UDP TX | TCP TX | UDP RX | TCP RX |
|---|---|---|---|---|
| b43 (11a 54M) | 24.6 | 19.0 | 25.3 | 19.4 |
| wl (11n + aggregation) | ≥60 | 159 | ≥60 | 198 |

Over the air, b43's median per-frame period is 429 µs; the theoretical value by 11a timing is about 398 µs (data 252 + SIFS 16 +
ACK 28 + AIFS 34 + mean backoff 67.5), **so it's essentially at the 11a ceiling**. The gap to wl comes from 802.11n:
wl uses RTS/CTS + A‑MPDU + BlockAck at HT MCS rates.

**New finding: b43 TX power is about 20 dB low**. A monitor NIC at the same position receives wl's data frames at about −33 dBm,
b43's at about −53 dBm (the AP's ACKs are about −42 dBm in both cases). Also, the monitor decodes only about 1% of b43's 54M frames, while the AP
side retry rate is only about 4%; presumably weak signal plus poor signal quality (EVM), possibly related to TX IQ/LO calibration.

## Round 5: TX power (2026-10-03)

The monitor NIC measures b43 about 20 dB below wl on 5GHz. New tools: `phy.sh` (indirect PHY read/write via debugfs mmio16,
no iomem=relaxed needed), `tabdump.py` (reconstructs PHY table writes from a trace, can compare two
traces), `air.sh` (monitor + benchmark + median signal).

**Cause 1: 5GHz uses the 2.4GHz TX gain table.** Table 26 0xC0–0x13F (128 entries, upper 16 bits radio
gain code, low byte baseband multiplier) is the TX gain table, shared by all three cores. wl swaps between two tables on band switch
(alternating uploads visible in the trace); b43 only has the 2.4GHz one (`b43_httab_0x1a_0xc0_late`, matching the trace entry
by entry). With power control off, `tx_power_fix` takes one fixed entry from this table and writes it into the gain override (table 7 0x110+core, table 13
bbmult). The patch adds a 5GHz table and uploads the right one per band on every channel switch.

Sweeping the entry on 5GHz open loop (monitor signal / throughput): 0 → AP doesn't hear it; 16 → −21 dBm, distorted, frames lost; 32 → −27;
40 (the previously hardcoded 0xE8) → −30; 48 → −34 (≈ wl's −33); 64 → −43. About 0.5 dB/entry. The patch uses 0x30 for 5GHz
and keeps 0x28 for 2.4GHz. Measured with the new module: 5GHz signal −52 → −36 dBm.

**Cause 2 (upstream bug, affects 2.4GHz too):** in `b43_phy_ht_tx_power_ctl_setup`, the power estimate table
`regval` is declared `u32[64]` but uploaded as 16-bit, so every other entry in the table is 0 and only the first 32 values are used. This
table is used by hardware closed-loop power control (TSSI → power); on 2.4GHz closed loop is enabled, so power gets pushed too high and distorts.
After changing it to `u16`, on 2.4GHz (channel 10): throughput 8.7–10.6 → 20.0–20.6 Mbit/s, monitor signal −22 → −26 dBm,
power control index 0x58 → 0x4D. **This one is worth submitting upstream separately.**

## Round 6: 5GHz closed-loop power control (2026-10-03)

Experimental parameter `htphy_pctl5g=1` (default off): on 5GHz, stop writing 0x32 to CMD_C1 (that write also clears the enable bit,
effectively disabling closed loop), redo idle TSSI measurement and `tx_power_ctl_setup` on every channel switch (upstream only does it once
at init, for whatever band is current), and use 0x20 (wl's value) as the 5GHz start index. The TSSI path reuses the
`TSSI_2G` settings directly: the AFE overrides and radio 0x159=0x11 that wl writes on 5GHz are identical.

**Upstream bugs fixed along the way** (effective regardless of the parameter):
- When `tx_power_ctl(enable)` restores the index, it uses `b43_phy_write` to overwrite the whole CMD register, clearing the just-set
  enable bit. Changed to modify only the index field (maskset 0x7f).
- The "index" saved on disable was taken from the low byte of the status register. Measured: **bits 8–14 of the status register are the current gain
  index, the low byte is the estimated output power** (converging to the target). Changed to `(status >> 8) & 0x7f`.

**Result: cores 1 and 3 converge normally, core 2 doesn't.** Core 2's TSSI reads about 7–10 dB low on 5GHz:
closed loop drives it to index 0 (full power) and the estimate still only reaches about 0x2d, so it stays pinned at max power, signal −23 dBm,
throughput halved. On 2.4GHz core 2 is fine (index about 0x0c, converges to target).

Reading wl's runtime state with `peek.py` in the mmiotrace boot entry: all three wl cores converge normally
(0x1ed/0x1ee/0x969 = 0x9c3d/0xa33a/0x9d3c, indices 0x1c/0x23/0x1d, estimate about 0x3b = target).
So b43 is missing some setting. Already ruled out (writing wl's values in at runtime, core 2 unchanged):
- PHY: TSSI delay 0x1e8, idle TSSI, target power, AFE overrides 0x911/915/919=0xfcc, 0x860/0x880,
  0x1f0–0x1f2, 0x970–0x972, 0x98f–0x992.
- Radio: a set that wl writes on every channel switch and b43 never writes {c7d=fe, c7e=c0, c6f=09, c75=0a, 448=0d,
  042=3c} (0x448 is the only radio register that differs on core 2 alone), plus all differences in 0x13d–0x154, 0x17f–0x19b,
  0x06f–0x0c3, 0x098. (0x00a/0x016/0x02c are PLL values from the channel table; writing them breaks the link.)
- Power estimate tables (tables 26–28): hardware readback is correct, only about 0.5 dB off from wl.

The largest remaining difference is **TX IQ/LO calibration** (table 13 0x40–0x7b, radio 0x151–0x15c group): wl does it,
b43's HT PHY doesn't implement it at all. Core 2's distortion fits this too: open loop with core 2 alone, the same index gives the strongest signal
yet throughput drops to 10 Mbit/s.

So 5GHz still defaults to open loop with fixed index 0x30 (−35 dBm, 24 Mbit/s, power comparable to wl).

**Tools from this round**: `peek.py dump` (scan all PHY/radio registers), `peek.py tabr` (read PHY tables),
`phy.sh rr/rw` (radio read/write: HT PHY uses 0x3d8/0x3da, reads must OR in 0x200). The mmiotrace boot entry's
kernel is different, so the module must be built separately with `specialisation.mmiotrace.configuration.boot.kernelPackages`;
`insmod` doesn't resolve dependencies, so `swap.sh` now does `modprobe cordic` first.

## Round 7: 5GHz closed-loop power control fixed (2026-10-03)

**Root cause for core 2: PHY table 8 offset 0x0b + 0x10×core.** wl rewrites this entry (and 0x0f) per band on every channel switch:
0x96/0x5a/0x96 for 2.4GHz, 0x91/0x15c/0x91 for 5GHz. b43 writes the 2.4GHz set only once at init
(around 0x96/0x9f/0x9f), so on 5GHz core 2's TSSI reads about 8 dB low, and closed loop pushes it to full power and distortion.
How it was found: write all differing table entries between the wl and b43 traces at once → core 2 converges → bisect table by table, entry by entry, down to this one.
No corresponding SPROM field was found (printed rxgainerr/noiselvl/fem/itssi/pa etc., none match), so for now it's a constant table,
verified only on this board (boardtype 0xe4).

Also: the TX IQ/LO correction coefficients (table 13 0x60–0x7b) were never written by b43; writing wl's coefficients had no effect on core 2,
so it's not this round's problem, but IQ/LO calibration is still missing.

**Target power**: the SPROM limit is total TX power; all three chains transmit the same frame simultaneously, so each chain must subtract 4.75 dB
(3 dB for two chains), and take the minimum of that, the regulatory limit and the user setting (same as N-PHY). Without the reduction each PA is about
5 dB above wl, and 5GHz 54M distorts (measured: 18.6 Mbit/s at target 0x48, 25 Mbit/s at 0x3b or below).

**Result**: closed loop is enabled by default on both bands; the `htphy_pctl5g` parameter has been removed.
- 5GHz: all three cores converge to target 0x35 (core 2 index 0x28), signal −29 dBm, UDP TX 24.4 / RX 22.4,
  TCP TX 19.1 / RX 19.5 Mbit/s.
- 2.4GHz: target 0x39, three cores converge, UDP TX 24.4 Mbit/s.

## Round 8: origin of the table 8 values (2026-10-03)

- Read the whole SPROM (220 words via chipcommon 0x800 in b43; before reading, temporarily disable 4331's
  external PA lines chipctl bits 4/7/12, otherwise it's all 0). Raw data contains the MAC, kept only in `<workdir>/sprom.txt`.
  0x91/0x15c/0x96/0x5a are not found anywhere in the SPROM, so they're not stored directly.
- **Meaning found**: HT table 8 = brcmsmac's `NPHY_TBL_ID_AFECTRL`. Per core, 0x08–0x0b are the aux ADC
  VMID, 0x0c–0x0f the gain, with the 4th entry used for TSSI. N-PHY picks values by SPROM `pdet_range` and band
  (the section at the end of `wlc_phy_workarounds_nphy`). On our board, pdet_range for both fem2g/fem5g is 5.
- The patch now writes these values (named vmid/gain) only when pdet_range==5; other detector types keep the init values,
  no risk taken. Retested: 5GHz three cores converge, UDP TX 23.9 / RX 24.4; 2.4GHz TX 21.6 / RX 23.0 Mbit/s.

## Round 9: RX gain tables (2026-10-03)

New tool `tabhist.py` (lists values written to table entries per band); tracking the channel via SHM 0x0028, wl's RX gain table pattern:

| Tables 0/1/40 (dB per core) | 2.4GHz | ≤5220 | 5230–5320 | ≥5745 |
|---|---|---|---|---|
| 0x08–0x0b LNA1 | 9 f 13 18 | b 11 15 19 | a 10 14 18 | a f 13 17 |
| 0x10–0x13 LNA2 | fd 7 b f | 0 7 b e | 0 7 b e | 2 9 d 10 |

Band-independent as well: tables 0/1/40 0x20–0x29 = 0 0 0 0 3×6, tables 2/3/41 (gain codes) 0x20–0x29 = 3×4 4×6,
never written by b43 (hardware defaults 5×10 / 3×10); table 47 entries 3–10 and 14–21 are 0x32064×6 + 0x2583c×2 in wl,
0x1581f in b43's init table.

- Patch: on every channel switch write LNA1/LNA2 per sub-band, and write 0x20–0x29; table 47 init values changed to wl's.
  5500–5700 MHz is not in the trace; the 5230–5320 set is used for now.
- Result: 5GHz reported signal −44 → −39 dBm (wl −38), throughput unchanged (UDP RX 26.2 / TX 25.3);
  2.4GHz no regression (UDP RX 23.2 / TX 23.2). No sensitivity difference measurable at close range; needs re-verification at a distance.
- Pitfall: when `phy.sh` reads a table, `cat` calls read() twice, and debugfs actually reads hardware each time, so the table address auto-increments one extra time
  and every other entry is skipped. Switched to `dd bs=64 count=1`. Earlier consecutive reads of 0x73 with phy.sh should be taken with a grain of salt.
## Round 10: TX IQ/LO calibration (2026-10-03)

Implemented following the register sequence in the wl trace (wl-5g.txt 54069–55600). The structure
matches N-PHY rev3+ `b43_nphy_cal_tx_iq_lo`, three cores:
- Setup: park in carrier search (classifier OFDM off, clip thresholds 0xffff, reset CCA); radio per core 0x155–0x15c
  (corresponding to 2057's SSI master / IQCAL VCM / IDAC / TSSI VCM / SSI mux / TSSI A / G / misc1;
  5GHz 0a 43 55 00 04 31 00 00, 2.4GHz inferred from N-PHY as 06 43 55 00 06 00 31 00); AFE 0x910/0x911
  override, table 8 offset 3 cleared, 0x84c=0x1480, 0x840|=2; gain taken from table 26 0xc0+0x19 (upper 16 bits go to 7:110+core,
  low byte is bbmult, goes to 13:063/073+4×core).
- Ladder tables (13:000–011 LO, 13:020–031 IQ) = N-PHY ladder percentages × bbmult.
- Test tone: table 17, amplitude 250, complex sinusoid at 1/8 of the sample rate (160 points at 20MHz), played through the IQLOCAL engine
  (CMDGCTL 0x8ad9, bit15 set instead of SAMP_CMD).
- 6 commands per core 0x434/0x334/0x084/0x267/0x056/0x234 (| 0x8000 | core<<12), CMDNNUM 0x7987,
  poll 0xc0 for bit15 clear; results at 13:080+7×core, copied by type into the work area 13:040+8×core (type 0→+0/+1,
  2→+3, 3→+4, 4→+5; clear +3/+4 before types 3/4).
- Apply: work area +0/+1/+3 written to 13:060+4×core and 13:070+4×core.

**Upstream bugs found along the way**
- `b43_httab_read` 32-bit read reads DATAHI first: the hardware latches the high half only when DATALO is read, so reading the high half
  first returns whatever the previous access left there. Affects the gain in `b43_phy_ht_tx_power_fix` (core 1 gets the wrong one). Changed to low then high.
- `stop_playback` restores bbmult to 0x67+4×core (should be 0x73+4×core; it corrupts the next core's value),
  and the saved value is never cleared, so the value from the first save is restored forever.
- `software_rfkill(false)` switches channel **before** PHY init; calibrating there produces garbage (tables are all empty,
  0x800=3, AFE overrides not set). That channel switch now skips calibration.
- **5GHz TX throughput drops 25% after a scan**: a cross-band scan switches bands, the band initvals reset IFSSLOT to long slot,
  and the Round 1 5GHz slot-time fix only takes effect at association. `b43_switch_band` now reapplies the recorded slot time at the end.
  UDP TX after scan 17.7 → 24.1 Mbit/s.

**Behavior**: calibrate once on every switch to a new channel (~39 ms), results cached per channel; no calibration during a scan (done afterwards),
returning to an already-calibrated channel just writes the cache back; NO_IR/radar channels are not calibrated (the test tone would be transmitted over the air). If the result looks suspicious (coarse LO
coefficient outside ±2) it is redone once. `htphy_txcal=0` disables it.

**Result**: coefficients are stable and close to wl's values on the same band (5GHz: core 1 ffeb/fffa, core 2 0041/0000,
core 3 0097/fff5; wl ffed/fff8, 0047/fff8, 00a3/fff2). Short-range throughput is no different from with it disabled
(UDP TX ~24 Mbit/s); the effect would only show at long range / low SNR, not verified.

## Round 11: RX IQ calibration (2026-10-03)

wl does it right after TX calibration (wl-5g.txt 55600–63240). The structure matches brcmsmac
`wlc_phy_cal_rxiq_nphy_rev3`, three cores in turn:
- PHY setup: AFE (0x911+4c clear bit2, 0x910+4c set 0x44), 0x801 changed so only this core transmits
  (high nibble cleared, low nibble = 1<<core), RF control override 0x84c+0x20c=0x1440, 0x840 |= 0x102,
  0x849 |= 0x420, 0x842 |= 0xe4, 0x84a/0x843 |= 9, 0x297+4c clear bit0.
- Radio: coupler 0x160=3, 0x15f=0xf (corresponding to 2057's TXRXCOUPLE_5G_PWRUP/ATTEN; 0x15d/0x15e are the 2G pair,
  only saved/restored), 0x172 clear bit1, 0x173/0x174=0x27, 0x09b=0x24, 0x0a6=2.
- Gain search: per brcmsmac `rxcal_gainctrl_nphy_rev5` 5GHz table, 0x845+0x20c =
  (mix/TIA 4)<<4 | LNA2<<2 | LNA1, 0x847+0x20c = fine<<4 | biq0, 0x840 set 0x3800 to apply;
  start at step 3, back off one step if power exceeds 10000, then compensate the fine gain against 2^13. TX gain 7:110..112 = 0x0ff8 | PA bits.
- Test tone: table 17, 320 points, 10-point period (2MHz at 20MHz), amplitude 181.
- I/Q estimation: 0x12b sample count, 0x12a low byte wait 32, 0x129 bit0 start; per-core result is 32-bit I·Q and two powers,
  base addresses 0x12c / 0x134 / 0x13a (the third core is not evenly spaced).
- Coefficients: same algorithm as N-PHY CalcRxIqComp, but with the two powers swapped and the square-root rounding as described in Round 12 — with this, wl's own
  readback estimates reproduce bit-for-bit the coefficients wl writes (three cores 0/0x11, 0xb4/0x5d, 0x3ad/0xa). Results go to 0x9a/0x9b + 2×core.

**Why the two powers are swapped**: measured with test-tone loopback, compensating with wl's coefficients actually increases the I/Q power mismatch (core 2 +28% → +62%).
Measuring instead with the receiver noise floor (no tone, only the RX chain's own imbalance): uncompensated core 2 is −20%, with wl's coefficients
+2%, with the N-PHY ordering −38%. So in loopback the TX path flips the direction of the imbalance, and wl's algorithm is correct.

**b43 vs wl init difference**: upstream op_init sets 0x860/0x880 bit0 (and 0x864/0x884 bit0) for cores 2/3; wl
never sets override bits. Previously RX calibration wrote 0 to 0x864, and with that override bit active cores 2/3 received no loopback signal; now 0x844 is left alone.
Clearing these two override bits at runtime changes neither throughput nor signal, so left as is for now.

**Also**: the TX calibration engine writes the LO fine adjustment into radio 0x151–0x154 (corresponding to 2057's LOFT fine/coarse I/Q;
wl also writes these four when restoring from cache), and they go back to 0x77 after the radio is reinitialized. The cache now also stores these four and the RX compensation coefficients.

**Another issue**: right after load the regulatory domain is unset, all 5GHz channels are NO_IR, every pre-association calibration is skipped, and none is done after association either.
Now one is done at association (transmission is already allowed, and on radar channels the AP has already done CAC).

**Result**: coefficients over three loads 0/18~24, 195~207/111~122, −90~−103/19~25, same magnitude and sign as wl's 0/17, 180/93, −83/10
(different time, different channel conditions). No change in short-range throughput (UDP both directions ~24 Mbit/s). There is no wl
reference sequence for 2.4GHz, so no RX calibration there (compensation zeroed). `htphy_rxcal=0` disables it.

## Round 12: 2.4GHz trace, 2.4GHz RX calibration, periodic calibration (2026-10-03)

New trace `wl-2g.mmio`: mmiotrace boot entry, modprobe → connect to DECO 2.4GHz (channel 10, 2457MHz) →
ping 2 minutes → scan → ping 1 minute. No lost events.

**2.4GHz TX calibration**: the radio 0x155–0x15c values wl writes are exactly the ones inferred from N-PHY in Round 10; confirmed correct.

**2.4GHz RX calibration** differences from 5GHz (everything else is the same):
- Coupler uses the 2G pair: 0x15e=3 (power up), 0x15d=0x7f (attenuation).
- 0x849 only sets 0x400 (5GHz is 0x420).
- The mixer/TIA field of 0x845 is 3 (5GHz is 4).
- Gain table is brcmsmac's `nphy_ipa_rxcal_gaintbl_2GHz_rev7` (biq0 1→4→6, LNA2 3); each step uses TX power index 10
  (table 26 0xca: gain goes to 7:110, low byte bbmult goes to 13:063/073) instead of a fixed gain.
- Test tone 160 points (5GHz 320 points).
- Coefficients: the square root is **rounded up** (the round-to-nearest described in Round 11 happened to match on the three 5GHz data sets; on 2.4GHz core 1 is off by 1);
  all four data sets match bit-for-bit.

**Effect** (no tone, measuring the receiver's I/Q imbalance on over-the-air signals, iq/p and (p0−p1)/p, units of 1/1000, `tools/iqest.sh`):

| | Core 1 | Core 2 | Core 3 |
|---|---|---|---|
| 2.4GHz uncompensated | −50/−95 | −20/−60 | +30/+125 |
| 2.4GHz compensated | ±15/±20 | ±20/±40 | ±10/±20 |
| 5GHz uncompensated | +10/−85 | −115/−205 | +70/−30 |
| 5GHz compensated | ±15/±30 | +40/±20 | ±15/+15 |

Roughly an image rejection improvement from −20 dB to about −35 dB. Short-range throughput unaffected. 2.4GHz coefficients (core 1/2/3 a/b)
40/53, 43/41, −33/−52; wl 47/56, 54/47, −27/−52.

**Periodic calibration**: wl redoes it every 120 seconds after association (182.7 s, association at 60.4 s; brcmsmac's N-PHY watchdog is also
a 120 s glacial timer). wl does a "partial" calibration split over several runs (TX only runs the refine commands, starting from the previous coefficients;
RX is fully redone); here this is simplified to a full redo every 120 seconds (~80 ms TX stall), only on previously calibrated channels.
A 5-minute ping showed no packet loss or latency spikes.

## Round 13: 802.11n (2026-10-03)

Parameter `htphy_11n` (default 0): 1 = HT rates (20 MHz, RX MCS 0–23, short GI) + RX aggregation,
2 = additionally TX aggregation. Both imply `qos4331` (HT requires WMM). All references are the open brcmsmac (same-generation ucode:
TX header, RX header and SHM addresses all match); the trace is only used to check the values written to SHM/template RAM.

**RX**
- RX header PHY status 0 frame types 2/3 are HT: the PLCP is the HT-SIG, byte 1 is the MCS (bit7 = 40 MHz),
  byte 4 bit7 = short GI. Previously these were decoded as OFDM, and when the rate could not be decoded the whole frame was dropped.
- RX aggregation is entirely in the ucode (sends BlockAck) and mac80211 (reordering): `ampdu_action` just returns 0 for RX_START/STOP.
  SHM 0xBA = 0xFFFF, 0x3C = 10 (brcmsmac's M_MIMO_MAXSYM / M_WATCHDOG_8TU; wl writes the same values).
- **TA of the BlockAck template** (template RAM 0x38+16, brcmsmac's T_BA_TPL_BASE) must be set to our MAC,
  otherwise the BAs we send have an all-zero source address (DECO accepts them anyway, other APs may not). wl writes exactly these 6 bytes.

**TX (single frames)**: TX header PHY control word encoding 2 = HT; high byte of control word 1 is the MCS coding rate/modulation/stream count
(brcmsmac mcs_table); 1 stream uses CDD (transmit on all three chains), multiple streams SDM; antenna bits 0x1c0; HT-SIG PLCP;
for mixed mode the L-SIG length goes into `mimo_modelen`; mac80211 does not fill in NAV for MCS frames, so we compute SIFS+ACK ourselves.

**TX aggregation** (the brcmsmac ampdu.c approach, assembled driver-side):
- In tx_work, consecutive frames with the same TID and receiver are chained into one A-MPDU: TX header mac_ctl bits 0x600 mark first/middle/last,
  the first frame's PLCP length is changed to the length of the whole A-MPDU with the aggregation bit set, L-SIG recomputed from the total length; DMA is kicked only once after all frame descriptors are queued.
- Status: only one per A-MPDU; when a BA is received, the immediately following second pair of status words is the bitmap (low 4 bits in bits 12–15 of the first word).
  Match the bitmap against sequence numbers; unacknowledged frames are put back at the head of the queue for retransmission (up to 4 times), then reported NO_BACK so mac80211 sends a BAR.
- At most 2 A-MPDUs in flight at once; otherwise frames go out singly as soon as they arrive and never aggregate. The sequence span of one A-MPDU does not exceed the peer's
  window (counted from the oldest unacknowledged frame).
- **Length cap 1.5 ms**: beyond ~2 ms, MPDUs at the tail are lost in large numbers (at 2.5 ms a quarter need retransmission), cause unknown.
  (Round 14: the real cause was that MCS 13 cannot be transmitted; now 3 ms.)
- **MPDU spacing at least 10 µs** (null delimiters): with a run of very small frames (TCP ACKs) DMA cannot keep up, the TX FIFO underflows
  (SHM 0xEE = BE txfunfl counter increasing), and the PHY reports "PHY transmission error". brcmsmac solves this with the TX header
  preload size, but with this firmware any non-zero value makes the ucode hang and stop transmitting. A small amount of underflow remains (a few dozen every 8 seconds).

**Upstream bugs fixed along the way**
- `MFP_CAPABLE`, but hardware CCMP does not encrypt management frames: the peer cannot decrypt protected ADDBA responses and SA Query replies,
  the AP resends ADDBA every second and aggregation never happens. CCMP keys now get `IEEE80211_KEY_FLAG_SW_MGMT_TX`.
- `b43_op_set_key` does `B43_WARN_ON` and returns -EINVAL for unsupported cipher suites (MFP's BIP): changed back to -EOPNOTSUPP
  so mac80211 falls back to software, no more WARN spam.

**Result** (Mbit/s, workstation wired, short range; values in parentheses are before this round)

| | UDP TX | TCP TX | UDP RX | TCP RX |
|---|---|---|---|---|
| 5GHz `htphy_11n=2` | 102–115 (24) | 76–85 (19) | 117–121 (25) | 56–98 (19) |
| 2.4GHz `htphy_11n=2` | 50–77 (22) | 20–60 (18) | 101–107 (23) | 34–66 (18) |
| wl 5GHz (measured at the same time) | 204 | 165 | 251 | 205 |

The 2.4GHz channel is busy, large variance. Rate settles at MCS 14–15 (2 streams). Known issue: with TCP running in both directions simultaneously our side only gets
a few Mbit/s — the AP's A-MPDUs are 5 ms and ours 1.5 ms, and most of the TX opportunities we win are filled with TCP ACKs for the other direction's flow.
(Round 14: wl behaves the same, not considered a problem.)

## Round 14: coding rate 2/3 cannot be transmitted, A-MPDU extended to 3 ms, BAR storm (2026-10-03)

**The "long A-MPDU tail loss" was actually MCS 13 being broken.** Tallying BAs per A-MPDU by MCS: fixed MCS 15, 14, 12, 7
show almost no loss even at 5–6 ms; MCS 13 and MCS 5 never get a single BA, the same for single frames, the workstation monitor cannot decode a single frame either,
and the ucode reports no error (neither txphyerr nor txfunfl increases). Previously at 1.5 ms minstrel always stayed on MCS 15, so this was invisible;
once A-MPDUs got longer, minstrel occasionally probed down to MCS 13 and lost the whole batch, which statistically looked like "tail loss".
- Coding rate in the high byte of TX header PHY control word 1 (brcmsmac mcs_table: 2/3 = 1, 3/4 = 2, 5/6 = 4). Sweeping 0–7:
  all odd values (bit 8 set) fail to transmit, all even values work, and for MCS 15 filling 0, 2, 4, 6 gives the same throughput → the HT-PHY takes the coding rate
  from the PLCP (HT-SIG / L-SIG), and this bit means something else here. 2/3 now filled as 0.
- Plain OFDM 48 Mbit/s uses the same bit (upstream b43's `B43_TXH_PHY1_CRATE_2_3`) and likewise fails to transmit on the HT-PHY;
  this is an upstream bug (minstrel routes around it, so nobody noticed). The bit is now cleared on HT-PHY.
- After the fix, MCS 15 fixed rate at 3 ms and 5 ms shows no tail loss; the rationale for the 1.5 ms cap no longer holds. Changed to 3 ms
  (brcmsmac uses 5 ms): on 5GHz 3 ms and 5 ms are the same, on the busy 2.4GHz channel TCP is slightly worse at 5 ms.
- Also: with the workstation's ath12k monitor set to 80 MHz it can barely decode our 20 MHz HT frames (only MCS 0 is visible);
  it needs HT20 (the default of `mon_on` in `tools/air.sh` was changed).

**BAR storm**: mac80211 sends one BAR for every abandoned frame marked `AMPDU_NO_BACK`; one bad A-MPDU abandons dozens of frames,
the BARs queue up one after another, each taking a channel access (captured 2500 BAR/BA exchanges in 3 seconds, data nearly stalled). Changed to have the driver send them itself:
at most one BAR per status, start = last abandoned frame + 1, but not beyond the oldest frame still pending retransmission or still in flight (otherwise the peer
discards it as an old frame), and never earlier than the previously sent BAR.

**Bidirectional TCP**: wl likewise gets ~200 in one direction and 3–4 Mbit/s in the other; this is AP/TCP behavior, not our problem.

**Result** (Mbit/s, values in parentheses are from Round 13)

| | UDP TX | TCP TX | UDP RX | TCP RX |
|---|---|---|---|---|
| 5GHz | 115–119 (102–115) | 93 (76–85) | 119–121 | 104–105 (56–98) |
| 2.4GHz | 86–89 (50–77) | 60–62 (20–60) | 101–103 | 88–90 (34–66) |

5GHz 60-second continuous TCP is stable in every 10-second interval (TX 93–95, RX 104–108). 20 MHz two-stream MCS 15 short GI is 144 Mbit/s,
so UDP at 120 is essentially at the ceiling; going higher requires 40 MHz.

## Round 15: 40 MHz, controller restart, null-delimiter limit (2026-10-03)

`htphy_11n=3`: on top of 2, advertise HT40 (`SUP_WIDTH_20_40`, `SGI_40`).

**What wl does** (wl-5g trace: on association it switches from ch44 20 MHz to ch44 + 48, i.e. 40 MHz centred on 5230). Used
`tools/regdiff.py file@line` to compare the state at two points of the same trace (after 20 MHz ch44 is set up vs after 40 MHz is set up),
then `tools/condense.py` to compare the write sequences of the two channel switches line by line:
- Bandwidth = the PHY clock bit in the core IOCTL (0x80 = 40 MHz/160 MHz PHY clock): wl writes 0x9d → 0x93 → 0x95,
  i.e. a PHY reset with the new bandwidth bit, then the usual init. In b43 this goes into `b43_switch_band()`: a bandwidth change
  resets and re-initialises the PHY just like a band change (scanning bouncing 40↔20 also takes this path, ~0.1 s each).
- Which half the primary channel is in: PHY 0x0a0 bit 4, 0x310 bit 15 (brcmsmac N-PHY rev7 BPHY_BAND_SEL_UP20 /
  PRIM_SEL_UP20; same address and meaning on HT-PHY; both bits cleared for ch44+48).
- Tune the radio to the centre frequency: add 40 MHz centres (5190, 5230, …) to the channel table. 5230 is taken verbatim from the trace; the rest are
  interpolated, with the rule verified against 5230: synthesizer word = 4096 + f/3; the fractional part and BW1–6 take the midpoint of the two neighbouring
  20 MHz channels; everything else (which steps per sub-band) takes the upper neighbour. The 2.4GHz 40 MHz centres were already in the table.
- SHM channel cookie: the centre channel number (both wl and brcmsmac do this, so the channel in the RX header becomes the centre channel too; `b43_rx`
  maps it back to the primary channel). Must **not** set `B43_SHM_SH_CHAN_40MHZ` (wl does): firmware 666.2 compares only the channel number from the TX header
  plus the 5GHz bit, so with 0x200 set every frame is judged a channel mismatch, TX status suppress=4, and nothing is transmitted.

**TX**: 40 MHz MCS frames have bandwidth = 4 in PHY control word 1, and HT-SIG byte 1 bit7; data bits per symbol are 54/26 of
20 MHz (L-SIG length, A-MPDU length limit and rate are all computed from it). 20 MHz frames (management, fallback) on a 40 MHz channel
get bandwidth 20U (=3) when the primary channel is the upper half, 20 (=2) when it is the lower half.

**Controller restart fixed (upstream bug)**: b43's `b43_chip_reset()` re-initialises by itself and then only replays config and
BSS info; but init wipes the hardware key table without mac80211 knowing, so under WPA every frame is silently dropped with -ENOKEY:
the link is "connected" but passes no traffic. Same at 20 MHz with HT off (reproducible via debugfs `restart`). Changed to stop the core and hand over to
`ieee80211_restart_hw()`, so mac80211 does the start, adds the interface, and replays keys and aggregation sessions. The PHY reset on the
restart path also sets the IOCTL according to the current bandwidth.

**Null delimiters**: at 40 MHz, TCP RX (we send A-MPDUs of small TCP ACK frames) with a 10 µs spacing gives ~75 TX
FIFO underflows per second (SHM txfunfl), sometimes in bursts; more than 1000 PHY errors in 15 s triggers a controller restart. Increasing the spacing to
16 µs brings underflows to zero; but larger spacings get every A-MPDU aborted by the PHY (txphyerr counter skyrockets, throughput halves):
sweeping the limit with a fixed 30 µs spacing, up to 124 null delimiters after a single MPDU is fine, 127 and above errors. Now 16 µs + limit 120.
At 20 MHz likewise 0 underflows, 0 errors.

**Results** (Mbit/s, 5GHz ch44 HT40+, close range; wl under the same conditions)

| | UDP TX | TCP TX | UDP RX | TCP RX |
|---|---|---|---|---|
| b43 `htphy_11n=3` | 220 | 161–166 | 253 | 191 |
| wl | 204 | 165 | 251 | 205 |
| b43 `htphy_11n=2` (20 MHz) | 119 | 93–94 | 119 | 100–101 |

minstrel mostly sits at HT40 short-GI MCS 15 (300 Mbit/s, 97% success). 10 minutes of stress (TCP RX/TX, UDP,
alternating bidirectional, a full-band scan every 2 minutes): no restarts, 0 underflows, 0 PHY errors. Bidirectional TCP gives ~180 / ~7,
wl ~203 / ~4, same behaviour. 2.4GHz: DECO on ch10 HT40- (primary channel in the upper half, takes the 20U path),
UDP RX 180, TCP RX 130, UDP TX 130–150, TCP TX 55–70 (busy channel).

**40 MHz differences not copied** (wl has them, b43 doesn't; close-range throughput already matches wl, long range/sensitivity may be affected,
can't measure): 0x280/0x283 low byte 0x3c (0x3f at 20 MHz, b43 init writes 0x3e/0x40); 0x424/0x464/0x4a4
low 6 bits 0x18 (0x19 at 20 MHz; incidentally found that b43 init's `maskset(0x424, 0x3f, 0xd)` has the mask inverted and clears the high bits;
wl has 0x14d); table 8 [4,5] 0xfc60/0xc (0xa840/0x8 at 20 MHz, 0 in b43); table 7 [0x14a…] 4 (2 at 20 MHz);
0x911 0xcc; 0x2f2/0x2f3 not written (written as 0x1c1c/0x1c at 20 MHz).

## Round 16: Stability (2026-10-04)

Tools: `tools/stress.sh` (run as root on the Mac mini: `reconnect`/`linkflap`/`restart`/`band`/`scan` × N; records seconds from the action until
the gateway answers ping, timestamps anything over 2 seconds), `tools/scanping.sh` (ping every 20 ms during a scan),
`tools/soak-mini.sh` + `tools/soak-ws.sh` (long runs: Mac mini logs link/errors/memory every minute, workstation pings every second and every 10 minutes
runs 30 s of TCP in each direction). Baseline is wl under the same conditions.

| Seconds | b43 before fixes | b43 after fixes | wl |
|---|---|---|---|
| Reconnect (nmcli down/up, 5 GHz 40 MHz) | 1–15, often needs auth retransmit | 1.1 ×22, 0 retransmits | 0–2.2 |
| Band switch (5 GHz ↔ 2.4 GHz BSSID) | 1.2–15.9 | 1.1–2.6, occasionally ~6 (see 4) | 2.2 |
| Controller restart (debugfs) | 0–0.9 | — | — |
| ip link down/up | 4–4.6 | 4–4.6 (see 5) | 2.0 |
| Incoming ping loss during scan (10/s) | 66% | **0%** | 0% |
| rmmod/insmod ×12 | No memory/slab growth, no WARN | | |

1. **Reconnecting at 40 MHz after disconnect gets no auth response**: after disconnect cfg80211 falls back to the world regdomain, all of 5 GHz is NO_IR,
   and by rule we don't calibrate; at 40 MHz without calibration (RX IQ coefficients left over from the last 2.4 GHz run) the AP's auth/assoc
   responses aren't received (over the air: AP replies immediately, retries 7 times, we never ACK) until wpa_supplicant completes a scan and a beacon lifts
   NO_IR so calibration runs. 20 MHz doesn't have this problem. Changed to calibrate in `mgd_prepare_tx`: mac80211 is about to send
   auth/assoc frames on this channel, so transmitting is allowed. Zeroing the RX coefficients isn't enough (tried).
2. **Calibration cache kept across chip re-init** (ifup, controller restart): as with band switches the radio is re-initialised,
   so the cache is equally valid; ifup is 80 ms faster (120 → 40 ms after firmware load); recalibration still happens every 2 minutes.
3. **No 40 MHz on 2.4 GHz**: at 2.4 GHz 40 MHz (DECO ch10 HT40-, primary channel in upper half) ~20% of CCK RX is lost
   (beacons in 30 s: 235/293; 281 at 20 MHz; 293 at 5 GHz 40 MHz). The AP answers auth at 1 Mbit/s on 2.4 GHz,
   so about one in five connections needs an auth retransmit and waits 10 s. wl also only uses 20 MHz on 2.4 GHz (over the air all frames are 20 MHz),
   so do the same: HT40 is advertised on 5 GHz only. Root cause not investigated (maybe settings needed for upper-sideband CCK RX; the trace has no wl
   2.4 GHz 40 MHz data).
4. **NetworkManager scans with a random MAC**: mac80211 can't change the MAC while the interface is up, so before every connection NM does
   down/up twice to restore the real MAC; a wpa_supplicant scan colliding with that gets `SCAN-FAILED ret=-100` and retries after ~5 s
   (b43 111/535 connections; wl can change MAC online, 0/151). With `wifi.scan-rand-mac-address` temporarily disabled, band switches take
   1.1–1.7 s with 0 retransmits. Not a driver problem; if b43 becomes the default, disable it in the host config.
5. **ip link down/up 2 s slower**: after ifup, under the world regdomain all of 5 GHz is passive scan, and one mac80211 software scan round takes
   ~3 s; wl uses firmware scanning.
6. **All frames from the AP lost during scans (upstream bug, fixed)**: the microcode rewrites the PM bit of every transmitted frame from MACCTL's HWPS bit,
   and b43 never sets it, so the PM=1 null frame mac80211 sends before leaving the channel goes out over the air with PM=0 (confirmed by air capture); the AP keeps
   sending to us and drops after retries. NM scans in the background every 5 min 15 s, each time losing 2–8 s of inbound traffic. Now before sending a
   (QoS) null frame, HWPS is set/cleared according to its PM bit (AWAKE stays set), and cleared when the scan ends. One ping every 100 ms during a scan
   went from 66% loss to 0% (a few delayed >300 ms, buffered by the AP). Locally originated traffic still loses about half during scans
   (mac80211 stops the queues, fq_codel drops packets that waited too long); every software-scanning driver is the same; wl's firmware scan takes 1.6 s
   with no loss, which we can't match.
7. Each scan bounces between 5 GHz 40 MHz and the scan channels; each bandwidth change needs PHY reset + init, ~40 ms.

**3-hour soak** (after fix 6; 5 GHz 40 MHz, mostly idle, 30 s of TCP each direction every 11 minutes): stayed at
40 MHz, MCS 15 throughout; PHY errors, underflows, controller restarts and disconnects all 0; workstation pinging once per second lost 5 of 10884
(the same soak for 1 hour before fix 6: 2–8 lost per background scan); TCP RX ~193, TX ~164, stable; available memory and
slab flat (the final slab increase is nix-optimise at 04:12 walking the whole store, bcachefs inode cache). No GTK rekey
occurred during the run (DECO's interval is probably longer).

Remaining: at 2.4 GHz 20 MHz ~5% of connections get no response to the first auth round (no air capture yet, not determined whether it's our problem);
on the host side, NM scan MAC randomisation must be disabled if b43 becomes the default (see 4).

## Round 17: 2.4 GHz auth re-check, LDPC, channel setup completed per wl (2026-10-04)

**No response to first 2.4 GHz auth round**: re-ran with air capture, 40 reconnects + 40 band switches, 0 auth retransmits; can't
reproduce, probably one of the issues fixed in round 16. The remaining 5–10 s cases are all host-side: `SCAN-FAILED` (round 16 item 4),
or a wpa_supplicant scan blocked by NM's running full-band passive scan ("Reject scan trigger since one is
already pending").

**STBC not done, LDPC RX done**: capturing wl's association request, it advertises LDPC RX and Greenfield RX and no STBC
in either direction (the AP supports both), so this HT-PHY probably has no STBC at all. Advertise LDPC RX like wl: under
moderate load (50 Mbit/s UDP) the AP uses LDPC almost exclusively (61384 LDPC vs 3391 BCC), 0.08% with the retry flag; at full load
it falls back to BCC by itself (~3% LDPC, all MCS 15). Counted LDPC frames in the driver (HT-SIG byte 4 bit 6): 0
FCS errors. Throughput unchanged; long-range gain can't be measured. TX uses BCC only (mac80211's LDPC flag only permits it). RX status
now carries the HT-SIG LDPC and STBC bits. Greenfield not advertised: the AP doesn't send it, can't test.

**Channel/bandwidth setup completed per wl** (`b43_phy_ht_bw_setup()`, called after every channel set). Method: read b43's actual
register values and compare one by one against wl snapshots on the same channel ch44 after 20 MHz setup and after 40 MHz association has settled (the snapshot diffs include
calibration and power control state, so only registers written during channel setup are picked); then tally the values wl writes per channel cookie. Note that wl writes
the cookie earlier or later depending on the path, so attributing by cookie mixes in state from the previous channel; look at where the writes happen too.
- 0x0a0 bit 4 (primary channel in upper half) is 1 after reset; we previously only wrote it at 40 MHz, so it was wrong at 20 MHz all along.
- LNA1 table (round 9): select the sub-band by the frequency the radio is actually tuned to: 40 MHz ch44 is centred on 5230, wl uses the 5230–5700 set
  (that's what "tables 0/1 [8–11] each minus 1 at 40 MHz" was).
- 0x280/0x283 low byte (looks like CRS minimum power): wl default 0x3f, 0x41 on 5 GHz from 5765 up, 0x3c at 40 MHz;
  upstream hardcodes 0x3e/0x40 (along with the comment "Did wl mean 2 instead of 40?"). wl adjusts it dynamically with interference (seen
  0x37–0x6d on ch6); we don't.
- 0x424/0x464/0x4a4: 2.4 GHz 0x14d, 5 GHz 0x159, 40 MHz 0x158 (also varies with interference). Upstream's
  `maskset(0x424, 0x3f, 0xd)` has the mask inverted and clears 0x140 (upstream bug); 0x464/0x4a4 are never written.
- Table 7 [0x14a/0x15a/0x16a] 4 at 40 MHz, 2 at 20 MHz; table 8 [4,5] (+16 per core) 0xa840/8 at 20 MHz, 0xfc60/0xc at 40 MHz,
  0 upstream; 0x2f2/0x2f3 are 0x1c1c/0x1c on both bands (not written upstream, reset value 0x0e0e/0x0e).
- 0x186–0x194 are the TX digital filter for the 20 MHz path (N-PHY's TXF_20CO). The reset value is exactly N-PHY's 40 MHz
  coefficients (`tbl_tx_filter_coef_rev4[3]`), which wl uses everywhere except 2.4 GHz ch1 and ch13; those two edge channels switch to a
  steeper set (ch2 seen with both; not copied). Independent of bandwidth.
- Not copied: 0x911 etc. (wl 0xcd, ours 0xcc; at 40 MHz wl's high bits vary), table 7 [272–274] (differs per
  channel, looks dynamic).

Close-range A/B (6 alternating loads): same throughput, RX retry rate 0.15–0.20% vs 0.16–0.17%, no visible difference,
as expected (sensitivity-related effects only show at long range). Since these are all wl's values with no regression, enabled by default.

## Round 18: TX FIFO underflow with long A-MPDUs at MCS 14/15 (2026-10-04, in progress)

Found while testing at medium signal (Mac mini in a metal bin, 5 GHz at -60 dBm, HT40 MCS 14/15): every TX test logs dozens of
"PHY transmission error" per second (behind net_ratelimit, so the log undercounts it). Same with the previous build, so not a regression.

- Only when we transmit data; never in the RX direction (A-MPDUs of TCP ACKs), never at 2.4 GHz / 20 MHz.
- txfunfl[BE] (SHM macstat) counts them one to one. The A-MPDU concerned gets a TX status with suppress reason 3 (brcmsmac:
  TX_STATUS_SUPR_FRAG, which its ffpld code treats as the underflow event) and none of its MPDUs is sent. ~8% of all A-MPDUs.
- Fixed MCS 12 or 13: (almost) none. Fixed MCS 14 or 15: hundreds per 10 s, at MCS 15 enough to trip the controller restart.
- Depends on the A-MPDU length: < 16 KB never, 16–48 KB ~5–10%, 56–64 KB 20–25%. A-MPDUs containing retried MPDUs are worse
  (24–40 KB: ~28% vs ~2%), which is also why it shows at medium signal and was 0 at close range (round 16).
- Not the fallback fields: brcmsmac's ampdu_finalize also sets the fallback L-SIG length and PLCP aggregation bit; doing so changes
  nothing. B43_TXH_MAC_USEFBR stops the underflows, but because it sends the whole A-MPDU at the fallback rate (MCS 7; checked by
  logging rate/fallback pairs), UDP drops to ~120.
- Not "nothing prefetched": capping only A-MPDUs queued when none is in flight does not help.
- This is what brcmsmac's ffpld code handles: DMA slower than the PHY at the top MCS, so the FIFO drains during a long PPDU; it
  preloads (TX header preload_size; stalls this firmware) and failing that lowers the per-MCS A-MPDU size on underflow feedback.

Cap on the A-MPDU length at MCS 14/15 (> 250 Mbit/s), same position, alternating runs, Mbit/s:

| cap | underflows / 10 s | UDP TX | TCP TX |
|---|---|---|---|
| none (64 KB) | 430–600 | 165–179 | 62–90 |
| 48 KB | 520–600 | 178–179 | 68–90 |
| 32 KB | 46–202 | 205–208 | 133–149 |
| 24 KB | 0–14 | 191–197 | 142–145 |
| 16 KB | 0–9 | 174–176 | 118–121 |

wl at the same position: UDP 176, TCP 75.

Two candidates, kept on branches in the kernel tree (not in the series yet):
- `ufl-cap`: fixed 24 KB above 250 Mbit/s.
- `ufl-adapt`: per bandwidth and MCS, an underflow cuts the limit to 3/4 of the lost A-MPDU (floor 8 KB), each A-MPDU that
  reached the limit raises it by 8 bytes. The underflow status is suppress reason 3 (B43_TXST_SUPP_PREV); _UNDER (6) never
  shows up, and brcmsmac likewise treats TX_STATUS_SUPR_FRAG on an A-MPDU as the underflow event.

Same position (-59 dBm), alternating, two runs of each per load, Mbit/s:

| | underflows / 10 s | UDP TX | TCP TX |
|---|---|---|---|
| none | 337–609 | 163–176 | 61–74 |
| `ufl-cap` | 0–95 | 186–203 | 122–148 |
| `ufl-adapt` | 13–19 | 183–197 | 129–140 |

`ufl-adapt` settles at 14–35 KB for MCS 14/15 here. To do: compare both at close range (64 KB A-MPDUs gave UDP 220 there,
with no underflows), then pick one.

PHY TX errors are now logged as a count every 15 s instead of one rate-limited message each (patch 0009).

## Next steps

1. Calibration complete (TX IQ/LO, RX IQ on both bands, redone every 120 s). Optional: split into multiple partial calibrations like wl
   to break up the 80 ms TX stall; calibration behaviour on DFS channels (currently only done after association).
2. Table 8: already restricted by pdet_range (see round 8). Other pdet_range values lack a reference; revisit if other boards turn up.
3. Other tables only wl writes: 0/1/2/3/40/41/47 handled (round 9). Table 17 = brcmsmac's
   `NPHY_TBL_ID_SAMPLEPLAY`, the test tone samples played during calibration; differences are just a different tone, no effect on TX/RX, not ported.
   Table 13 = IQLOCAL, i.e. IQ/LO calibration (done in round 10).
4. Long-range verification: the machine is hard to move. Tried running hostapd on the workstation's wlan0: 5GHz not allowed to transmit (No IR); the 2.4GHz AP
   came up but both b43 and wl got stuck at auth with no response from the AP, cause not investigated; and TX power can only go down to 10 dBm, so of limited value.
5. 802.11n: HT, A-MPDU in both directions, 40 MHz on 5 GHz and LDPC RX done (rounds 13–17); throughput on par with wl at close range.
   Not done: AP-mode TX aggregation; no STBC (wl doesn't advertise it on this chip); 40 MHz centre frequencies other than 5230 MHz are
   interpolated and untested.
6. Upstreaming: rebase on wireless-next and split the generic fixes (see README) into separate patches.

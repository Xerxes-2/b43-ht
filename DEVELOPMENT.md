# Development

The driver is developed as a series of commits in a kernel tree; this repo
holds the exported series, the Nix packaging, the notes and the tools.

## Setup

```sh
git clone https://git.kernel.org/pub/scm/linux/kernel/git/wireless/wireless-next.git linux
cd linux
git config user.name "Your Name"; git config user.email you@example.org
git switch -c b43-ht origin/main
for p in $(grep -v '^#' ../b43-ht/patches/series); do git am ../b43-ht/patches/$p; done

# Build directory for compile checks (outside the source tree)
make O=../linux-build defconfig
scripts/config --file ../linux-build/.config -e WLAN -e WLAN_VENDOR_BROADCOM \
  -e CFG80211 -e MAC80211 -e BCMA -e SSB -m B43 -e B43_BCMA -e B43_SSB \
  -e B43_PHY_N -e B43_PHY_LP -e B43_PHY_HT -e B43_PHY_G -e B43_DEBUG
make O=../linux-build olddefconfig prepare
```

## Workflow

1. Change the code as commits on the `b43-ht` branch. Fixes meant for
   upstream go first, each self-contained (it builds and works without the
   later patches), in kernel style: `wifi: b43: ...` subject, a description
   of the problem and its effect, `Fixes:` where a commit introduced it.
   Everything else stays in the last patch until split out.

   Much of this work was done with an AI coding assistant. Per
   Documentation/process/coding-assistants.rst and generated-content.rst,
   commits carry an `Assisted-by:` tag and the assistant never adds
   `Signed-off-by:`: the human submitter reviews each patch and signs it off
   (`git rebase --signoff <base>`) right before sending, and the cover
   letter says which parts were tool-assisted and how they were tested.
2. Check every commit builds and is checkpatch-clean:
   `B=../linux-build ../b43-ht/tools/kbuild-check.sh origin/main..b43-ht`
3. Export: `../b43-ht/tools/export-series.sh . origin/main`
4. Test on hardware: the Nix package applies `patches/series` to the running
   kernel's b43 (or use `nix/package.nix` with a different series for a
   one-off). See tools/README.md for the measurement scripts.
5. Rebase on wireless-next from time to time:
   `git fetch && git rebase origin/main`, then re-run 2 and 3.

## Testing fixes for upstream

Each fix is tested on its own, against the configuration upstream users
have (HT-PHY on 2.4 GHz only, no 802.11n, i.e. without the last patch): once
without the fix, showing the problem, and once with it. The result goes into
the table below before the patch is sent.

## Upstream status

| # | Patch | Batch | Tested alone (BCM4331, 2.4 GHz, 6.18 b43 + this patch only) | Sent | Status |
|---|---|---|---|---|---|
| 1 | HT-PHY: fix the TX power estimate table upload | 1 | Table read back: odd entries 0 before, monotonic after. Monitor signal -4..5 dB, minstrel success 36M 40%→84%, 54M 31%→60% | | |
| 2 | HT-PHY: don't flag coding rate 2/3 in PHY control word 1 | 1 | Monitor decodes 0 of ~2500 frames at 48M before, 124 after (54M visible in both) | | |
| 3 | return -EOPNOTSUPP for ciphers the hardware can't do | 1 | WARN in b43_op_set_key and "failed to set key (4, ...) (-22)" on every PMF connection before, none after | | |
| 4 | encrypt protected management frames in software | 1 | Our SA Query responses / RM reports / deauth decrypt with the PTK only after; before they match a QoS-data nonce/AAD | | |
| 5 | HT-PHY: read the low half of 32-bit table entries first | held: needs the 5 GHz / calibration code that reaches it | No visible effect: the stale read only hits core 0 on the first channel switch, later calls latch the right value | | |
| 6 | HT-PHY: restore the baseband multipliers to the right slots | held: needs the 5 GHz / calibration code that reaches it | Not observable: the only playback is during init, the channel switch rewrites the slots | | |
| 7 | HT-PHY: fix saving and restoring the TX power control index | held: needs the 5 GHz / calibration code that reaches it | Not observable: power control is only toggled at init, when nothing has been saved | | |

b43 is orphaned (MAINTAINERS: `S: Orphan`); patches go to
linux-wireless@vger.kernel.org and b43-dev@lists.infradead.org and are
picked up by the wireless maintainers.

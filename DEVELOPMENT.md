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

## Submission rules

Besides Documentation/process/submitting-patches.rst, linux-wireless has its
own rules
(https://wireless.docs.kernel.org/en/latest/en/developers/documentation/submittingpatches.html).
The ones that matter here:

- **Target tree in the subject prefix**: `[PATCH wireless-next n/m]`. Fixes
  for regressions or serious bugs in the current release would go to
  `wireless`; the bugs fixed here date back to 2011-2020 and are not
  recent regressions, so everything goes to wireless-next. `export-series.sh` sets
  the prefix; in the kernel tree `git config format.subjectPrefix "PATCH
  wireless-next"`, with b4 `b4 prep --set-prefixes wireless-next`.
- **Subject** `wifi: b43: ...` (`wifi: b43: HT-PHY: ...` for HT-PHY code),
  imperative.
- **Description says why.** Problem, effect for users, how it was tested. If
  a fix has no user-visible effect (only theoretical), say so plainly. A
  bulleted list of changes usually means the patch should be split.
- **Tags**: `Fixes: <12-char sha> ("subject")` when a commit introduced the
  bug, above `Assisted-by:` and `Signed-off-by:`. checkpatch verifies the
  sha and subject.
- **Series size**: at most about 7-12 patches. A new version resends the
  whole series as `[PATCH wireless-next v2 n/m]`, with the changes since v1
  in the cover letter.
- **Addressing**: To linux-wireless@vger.kernel.org. b43 has no maintainer,
  so Cc b43-dev@lists.infradead.org, and people who reviewed b43 recently
  (Michael Büsch acked the N-PHY rev 8 series in 2026). Check with
  `scripts/get_maintainer.pl`.
- **Mail**: plain text, inline patches, no PGP signature, no top-posting.
  b4 (web endpoint) takes care of the first three.
- **Follow-up**: status is on patchwork
  (https://patchwork.kernel.org/project/linux-wireless/list/), not by
  pinging the maintainer.

### AI assistance

The wireless maintainer, Johannes Berg, said in August 2026 (LKML thread
"sysbot AI patches and wireless",
https://lore.kernel.org/lkml/3b6c46b6d79f3a0e0ded2967db3cfd469314b05c.camel@sipsolutions.net/)
that he will ignore syzbot's AI-generated patches unless a quick look shows
they are obviously right, and won't argue with an LLM. The thread is about
syzbot, but the complaints apply to any assisted patch: narrow point fixes
with a lot of explanation around them, where nobody stepped back to ask
what the code should do in the first place, and human "reviewers" who only
pass LLM output along. So:

- `Assisted-by:` is required and stays honest; the submitter signs off only
  after reviewing and understanding every patch.
- The submitter must be able to explain and defend each patch on the list,
  in their own words. Replies to review are written by the submitter, not
  pasted from an assistant.
- Prefer the fix that matches the hardware's semantics over a patch on top
  of wrong code (e.g. don't set a field the PHY ignores, rather than
  setting it and masking a bit back out).
- Keep descriptions short: the facts, the measurement, one or two key
  references. Background goes in NOTES.md or the cover letter.

## Testing fixes for upstream

Each fix is tested on its own, against the configuration upstream users
have (HT-PHY on 2.4 GHz only, no 802.11n, i.e. without the last patch): once
without the fix, showing the problem, and once with it. The result goes into
the table below before the patch is sent.

## Upstream status

| # | Patch | Batch | Tested alone (BCM4331, 2.4 GHz, 6.18 b43 + this patch only) | Sent | Status |
|---|---|---|---|---|---|
| 1 | HT-PHY: fix the TX power estimate table upload | 1 | Table read back: odd entries 0 before, monotonic after. Monitor signal -4..5 dB, minstrel success 36M 40%→84%, 54M 31%→60% | | |
| 2 | HT-PHY: don't set the coding rate in PHY control word 1 | 1 | Monitor decodes 0 of ~2500 frames at 48M before, ~200 after (two runs each); 9/18/36/54M (3/4, field now 0) decode the same before and after; 5 GHz with the full series: 9-54M only, 0% loss | | |
| 3 | return -EOPNOTSUPP for ciphers the hardware can't do | 1 | WARN in b43_op_set_key and "failed to set key (4, ...) (-22)" on every PMF connection before, none after | | |
| 4 | encrypt protected management frames in software | 1 | Our SA Query responses / RM reports / deauth decrypt with the PTK only after; before they match a QoS-data nonce/AAD | | |
| 5 | HT-PHY: read the low half of 32-bit table entries first | held: needs the 5 GHz / calibration code that reaches it | No visible effect: the stale read only hits core 0 on the first channel switch, later calls latch the right value | | |
| 6 | HT-PHY: restore the baseband multipliers to the right slots | held: needs the 5 GHz / calibration code that reaches it | Not observable: the only playback is during init, the channel switch rewrites the slots | | |
| 7 | HT-PHY: fix saving and restoring the TX power control index | held: needs the 5 GHz / calibration code that reaches it | Not observable: power control is only toggled at init, when nothing has been saved | | |
| 9 | report PHY transmission errors as a count every 15 s | candidate for batch 2 | Not yet tested alone (no PHY TX errors at 2.4 GHz). Full series, 5 GHz MCS 15 at -59 dBm: "N PHY transmission errors in the last 15 s", N = 420-815 without an A-MPDU limit, matching txfunfl | | |
| 10 | HT-PHY: shorten A-MPDUs per MCS after TX FIFO underflows | not upstream on its own (needs A-MPDU TX from patch 8) | Full series, 5 GHz HT40 MCS 15: underflows 400-600 -> 8-17 per 10 s, TCP TX 55-79 -> 130-137 | | |

b43 is orphaned (MAINTAINERS: `S: Orphan`); patches go to
linux-wireless@vger.kernel.org and b43-dev@lists.infradead.org and are
picked up by the wireless maintainers (see Submission rules).

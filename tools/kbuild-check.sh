#!/usr/bin/env bash
# Compile-checks b43 at every commit of a range and runs checkpatch on each.
# Runs on the workstation, in a kernel tree with a prepared build directory.
# Usage: kbuild-check.sh <base>..<tip>   (env: B = build dir, default ../linux-build)
set -u
B=${B:-$(realpath ../linux-build)}
range=${1:?usage: kbuild-check.sh base..tip}
orig=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
fail=0
for c in $(git rev-list --reverse "$range"); do
  git checkout -q "$c" || exit 1
  printf '%s %s\n' "$(git log -1 --format=%h "$c")" "$(git log -1 --format=%s "$c")"
  if ! log=$(make O="$B" -s -j"$(nproc)" W=1 drivers/net/wireless/broadcom/b43/ 2>&1); then
    echo "  BUILD FAILED"; fail=1
  fi
  grep -E 'warning|error' <<<"$log" | sed 's/^/  /'
  git format-patch -1 --stdout "$c" | scripts/checkpatch.pl -q --strict --no-signoff - | grep -E '^(ERROR|WARNING|CHECK)' | sed 's/^/  /'
done
git checkout -q "$orig"
exit $fail

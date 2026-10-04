#!/usr/bin/env bash
# Exports the patch series from a kernel tree into this repo's patches/.
# Runs on the workstation. The kernel tree is a wireless-next clone with the
# series as commits on a branch; patches/series lists them in order and
# records the base commit (git format-patch --base).
# Subjects get the target tree in the prefix, as linux-wireless asks
# ("[PATCH wireless-next n/m]"); set PREFIX to override.
# Usage: export-series.sh <kernel-tree> [<base> [<branch>]]
#   base defaults to origin/main, branch to b43-ht.
set -eu
tree=${1:?usage: export-series.sh <kernel-tree> [base [branch]]}
base=${2:-origin/main}
branch=${3:-b43-ht}
out=$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches" && pwd)
base=$(git -C "$tree" merge-base "$base" "$branch")
rm -f "$out"/*.patch "$out/series"
git -C "$tree" format-patch -q --zero-commit --no-signature --base="$base" \
	--subject-prefix="${PREFIX:-PATCH wireless-next}" -o "$out" "$base..$branch"
{
	echo "# Base: $(git -C "$tree" log -1 --format='%H (%s)' "$base")"
	(cd "$out" && ls -1 [0-9]*.patch)
} > "$out/series"
cat "$out/series"

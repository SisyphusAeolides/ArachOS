#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOCK=$ROOT/sources.lock

declare -A source_roots=(
  [rustd]="${RUSTD_SOURCE_ROOT:-$ROOT/../rustd}"
  [rustd-resolved]="${RESOLVED_SOURCE_ROOT:-$ROOT/../rustd-resolved}"
  [arach-kernel]="${ARACH_KERNEL_SOURCE_ROOT:-$ROOT/../arach-kernel}"
  [iwchaos]="${IWCHAOS_SOURCE_ROOT:-$ROOT/../iwchaos}"
  [tuned-rs]="${TUNED_SOURCE_ROOT:-$ROOT/../tuned-rs}"
  [libinput-rs]="${LIBINPUT_SOURCE_ROOT:-$ROOT/../libinput-rs}"
  [blerust]="${BLERUST_SOURCE_ROOT:-$ROOT/../blerust}"
  [ccze-rs]="${CCZE_SOURCE_ROOT:-$ROOT/../ccze-rs}"
  [hermes]="${HERMES_SOURCE_ROOT:-$ROOT/../Hermes}"
  [arach-hwd]="${ARACH_HWD_SOURCE_ROOT:-$ROOT/../Arach-HWD}"
  [corinth]="${CORINTH_SOURCE_ROOT:-$ROOT/../Corinth}"
)

fail() { printf 'source verification: %s\n' "$*" >&2; exit 1; }

for name in "${!source_roots[@]}"; do
  repo=${source_roots[$name]}
  [[ -d $repo/.git ]] || fail "$name checkout is missing: $repo"
  expected=$(awk -v key="$name" '$1 == key {print $3}' "$LOCK")
  [[ $expected =~ ^[0-9a-f]{40}$ ]] || fail "invalid lock entry for $name"
  actual=$(git -C "$repo" rev-parse HEAD)
  [[ $actual == "$expected" ]] || fail "$name is $actual, expected $expected"
  [[ -z $(git -C "$repo" status --porcelain --untracked-files=normal) ]] \
    || fail "$name checkout has uncommitted changes"
done

# Calamares is fetched by its ArachOS PKGBUILD rather than as a sibling
# checkout. Keep its source revision in the same lock file and verify the
# package definition before makepkg is allowed to fetch it.
calamares_lock=$(awk '$1 == "calamares" {print $3}' "$LOCK")
[[ $calamares_lock =~ ^[0-9a-f]{40}$ ]] || fail 'invalid lock entry for calamares'
calamares_commit=$(sed -n 's/^_commit=//p' "$ROOT/packaging/pkgbuild/calamares/PKGBUILD")
[[ "$calamares_commit" == "$calamares_lock" ]] \
  || fail "calamares PKGBUILD is $calamares_commit, expected $calamares_lock"

printf 'verified %d source checkouts against %s\n' "${#source_roots[@]}" "$LOCK"

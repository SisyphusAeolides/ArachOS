#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${IWCHAOS_SOURCE_ROOT:-$root/../iwchaos}

fail() { printf 'chaos component check: %s\n' "$*" >&2; exit 1; }
[[ -d $source_root/.git ]] || fail "iwchaos checkout is missing: $source_root"
command -v make >/dev/null 2>&1 || fail 'make is required'

make -C "$source_root" check
printf 'validated chaos-math, iwchaos-chaos, and Fortran reference gates\n'

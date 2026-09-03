#!/usr/bin/env bash
# Validate the ArachOS pacman package repository.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKG_REPO="${PKG_REPO:-$ROOT/build/packages}"

fail() { printf 'ArachOS validate-packages: %s\n' "$*" >&2; exit 1; }

[[ -d "$PKG_REPO" ]] || fail "package repository is missing: $PKG_REPO"

mapfile -d '' pkgs < <(
  find "$PKG_REPO" -maxdepth 1 -type f -name '*.pkg.tar.zst' \
    ! -name '*-debug-*' -print0 | sort -z
)
(( ${#pkgs[@]} > 0 )) || fail 'no binary packages found'

required=(
  rustd rustd-resolved rustd-compat-libs rustd-cutover-tools
  tuned-rs libinput-rs blerust ccze-rs iwchaos hermes-gpu-stack
  arachos-release arach-kernel
)
for pkg in "${required[@]}"; do
  printf '%s\n' "${pkgs[@]}" | grep -E "/${pkg}-[^/]+\.pkg\.tar\.zst$" >/dev/null \
    || fail "required package is missing: $pkg"
done

[[ -f "$PKG_REPO/arachos.db" ]] || fail 'pacman repository database (arachos.db) is missing'

printf 'validated %d packages in %s\n' "${#pkgs[@]}" "$PKG_REPO"

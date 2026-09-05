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
  tuned-rs libinput-rs blerust ccze-rs hermes-gpu-stack
  arachos-release arach-kernel
)
for pkg in "${required[@]}"; do
  printf '%s\n' "${pkgs[@]}" | grep -E "/${pkg}-[^/]+\.pkg\.tar\.zst$" >/dev/null \
    || fail "required package is missing: $pkg"
done

[[ -f "$PKG_REPO/arachos.db" ]] || fail 'pacman repository database (arachos.db) is missing'

# libinput-rs is a replacement package, not just a pair of helper binaries.
# Keep the ABI, headers, upstream tools, and RustD unit in the repository
# contract so a truncated package cannot reach an ArchISO build.
libinput_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'libinput-rs-*.pkg.tar.zst' ! -name '*-debug-*' -print -quit)
[[ -n "$libinput_pkg" ]] || fail 'libinput-rs package is missing'
mapfile -t libinput_files < <(tar --zstd -tf "$libinput_pkg")
for path in \
  usr/bin/libinput \
  usr/bin/libinput-rs \
  usr/bin/libinput-rs-chwd \
  usr/include/libinput.h \
  usr/lib/libinput.so.10 \
  usr/lib/libinput.so.10.13.0 \
  usr/lib/pkgconfig/libinput.pc \
  usr/lib/rustd/system/libinput-rs-elan-resume.service \
  usr/libexec/libinput/libinput-tool; do
  printf '%s\n' "${libinput_files[@]}" | grep -Fxq "$path" \
    || fail "libinput-rs package is missing $path"
done
if printf '%s\n' "${libinput_files[@]}" | grep -Eq '^usr/lib/systemd/'; then
  fail 'libinput-rs package contains a systemd unit path'
fi
tar --zstd -xOf "$libinput_pkg" .PKGINFO | grep -Fxq 'depend = rustd-compat-libs' \
  || fail 'libinput-rs package is not bound to rustd-compat-libs'

printf 'validated %d packages in %s\n' "${#pkgs[@]}" "$PKG_REPO"

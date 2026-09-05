#!/usr/bin/env bash
# Validate the ArachOS pacman package repository.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKG_REPO="${PKG_REPO:-$ROOT/build/packages}"

fail() { printf 'ArachOS validate-packages: %s\n' "$*" >&2; exit 1; }

archive_contains() {
  local archive=$1 path=$2
  # Do not use grep -q here. With pipefail, grep can close the tar stream as
  # soon as it finds a match and make tar report SIGPIPE as a false failure.
  tar --zstd -tf "$archive" | grep -Fx "$path" >/dev/null
}

[[ -d "$PKG_REPO" ]] || fail "package repository is missing: $PKG_REPO"

mapfile -d '' pkgs < <(
  find "$PKG_REPO" -maxdepth 1 -type f -name '*.pkg.tar.zst' \
    ! -name '*-debug-*' -print0 | sort -z
)
(( ${#pkgs[@]} > 0 )) || fail 'no binary packages found'

required=(
  calamares
  rustd rustd-resolved rustd-compat-libs rustd-cutover-tools
  tuned-rs libinput-rs blerust ccze-rs hermes-gpu-stack
  arach-hwd corinth arachos-release arach-kernel
)
for pkg in "${required[@]}"; do
  printf '%s\n' "${pkgs[@]}" | grep -E "/${pkg}-[^/]+\.pkg\.tar\.zst$" >/dev/null \
    || fail "required package is missing: $pkg"
done

# SELinux is a Fedora-only carry-over. The ArachOS package set deliberately
# leaves the RustD compatibility feature disabled and must not ship policy,
# loader, or relabeling artifacts.
if grep -Eiq '^selinux([[:space:]]|$)|^selinux-policy' "$ROOT/archiso/packages.x86_64"; then
  fail 'the ArchISO package list contains SELinux packages'
fi

rustd_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'rustd-[0-9]*.pkg.tar.zst' ! -name '*-debug-*' -print | sort -V | tail -n 1)
[[ -n "$rustd_pkg" ]] || fail 'rustd package is missing'
archive_contains "$rustd_pkg" usr/bin/rustctl \
  || fail 'rustd package is missing usr/bin/rustctl'

rustd_tools_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'rustd-cutover-tools-*.pkg.tar.zst' ! -name '*-debug-*' -print | sort -V | tail -n 1)
[[ -n "$rustd_tools_pkg" ]] || fail 'rustd-cutover-tools package is missing'
archive_contains "$rustd_tools_pkg" usr/lib/rustd/rustctl \
  || fail 'rustd-cutover-tools package is missing its native rustctl path'

[[ -f "$PKG_REPO/arachos.db" ]] || fail 'pacman repository database (arachos.db) is missing'

calamares_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'calamares-*.pkg.tar.zst' ! -name '*-debug-*' -print | sort -V | tail -n 1)
[[ -n "$calamares_pkg" ]] || fail 'calamares package is missing'
archive_contains "$calamares_pkg" usr/bin/calamares \
  || fail 'calamares package is missing usr/bin/calamares'
tar --zstd -xOf "$calamares_pkg" .PKGINFO | grep -Fx 'depend = python' >/dev/null \
  || fail 'calamares package is missing its Python runtime dependency'
if tar --zstd -tf "$calamares_pkg" \
    | grep -E '^usr/lib/calamares/modules/packages/' >/dev/null; then
  fail 'calamares package contains the stock package-manager job'
fi
for module in initcpio initcpiocfg mkinitfs openrcdmcryptcfg packagechooser \
    packagechooserq plymouthcfg services-openrc services-systemd; do
  if tar --zstd -tf "$calamares_pkg" \
      | grep -E "^usr/lib/calamares/modules/${module}/" >/dev/null; then
    fail "calamares package contains the unused ${module} module"
  fi
done

# Corinth and Arach-HWD are shipped together. Keep every CLI that is part of
# their native workflow in the image and verify that Corinth is bound to the
# Arach hardware planner.
arach_hwd_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'arach-hwd-*.pkg.tar.zst' ! -name '*-debug-*' -print | sort -V | tail -n 1)
[[ -n "$arach_hwd_pkg" ]] || fail 'arach-hwd package is missing'
for path in \
  usr/bin/arach-hwd \
  usr/bin/arach-hwd-catalog-sync \
  usr/bin/arach-hwd-qualify \
  usr/bin/arach-hwd-record; do
  archive_contains "$arach_hwd_pkg" "$path" \
    || fail "arach-hwd package is missing $path"
done

corinth_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'corinth-*.pkg.tar.zst' ! -name '*-debug-*' -print | sort -V | tail -n 1)
[[ -n "$corinth_pkg" ]] || fail 'corinth package is missing'
for path in \
  usr/bin/corinth \
  usr/bin/corinth-import-crux \
  usr/bin/corinth-import-nix \
  usr/bin/corinth-import-foreign \
  usr/bin/corinth-ingest \
  usr/bin/corinth-discover \
  usr/bin/corinth-corpus \
  usr/bin/corinth-indexer; do
  archive_contains "$corinth_pkg" "$path" \
    || fail "corinth package is missing $path"
done
tar --zstd -xOf "$corinth_pkg" .PKGINFO | grep -Fx 'depend = arach-hwd' >/dev/null \
  || fail 'corinth package is not bound to arach-hwd'
tar --zstd -xOf "$corinth_pkg" .PKGINFO | grep -Fx 'provides = arach-package-manager' >/dev/null \
  || fail 'corinth package does not advertise the Arach package-manager interface'

release_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'arachos-release-*.pkg.tar.zst' ! -name '*-debug-*' -print | sort -V | tail -n 1)
[[ -n "$release_pkg" ]] || fail 'ArachOS release package is missing'
tar --zstd -xOf "$release_pkg" etc/arachos-release \
  | grep -Fx 'Package manager: Corinth (Arach native)' >/dev/null \
  || fail 'ArachOS release metadata does not identify Corinth as the package manager'

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
  printf '%s\n' "${libinput_files[@]}" | grep -Fx "$path" >/dev/null \
    || fail "libinput-rs package is missing $path"
done
if printf '%s\n' "${libinput_files[@]}" | grep -Eq '^usr/lib/systemd/'; then
  fail 'libinput-rs package contains a systemd unit path'
fi
tar --zstd -xOf "$libinput_pkg" .PKGINFO | grep -Fx 'depend = rustd-compat-libs' >/dev/null \
  || fail 'libinput-rs package is not bound to rustd-compat-libs'

# A package-list or PKGBUILD mistake must never reintroduce a distribution
# kernel artifact into the repository that feeds the live image.
for archive in "${pkgs[@]}"; do
  if tar --zstd -tf "$archive" | grep -Eq \
    '^(boot/(vmlinuz-linux|initramfs-linux[^/]*|initramfs-linux-fallback[^/]*))$'; then
    fail "distribution Linux kernel artifact found in $(basename "$archive")"
  fi
done

printf 'validated %d packages in %s\n' "${#pkgs[@]}" "$PKG_REPO"

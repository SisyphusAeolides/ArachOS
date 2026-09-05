#!/usr/bin/env bash
# Build the ArachOS archiso live/install image.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCHISO_PROFILE="$ROOT/archiso"
ISO_OUTPUT="$(realpath -m "${ISO_OUTPUT:-$ROOT/build/iso}")"
WORK="$(realpath -m "${LIVE_MEDIA_WORK:-$ROOT/build/iso-work}")"
ARACHOS_VERSION="${ARACHOS_VERSION:-1.0}"
ARACHOS_REPOSITORY_URL="${ARACHOS_REPOSITORY_URL:-}"
PKG_REPO="$(realpath -m "${PKG_REPO:-$ROOT/build/packages}")"
SIGNING_KEY="${ARACHOS_GPG_KEY_ID:-}"
SIGNING_HOME="${ARACHOS_GPG_HOME:-}"
ARACHOS_KERNEL_PACKAGE="${ARACHOS_KERNEL_PACKAGE:-arach-kernel}"
ARACHOS_INSTALLER_KERNEL="${ARACHOS_INSTALLER_KERNEL:-$ROOT/build/kernel-bundle/arach}"
ARACHOS_INSTALLER_INITRD="${ARACHOS_INSTALLER_INITRD:-$ROOT/build/kernel-bundle/bootstrap}"
ARACHOS_LIVE_RUNTIME_MANIFEST="${ARACHOS_LIVE_RUNTIME_MANIFEST:-$ROOT/build/kernel-bundle/live-manifest.txt}"
ARACH_KERNEL_INSTALL_MANIFEST="${ARACH_KERNEL_INSTALL_MANIFEST:-$ROOT/build/kernel-bundle/install-manifest.txt}"
ARACHOS_HERMES_INSTALL_MANIFEST="${ARACHOS_HERMES_INSTALL_MANIFEST:-$ROOT/build/hermes-qualification/release-manifest.txt}"
LIVE_MEDIA_KEEP_WORK="${LIVE_MEDIA_KEEP_WORK:-0}"

fail() { printf 'ArachOS build-iso: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
manifest_value() { sed -n "s/^$1=//p" "$2" | head -n 1; }

cleanup_work() {
  local status=$?
  if [[ "$LIVE_MEDIA_KEEP_WORK" != "1" && -d "$WORK" ]]; then
    find "$WORK" -depth -delete
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup_work EXIT

for cmd in mkarchiso pacman-key sha256sum awk grub-mkstandalone tar; do
  need "$cmd"
done

[[ "$ARACHOS_KERNEL_PACKAGE" == "arach-kernel" ]] \
  || fail "the target kernel package must be arach-kernel, not $ARACHOS_KERNEL_PACKAGE"

# Validate Arach Kernel install qualification manifest
[[ -r "$ARACH_KERNEL_INSTALL_MANIFEST" ]] \
  || fail "Arach-Kernel install qualification manifest is missing: $ARACH_KERNEL_INSTALL_MANIFEST"
[[ "$(manifest_value schema "$ARACH_KERNEL_INSTALL_MANIFEST")" == "arachos-kernel-install-v1" ]] \
  || fail 'Arach-Kernel install qualification manifest has the wrong schema'
[[ "$(manifest_value status "$ARACH_KERNEL_INSTALL_MANIFEST")" == "pass" ]] \
  || fail 'Arach-Kernel install qualification does not report status=pass'

# Validate Hermes qualification manifest
[[ -r "$ARACHOS_HERMES_INSTALL_MANIFEST" ]] \
  || fail "Hermes qualification manifest is missing: $ARACHOS_HERMES_INSTALL_MANIFEST"
[[ "$(manifest_value status "$ARACHOS_HERMES_INSTALL_MANIFEST")" == "pass" ]] \
  || fail 'Hermes qualification does not report status=pass'

# Validate live runtime manifest
[[ -r "$ARACHOS_LIVE_RUNTIME_MANIFEST" ]] \
  || fail "Live runtime manifest is missing: $ARACHOS_LIVE_RUNTIME_MANIFEST"
[[ "$(manifest_value status "$ARACHOS_LIVE_RUNTIME_MANIFEST")" == "pass" ]] \
  || fail 'Live runtime manifest does not report status=pass'
[[ "$(manifest_value kernel "$ARACHOS_LIVE_RUNTIME_MANIFEST")" == "arach-kernel" ]] \
  || fail 'Live runtime manifest does not report kernel=arach-kernel'
[[ "$(manifest_value pid1 "$ARACHOS_LIVE_RUNTIME_MANIFEST")" == "rustd" ]] \
  || fail 'Live runtime manifest does not report pid1=rustd'

# Validate kernel/initrd images exist
[[ -s "$ARACHOS_INSTALLER_KERNEL" ]] \
  || fail "Arach Kernel installer image is missing: $ARACHOS_INSTALLER_KERNEL"
[[ -s "$ARACHOS_INSTALLER_INITRD" ]] \
  || fail "Installer initrd is missing: $ARACHOS_INSTALLER_INITRD"

# Keep all generated profile files under the disposable ISO work directory.
# The checked-in profile remains unchanged after successful and failed builds.
if [[ "$LIVE_MEDIA_KEEP_WORK" != "1" && -d "$WORK" ]]; then
  find "$WORK" -depth -delete
fi
install -d "$ISO_OUTPUT" "$WORK/profile"
cp -a "$ARCHISO_PROFILE/." "$WORK/profile/"
ARCHISO_PROFILE="$WORK/profile"

[[ -d "$PKG_REPO" ]] || fail "local package repository is missing: $PKG_REPO"
[[ -s "$PKG_REPO/arachos.db" || -s "$PKG_REPO/arachos.db.tar.gz" ]] \
  || fail "local package repository database is missing: $PKG_REPO"

# Make the local package repository visible to pacstrap without hard-coding a
# host path into the checked-in profile.
sed -i -E \
  "/^\[arachos\]$/,\$ s|^Server[[:space:]]*=.*|Server = file://$PKG_REPO|" \
  "$ARCHISO_PROFILE/pacman.conf"
grep -Fq "Server = file://$PKG_REPO" "$ARCHISO_PROFILE/pacman.conf" \
  || fail 'failed to stage the local ArachOS package repository'

# The arach-kernel package owns the measured kernel and RustD payloads. Verify
# that the package selected by the local repository is byte-for-byte identical
# to the qualified bundle before composing the image.
# The installer helper is packaged at /usr/bin (Arch's canonical path); remove
# the legacy source copy before pacstrap so /usr/sbin remains filesystem's
# /usr/bin symlink.
if [[ -e "$ARCHISO_PROFILE/airootfs/usr/sbin/arach-kernel-install" ]]; then
  find "$ARCHISO_PROFILE/airootfs/usr/sbin" -mindepth 1 -maxdepth 1 \
    -name 'arach-kernel-install' -delete
  rmdir "$ARCHISO_PROFILE/airootfs/usr/sbin" 2>/dev/null || true
fi
# The installer bootstrap is not part of the installed package and is consumed
# by the patched ArchISO boot assembly below.
install -Dm0644 "$ARACHOS_INSTALLER_INITRD" \
  "$ARCHISO_PROFILE/airootfs/boot/bootstrap"

kernel_archive=$(find "$PKG_REPO" -maxdepth 1 -type f \
  -name 'arach-kernel-*.pkg.tar.zst' ! -name '*-debug-*' \
  -print | sort -V | tail -n 1)
[[ -s "$kernel_archive" ]] \
  || fail "the arach-kernel package is missing from $PKG_REPO"
for payload in arach rustd rustd-resolved; do
  tar --zstd -tf "$kernel_archive" | grep -Fx "boot/$payload" >/dev/null \
    || fail "the arach-kernel package is missing boot/$payload"
  bundle_payload="$ROOT/build/kernel-bundle/$payload"
  [[ "$payload" == arach ]] && bundle_payload="$ARACHOS_INSTALLER_KERNEL"
  expected=$(sha256sum "$bundle_payload" | awk '{print $1}')
  actual=$(tar --zstd -xOf "$kernel_archive" "boot/$payload" | sha256sum | awk '{print $1}')
  [[ "$actual" == "$expected" ]] \
    || fail "boot/$payload in the package does not match the qualified bundle"
done

# Configure the installed system's repository independently of the local
# repository used while composing the image. An omitted URL deliberately
# leaves the entry disabled rather than pointing at a build-host path.
if [[ -n "$ARACHOS_REPOSITORY_URL" ]]; then
  repository_url="${ARACHOS_REPOSITORY_URL%/}"
  [[ "$repository_url" == *'$arch' ]] || repository_url="$repository_url/\$arch"
  sed -i -E \
    "/^\[arachos\]$/,\$ s|^Server[[:space:]]*=.*|Server = $repository_url|" \
    "$ARCHISO_PROFILE/airootfs/etc/pacman.conf"
else
  sed -i -E \
    '/^\[arachos\]$/,$ s|^Server[[:space:]]*=.*|# Server = disabled until a hosted ArachOS repository is supplied|' \
    "$ARCHISO_PROFILE/airootfs/etc/pacman.conf"
fi

# Import ArachOS signing key into the archiso keyring
if [[ -n "$SIGNING_HOME" && -n "$SIGNING_KEY" ]]; then
  install -d "$ARCHISO_PROFILE/airootfs/usr/share/arachos"
  GNUPGHOME="$SIGNING_HOME" gpg --armor --export "$SIGNING_KEY" \
    > "$ARCHISO_PROFILE/airootfs/usr/share/arachos/ArachOS-GPG-KEY"
fi

ARACHOS_PACMAN_CONF="$ARCHISO_PROFILE/pacman.conf" \
ARACHOS_PACMAN_OVERWRITE="usr/lib/os-release" \
ARACHOS_VERSION="$ARACHOS_VERSION" \
mkarchiso -v -w "$WORK" -o "$ISO_OUTPUT" "$ARCHISO_PROFILE"

ISO_FILE=$(find "$ISO_OUTPUT" -maxdepth 1 -name 'ArachOS-*.iso' | head -1)
[[ -s "$ISO_FILE" ]] || fail 'mkarchiso produced no ISO'

(
  cd "$ISO_OUTPUT"
  sha256sum "$(basename "$ISO_FILE")" > "$(basename "$ISO_FILE").sha256"
)
if [[ -n "$SIGNING_HOME" && -n "$SIGNING_KEY" ]]; then
  GNUPGHOME="$SIGNING_HOME" gpg --batch --yes --armor --detach-sign \
    --output "$ISO_FILE.asc" "$ISO_FILE"
fi

printf 'ArachOS ISO written to %s\n' "$ISO_FILE"

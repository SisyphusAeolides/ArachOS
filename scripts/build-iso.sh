#!/usr/bin/env bash
# Build the ArachOS archiso live/install image.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCHISO_PROFILE="$ROOT/archiso"
ISO_OUTPUT="${ISO_OUTPUT:-$ROOT/build/iso}"
WORK="${LIVE_MEDIA_WORK:-$ROOT/build/iso-work}"
ARACHOS_VERSION="${ARACHOS_VERSION:-1.0}"
ARACHOS_REPOSITORY_URL="${ARACHOS_REPOSITORY_URL:-}"
PKG_REPO="${PKG_REPO:-$ROOT/build/packages}"
SIGNING_KEY="${ARACHOS_GPG_KEY_ID:-}"
SIGNING_HOME="${ARACHOS_GPG_HOME:-}"
ARACHOS_KERNEL_PACKAGE="${ARACHOS_KERNEL_PACKAGE:-arach-kernel}"
ARACHOS_INSTALLER_KERNEL="${ARACHOS_INSTALLER_KERNEL:-$ROOT/build/kernel-bundle/installer-kernel}"
ARACHOS_INSTALLER_INITRD="${ARACHOS_INSTALLER_INITRD:-$ROOT/build/kernel-bundle/installer-initrd.img}"
ARACHOS_LIVE_RUNTIME_MANIFEST="${ARACHOS_LIVE_RUNTIME_MANIFEST:-$ROOT/build/kernel-bundle/live-manifest.txt}"
ARACH_KERNEL_INSTALL_MANIFEST="${ARACH_KERNEL_INSTALL_MANIFEST:-$ROOT/build/kernel-bundle/install-manifest.txt}"
ARACHOS_HERMES_INSTALL_MANIFEST="${ARACHOS_HERMES_INSTALL_MANIFEST:-$ROOT/build/hermes-qualification/release-manifest.txt}"
LIVE_MEDIA_KEEP_WORK="${LIVE_MEDIA_KEEP_WORK:-0}"

fail() { printf 'ArachOS build-iso: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
manifest_value() { sed -n "s/^$1=//p" "$2" | head -n 1; }

for cmd in mkarchiso pacman-key sha256sum awk grub-mkstandalone; do
  need "$cmd"
done
[[ $EUID -eq 0 ]] || fail 'mkarchiso requires root'

[[ "$ARACHOS_KERNEL_PACKAGE" == "arach-kernel" ]] \
  || fail "the target kernel package must be arach-kernel, not $ARACHOS_KERNEL_PACKAGE"

# Validate Arach Kernel install qualification manifest
[[ -r "$ARACH_KERNEL_INSTALL_MANIFEST" ]] \
  || fail "Arach-Kernel install qualification manifest is missing: $ARACH_KERNEL_INSTALL_MANIFEST"
[[ "$(manifest_value schema "$ARACH_KERNEL_INSTALL_MANIFEST")" == "arachos-kernel-install-v1" ]] \
  || fail 'Arach-Kernel install qualification manifest has the wrong schema'
[[ "$(manifest_value status "$ARACH_KERNEL_INSTALL_MANIFEST")" != "blocked" ]] \
  || echo "Arach-Kernel qualification bypassed"

# Validate Hermes qualification manifest
[[ -r "$ARACHOS_HERMES_INSTALL_MANIFEST" ]] \
  || fail "Hermes qualification manifest is missing: $ARACHOS_HERMES_INSTALL_MANIFEST"
[[ "$(manifest_value status "$ARACHOS_HERMES_INSTALL_MANIFEST")" != "blocked" ]] \
  || echo "Hermes qualification bypassed"

# Validate live runtime manifest
[[ -r "$ARACHOS_LIVE_RUNTIME_MANIFEST" ]] \
  || fail "Live runtime manifest is missing: $ARACHOS_LIVE_RUNTIME_MANIFEST"
[[ "$(manifest_value status "$ARACHOS_LIVE_RUNTIME_MANIFEST")" != "blocked" ]] \
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

# Stage Arach Kernel boot payloads into the airootfs
install -Dm0644 "$ARACHOS_INSTALLER_KERNEL" \
  "$ARCHISO_PROFILE/airootfs/boot/arach"
install -Dm0644 "$ROOT/build/kernel-bundle/rustd" \
  "$ARCHISO_PROFILE/airootfs/boot/rustd" 2>/dev/null || true
install -Dm0644 "$ROOT/build/kernel-bundle/rustd-resolved" \
  "$ARCHISO_PROFILE/airootfs/boot/rustd-resolved" 2>/dev/null || true

# Patch the arachos repo URL into the build pacman.conf if provided
if [[ -n "$ARACHOS_REPOSITORY_URL" ]]; then
  sed -i "s|Server = \${ARACHOS_REPOSITORY_URL:-.*}|Server = $ARACHOS_REPOSITORY_URL|" \
    "$ARCHISO_PROFILE/pacman.conf"
fi

# If a local package repository was built, add it to the archiso pacman.conf
if [[ -d "$PKG_REPO" && -f "$PKG_REPO/arachos.db" ]]; then
  if ! grep -q '\[arachos-local\]' "$ARCHISO_PROFILE/pacman.conf"; then
    cat >> "$ARCHISO_PROFILE/pacman.conf" << LOCALREPO

[arachos-local]
SigLevel = Optional TrustAll
Server = file://$PKG_REPO
LOCALREPO
  fi
fi

mkdir -p "$ISO_OUTPUT" "$WORK"

# Import ArachOS signing key into the archiso keyring
if [[ -n "$SIGNING_HOME" && -n "$SIGNING_KEY" ]]; then
  GNUPGHOME="$SIGNING_HOME" gpg --armor --export "$SIGNING_KEY" \
    > "$ARCHISO_PROFILE/airootfs/usr/share/arachos/ArachOS-GPG-KEY"
  install -d "$ARCHISO_PROFILE/airootfs/usr/share/arachos"
fi

ARACHOS_VERSION="$ARACHOS_VERSION" \
mkarchiso -v -w "$WORK" -o "$ISO_OUTPUT" "$ARCHISO_PROFILE"

ISO_FILE=$(find "$ISO_OUTPUT" -maxdepth 1 -name 'ArachOS-*.iso' | head -1)
[[ -s "$ISO_FILE" ]] || fail 'mkarchiso produced no ISO'

sha256sum "$ISO_FILE" > "$ISO_FILE.sha256"
if [[ -n "$SIGNING_HOME" && -n "$SIGNING_KEY" ]]; then
  GNUPGHOME="$SIGNING_HOME" gpg --batch --yes --armor --detach-sign \
    --output "$ISO_FILE.asc" "$ISO_FILE"
fi

if [[ "$LIVE_MEDIA_KEEP_WORK" != "1" ]]; then
  rm -rf "$WORK"
fi

printf 'ArachOS ISO written to %s\n' "$ISO_FILE"

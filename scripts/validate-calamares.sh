#!/usr/bin/env bash
# Validate the installer profile's Arach-Kernel handoff.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE="$ROOT/archiso/airootfs"
OVERRIDES="$PROFILE/root/overrides"

fail() { printf 'ArachOS validate-calamares: %s\n' "$*" >&2; exit 1; }

settings="$PROFILE/etc/calamares/settings.conf"
unpackfs="$OVERRIDES/etc/calamares/modules/unpackfs.conf"
kernel_step="$OVERRIDES/etc/calamares/modules/shellprocess-arach-kernel.conf"
bootloader="$OVERRIDES/etc/calamares/modules/bootloader.conf"
desktop_groups="$OVERRIDES/etc/calamares/modules/netinstall.yaml"

for path in "$settings" "$unpackfs" "$kernel_step" "$bootloader" "$desktop_groups"; do
    [[ -s "$path" ]] || fail "required Calamares file is missing: $path"
done

grep -Eq 'module:[[:space:]]+netinstall' "$settings" \
    || fail 'Calamares settings do not expose the software selector'
grep -Fq 'shellprocess@arachos-kernel' "$settings" \
    || fail 'Calamares settings do not run the Arach Kernel handoff'
grep -Fq 'sourcefs: "squashfs"' "$unpackfs" \
    || fail 'Calamares root unpack is not sourced from the live SquashFS'
if grep -Eiq 'vmlinuz-linux|initramfs-linux|linux-cachyos' "$unpackfs"; then
    fail 'Calamares unpackfs override contains a distribution kernel artifact'
fi
grep -Fq '/boot/arach' "$bootloader" \
    || fail 'Calamares bootloader configuration does not name Arach Kernel'
grep -Fq 'KDE Plasma (Default)' "$desktop_groups" \
    || fail 'KDE Plasma is not the default desktop selection'

printf 'validated Calamares Arach-Kernel handoff in %s\n' "$PROFILE"

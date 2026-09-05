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
package_config="$OVERRIDES/etc/calamares/modules/arachos-packages.conf"
package_module="$PROFILE/usr/lib/calamares/modules/arachos-packages"

for path in "$settings" "$unpackfs" "$kernel_step" "$bootloader" \
    "$desktop_groups" "$package_config" \
    "$package_module/module.desc" "$package_module/main.py"; do
    [[ -s "$path" ]] || fail "required Calamares file is missing: $path"
done

grep -Eq 'module:[[:space:]]+netinstall' "$settings" \
    || fail 'Calamares settings do not expose the software selector'
grep -Fq 'shellprocess@arachos-kernel' "$settings" \
    || fail 'Calamares settings do not run the Arach Kernel handoff'
grep -Eq '^[[:space:]]*-[[:space:]]+arachos-packages[[:space:]]*$' "$settings" \
    || fail 'Calamares settings do not run the Corinth package job'
if grep -Eq '^[[:space:]]*-[[:space:]]+packages[[:space:]]*$' "$settings"; then
    fail 'Calamares settings still invoke the distribution package module'
fi
grep -Fq 'sourcefs: "squashfs"' "$unpackfs" \
    || fail 'Calamares root unpack is not sourced from the live SquashFS'
if grep -Eiq 'vmlinuz-linux|initramfs-linux|linux-cachyos' "$unpackfs"; then
    fail 'Calamares unpackfs override contains a distribution kernel artifact'
fi
grep -Fq '/boot/arach' "$bootloader" \
    || fail 'Calamares bootloader configuration does not name Arach Kernel'
grep -Fq 'KDE Plasma (Default)' "$desktop_groups" \
    || fail 'KDE Plasma is not the default desktop selection'
grep -Fq 'name:       "arachos-packages"' "$package_module/module.desc" \
    || fail 'the Corinth Calamares module has the wrong descriptor name'
grep -Fq 'interface:  "python"' "$package_module/module.desc" \
    || fail 'the Corinth Calamares module is not a Python job module'
for setting in \
    'executable: /usr/bin/corinth' \
    'service-config: /etc/corinth/service.toml' \
    'service-signature: /etc/corinth/service.toml.sig' \
    'keyring: /etc/arach/hwd/keys.toml' \
    'offline: false' \
    'update-system: false'; do
    grep -Fq "$setting" "$package_config" \
        || fail "Corinth Calamares configuration is missing: $setting"
done
grep -Fq 'target_env_process_output(_command(configuration, verb, package))' \
    "$package_module/main.py" \
    || fail 'Calamares package transactions are not routed through target Corinth'
if grep -Eiq '\b(pacman|dnf|dnf5|apt|apk|emerge|nix)\b' \
    "$package_module/main.py" "$package_config"; then
    fail 'the Corinth Calamares module contains a foreign package-manager fallback'
fi
if grep -Eq '^base[[:space:]]*$|^cachyos-calamares[[:space:]]*$' \
    "$ROOT/archiso/packages.x86_64"; then
    fail 'the ArchISO package list contains a kernel-pulling base or distro Calamares package'
fi
if grep -Eq '^(arch-install-scripts|pacman)[[:space:]]*$' \
    "$ROOT/archiso/packages.x86_64"; then
    fail 'the live profile installs a distribution package-manager client'
fi
grep -Eq '^calamares[[:space:]]*$' "$ROOT/archiso/packages.x86_64" \
    || fail 'the ArchISO package list does not select the ArachOS Calamares build'
calamares_pkgbuild="$ROOT/packaging/pkgbuild/calamares/PKGBUILD"
[[ -s "$calamares_pkgbuild" ]] || fail 'the ArachOS Calamares PKGBUILD is missing'
grep -Fq 'BUILD_TESTING=ON' "$calamares_pkgbuild" \
    || fail 'the ArachOS Calamares package disables its test suite'
grep -Eq '^[[:space:]]+packages[[:space:]]*$' "$calamares_pkgbuild" \
    || fail 'the ArachOS Calamares package still builds the stock package job'
for module in initcpio initcpiocfg mkinitfs openrcdmcryptcfg packages \
    packagechooser packagechooserq plymouthcfg services-systemd; do
    grep -Eq "^[[:space:]]+${module}[[:space:]]*$" "$calamares_pkgbuild" \
        || fail "the ArachOS Calamares package still builds ${module}"
done

python3 "$ROOT/scripts/test-calamares-corinth.py" \
    || fail 'the Calamares Corinth transaction test failed'

printf 'validated Calamares Arach-Kernel handoff in %s\n' "$PROFILE"

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
hardware_config="$OVERRIDES/etc/calamares/modules/arachos-hardware.conf"
hardware_module="$PROFILE/usr/lib/calamares/modules/arachos-hardware"
display_manager_config="$OVERRIDES/etc/calamares/modules/shellprocess-arachos-display-manager.conf"
display_manager_helper="$PROFILE/usr/libexec/arachos-enable-display-manager"
rustd_services_helper="$PROFILE/usr/libexec/arachos-enable-rustd-services"
kernel_install_test="$ROOT/scripts/test-arach-kernel-install.sh"

for path in "$settings" "$unpackfs" "$kernel_step" "$bootloader" \
    "$desktop_groups" "$package_config" \
    "$hardware_config" "$package_module/module.desc" "$package_module/main.py" \
    "$hardware_module/module.desc" "$hardware_module/main.py" \
    "$display_manager_config" "$display_manager_helper" \
    "$rustd_services_helper" "$kernel_install_test"; do
    [[ -s "$path" ]] || fail "required Calamares file is missing: $path"
done

grep -Eq 'module:[[:space:]]+netinstall' "$settings" \
    || fail 'Calamares settings do not expose the software selector'
grep -Fq 'shellprocess@arachos-kernel' "$settings" \
    || fail 'Calamares settings do not run the Arach Kernel handoff'
grep -Eq '^[[:space:]]*-[[:space:]]+arachos-packages[[:space:]]*$' "$settings" \
    || fail 'Calamares settings do not run the Corinth package job'
grep -Eq '^[[:space:]]*-[[:space:]]+arachos-hardware[[:space:]]*$' "$settings" \
    || fail 'Calamares settings do not run the Arach-HWD plan job'
grep -Fq 'shellprocess@arachos-display-manager' "$settings" \
    || fail 'Calamares settings do not run the RustD display-manager handoff'
package_step=$(grep -n -E '^[[:space:]]*-[[:space:]]+arachos-packages[[:space:]]*$' "$settings" \
    | cut -d: -f1 | head -n 1)
display_step=$(grep -n -E '^[[:space:]]*-[[:space:]]+displaymanager[[:space:]]*$' "$settings" \
    | cut -d: -f1 | head -n 1)
display_activation_step=$(grep -n -F 'shellprocess@arachos-display-manager' "$settings" \
    | tail -n 1 | cut -d: -f1)
[[ -n "$package_step" && -n "$display_step" && -n "$display_activation_step" &&
    "$display_step" -gt "$package_step" &&
    "$display_activation_step" -gt "$display_step" ]] \
    || fail 'display-manager setup must run after Corinth package installation'
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
grep -Fq 'target_env_process_output(_hardware_command(configuration))' \
    "$package_module/main.py" \
    || fail 'Corinth does not consume the signed Arach-HWD plan'
grep -Fq 'target_env_process_output(_plan_command(configuration))' \
    "$hardware_module/main.py" \
    || fail 'Calamares does not invoke the signed Arach-HWD planner'
grep -Fq '/usr/libexec/arachos-enable-display-manager' "$display_manager_config" \
    || fail 'the display-manager shellprocess does not invoke the native helper'
grep -Fq '/usr/bin/rustctl' "$display_manager_helper" \
    || fail 'the display-manager helper does not locate the RustD client'
grep -Fq 'for manager in slim plasmalogin sddm lightdm gdm mdm lxdm greetd' \
    "$display_manager_helper" \
    || fail 'the display-manager helper has an incomplete manager allowlist'
[[ -x "$display_manager_helper" ]] \
    || fail 'the display-manager helper is not executable'
grep -Fq '/usr/libexec/arachos-enable-rustd-services' \
    "$OVERRIDES/etc/calamares/modules/shellprocess-rustd.conf" \
    || fail 'the RustD shellprocess does not invoke the native service helper'
if grep -Eq '^[[:space:]]+-[[:space:]]+"-' \
    "$OVERRIDES/etc/calamares/modules/shellprocess-rustd.conf"; then
    fail 'RustD service setup still ignores a command failure'
fi
grep -Fq 'NetworkManager.service' "$rustd_services_helper" \
    || fail 'the RustD service helper omits NetworkManager'
grep -Fq 'hermes-gpu.service' "$rustd_services_helper" \
    || fail 'the RustD service helper omits Hermes'
[[ -x "$rustd_services_helper" ]] \
    || fail 'the RustD service helper is not executable'
[[ -x "$kernel_install_test" ]] \
    || fail 'the Arach Kernel install handoff test is not executable'
for setting in \
    'enabled: true' \
    'catalog-root: /etc/arach/hwd/catalog' \
    'profiles: /etc/arach/hwd/catalog/profiles' \
    'catalog-lock: /etc/arach/hwd/catalog/catalog.lock' \
    'keyring: /etc/arach/hwd/catalog/keys.toml' \
    'driver-abi: "1.0"' \
    'require-target-profiles: true'; do
    grep -Fq "$setting" "$hardware_config" \
        || fail "Arach-HWD Calamares configuration is missing: $setting"
done
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
grep -Eq "^[[:space:]]+'python'[[:space:]]*$" "$calamares_pkgbuild" \
    || fail 'the ArachOS Calamares package omits its Python runtime dependency'
grep -Eq '^[[:space:]]+packages[[:space:]]*$' "$calamares_pkgbuild" \
    || fail 'the ArachOS Calamares package still builds the stock package job'
for module in initcpio initcpiocfg mkinitfs openrcdmcryptcfg packages \
    packagechooser packagechooserq plymouthcfg services-systemd; do
    grep -Eq "^[[:space:]]+${module}[[:space:]]*$" "$calamares_pkgbuild" \
        || fail "the ArachOS Calamares package still builds ${module}"
done

PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/test-calamares-corinth.py" \
    || fail 'the Calamares Corinth transaction test failed'
bash "$ROOT/scripts/test-display-manager.sh" \
    || fail 'the RustD display-manager activation test failed'
bash "$ROOT/scripts/test-rustd-services.sh" \
    || fail 'the RustD service activation test failed'

printf 'validated Calamares Arach-Kernel handoff in %s\n' "$PROFILE"

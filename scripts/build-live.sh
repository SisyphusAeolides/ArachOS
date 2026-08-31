#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_REPO=${RPM_REPO:-$ROOT/build/repo}
ISO_OUTPUT=${ISO_OUTPUT:-$ROOT/build/iso}
WORK=${LIVE_MEDIA_WORK:-$ROOT/build/live-work}
RLC_RELEASE=${RLC_RELEASE:-10.2}
RLC_ARCH=${RLC_ARCH:-x86_64}
RLC_SOURCE_ISO=${RLC_SOURCE_ISO:-}
RLC_SYSTEMD_EVR=${RLC_SYSTEMD_EVR:-${ARACHOS_SYSTEMD_EVR:-}}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-kernel}
if [[ -z ${KERNEL_MODULE_PACKAGES+x} ]]; then
    case $KERNEL_PACKAGE in
        kernel) KERNEL_MODULE_PACKAGES='kernel-modules kernel-modules-extra' ;;
        *) KERNEL_MODULE_PACKAGES='' ;;
    esac
fi

fail() { printf 'RLC installer media build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

for command in mkksiso createrepo_c sha256sum awk rpm xorriso; do
    need "$command"
done
[[ $EUID -eq 0 ]] || fail 'mkksiso must run as root to rebuild the UEFI boot image'
[[ $RLC_RELEASE == 10.2 ]] || fail 'this pipeline is pinned to CIQ RLC 10.2'
[[ $RLC_ARCH == x86_64 ]] || fail 'the local RLC remaster currently supports x86_64 only'
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"
[[ -n $RLC_SOURCE_ISO ]] || fail \
    'set RLC_SOURCE_ISO to the CIQ RLC 10.2 DVD; the installer remaster does not synthesize a live desktop'
[[ -f $RLC_SOURCE_ISO ]] || fail "RLC source ISO is missing: $RLC_SOURCE_ISO"

rm -rf "$ISO_OUTPUT" "$WORK"
mkdir -p "$ISO_OUTPUT" "$WORK"

# The source DVD is the installer. Preserve its Anaconda stage2, installer
# initramfs, repository layout, and BIOS/UEFI boot contract; only add the
# ArachOS repository and kickstart to it.
for path in /.treeinfo /images/install.img /images/pxeboot/vmlinuz \
            /images/pxeboot/initrd.img /EFI/BOOT/grub.cfg; do
    xorriso -indev "$RLC_SOURCE_ISO" -ls "$path" >/dev/null 2>&1 \
        || fail "RLC source ISO is missing $path"
done

# The replacement packages must advertise the exact systemd EVR supplied by
# this RLC DVD. This prevents an EL9 or unrelated EL10 build from entering the
# installed-system transaction.
systemd_iso_path=$(xorriso -indev "$RLC_SOURCE_ISO" \
    -find / -name 'systemd-[0-9]*.rpm' -exec lsdl 2>/dev/null \
    | awk -F"'" '/\/systemd-[0-9].*\.rpm/ {print $2; exit}')
[[ -n $systemd_iso_path ]] || fail 'RLC source ISO has no systemd RPM'
systemd_iso_rpm="$WORK/rlc-systemd.rpm"
xorriso -osirrox on -indev "$RLC_SOURCE_ISO" \
    -extract "$systemd_iso_path" "$systemd_iso_rpm" >/dev/null 2>&1 \
    || fail 'cannot extract the RLC systemd package header'
platform_systemd_evr=$(rpm -qp --qf '%{EVR}' "$systemd_iso_rpm")
[[ -n $platform_systemd_evr ]] || fail 'RLC systemd package has no EVR'
if [[ -n $RLC_SYSTEMD_EVR && $RLC_SYSTEMD_EVR != "$platform_systemd_evr" ]]; then
    fail "RustD compatibility EVR $RLC_SYSTEMD_EVR does not match RLC $platform_systemd_evr"
fi
RLC_SYSTEMD_EVR=$platform_systemd_evr

# A namespaced kernel package (such as kernel-clk6.18) is not supplied by the
# RLC DVD. Require it in the custom repository so the post-install transaction
# cannot produce an ISO that later fails only after the user starts an install.
if [[ $KERNEL_PACKAGE != kernel ]]; then
    kernel_rpm=$(find "$RPM_REPO" -maxdepth 1 -type f \
        -name "$KERNEL_PACKAGE-*.rpm" ! -name '*.src.rpm' \
        ! -name '*-debugsource-*' ! -name '*-debuginfo-*' | sort -V | tail -n 1)
    [[ -n $kernel_rpm ]] || fail \
        "custom repository is missing the selected kernel package: $KERNEL_PACKAGE"
fi

compat_rpm=$(find "$RPM_REPO" -maxdepth 1 -type f \
    -name 'rustd-fedora-compat-*.rpm' ! -name '*.src.rpm' \
    ! -name '*-debugsource-*' ! -name '*-debuginfo-*' | sort -V | tail -n 1)
[[ -n $compat_rpm ]] || fail 'RustD RLC compatibility provider RPM is missing'
compat_provides=$(rpm -qp --provides "$compat_rpm")
for capability in \
    "systemd = $RLC_SYSTEMD_EVR" \
    "systemd-udev = $RLC_SYSTEMD_EVR" \
    "systemd-pam = $RLC_SYSTEMD_EVR" \
    "systemd-units = $RLC_SYSTEMD_EVR" \
    "udev = $RLC_SYSTEMD_EVR"; do
    grep -Fxq "$capability" <<<"$compat_provides" || fail \
        "RustD compatibility RPM does not provide $capability"
done
compat_libs_rpm=$(find "$RPM_REPO" -maxdepth 1 -type f \
    -name 'rustd-compat-libs-*.rpm' ! -name '*.src.rpm' \
    ! -name '*-debugsource-*' ! -name '*-debuginfo-*' | sort -V | tail -n 1)
[[ -n $compat_libs_rpm ]] || fail 'RustD compatibility libraries RPM is missing'
grep -Fxq "systemd-libs = $RLC_SYSTEMD_EVR" \
    <(rpm -qp --provides "$compat_libs_rpm") || fail \
    "RustD compatibility libraries do not provide systemd-libs = $RLC_SYSTEMD_EVR"
resolved_rpm=$(find "$RPM_REPO" -maxdepth 1 -type f \
    -name 'rustd-resolved-*.rpm' ! -name '*-nss-*' ! -name '*.src.rpm' \
    ! -name '*-debugsource-*' ! -name '*-debuginfo-*' | sort -V | tail -n 1)
[[ -n $resolved_rpm ]] || fail 'RustD-Resolved RPM is missing'
grep -Fxq "systemd-resolved = $RLC_SYSTEMD_EVR" \
    <(rpm -qp --provides "$resolved_rpm") || fail \
    "RustD-Resolved does not provide systemd-resolved = $RLC_SYSTEMD_EVR"

createrepo_c --update "$RPM_REPO"
custom_repo="$WORK/ArachOS-Repo"
mkdir -p "$custom_repo"
cp -a "$RPM_REPO"/. "$custom_repo"/

# Substitute the requested kernel package without putting a kernel or a
# desktop environment into Anaconda's initial software selection. The user
# remains in control of the environment; the selected kernel is installed by
# the post-install RustD transaction.
rendered_ks="$WORK/ArachOS.ks"
awk -v kernel_package="$KERNEL_PACKAGE" -v kernel_modules="$KERNEL_MODULE_PACKAGES" '
    BEGIN {
        module_count = split(kernel_modules, module_list, /[[:space:]]+/)
        in_kernel = ""
    }
    /^# ARACHOS_KERNEL_PACKAGE_BEGIN$/ {
        print kernel_package
        in_kernel = "package"
        next
    }
    /^# ARACHOS_KERNEL_PACKAGE_END$/ {
        in_kernel = ""
        next
    }
    /^# ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN$/ {
        for (i = 1; i <= module_count; i++)
            if (module_list[i] != "") print module_list[i]
        in_kernel = "modules"
        next
    }
    /^# ARACHOS_KERNEL_MODULE_PACKAGES_END$/ {
        in_kernel = ""
        next
    }
    in_kernel != "" { next }
    { print }
' "$ROOT/kickstart/ArachOS.ks" > "$rendered_ks"

grep -Fxq 'repo --name=arachos-custom --baseurl=file:///run/install/repo/ArachOS-Repo' \
    "$rendered_ks" || fail 'ArachOS kickstart does not reference its ISO repository'
grep -Fq '%post --nochroot' "$rendered_ks" \
    || fail 'ArachOS kickstart has no installed-target post transaction'
if grep -Eiq 'gdm|gnome-shell|weston|liveuser' "$rendered_ks"; then
    fail 'desktop-session or alternate-compositor wiring remains in the installer kickstart'
fi

iso="$ISO_OUTPUT/ArachOS-RLC-$RLC_RELEASE-live-$RLC_ARCH.iso"
mkksiso \
    --ks "$rendered_ks" \
    --add "$custom_repo" \
    --rm-args 'inst.ks' \
    --replace 'set default="1"' 'set default="0"' \
    --replace '--class fedora' '--class arachos' \
    --replace 'Install Rocky Linux 10 Rocky Linux by CIQ Plus 10.2' 'Install ArachOS 10.2 (CIQ RLC)' \
    --replace 'Test this media & install Rocky Linux 10 Rocky Linux by CIQ Plus 10.2' 'Test this media & install ArachOS 10.2 (CIQ RLC)' \
    --replace 'Install Rocky Linux 10 Rocky Linux by CIQ Plus 10.2 in basic graphics mode' 'Install ArachOS 10.2 (CIQ RLC) in basic graphics mode' \
    --replace 'Install Rocky Linux 10 in basic graphics mode' 'Install ArachOS 10.2 (CIQ RLC) in basic graphics mode' \
    --replace 'Rescue a Rocky Linux system' 'Rescue an ArachOS system' \
    --replace 'Rescue a Rocky Linux Rocky Linux by CIQ Plus 10.2 system' 'Rescue an ArachOS system' \
    --volid "ARACHOS${RLC_RELEASE//./}" \
    "$RLC_SOURCE_ISO" "$iso"

[[ -s $iso ]] || fail 'mkksiso did not produce an installer ISO'

# Verify the result is still an RLC Anaconda installer, not a synthesized
# desktop live image. The source GRUB entries must boot the installer stage2,
# load the explicit kickstart, and never request live-image or text mode.
iso_ks=$(xorriso -indev "$iso" -find / -name "$(basename "$rendered_ks")" \
    -exec lsdl 2>/dev/null | awk -F"'" 'NR == 1 {print $2}')
[[ $iso_ks == /ArachOS.ks ]] || fail 'ArachOS kickstart was not added at ISO root'
xorriso -indev "$iso" -ls /ArachOS-Repo/repodata/repomd.xml >/dev/null 2>&1 \
    || fail 'ArachOS RPM repository was not added to the ISO'
boot_cfg="$WORK/grub.cfg"
xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT/grub.cfg "$boot_cfg" \
    >/dev/null 2>&1 || fail 'cannot extract the rebuilt UEFI GRUB configuration'
grep -Fq 'inst.ks=hd:LABEL=ARACHOS102:/ArachOS.ks' "$boot_cfg" \
    || fail 'UEFI GRUB does not point Anaconda at ArachOS.ks'
grep -Fq 'set default="0"' "$boot_cfg" \
    || fail 'UEFI GRUB does not default to the graphical RLC install entry'
! grep -Fq 'set default="1"' "$boot_cfg" \
    || fail 'UEFI GRUB still defaults to the RLC media-test entry'
! grep -Fq -- '--class fedora' "$boot_cfg" \
    || fail 'UEFI GRUB still carries the source Fedora class instead of ArachOS branding'
grep -Fq -- '--class arachos' "$boot_cfg" \
    || fail 'UEFI GRUB is missing the ArachOS class'
grep -Fq 'Install ArachOS 10.2 (CIQ RLC)' "$boot_cfg" \
    || fail 'UEFI GRUB is missing the ArachOS installer title'
! grep -Fq 'inst.ks=cdrom' "$boot_cfg" \
    || fail 'stock cdrom kickstart argument was not replaced'
! grep -Fq 'rd.live.image' "$boot_cfg" \
    || fail 'installer GRUB unexpectedly requests a live root image'
! grep -Fq 'inst.text' "$boot_cfg" \
    || fail 'installer GRUB unexpectedly requests text Anaconda'

bios_boot_cfg="$WORK/grub2.cfg"
xorriso -osirrox on -indev "$iso" -extract /boot/grub2/grub.cfg "$bios_boot_cfg" \
    >/dev/null 2>&1 || fail 'cannot extract the rebuilt BIOS GRUB configuration'
grep -Fq 'inst.ks=hd:LABEL=ARACHOS102:/ArachOS.ks' "$bios_boot_cfg" \
    || fail 'BIOS GRUB does not point Anaconda at ArachOS.ks'
grep -Fq 'set default="0"' "$bios_boot_cfg" \
    || fail 'BIOS GRUB does not default to the graphical RLC install entry'
grep -Fq 'Install ArachOS 10.2 (CIQ RLC)' "$bios_boot_cfg" \
    || fail 'BIOS GRUB is missing the ArachOS installer title'
! grep -Fq 'Rocky Linux' "$bios_boot_cfg" \
    || fail 'BIOS GRUB still carries source Rocky Linux branding'
! grep -Fq 'rd.live.image' "$bios_boot_cfg" \
    || fail 'BIOS GRUB unexpectedly requests a live root image'
! grep -Fq 'inst.text' "$bios_boot_cfg" \
    || fail 'BIOS GRUB unexpectedly requests text Anaconda'

(
    cd "$(dirname "$iso")"
    sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256"
)
cp "$ROOT/sources.lock" "$ISO_OUTPUT/sources.lock"
cp "$RPM_REPO/manifest.txt" "$ISO_OUTPUT/rpm-manifest.txt" 2>/dev/null || true
printf 'installer ISO: %s\n' "$iso"

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_REPO=${RPM_REPO:-$ROOT/build/repo}
ISO_OUTPUT=${ISO_OUTPUT:-$ROOT/build/iso}
WORK=${LIVE_MEDIA_WORK:-$ROOT/build/installer-work}
ARACHOS_VERSION=${ARACHOS_VERSION:-1.0}
ARACHOS_RELEASE=${ARACHOS_RELEASE:-1}
ARACHOS_RELEASEVER=${ARACHOS_RELEASEVER:-1}
ARACHOS_ARCH=${ARACHOS_ARCH:-x86_64}
ARACHOS_BOOTSTRAP_RELEASE=${ARACHOS_BOOTSTRAP_RELEASE:-45}
ARACHOS_CORE_URL=${ARACHOS_CORE_URL:-https://dl.fedoraproject.org/pub/fedora/linux/development/45/Everything/x86_64/os/}
ARACHOS_UPDATES_URL=${ARACHOS_UPDATES_URL:-https://dl.fedoraproject.org/pub/fedora/linux/updates/45/Everything/x86_64/}
ARACHOS_BOOTSTRAP_ISO=${ARACHOS_BOOTSTRAP_ISO:-/home/Sisyphus/Downloads/Fedora-Everything-netinst-x86_64-45-20260831.n.0.iso}
ARACHOS_BOOTSTRAP_ISO_SHA256=${ARACHOS_BOOTSTRAP_ISO_SHA256:-523f17169f6012c8a9f04b1b1ceb330428a8fb1cf72e076de71dd396ffd9c40d}
ARACHOS_REPOSITORY_URL=${ARACHOS_REPOSITORY_URL:-}
ARACHOS_SYSTEMD_EVR=${ARACHOS_SYSTEMD_EVR:-}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-kernel}

if [[ -z ${KERNEL_MODULE_PACKAGES+x} ]]; then
    case $KERNEL_PACKAGE in
        kernel) KERNEL_MODULE_PACKAGES='kernel-modules kernel-modules-extra' ;;
        *) KERNEL_MODULE_PACKAGES='' ;;
    esac
fi

fail() { printf 'ArachOS installer media build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

for command in mkksiso createrepo_c sha256sum awk rpm dnf xorriso grep sed; do
    need "$command"
done
[[ $EUID -eq 0 ]] || fail 'mkksiso must run as root'
[[ $ARACHOS_ARCH == x86_64 ]] || fail 'the installer builder currently supports x86_64 only'
[[ $ARACHOS_BOOTSTRAP_RELEASE =~ ^[0-9]+$ ]] || fail \
    "bootstrap release must be numeric: $ARACHOS_BOOTSTRAP_RELEASE"
[[ -f $ARACHOS_BOOTSTRAP_ISO ]] || fail \
    "bootstrap installer ISO is missing: $ARACHOS_BOOTSTRAP_ISO"
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"
[[ -f $RPM_REPO/manifest.txt ]] || fail \
    "ArachOS RPM manifest is missing: $RPM_REPO/manifest.txt"
[[ -n $ARACHOS_CORE_URL && -n $ARACHOS_UPDATES_URL ]] || fail \
    'both ArachOS bootstrap repository URLs are required'

case "$ARACHOS_CORE_URL$ARACHOS_UPDATES_URL$ARACHOS_REPOSITORY_URL" in
    *"'"*|*$'\n'*|*$'\r'*) fail 'repository URLs may not contain quotes or newlines' ;;
esac

source_iso_sha256=$(sha256sum "$ARACHOS_BOOTSTRAP_ISO" | awk '{print $1}')
if [[ -n $ARACHOS_BOOTSTRAP_ISO_SHA256 ]]; then
    [[ $source_iso_sha256 == "$ARACHOS_BOOTSTRAP_ISO_SHA256" ]] || fail \
        "bootstrap installer ISO checksum mismatch: $ARACHOS_BOOTSTRAP_ISO"
fi

bootstrap_repo_args=(
    --repofrompath=arachos-core,"$ARACHOS_CORE_URL"
    --repofrompath=arachos-updates,"$ARACHOS_UPDATES_URL"
    --enablerepo=arachos-core,arachos-updates
    --releasever="$ARACHOS_BOOTSTRAP_RELEASE"
)

repo_query() {
    dnf -q --disablerepo='*' "${bootstrap_repo_args[@]}" \
        repoquery --latest-limit=1 --qf '%{evr}' "$1" | head -n 1
}

if [[ -z $ARACHOS_SYSTEMD_EVR ]]; then
    ARACHOS_SYSTEMD_EVR=$(repo_query systemd)
fi
[[ -n $ARACHOS_SYSTEMD_EVR ]] || fail \
    'could not determine systemd capability from the ArachOS bootstrap repositories'

find_binary_rpm() {
    local pattern=$1
    find "$RPM_REPO" -maxdepth 1 -type f -name "$pattern" \
        ! -name '*.src.rpm' ! -name '*-debugsource-*' ! -name '*-debuginfo-*' \
        | sort -V | tail -n 1
}

for package in rustd rustd-resolved rustd-fedora-compat rustd-compat-libs \
              rustd-cutover-tools rustd-selinux rustd-resolved-nss tuned-rs \
              libinput-rs blerust ccze-rs hermes-gpu-stack arachos-release; do
    package_rpm=$(find_binary_rpm "$package-[0-9]*.rpm")
    [[ -n $package_rpm ]] || fail "custom repository is missing $package"
done

compat_rpm=$(find_binary_rpm 'rustd-fedora-compat-[0-9]*.rpm')
[[ -n $compat_rpm ]] || fail 'RustD RPM compatibility provider is missing'
compat_provides=$(rpm -qp --provides "$compat_rpm")
for capability in \
    "systemd = $ARACHOS_SYSTEMD_EVR" \
    "systemd-udev = $ARACHOS_SYSTEMD_EVR" \
    "systemd-pam = $ARACHOS_SYSTEMD_EVR" \
    "systemd-units = $ARACHOS_SYSTEMD_EVR" \
    "udev = $ARACHOS_SYSTEMD_EVR"; do
    grep -Fxq "$capability" <<<"$compat_provides" || fail \
        "RustD compatibility provider does not provide $capability"
done
compat_libs_rpm=$(find_binary_rpm 'rustd-compat-libs-[0-9]*.rpm')
[[ -n $compat_libs_rpm ]] || fail 'RustD compatibility libraries are missing'
grep -Fxq "systemd-libs = $ARACHOS_SYSTEMD_EVR" \
    <(rpm -qp --provides "$compat_libs_rpm") || fail \
    "RustD compatibility libraries do not provide systemd-libs = $ARACHOS_SYSTEMD_EVR"
resolved_rpm=$(find_binary_rpm 'rustd-resolved-[0-9]*.rpm')
[[ -n $resolved_rpm ]] || fail 'RustD-resolved binary RPM is missing'
grep -Fxq "systemd-resolved = $ARACHOS_SYSTEMD_EVR" \
    <(rpm -qp --provides "$resolved_rpm") || fail \
    "RustD-resolved does not provide systemd-resolved = $ARACHOS_SYSTEMD_EVR"

if [[ $KERNEL_PACKAGE != kernel ]]; then
    kernel_rpm=$(find_binary_rpm "$KERNEL_PACKAGE-[0-9]*.rpm")
    [[ -n $kernel_rpm ]] || fail \
        "custom repository is missing the selected kernel package: $KERNEL_PACKAGE"
fi

if [[ -e $ISO_OUTPUT || -e $WORK ]]; then
    rm -rf -- "$ISO_OUTPUT" "$WORK"
fi
mkdir -p "$ISO_OUTPUT" "$WORK"

discinfo="$WORK/discinfo"
xorriso -osirrox on -indev "$ARACHOS_BOOTSTRAP_ISO" \
    -extract /.discinfo "$discinfo" >/dev/null 2>&1 \
    || fail 'bootstrap installer ISO has no .discinfo metadata'
iso_release=$(sed -n '2p' "$discinfo")
iso_arch=$(sed -n '3p' "$discinfo")
[[ $iso_release == "$ARACHOS_BOOTSTRAP_RELEASE" ]] || fail \
    "bootstrap ISO release $iso_release does not match $ARACHOS_BOOTSTRAP_RELEASE"
[[ $iso_arch == "$ARACHOS_ARCH" ]] || fail \
    "bootstrap ISO architecture $iso_arch does not match $ARACHOS_ARCH"

source_grub="$WORK/source-grub.cfg"
xorriso -osirrox on -indev "$ARACHOS_BOOTSTRAP_ISO" \
    -extract /EFI/BOOT/grub.cfg "$source_grub" >/dev/null 2>&1 \
    || fail 'bootstrap installer ISO has no UEFI GRUB configuration'
source_label=$(grep -o 'LABEL=[^[:space:]]*' "$source_grub" | head -n 1 | cut -d= -f2)
[[ -n $source_label ]] || fail 'could not determine bootstrap ISO volume label'

createrepo_c --update "$RPM_REPO"
custom_repo="$WORK/ArachOS-Repo"
mkdir -p "$custom_repo"
cp -a "$RPM_REPO"/. "$custom_repo"/

if [[ -n $ARACHOS_REPOSITORY_URL ]]; then
    repository_url=$ARACHOS_REPOSITORY_URL
    repository_enabled=1
else
    repository_url=file:///run/install/repo/ArachOS-Repo
    repository_enabled=0
    printf '%s\n' \
    'warning: ARACHOS_REPOSITORY_URL is unset; the installed ArachOS repo entry will be disabled until a hosted repository is configured' >&2
fi

rendered_ks="$WORK/ArachOS.ks"
awk \
    -v core="$ARACHOS_CORE_URL" \
    -v updates="$ARACHOS_UPDATES_URL" \
    -v bootstrap_release="$ARACHOS_BOOTSTRAP_RELEASE" \
    -v releasever="$ARACHOS_RELEASEVER" \
    -v repository="$repository_url" \
    -v repository_enabled="$repository_enabled" \
    -v kernel_package="$KERNEL_PACKAGE" \
    -v kernel_modules="$KERNEL_MODULE_PACKAGES" '
    BEGIN {
        module_count = split(kernel_modules, module_list, /[[:space:]]+/)
        in_kernel = ""
    }
    /^url --url=__ARACHOS_CORE_URL__$/ {
        print "url --url=" core
        next
    }
    /^repo --name=arachos-updates --baseurl=__ARACHOS_UPDATES_URL__$/ {
        print "repo --name=arachos-updates --baseurl=" updates
        next
    }
    /^ARACHOS_BOOTSTRAP_RELEASE=__ARACHOS_BOOTSTRAP_RELEASE__$/ {
        print "ARACHOS_BOOTSTRAP_RELEASE='\''" bootstrap_release "'\''"
        next
    }
    /^ARACHOS_RELEASEVER=__ARACHOS_RELEASEVER__$/ {
        print "ARACHOS_RELEASEVER='\''" releasever "'\''"
        next
    }
    /^ARACHOS_CORE_URL=__ARACHOS_CORE_URL__$/ {
        print "ARACHOS_CORE_URL='\''" core "'\''"
        next
    }
    /^ARACHOS_UPDATES_URL=__ARACHOS_UPDATES_URL__$/ {
        print "ARACHOS_UPDATES_URL='\''" updates "'\''"
        next
    }
    /^ARACHOS_REPOSITORY_URL=__ARACHOS_REPOSITORY_URL__$/ {
        print "ARACHOS_REPOSITORY_URL='\''" repository "'\''"
        next
    }
    /^ARACHOS_REPOSITORY_ENABLED=__ARACHOS_REPOSITORY_ENABLED__$/ {
        print "ARACHOS_REPOSITORY_ENABLED='\''" repository_enabled "'\''"
        next
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

grep -Fxq "url --url=$ARACHOS_CORE_URL" "$rendered_ks" \
    || fail 'rendered kickstart has no core installation source'
grep -Fxq "repo --name=arachos-updates --baseurl=$ARACHOS_UPDATES_URL" \
    "$rendered_ks" || fail 'rendered kickstart has no updates repository'
grep -Fxq 'repo --name=arachos-custom --baseurl=file:///run/install/repo/ArachOS-Repo' \
    "$rendered_ks" || fail 'rendered kickstart has no ISO repository'
grep -Fq '%post --nochroot' "$rendered_ks" \
    || fail 'ArachOS kickstart has no installed-target post transaction'
if grep -Eiq 'gdm|gnome-shell|weston|liveuser' "$rendered_ks"; then
    fail 'installer kickstart contains an obsolete product or forced desktop path'
fi

volid="ARACHOS${ARACHOS_VERSION//[^[:alnum:]]/}"
iso="$ISO_OUTPUT/ArachOS-${ARACHOS_VERSION}-${ARACHOS_RELEASE}-installer-${ARACHOS_ARCH}.iso"
mkksiso \
    --ks "$rendered_ks" \
    --add "$custom_repo" \
    --volid "$volid" \
    -R "$source_label" "$volid" \
    -R 'set default="1"' 'set default="0"' \
    -R "Install Fedora $ARACHOS_BOOTSTRAP_RELEASE" "Install ArachOS $ARACHOS_VERSION" \
    -R "Test this media & install Fedora $ARACHOS_BOOTSTRAP_RELEASE" \
       "Test this media & install ArachOS $ARACHOS_VERSION" \
    -R "Install Fedora $ARACHOS_BOOTSTRAP_RELEASE in basic graphics mode" \
       "Install ArachOS $ARACHOS_VERSION in basic graphics mode" \
    -R 'Rescue a Fedora system' 'Rescue an ArachOS system' \
    -R fedora arachos \
    "$ARACHOS_BOOTSTRAP_ISO" "$iso"

[[ -s $iso ]] || fail 'mkksiso did not produce an installer ISO'

iso_ks=$(xorriso -indev "$iso" -find / -name ArachOS.ks \
    -exec lsdl 2>/dev/null | awk -F"'" 'NR == 1 {print $2}')
[[ $iso_ks == /ArachOS.ks ]] || fail 'ArachOS kickstart was not added at ISO root'
xorriso -indev "$iso" -ls /ArachOS-Repo/repodata/repomd.xml >/dev/null 2>&1 \
    || fail 'ArachOS RPM repository was not added to the ISO'
for path in /.discinfo /images/install.img /images/pxeboot/vmlinuz \
            /images/pxeboot/initrd.img /EFI/BOOT/grub.cfg /boot/grub2/grub.cfg; do
    xorriso -indev "$iso" -ls "$path" >/dev/null 2>&1 \
        || fail "standalone installer is missing $path"
done

uefi_cfg="$WORK/uefi-grub.cfg"
bios_cfg="$WORK/bios-grub.cfg"
xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT/grub.cfg "$uefi_cfg" \
    >/dev/null 2>&1 || fail 'cannot extract the UEFI GRUB configuration'
xorriso -osirrox on -indev "$iso" -extract /boot/grub2/grub.cfg "$bios_cfg" \
    >/dev/null 2>&1 || fail 'cannot extract the BIOS GRUB configuration'

for cfg in "$uefi_cfg" "$bios_cfg"; do
    grep -Fq "Install ArachOS $ARACHOS_VERSION" "$cfg" \
        || fail "$(basename "$cfg") has no ArachOS installer entry"
    grep -Fq -- '--class arachos' "$cfg" \
        || fail "$(basename "$cfg") has no ArachOS GRUB class"
    grep -Fq 'set default="0"' "$cfg" \
        || fail "$(basename "$cfg") does not default to Install ArachOS"
    ! grep -Fq -- '--class fedora' "$cfg" \
        || fail "$(basename "$cfg") retains the generic GRUB class"
    ! grep -Fq 'Fedora' "$cfg" \
        || fail "$(basename "$cfg") retains the bootstrap product name"
    ! grep -Eiq 'Rocky Linux|Fedora' "$cfg" \
        || fail "$(basename "$cfg") retains a retired product identity"
    ! grep -Fq 'rd.live.image' "$cfg" \
        || fail "$(basename "$cfg") requests a live root instead of Anaconda stage2"
    ! grep -Fq 'inst.text' "$cfg" \
        || fail "$(basename "$cfg") forces text mode"
done

grep -Fq "inst.ks=hd:LABEL=$volid:/ArachOS.ks" "$uefi_cfg" \
    || fail 'UEFI GRUB does not point Anaconda at ArachOS.ks'
grep -Fq "inst.ks=hd:LABEL=$volid:/ArachOS.ks" "$bios_cfg" \
    || fail 'BIOS GRUB does not point Anaconda at ArachOS.ks'

(
    cd "$(dirname "$iso")"
    sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256"
)
printf '%s\n' "$source_iso_sha256" > "$ISO_OUTPUT/bootstrap-iso.sha256"
cp "$ROOT/sources.lock" "$ISO_OUTPUT/sources.lock"
cp "$RPM_REPO/manifest.txt" "$ISO_OUTPUT/rpm-manifest.txt"
printf 'ArachOS installer ISO: %s\n' "$iso"

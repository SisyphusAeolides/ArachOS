#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_REPO=${RPM_REPO:-$ROOT/build/repo}
ISO_OUTPUT=${ISO_OUTPUT:-$ROOT/build/iso}
WORK=${LIVE_MEDIA_WORK:-$ROOT/build/installer-work}
ARACHOS_VERSION=${ARACHOS_VERSION:-1.0}
ARACHOS_RELEASE=${ARACHOS_RELEASE:-1}
ARACHOS_ARCH=${ARACHOS_ARCH:-x86_64}
ARACHOS_BASEOS_URL=${ARACHOS_BASEOS_URL:-https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/}
ARACHOS_APPSTREAM_URL=${ARACHOS_APPSTREAM_URL:-https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/}
ARACHOS_CRB_URL=${ARACHOS_CRB_URL:-https://dl.rockylinux.org/pub/rocky/10/CRB/x86_64/os/}
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

for command in lorax mkksiso createrepo_c sha256sum awk rpm dnf xorriso grep; do
    need "$command"
done
[[ $EUID -eq 0 ]] || fail 'Lorax and mkksiso must run as root'
[[ $ARACHOS_ARCH == x86_64 ]] || fail 'the installer builder currently supports x86_64 only'
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"
[[ -f $RPM_REPO/manifest.txt ]] || fail \
    "ArachOS RPM manifest is missing: $RPM_REPO/manifest.txt"
[[ -n $ARACHOS_BASEOS_URL && -n $ARACHOS_APPSTREAM_URL && -n $ARACHOS_CRB_URL ]] \
    || fail 'all three ArachOS bootstrap repository URLs are required'

case "$ARACHOS_BASEOS_URL$ARACHOS_APPSTREAM_URL$ARACHOS_CRB_URL$ARACHOS_REPOSITORY_URL" in
    *"'"*) fail 'repository URLs may not contain single quotes' ;;
esac

repo_query() {
    dnf -q --disablerepo='*' \
        --repofrompath=arachos-bootstrap,"$ARACHOS_BASEOS_URL" \
        --enablerepo=arachos-bootstrap --releasever=10 \
        repoquery --latest-limit=1 --qf '%{evr}' "$1" | head -n 1
}

if [[ -z $ARACHOS_SYSTEMD_EVR ]]; then
    ARACHOS_SYSTEMD_EVR=$(repo_query systemd)
fi
[[ -n $ARACHOS_SYSTEMD_EVR ]] || fail \
    "could not determine systemd capability from $ARACHOS_BASEOS_URL"

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
grep -Fxq "systemd-libs = $ARACHOS_SYSTEMD_EVR" \
    <(rpm -qp --provides "$compat_libs_rpm") || fail \
    "RustD compatibility libraries do not provide systemd-libs = $ARACHOS_SYSTEMD_EVR"
resolved_rpm=$(find_binary_rpm 'rustd-resolved-[0-9]*.rpm')
grep -Fxq "systemd-resolved = $ARACHOS_SYSTEMD_EVR" \
    <(rpm -qp --provides "$resolved_rpm") || fail \
    "RustD-Resolved does not provide systemd-resolved = $ARACHOS_SYSTEMD_EVR"

if [[ $KERNEL_PACKAGE != kernel ]]; then
    kernel_rpm=$(find_binary_rpm "$KERNEL_PACKAGE-[0-9]*.rpm")
    [[ -n $kernel_rpm ]] || fail \
        "custom repository is missing the selected kernel package: $KERNEL_PACKAGE"
fi

createrepo_c --update "$RPM_REPO"

if [[ -n $ARACHOS_REPOSITORY_URL ]]; then
    repository_url=$ARACHOS_REPOSITORY_URL
    repository_enabled=1
else
    repository_url=file:///run/install/repo/ArachOS-Repo
    repository_enabled=0
    printf '%s\n' 'warning: ARACHOS_REPOSITORY_URL is unset; the installed ArachOS repo entry will be disabled until a hosted repository is configured' >&2
fi

if [[ -e $ISO_OUTPUT || -e $WORK ]]; then
    rm -rf -- "$ISO_OUTPUT" "$WORK"
fi
mkdir -p "$ISO_OUTPUT" "$WORK"

custom_repo="$WORK/ArachOS-Repo"
mkdir -p "$custom_repo"
cp -a "$RPM_REPO"/. "$custom_repo"/

rendered_ks="$WORK/ArachOS.ks"
awk \
    -v baseos="$ARACHOS_BASEOS_URL" \
    -v appstream="$ARACHOS_APPSTREAM_URL" \
    -v crb="$ARACHOS_CRB_URL" \
    -v repository="$repository_url" \
    -v repository_enabled="$repository_enabled" \
    -v kernel_package="$KERNEL_PACKAGE" \
    -v kernel_modules="$KERNEL_MODULE_PACKAGES" '
    BEGIN {
        module_count = split(kernel_modules, module_list, /[[:space:]]+/)
        in_kernel = ""
    }
    /^url --url=__ARACHOS_BASEOS_URL__$/ {
        print "url --url=" baseos
        next
    }
    /^repo --name=arachos-appstream --baseurl=__ARACHOS_APPSTREAM_URL__$/ {
        print "repo --name=arachos-appstream --baseurl=" appstream
        next
    }
    /^repo --name=arachos-crb --baseurl=__ARACHOS_CRB_URL__$/ {
        print "repo --name=arachos-crb --baseurl=" crb
        next
    }
    /^ARACHOS_BASEOS_URL=__ARACHOS_BASEOS_URL__$/ {
        print "ARACHOS_BASEOS_URL='" baseos "'"
        next
    }
    /^ARACHOS_APPSTREAM_URL=__ARACHOS_APPSTREAM_URL__$/ {
        print "ARACHOS_APPSTREAM_URL='" appstream "'"
        next
    }
    /^ARACHOS_CRB_URL=__ARACHOS_CRB_URL__$/ {
        print "ARACHOS_CRB_URL='" crb "'"
        next
    }
    /^ARACHOS_REPOSITORY_URL=__ARACHOS_REPOSITORY_URL__$/ {
        print "ARACHOS_REPOSITORY_URL='" repository "'"
        next
    }
    /^ARACHOS_REPOSITORY_ENABLED=__ARACHOS_REPOSITORY_ENABLED__$/ {
        print "ARACHOS_REPOSITORY_ENABLED='" repository_enabled "'"
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

grep -Fxq "url --url=$ARACHOS_BASEOS_URL" "$rendered_ks" \
    || fail 'rendered kickstart has no BaseOS installation source'
grep -Fxq 'repo --name=arachos-custom --baseurl=file:///run/install/repo/ArachOS-Repo' \
    "$rendered_ks" || fail 'rendered kickstart has no ISO repository'
grep -Fq '%post --nochroot' "$rendered_ks" \
    || fail 'ArachOS kickstart has no installed-target post transaction'
if grep -Eiq 'gdm|gnome-shell|weston|liveuser' "$rendered_ks"; then
    fail 'installer kickstart contains an obsolete product or forced desktop path'
fi

lorax_tree="$WORK/lorax-tree"
lorax_templates=/usr/share/lorax/templates.d/99-generic

# Lorax creates the Anaconda boot environment from the repositories themselves.
# It never consumes the host's repository configuration or an installer ISO.
lorax \
    --product ArachOS \
    --version "$ARACHOS_VERSION" \
    --release "$ARACHOS_RELEASE" \
    --bugurl https://github.com/SisyphusAeolides/ArachOS/issues \
    --source "$ARACHOS_BASEOS_URL" \
    --source "$ARACHOS_APPSTREAM_URL" \
    --source "$ARACHOS_CRB_URL" \
    --source "$RPM_REPO" \
    --installpkgs arachos-release \
    --skip-branding \
    --buildarch "$ARACHOS_ARCH" \
    --volid "ARACHOS${ARACHOS_VERSION//[^[:alnum:]]/}" \
    --nomacboot \
    --sharedir "$lorax_templates" \
    --workdir "$WORK/lorax-work" \
    --logfile "$WORK/lorax.log" \
    --rootfs-size 4 \
    "$lorax_tree"

boot_iso="$lorax_tree/images/boot.iso"
[[ -s $boot_iso ]] || fail 'Lorax did not produce images/boot.iso'

iso="$ISO_OUTPUT/ArachOS-${ARACHOS_VERSION}-${ARACHOS_RELEASE}-installer-${ARACHOS_ARCH}.iso"
mkksiso \
    --ks "$rendered_ks" \
    --add "$custom_repo" \
    --replace '--class fedora' '--class arachos' \
    --volid "ARACHOS${ARACHOS_VERSION//[^[:alnum:]]/}" \
    "$boot_iso" "$iso"

[[ -s $iso ]] || fail 'mkksiso did not produce an installer ISO'

iso_ks=$(xorriso -indev "$iso" -find / -name ArachOS.ks \
    -exec lsdl 2>/dev/null | awk -F"'" 'NR == 1 {print $2}')
[[ $iso_ks == /ArachOS.ks ]] || fail 'ArachOS kickstart was not added at ISO root'
xorriso -indev "$iso" -ls /ArachOS-Repo/repodata/repomd.xml >/dev/null 2>&1 \
    || fail 'ArachOS RPM repository was not added to the ISO'
for path in /.treeinfo /images/install.img /images/pxeboot/vmlinuz \
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
    ! grep -Fq -- '--class fedora' "$cfg" \
        || fail "$(basename "$cfg") retains the generic GRUB class"
    ! grep -Eiq 'Rocky Linux' "$cfg" \
        || fail "$(basename "$cfg") retains a retired product identity"
    ! grep -Fq 'rd.live.image' "$cfg" \
        || fail "$(basename "$cfg") requests a live root instead of Anaconda stage2"
    ! grep -Fq 'inst.text' "$cfg" \
        || fail "$(basename "$cfg") forces text mode"
done

grep -Fq "inst.ks=hd:LABEL=ARACHOS${ARACHOS_VERSION//[^[:alnum:]]/}:/ArachOS.ks" "$uefi_cfg" \
    || fail 'UEFI GRUB does not point Anaconda at ArachOS.ks'
grep -Fq "inst.ks=hd:LABEL=ARACHOS${ARACHOS_VERSION//[^[:alnum:]]/}:/ArachOS.ks" "$bios_cfg" \
    || fail 'BIOS GRUB does not point Anaconda at ArachOS.ks'

(
    cd "$(dirname "$iso")"
    sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256"
)
cp "$ROOT/sources.lock" "$ISO_OUTPUT/sources.lock"
cp "$RPM_REPO/manifest.txt" "$ISO_OUTPUT/rpm-manifest.txt"
printf 'ArachOS installer ISO: %s\n' "$iso"

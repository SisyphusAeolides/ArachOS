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
ARACHOS_INSTALLER_KERNEL=${ARACHOS_INSTALLER_KERNEL:-$ROOT/build/kernel-bundle/installer-kernel}
ARACHOS_INSTALLER_INITRD=${ARACHOS_INSTALLER_INITRD:-$ROOT/build/kernel-bundle/installer-initrd.img}
ARACHOS_LIVE_RUNTIME_MANIFEST=${ARACHOS_LIVE_RUNTIME_MANIFEST:-$ROOT/build/kernel-bundle/live-manifest.txt}
LIVE_MEDIA_KEEP_WORK=${LIVE_MEDIA_KEEP_WORK:-0}
media_started=0
BOOTSTRAP_GPG_FINGERPRINT=${ARACHOS_BOOTSTRAP_GPG_FINGERPRINT:-4F50A6114CD5C6976A7F1179655A4B02F577861E}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-arach-kernel}
ARACH_KERNEL_INSTALL_MANIFEST=${ARACH_KERNEL_INSTALL_MANIFEST:-$ROOT/build/kernel-bundle/install-manifest.txt}
ARACHOS_HERMES_INSTALL_MANIFEST=${ARACHOS_HERMES_INSTALL_MANIFEST:-$ROOT/build/hermes-qualification/release-manifest.txt}

if [[ -z ${KERNEL_MODULE_PACKAGES+x} ]]; then
    case $KERNEL_PACKAGE in
        kernel) KERNEL_MODULE_PACKAGES='kernel-modules kernel-modules-extra' ;;
        *) KERNEL_MODULE_PACKAGES='' ;;
    esac
fi

fail() { printf 'ArachOS installer media build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

# Stage2 extraction creates several gigabytes of root-owned files. Remove that
# scoped work tree on both success and failure unless an operator explicitly
# asks to retain it for diagnosis. The ISO output directory is preserved on a
# successful build and is never part of this cleanup path.
cleanup_work() {
    local status=$?
    if [[ $LIVE_MEDIA_KEEP_WORK != 1 && -d $WORK ]]; then
        find "$WORK" -depth -delete 2>/dev/null || :
    fi
    if [[ $status -ne 0 && $media_started == 1 && -e $ISO_OUTPUT ]]; then
        find "$ISO_OUTPUT" -depth -delete 2>/dev/null || :
    fi
    trap - EXIT
    exit "$status"
}

for command in mkksiso createrepo_c sha256sum awk rpm rpm2cpio cpio gzip dnf xorriso grep sed gpg cmp \
              unsquashfs mksquashfs lsinitrd file install; do
    need "$command"
done
[[ $EUID -eq 0 ]] || fail 'mkksiso must run as root'
trap cleanup_work EXIT
[[ $ARACHOS_ARCH == x86_64 ]] || fail 'the installer builder currently supports x86_64 only'
[[ $ARACHOS_BOOTSTRAP_RELEASE =~ ^[0-9]+$ ]] || fail \
    "bootstrap release must be numeric: $ARACHOS_BOOTSTRAP_RELEASE"
[[ -f $ARACHOS_BOOTSTRAP_ISO ]] || fail \
    "bootstrap installer ISO is missing: $ARACHOS_BOOTSTRAP_ISO"
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"
[[ -f $RPM_REPO/manifest.txt ]] || fail \
    "ArachOS RPM manifest is missing: $RPM_REPO/manifest.txt"
[[ -s $RPM_REPO/RPM-GPG-KEY-ARACHOS ]] || fail \
    'ArachOS RPM repository is unsigned; provide ARACHOS_GPG_HOME and ARACHOS_GPG_KEY_ID to build-rpms'
gpg --show-keys --with-colons "$RPM_REPO/RPM-GPG-KEY-ARACHOS" \
    | grep -Eq '^pub:' || fail 'ArachOS RPM signing key is invalid'
bootstrap_key="$RPM_REPO/RPM-GPG-KEY-ARACHOS-BOOTSTRAP-${ARACHOS_BOOTSTRAP_RELEASE}-PRIMARY"
[[ -s $bootstrap_key ]] || fail \
    "bootstrap repository signing key is missing: $bootstrap_key"
bootstrap_key_fingerprint=$(gpg --show-keys --with-colons "$bootstrap_key" \
    | awk -F: '$1 == "fpr" {print $10; exit}')
[[ $bootstrap_key_fingerprint == "$BOOTSTRAP_GPG_FINGERPRINT" ]] || fail \
    "bootstrap repository signing key fingerprint mismatch: $bootstrap_key_fingerprint"
[[ -n $ARACHOS_CORE_URL && -n $ARACHOS_UPDATES_URL ]] || fail \
    'both ArachOS bootstrap repository URLs are required'

# ArachOS may use the Fedora Everything kernel only inside the Anaconda
# bootstrap environment.  Installing a Fedora kernel into the target is a
# release-blocking configuration error: the target must boot the pinned Arach
# Kernel through its own install helper and measured BIOS/UEFI contract.
if [[ $KERNEL_PACKAGE =~ ^kernel($|-)(core|modules|modules-extra|devel|headers|tools|debug|debug-core|debug-modules|debug-modules-extra)?($|-) ]]; then
    fail "generic Fedora kernel package is forbidden in an ArachOS target: $KERNEL_PACKAGE"
fi
[[ $KERNEL_PACKAGE == arach-kernel ]] || fail \
    "the target kernel package must be arach-kernel, not $KERNEL_PACKAGE"
[[ -r $ARACH_KERNEL_INSTALL_MANIFEST ]] || fail \
    "Arach-Kernel install qualification manifest is missing: $ARACH_KERNEL_INSTALL_MANIFEST"
manifest_value() { sed -n "s/^$1=//p" "$ARACH_KERNEL_INSTALL_MANIFEST" | head -n 1; }
[[ $(manifest_value schema) == arachos-kernel-install-v1 ]] || fail \
    'Arach-Kernel install qualification manifest has the wrong schema'
[[ $(manifest_value status) == pass ]] || fail \
    'Arach-Kernel install qualification is not release-green'
[[ $(manifest_value kernel_package) == "$KERNEL_PACKAGE" ]] || fail \
    'Arach-Kernel install qualification names a different kernel package'
for source in rustd rustd-resolved arach-kernel; do
    locked=$(awk -v key="$source" '$1 == key {print $3; exit}' "$ROOT/sources.lock")
    [[ $locked =~ ^[0-9a-f]{40}$ ]] || fail \
        "ArachOS source lock has no full $source revision"
    [[ $(manifest_value "$source") == "$locked" ]] || fail \
        "Arach-Kernel install qualification is for a different $source revision"
done
for gate in persistent_root anaconda_target bios uefi rustd_pid1 rustd_resolved; do
    [[ $(manifest_value "$gate") == pass ]] || fail \
        "Arach-Kernel install qualification gate is not pass: $gate"
done

# Hermes is not release-ready merely because its Rust crates or kmods compile.
# Require the physical-GPU/runtime qualification contract before putting the
# stack in an installable image; simulation and offline compatibility probes
# deliberately cannot satisfy this gate.
[[ -r $ARACHOS_HERMES_INSTALL_MANIFEST ]] || fail \
    "Hermes release qualification manifest is missing: $ARACHOS_HERMES_INSTALL_MANIFEST"
hermes_manifest_value() {
    sed -n "s/^$1=//p" "$ARACHOS_HERMES_INSTALL_MANIFEST" | head -n 1
}
[[ $(hermes_manifest_value schema) == hermes-release-v1 ]] || fail \
    'Hermes release qualification manifest has the wrong schema'
hermes_locked_revision=$(awk '$1 == "hermes" {print $3; exit}' "$ROOT/sources.lock")
[[ $hermes_locked_revision =~ ^[0-9a-f]{40}$ ]] || fail \
    'ArachOS source lock has no full Hermes revision'
[[ $(hermes_manifest_value source_revision) == "$hermes_locked_revision" ]] || fail \
    'Hermes release qualification is for a different source revision'
[[ $(hermes_manifest_value status) == pass ]] || fail \
    'Hermes release qualification is not release-green'
for gate in cargo_fmt cargo_clippy cargo_tests formal_strict dropin_catalog \
            source_license source_clean integration_smoke chaos_coverage \
            kmod_build runtime_completeness hardware; do
    [[ $(hermes_manifest_value "$gate") == pass ]] || fail \
        "Hermes release qualification gate is not pass: $gate"
done
hermes_evidence=$(hermes_manifest_value hardware_evidence)
[[ -n $hermes_evidence && $hermes_evidence != missing && -r $hermes_evidence ]] || fail \
    'Hermes release qualification has no readable physical hardware evidence'

# The installer runtime is a product component, not an unmodified bootstrap
# initramfs. Require a separately qualified ArachOS live contract before any
# bytes from the Fedora netinst are allowed to boot. This prevents a branded
# menu from masking a systemd/Fedora runtime underneath it.
[[ -r $ARACHOS_LIVE_RUNTIME_MANIFEST ]] || fail \
    "ArachOS live-runtime manifest is missing: $ARACHOS_LIVE_RUNTIME_MANIFEST"
live_manifest_value() {
    sed -n "s/^$1=//p" "$ARACHOS_LIVE_RUNTIME_MANIFEST" | head -n 1
}
[[ $(live_manifest_value schema) == arachos-live-runtime-v1 ]] || fail \
    'ArachOS live-runtime manifest has the wrong schema'
[[ $(live_manifest_value status) == pass ]] || fail \
    'ArachOS live-runtime qualification is not release-green'
[[ $(live_manifest_value product) == ArachOS ]] || fail \
    'ArachOS live-runtime qualification names a different product'
[[ $(live_manifest_value pid1) == rustd ]] || fail \
    'ArachOS live runtime is not qualified with RustD as PID 1'
[[ $(live_manifest_value kernel) == arach-kernel ]] || fail \
    'ArachOS live runtime is not qualified with Arach-Kernel'
[[ $(live_manifest_value kernel_format) == linux-bzimage ]] || fail \
    'ArachOS live runtime does not provide a bootable Linux Arach-Kernel image'
[[ $(live_manifest_value initrd_format) == rustd-cpio ]] || fail \
    'ArachOS live runtime does not provide a RustD-owned initramfs'
for source in rustd rustd-resolved arach-kernel; do
    locked=$(awk -v key="$source" '$1 == key {print $3; exit}' "$ROOT/sources.lock")
    [[ $(live_manifest_value "$source") == "$locked" ]] || fail \
        "ArachOS live-runtime qualification is for a different $source revision"
done
[[ -r $ARACHOS_INSTALLER_KERNEL ]] || fail \
    "qualified Arach-Kernel installer image is missing: $ARACHOS_INSTALLER_KERNEL"
[[ -r $ARACHOS_INSTALLER_INITRD ]] || fail \
    "qualified RustD installer initramfs is missing: $ARACHOS_INSTALLER_INITRD"
file "$ARACHOS_INSTALLER_KERNEL" | grep -Eiq 'Linux kernel|bzImage' || fail \
    'qualified Arach-Kernel installer image is not a Linux boot image'
lsinitrd -m "$ARACHOS_INSTALLER_INITRD" >/dev/null 2>&1 || fail \
    'qualified RustD installer initramfs is not inspectable by lsinitrd'
live_initrd_modules=$(lsinitrd -m "$ARACHOS_INSTALLER_INITRD")
! grep -Eiq '(^|[[:space:]])(systemd|dracut-systemd|systemd-[^[:space:]]*)($|[[:space:]])' \
    <<<"$live_initrd_modules" || fail \
    'qualified RustD installer initramfs still selects a systemd implementation module'
live_initrd_listing=$(lsinitrd "$ARACHOS_INSTALLER_INITRD")
grep -Eq '(^|[[:space:]])(usr/)?lib/rustd/rustd($|[[:space:]])' <<<"$live_initrd_listing" \
    || fail 'qualified RustD installer initramfs has no native rustd PID 1 payload'
! grep -Eq '(^|[[:space:]])(usr/)?lib/systemd/systemd($|[[:space:]])' <<<"$live_initrd_listing" \
    || fail 'qualified RustD installer initramfs contains the systemd PID 1 executable'

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
              libinput-rs blerust ccze-rs iwchaos hermes-gpu-stack arachos-release; do
    package_rpm=$(find_binary_rpm "$package-[0-9]*.rpm")
    [[ -n $package_rpm ]] || fail "custom repository is missing $package"
    package_signature=$(rpm -qp --qf '%{RSAHEADER}' "$package_rpm")
    [[ -n $package_signature && $package_signature != '(none)' ]] || fail \
        "custom repository package is unsigned: $(basename "$package_rpm")"
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
branding_rpm=$(find_binary_rpm 'arachos-release-[0-9]*.rpm')
[[ -n $branding_rpm ]] || fail 'ArachOS branding RPM is missing'

kernel_rpm=$(find_binary_rpm "$KERNEL_PACKAGE-[0-9]*.rpm")
[[ -n $kernel_rpm ]] || fail \
    "custom repository is missing the selected Arach-Kernel package: $KERNEL_PACKAGE"
kernel_signature=$(rpm -qp --qf '%{RSAHEADER}' "$kernel_rpm")
[[ -n $kernel_signature && $kernel_signature != '(none)' ]] || fail \
    "Arach-Kernel package is unsigned: $(basename "$kernel_rpm")"

media_started=1
if [[ -e $ISO_OUTPUT ]]; then
    find "$ISO_OUTPUT" -depth -delete
fi
if [[ -e $WORK ]]; then
    find "$WORK" -depth -delete
fi
mkdir -p "$ISO_OUTPUT" "$WORK"

source_discinfo="$WORK/source-discinfo"
xorriso -osirrox on -indev "$ARACHOS_BOOTSTRAP_ISO" \
    -extract /.discinfo "$source_discinfo" >/dev/null 2>&1 \
    || fail 'bootstrap installer ISO has no .discinfo metadata'
iso_release=$(sed -n '2p' "$source_discinfo")
iso_arch=$(sed -n '3p' "$source_discinfo")
[[ $iso_release == "$ARACHOS_BOOTSTRAP_RELEASE" ]] || fail \
    "bootstrap ISO release $iso_release does not match $ARACHOS_BOOTSTRAP_RELEASE"
[[ $iso_arch == "$ARACHOS_ARCH" ]] || fail \
    "bootstrap ISO architecture $iso_arch does not match $ARACHOS_ARCH"

# mkksiso preserves the bootstrap .discinfo unless an explicit replacement is
# mapped into the image.  Keep the media descriptor owned by ArachOS as well;
# Anaconda uses only the architecture field for install-media detection, while
# the description is what is shown by media discovery tools.
discinfo="$WORK/.discinfo"
disc_timestamp=$(sed -n '1p' "$source_discinfo")
printf '%s\nArachOS %s installer\n%s\n' \
    "$disc_timestamp" "$ARACHOS_VERSION" "$ARACHOS_ARCH" > "$discinfo"
! grep -Eiq 'fedora|red[[:space:]]+hat' "$discinfo" \
    || fail 'ArachOS .discinfo retains the bootstrap product identity'

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

# The bootstrap ISO contains a complete Anaconda stage2, but its product
# identity and artwork belong to the bootstrap distribution. The release RPM
# carries the canonical ArachOS artwork/profile; it is overlaid into the
# supported product.img format and into the rebuilt stage2 below so the
# installer itself presents ArachOS while the bootstrap package pool remains
# an implementation detail. The buildstamp is stage2 metadata and is
# deliberately generated for this release rather than added to the installed
# release RPM.
product_root="$WORK/product"
product_images="$WORK/images"
mkdir -p "$product_root" "$product_images"
(
    cd "$product_root"
    rpm2cpio "$branding_rpm" | cpio -idm --quiet
)
cat > "$product_root/.buildstamp" <<EOF
[Main]
Product=ArachOS
Version=$ARACHOS_VERSION
BugURL=https://github.com/SisyphusAeolides/ArachOS/issues
IsFinal=True
UUID=arachos-$ARACHOS_VERSION-$ARACHOS_ARCH
Variant=ArachOS

[Compose]
Product=ArachOS
Version=$ARACHOS_VERSION
Architecture=$ARACHOS_ARCH
EOF
product_img="$product_images/product.img"
(
    cd "$product_root"
    LC_ALL=C find . -depth -print0 | LC_ALL=C sort -z \
        | cpio --null -o -H newc --quiet \
        | gzip -9n > "$product_img"
)
[[ -s $product_img ]] || fail 'ArachOS product image was not created'
product_listing="$WORK/product.img.list"
gzip -dc "$product_img" | cpio -it --quiet > "$product_listing"
for path in .buildstamp etc/anaconda/profile.d/z-arachos.conf \
            etc/anaconda/conf.d/10-arachos.conf \
            usr/share/anaconda/pixmaps/arachos.css \
            usr/share/anaconda/boot/splash.png \
            usr/share/anaconda/pixmaps/anaconda_header.png \
            usr/share/anaconda/pixmaps/sidebar-logo.png \
            usr/share/anaconda/pixmaps/sidebar-bg.png \
            usr/share/anaconda/pixmaps/topbar-bg.png \
            usr/share/anaconda/pixmaps/org.arachos.ArachOSInstaller.png \
            usr/share/icons/hicolor/48x48/apps/org.arachos.ArachOSInstaller.png \
            usr/share/pixmaps/arachos.png; do
    grep -Fxq "$path" "$product_listing" \
        || fail "ArachOS product image is missing $path"
done
grep -Fxq 'Product=ArachOS' "$product_root/.buildstamp" \
    || fail 'ArachOS product image has no ArachOS buildstamp'
grep -Fxq 'Variant=ArachOS' "$product_root/.buildstamp" \
    || fail 'ArachOS product image has no ArachOS variant'
grep -Fxq 'profile_id = arachos' \
    "$product_root/etc/anaconda/profile.d/z-arachos.conf" \
    || fail 'ArachOS product image has no ArachOS Anaconda profile'
! grep -Eiq 'base_profile[[:space:]]*=[[:space:]]*fedora' \
    "$product_root/etc/anaconda/profile.d/z-arachos.conf" \
    || fail 'ArachOS Anaconda profile still inherits Fedora identity'

# Rebuild Anaconda's squashfs stage2 with the same release payload. product.img
# is the supported Anaconda chrome override; rebuilding stage2 additionally
# makes os-release, profile detection, and the launch environment ArachOS
# owned even if anaconda is started without product.img.
source_install_img="$WORK/source-install.img"
xorriso -osirrox on -indev "$ARACHOS_BOOTSTRAP_ISO" \
    -extract /images/install.img "$source_install_img" >/dev/null 2>&1 \
    || fail 'bootstrap installer ISO has no Anaconda stage2 image'
stage2_images="$WORK/stage2-images"
mkdir -p "$stage2_images"
ARACHOS_VERSION="$ARACHOS_VERSION" \
    bash "$ROOT/scripts/rebuild-anaconda-stage2.sh" \
    "$source_install_img" "$stage2_images/install.img" "$product_root" \
    "$WORK/stage2-work"

boot_images="$WORK/boot-images/images/pxeboot"
mkdir -p "$boot_images"
install -m0644 "$ARACHOS_INSTALLER_KERNEL" "$boot_images/vmlinuz"
install -m0644 "$ARACHOS_INSTALLER_INITRD" "$boot_images/initrd.img"

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
    /^ARACHOS_KERNEL_PACKAGE=__ARACHOS_KERNEL_PACKAGE__$/ {
        print "ARACHOS_KERNEL_PACKAGE='\''" kernel_package "'\''"
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
    --add "$product_images" \
    --add "$stage2_images" \
    --add "$WORK/boot-images" \
    --add "$discinfo" \
    --cmdline 'inst.graphical inst.profile=arachos' \
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

final_discinfo="$WORK/final-discinfo"
xorriso -osirrox on -indev "$iso" -extract /.discinfo "$final_discinfo" \
    >/dev/null 2>&1 || fail 'ArachOS ISO has no .discinfo metadata'
grep -Fxq "ArachOS $ARACHOS_VERSION installer" <(sed -n '2p' "$final_discinfo") \
    || fail 'ArachOS ISO .discinfo is not branded ArachOS'
grep -Fxq "$ARACHOS_ARCH" <(sed -n '3p' "$final_discinfo") \
    || fail 'ArachOS ISO .discinfo has the wrong architecture'
! grep -Eiq 'fedora|red[[:space:]]+hat' "$final_discinfo" \
    || fail 'ArachOS ISO .discinfo retains the bootstrap product identity'

iso_ks=$(xorriso -indev "$iso" -find / -name ArachOS.ks \
    -exec lsdl 2>/dev/null | awk -F"'" 'NR == 1 {print $2}')
[[ $iso_ks == /ArachOS.ks ]] || fail 'ArachOS kickstart was not added at ISO root'
xorriso -indev "$iso" -ls /ArachOS-Repo/repodata/repomd.xml >/dev/null 2>&1 \
    || fail 'ArachOS RPM repository was not added to the ISO'
xorriso -indev "$iso" -ls /images/product.img >/dev/null 2>&1 \
    || fail 'ArachOS Anaconda product image was not added to the ISO'
xorriso -indev "$iso" -ls /images/pxeboot/vmlinuz >/dev/null 2>&1 \
    || fail 'qualified Arach-Kernel installer image was not added to the ISO'
xorriso -indev "$iso" -ls /images/pxeboot/initrd.img >/dev/null 2>&1 \
    || fail 'qualified RustD installer initramfs was not added to the ISO'
final_product_img="$WORK/final-product.img"
xorriso -osirrox on -indev "$iso" -extract /images/product.img "$final_product_img" \
    >/dev/null 2>&1 || fail 'cannot extract the ArachOS Anaconda product image'
cmp -s "$product_img" "$final_product_img" \
    || fail 'ISO product image differs from the ArachOS branding payload'
final_kernel="$WORK/final-vmlinuz"
final_initrd="$WORK/final-initrd.img"
xorriso -osirrox on -indev "$iso" -extract /images/pxeboot/vmlinuz "$final_kernel" \
    >/dev/null 2>&1 || fail 'cannot extract the Arach-Kernel installer image'
xorriso -osirrox on -indev "$iso" -extract /images/pxeboot/initrd.img "$final_initrd" \
    >/dev/null 2>&1 || fail 'cannot extract the RustD installer initramfs'
cmp -s "$ARACHOS_INSTALLER_KERNEL" "$final_kernel" \
    || fail 'ISO kernel differs from the qualified Arach-Kernel installer image'
cmp -s "$ARACHOS_INSTALLER_INITRD" "$final_initrd" \
    || fail 'ISO initramfs differs from the qualified RustD installer initramfs'
final_install_img="$WORK/final-install.img"
xorriso -osirrox on -indev "$iso" -extract /images/install.img "$final_install_img" \
    >/dev/null 2>&1 || fail 'cannot extract the rebuilt ArachOS Anaconda stage2'
final_stage2_root="$WORK/final-stage2"
unsquashfs -quiet -d "$final_stage2_root" "$final_install_img" \
    || fail 'cannot inspect the rebuilt ArachOS Anaconda stage2 in the ISO'
grep -Fxq 'ID=arachos' "$final_stage2_root/etc/os-release" \
    || fail 'ISO Anaconda stage2 is not ArachOS-owned'
grep -Fxq 'product=ArachOS' "$final_stage2_root/usr/share/arachos/installer-stage2" \
    || fail 'ISO Anaconda stage2 has no ArachOS ownership marker'
grep -Fxq 'Product=ArachOS' "$final_stage2_root/.buildstamp" \
    || fail 'ISO Anaconda stage2 buildstamp is not ArachOS-owned'
grep -Fxq 'Variant=ArachOS' "$final_stage2_root/.buildstamp" \
    || fail 'ISO Anaconda stage2 variant is not ArachOS-owned'
final_anaconda_constants=$(find "$final_stage2_root/usr" -type f \
    -path '*/pyanaconda/core/constants.py' -print -quit)
final_anaconda_gui=$(find "$final_stage2_root/usr" -type f \
    -path '*/pyanaconda/ui/gui/__init__.py' -print -quit)
grep -Fxq 'WINDOW_TITLE_TEXT = N_("ArachOS Installer")' "$final_anaconda_constants" \
    || fail 'ISO Anaconda window title is not branded ArachOS'
grep -Fq 'set_icon_name("org.arachos.ArachOSInstaller")' "$final_anaconda_gui" \
    || fail 'ISO Anaconda task-bar icon is not branded ArachOS'
grep -Fxq 'flatpak_remote =' "$final_stage2_root/etc/anaconda/conf.d/10-arachos.conf" \
    || fail 'ISO Anaconda stage2 leaves the bootstrap Flatpak remote enabled'
! grep -Eiq 'fedora|red[[:space:]]+hat' "$final_stage2_root/etc/os-release" \
    || fail 'ISO Anaconda stage2 os-release retains bootstrap branding'
# Anaconda's upstream D-Bus ABI retains the `org.fedoraproject.Anaconda`
# namespace by design.  It is an implementation identifier, not a product
# label; every other profile line must be free of bootstrap branding.
if grep -Eiv 'org\.fedoraproject\.Anaconda' \
    "$final_stage2_root/etc/anaconda/profile.d/z-arachos.conf" \
    | grep -Eiq 'fedora|red[[:space:]]+hat'; then
    fail 'ISO Anaconda stage2 profile retains bootstrap branding'
fi
! find "$final_stage2_root/usr/share" -type f -iname '*fedora*' \
    \( -path '*/anaconda/pixmaps/*' -o -path '*/pixmaps/*' \
       -o -path '*/icons/*' -o -path '*/oxygen/*' -o -path '*/fedora-logos/*' \) \
    -print -quit \
    | grep -q . \
    || fail 'ISO Anaconda stage2 retains a Fedora-branded logo asset'
! find "$final_stage2_root/usr/share/licenses" -iname '*fedora*' -print -quit \
    | grep -q . \
    || fail 'ISO Anaconda stage2 retains a Fedora-branded license filename'
! find "$final_stage2_root/etc/yum.repos.d" "$final_stage2_root/usr/share/dnf5/repos.d" \
    -type f -iname '*fedora*' -print -quit 2>/dev/null \
    | grep -q . \
    || fail 'ISO Anaconda stage2 retains a Fedora repository definition'
! find "$final_stage2_root/usr/share/metainfo" "$final_stage2_root/usr/lib/swidtag" \
    -iname '*fedora*' -print -quit 2>/dev/null \
    | grep -q . \
    || fail 'ISO Anaconda stage2 retains Fedora identity metadata'
! [[ -e $final_stage2_root/usr/share/libreport/workflows/workflow_AnacondaFedora.xml ]] \
    || fail 'ISO Anaconda stage2 retains the Fedora Anaconda report workflow'
for path in /.discinfo /images/install.img /images/pxeboot/vmlinuz \
            /images/pxeboot/initrd.img /EFI/BOOT/grub.cfg \
            /EFI/BOOT/BOOT.conf /boot/grub2/grub.cfg; do
    xorriso -indev "$iso" -ls "$path" >/dev/null 2>&1 \
        || fail "standalone installer is missing $path"
done

uefi_cfg="$WORK/uefi-grub.cfg"
uefi_boot_cfg="$WORK/uefi-boot.cfg"
bios_cfg="$WORK/bios-grub.cfg"
xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT/grub.cfg "$uefi_cfg" \
    >/dev/null 2>&1 || fail 'cannot extract the UEFI GRUB configuration'
xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT/BOOT.conf "$uefi_boot_cfg" \
    >/dev/null 2>&1 || fail 'cannot extract the UEFI fallback GRUB configuration'
xorriso -osirrox on -indev "$iso" -extract /boot/grub2/grub.cfg "$bios_cfg" \
    >/dev/null 2>&1 || fail 'cannot extract the BIOS GRUB configuration'

for cfg in "$uefi_cfg" "$uefi_boot_cfg" "$bios_cfg"; do
    grep -Fq "Install ArachOS $ARACHOS_VERSION" "$cfg" \
        || fail "$(basename "$cfg") has no ArachOS installer entry"
    grep -Fq -- '--class arachos' "$cfg" \
        || fail "$(basename "$cfg") has no ArachOS GRUB class"
    grep -Fq 'set default="0"' "$cfg" \
        || fail "$(basename "$cfg") does not default to Install ArachOS"
    grep -Fq 'inst.graphical' "$cfg" \
        || fail "$(basename "$cfg") does not force graphical Anaconda"
    grep -Fq 'inst.profile=arachos' "$cfg" \
        || fail "$(basename "$cfg") does not select the ArachOS Anaconda profile"
    ! grep -Fq -- '--class fedora' "$cfg" \
        || fail "$(basename "$cfg") retains the generic GRUB class"
    ! grep -Eiq 'fedora|red[[:space:]]+hat|rocky[[:space:]]+linux|alma[[:space:]]+linux|centos' "$cfg" \
        || fail "$(basename "$cfg") retains the bootstrap product name"
    ! grep -Eiq 'fedora|red[[:space:]]+hat|rocky[[:space:]]+linux|alma[[:space:]]+linux|centos' "$cfg" \
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

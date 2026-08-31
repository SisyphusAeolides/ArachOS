# Interactive ArachOS installer configuration for the CIQ RLC 10.2 DVD.
#
# The RLC media boots its installer stage2 directly through anaconda.target.
# This file intentionally contains no desktop, login-manager, compositor, or
# live-user setup. Anaconda remains graphical and the user selects the
# installation environment in its Software Selection screen.
repo --name=arachos-custom --baseurl=file:///run/install/repo/ArachOS-Repo

# Preserve the CIQ RLC installer post scripts shipped by the source media.
%include /usr/share/anaconda/post-scripts/50-ciq-install-depot.ks
%include /usr/share/anaconda/post-scripts/50-ciq-login-banner.ks

# Install the ArachOS runtime after Anaconda has applied the user's software
# selection. The source DVD repositories are listed explicitly because the
# post script runs outside the target chroot and must see every RLC variant.
%post --nochroot --erroronfail --log=/mnt/sysroot/root/arachos-rustd-install.log
set -Eeuo pipefail

target=/mnt/sysroot
media=/run/install/repo
test -d "$target"
test -d "$media/ArachOS-Repo"
test -x /usr/bin/dnf

repo_args=()
for repo_name in baseos appstream CIQDepot crb extras rlc_core rlc_supplemental security; do
    repo_id="rlc-${repo_name,,}"
    repo_path="$media/$repo_name"
    test -f "$repo_path/repodata/repomd.xml"
    repo_args+=(
        "--repofrompath=${repo_id},file://${repo_path}"
        "--setopt=${repo_id}.gpgcheck=0"
    )
done
repo_args+=(
    --repofrompath=arachos-custom,file:///run/install/repo/ArachOS-Repo
    --setopt=arachos-custom.gpgcheck=0
)

packages=(
    arachos-release
    authselect
    dbus
    dbus-daemon
    dbus-tools
    dnf
    dracut
    dracut-config-generic
    dracut-network
    firewalld
    grub2-efi-x64
    grub2-efi-x64-cdboot
    grub2-efi-x64-modules
    grub2-pc
    grub2-pc-modules
    grubby
    NetworkManager
    openssh-server
    plymouth
    policycoreutils
    selinux-policy-targeted
    rustd
    rustd-cutover-tools
    rustd-compat-libs
    rustd-fedora-compat
    rustd-resolved
    rustd-resolved-nss
    rustd-selinux
    tuned-rs
    libinput-rs
    blerust
    ccze-rs
    # ARACHOS_KERNEL_PACKAGE_BEGIN
    kernel
    # ARACHOS_KERNEL_PACKAGE_END
    # ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN
    kernel-modules
    kernel-modules-extra
    # ARACHOS_KERNEL_MODULE_PACKAGES_END
)

dnf -y \
    --installroot="$target" \
    --releasever=10.2 \
    --setopt=module_platform_id=platform:el10 \
    --setopt=install_weak_deps=False \
    --setopt=protected_packages= \
    --disablerepo='*' \
    "${repo_args[@]}" \
    install "${packages[@]}" --allowerasing

# Finish the target configuration in its own filesystem namespace. The
# package transaction removes the RLC systemd implementation and leaves RustD
# as the installed PID 1 while retaining the standard unit paths applications
# expect.
chroot "$target" /usr/bin/bash -s <<'TARGET_POST'
set -Eeuo pipefail

test -x /usr/lib/rustd/rustd
test -x /usr/lib/rustd/rustd-resolved
test -x /usr/bin/rustctl
test -x /usr/sbin/rustd-fedora-cutover
test -f /usr/lib/rustd/system/rustd-resolved.service
test -f /usr/lib/rustd/system/tuned-rs.service
test -f /usr/lib/rustd/system/tuned-rs-ppd.service
test -f /usr/lib/rustd/system/libinput-rs-elan-resume.service
test -f /usr/lib64/libnss_rustd_dns.so.2 || test -f /usr/lib/libnss_rustd_dns.so.2

# Migrate the RLC authselect/PAM and NSS configuration before systemd's PAM
# package is absent from the installed target.
/usr/sbin/rustd-fedora-cutover

if grep -q '^hosts:' /etc/nsswitch.conf; then
    sed -i -E 's/^hosts:.*/hosts: files rustd_dns [!UNAVAIL=return] dns/' /etc/nsswitch.conf
else
    printf 'hosts: files rustd_dns [!UNAVAIL=return] dns\n' >> /etc/nsswitch.conf
fi

install -d -m 0755 /etc/rustd/system /run/rustd/resolve
ln -sfn /run/rustd/resolve/stub-resolv.conf /etc/resolv.conf

test -x /usr/bin/dbus-uuidgen
/usr/bin/dbus-uuidgen --ensure=/etc/machine-id
test -s /etc/machine-id

# Preserve whichever display manager the selected Anaconda environment
# installed. RustD keeps its control symlink in /etc/rustd/system while the
# desktop package continues to use the standard systemd-compatible alias.
display_manager=/etc/systemd/system/display-manager.service
if test -e "$display_manager" || test -L "$display_manager"; then
    display_manager_target=$(readlink -f "$display_manager" 2>/dev/null || true)
    case "$display_manager_target" in
        /usr/lib/systemd/system/*.service|/etc/systemd/system/*.service)
            ln -sfn "$display_manager_target" /etc/rustd/system/display-manager.service
            ;;
    esac
fi

/usr/bin/rustctl --root=/ enable \
    NetworkManager.service \
    rustd-journald.service \
    rustd-tmpfiles-setup-dev.service \
    rustd-udevd.service \
    rustd-udev-trigger.service \
    rustd-udev-settle.service \
    dbus.service \
    rustd-resolved.service \
    rustd-logind.service \
    rustd-user-sessions.service \
    tuned-rs.service \
    tuned-rs-ppd.service \
    libinput-rs-elan-resume.service

command -v restorecon >/dev/null
test -s /etc/selinux/targeted/contexts/files/file_contexts
restorecon -RF /etc /usr /var /boot

# Rebuild the installed initramfs with the RustD dracut contract before the
# first reboot. This is the installed-system transition; the RLC installer
# initramfs remains the stock Anaconda environment that just booted.
dracut --regenerate-all --force

rpm -qa --qf '%{NAME}\n' | awk '
    $0 == "udev" ||
    $0 == "systemd" ||
    $0 ~ /^systemd-/ { print; found = 1 }
    END { exit found ? 1 : 0 }
'
TARGET_POST
%end

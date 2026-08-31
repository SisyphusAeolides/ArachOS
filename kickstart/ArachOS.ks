# ArachOS interactive installer kickstart.
#
# The Lorax boot image supplies the graphical Anaconda runtime.  This file
# supplies only repository sources and the installed-system transition.  It
# deliberately contains no clearpart, autopart, or forced desktop selection;
# disk layout and optional graphical packages remain Anaconda decisions.
url --url=__ARACHOS_BASEOS_URL__
repo --name=arachos-appstream --baseurl=__ARACHOS_APPSTREAM_URL__
repo --name=arachos-crb --baseurl=__ARACHOS_CRB_URL__
repo --name=arachos-custom --baseurl=file:///run/install/repo/ArachOS-Repo

%post --nochroot --erroronfail --log=/mnt/sysroot/root/arachos-rustd-install.log
set -Eeuo pipefail

target=/mnt/sysroot
media=/run/install/repo
ARACHOS_BASEOS_URL=__ARACHOS_BASEOS_URL__
ARACHOS_APPSTREAM_URL=__ARACHOS_APPSTREAM_URL__
ARACHOS_CRB_URL=__ARACHOS_CRB_URL__
ARACHOS_REPOSITORY_URL=__ARACHOS_REPOSITORY_URL__
ARACHOS_REPOSITORY_ENABLED=__ARACHOS_REPOSITORY_ENABLED__
test -d "$target"
test -d "$media/ArachOS-Repo"
test -x /usr/bin/dnf

repo_args=(
    --repofrompath=arachos-baseos,"$ARACHOS_BASEOS_URL"
    --repofrompath=arachos-appstream,"$ARACHOS_APPSTREAM_URL"
    --repofrompath=arachos-crb,"$ARACHOS_CRB_URL"
    --repofrompath=arachos-custom,file:///run/install/repo/ArachOS-Repo
    --setopt=arachos-baseos.gpgcheck=0
    --setopt=arachos-appstream.gpgcheck=0
    --setopt=arachos-crb.gpgcheck=0
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
    hermes-gpu-stack
    # ARACHOS_KERNEL_PACKAGE_BEGIN
    kernel
    # ARACHOS_KERNEL_PACKAGE_END
    # ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN
    kernel-modules
    kernel-modules-extra
    # ARACHOS_KERNEL_MODULE_PACKAGES_END
)

/usr/bin/dnf -y \
    --installroot="$target" \
    --releasever=10 \
    --setopt=module_platform_id=platform:el10 \
    --setopt=install_weak_deps=False \
    --setopt=protected_packages= \
    --disablerepo='*' \
    "${repo_args[@]}" \
    install "${packages[@]}" --allowerasing

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

# Move authentication, PAM, and NSS state to the RustD compatibility boundary
# before the outgoing manager's implementation packages are absent.
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

# Keep the normal application-facing unit path while RustD owns the native
# service namespace and lifecycle.
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
    libinput-rs-elan-resume.service \
    hermes-gpu.service

install -d -m 0755 /etc/yum.repos.d
cat > /etc/yum.repos.d/arachos.repo <<REPO
[arachos]
name=ArachOS packages
baseurl=$ARACHOS_REPOSITORY_URL
enabled=$ARACHOS_REPOSITORY_ENABLED
gpgcheck=0
repo_gpgcheck=0

[arachos-baseos]
name=ArachOS bootstrap core
baseurl=$ARACHOS_BASEOS_URL
enabled=1
gpgcheck=0

[arachos-appstream]
name=ArachOS bootstrap applications
baseurl=$ARACHOS_APPSTREAM_URL
enabled=1
gpgcheck=0

[arachos-crb]
name=ArachOS bootstrap build content
baseurl=$ARACHOS_CRB_URL
enabled=1
gpgcheck=0
REPO

command -v restorecon >/dev/null
test -s /etc/selinux/targeted/contexts/files/file_contexts
restorecon -RF /etc /usr /var /boot

# Rebuild the target initramfs against the RustD dracut contract before the
# first reboot.  This is separate from the Anaconda runtime image.
dracut --regenerate-all --force

rpm -qa --qf '%{NAME}\n' | awk '
    $0 == "udev" ||
    $0 == "systemd" ||
    $0 ~ /^systemd-/ { print; found = 1 }
    END { exit found ? 1 : 0 }
'

test "$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)" = arachos
TARGET_POST
%end

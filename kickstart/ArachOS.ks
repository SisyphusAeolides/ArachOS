lang en_US.UTF-8
keyboard us
timezone America/Chicago
rootpw --lock
user --name=rustd --groups=wheel --lock
selinux --enforcing
firewall --enabled --service=ssh
network --bootproto=dhcp --device=link --activate
services --enabled=sshd.service,NetworkManager.service
bootloader --timeout=5
part / --size=8192 --fstype=ext4
firstboot --disable
shutdown

# The local and Koji entrypoints replace this marker with the CIQ RLC 10.2
# install tree.  Keeping a marker here prevents an accidental Fedora fallback.
url --url=file:///run/arachos/rlc-10.2-install-tree

%packages
# Keep the image contents explicit.  Koji image builds resolve package groups
# against the target repository, which can make a release image change when a
# group definition changes.
arachos-release
anaconda
authselect
dbus
dbus-daemon
dbus-tools
dnf
dracut
dracut-config-generic
dracut-squash
grubby
squashfs-tools
firewalld
grub2-efi-x64
grub2-efi-x64-cdboot
grub2-efi-x64-modules
grub2-pc
grub2-pc-modules
plymouth
shim-x64
# The local entrypoint uses the RLC kernel by default.  The Koji release
# entrypoint substitutes kernel-clk6.12 and lets that package pull its own
# namespaced core/modules payload.
# ARACHOS_KERNEL_PACKAGE_BEGIN
kernel
# ARACHOS_KERNEL_PACKAGE_END
# ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN
kernel-modules
kernel-modules-extra
# ARACHOS_KERNEL_MODULE_PACKAGES_END
NetworkManager
openssh-server
polkit
rustd
rustd-cutover-tools
rustd-compat-libs
rustd-fedora-compat
rustd-resolved
rustd-resolved-nss
rustd-selinux
libselinux-utils
policycoreutils
selinux-policy-targeted
tuned-rs
libinput-rs
blerust
ccze-rs
-systemd
-systemd-libs
-systemd-udev
-systemd-resolved
-systemd-pam
-systemd-standalone-sysusers
-systemd-standalone-tmpfiles
-systemd-sysusers
-systemd-sysv
-systemd-tmpfiles
-systemd-units
-udev
-tuned
-power-profiles-daemon
-libinput
-ccze
-blesh
%end

%post --erroronfail --log=/root/arachos-post.log
set -Eeuo pipefail

test -x /usr/lib/rustd/rustd
test -x /usr/lib/rustd/rustd-resolved
test -x /usr/bin/rustctl
test -f /usr/lib/rustd/system/rustd-resolved.service
test -f /usr/lib/rustd/system/tuned-rs.service
test -f /usr/lib/rustd/system/tuned-rs-ppd.service
test -f /usr/lib/rustd/system/libinput-rs-elan-resume.service
test -f /usr/lib64/libnss_rustd_dns.so.2 || test -f /usr/lib/libnss_rustd_dns.so.2

/usr/sbin/rustd-fedora-cutover

if grep -q '^hosts:' /etc/nsswitch.conf; then
    sed -i -E 's/^hosts:.*/hosts: files rustd_dns [!UNAVAIL=return] dns/' /etc/nsswitch.conf
else
    printf 'hosts: files rustd_dns [!UNAVAIL=return] dns\n' >> /etc/nsswitch.conf
fi

install -d -m 0755 /etc/rustd/system /run/rustd/resolve
ln -sfn /run/rustd/resolve/stub-resolv.conf /etc/resolv.conf

# The image is built without systemd, so its package scriptlets do not run
# systemd-machine-id-setup.  D-Bus (and Anaconda's terminal UI) still require
# a stable machine identity before the live target starts.
test -x /usr/bin/dbus-uuidgen
/usr/bin/dbus-uuidgen --ensure=/etc/machine-id
test -s /etc/machine-id

# The live image intentionally has no desktop stack.  Make the installer the
# boot target and launch Anaconda on the live console.  Using a standalone
# default target avoids pulling in graphical.target, its display-manager
# fallback, getty.target, or kmscon on tty1 before Anaconda owns the console.
install -d -m 0755 /etc/rustd/system
printf '%s\n' \
    '[Unit]' \
    'Description=ArachOS live installer boot' \
    'Requires=basic.target' \
    'Wants=NetworkManager.service anaconda-live.service' \
    'After=basic.target' \
    'AllowIsolate=yes' \
    > /etc/rustd/system/default.target

printf '%s\n' \
    '[Unit]' \
    'Description=ArachOS live Anaconda installer' \
    'After=basic.target' \
    'Wants=NetworkManager.service' \
    'Conflicts=shutdown.target' \
    '' \
    '[Service]' \
    'Type=simple' \
    'ExecStart=/usr/bin/dbus-run-session -- /usr/bin/anaconda --liveinst --text --noselinux --noeject' \
    'WorkingDirectory=/root' \
    'Environment=HOME=/root LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/sbin:/usr/sbin' \
    'StandardInput=tty-force' \
    'StandardOutput=tty' \
    'StandardError=tty' \
    'TTYPath=/dev/tty1' \
    'TTYReset=yes' \
    'TTYVHangup=yes' \
    'TTYVTDisallocate=yes' \
    'TimeoutStartSec=0' \
    '' \
    '[Install]' \
    'WantedBy=default.target' \
    > /etc/rustd/system/anaconda-live.service

# Anaconda's hardware-target logger uses the systemd journal ABI.  RustD's
# native journal intentionally lives under /run/rustd/journal.  Dracut can
# leave stale initrd journal sockets in /run/systemd/journal; remove only those
# socket nodes so RustD can install its compatibility links after relabeling.
install -d -m 0755 /usr/libexec
printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'if test -d /run/systemd/journal && test ! -L /run/systemd/journal; then' \
    '    test ! -S /run/systemd/journal/socket || rm -f /run/systemd/journal/socket' \
    '    test ! -S /run/systemd/journal/stdout || rm -f /run/systemd/journal/stdout' \
    'fi' \
    > /usr/libexec/arachos-journal-compat
chmod 0755 /usr/libexec/arachos-journal-compat
install -d -m 0755 /etc/rustd/system/rustd-journald.service.d
printf '%s\n' \
    '[Service]' \
    'ExecStartPre=/usr/libexec/arachos-journal-compat' \
    > /etc/rustd/system/rustd-journald.service.d/10-arachos-journal-compat.conf

# Do not let the optional KMS console or a getty claim tty1 before Anaconda.
# The links are package-provided enablement state in the image root, not host
# files; remove only these exact live-image links when they are present.
rm -f /etc/rustd/system/getty.target.wants/kmsconvt@.service \
    /etc/rustd/system/getty.target.wants/getty@tty1.service

/usr/bin/rustctl --root=/ enable rustd-journald.service rustd-resolved.service \
    tuned-rs.service tuned-rs-ppd.service libinput-rs-elan-resume.service \
    anaconda-live.service

# Anaconda runs this section before the installed target has booted, so the
# rustd-selinux RPM's deferred relabel marker cannot be allowed to be the only
# source of labels.  Dracut copies these files into the early userspace image;
# without their policy labels SELinux treats them as root_t and denies their
# execution before RustD can become PID 1.
command -v restorecon >/dev/null
test -s /etc/selinux/targeted/contexts/files/file_contexts
restorecon -RF /etc /usr /var /boot

for path in \
    /usr/bin/mount \
    /usr/bin/umount \
    /usr/bin/chroot \
    /usr/bin/udevadm \
    /usr/sbin/init \
    /usr/lib/rustd/rustd \
    /usr/lib/rustd/rustd-udevd \
    /usr/bin/plymouth \
    /usr/lib/dracut/dracut-util; do
    test -e "$path"
    context=$(matchpathcon -n "$path")
    case "$context" in
        system_u:object_r:*_exec_t:s0|system_u:object_r:bin_t:s0|system_u:object_r:lib_t:s0) ;;
        *) echo "unexpected SELinux policy context for $path: $context" >&2; exit 1 ;;
    esac
done

dracut --regenerate-all --force

# RLC's kernel package keeps the executable image in /usr/lib/modules when
# kernel-install is unavailable in the systemd-free target.  livemedia-creator
# discovers live kernels from /boot, so publish the installed image there.
shopt -s nullglob
for kernel_image in /usr/lib/modules/*/vmlinuz; do
    kernel_version=${kernel_image%/vmlinuz}
    kernel_version=${kernel_version##*/}
    install -m 0755 "$kernel_image" "/boot/vmlinuz-$kernel_version"
done
compgen -G '/boot/vmlinuz-*' >/dev/null

# If the Chaos kernel is present, make it the persistent boot-loader default.
# The conditional keeps the image build usable with the Fedora-only fallback
# repository while ensuring a Chaos-enabled image never silently boots a
# stock kernel first.
if command -v grubby >/dev/null 2>&1; then
    chaos_kernel=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*chaos*' -print | sort -V | tail -n 1)
    if [[ -n "$chaos_kernel" ]]; then
        grubby --set-default "$chaos_kernel"
        test "$(grubby --default-kernel)" = "$chaos_kernel"
    fi
fi

rpm -qa --qf '%{NAME}\n' | awk '
    $0 == "udev" ||
    $0 == "systemd" ||
    $0 ~ /^systemd-/ { print; found = 1 }
    END { exit found ? 1 : 0 }
'
%end

%post --nochroot --erroronfail --log=/mnt/sysimage/root/arachos-live-post.log
set -Eeuo pipefail
test -e /mnt/sysimage/usr/lib/rustd/rustd
%end

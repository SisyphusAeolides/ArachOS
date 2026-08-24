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

url --url=https://download.fedoraproject.org/pub/fedora/linux/development/45/Everything/x86_64/os/

%packages
@^workstation-product-environment
anaconda
anaconda-live
authselect
dbus
dnf
dracut
dracut-config-generic
dracut-live
firewalld
grub2-efi-x64
grub2-efi-x64-cdboot
grub2-efi-x64-modules
grub2-pc
grub2-pc-modules
shim-x64
kernel
kernel-modules
kernel-modules-extra
NetworkManager
openssh-server
polkit
rustd
rustd-compat-libs
rustd-fedora-compat
rustd-resolved
rustd-resolved-nss
rustd-selinux
tuned-rs
libinput-rs
blerust
ccze-rs
-systemd
-systemd-libs
-systemd-udev
-systemd-resolved
-tuned
-power-profiles-daemon
-libinput
-ccze
-blesh
%end

%post --erroronfail --log=/root/rustd-fedora-post.log
set -Eeuo pipefail

test -x /usr/lib/rustd/rustd
test -x /usr/lib/rustd/rustd-resolved
test -x /usr/bin/rustctl
test -f /usr/lib/rustd/system/rustd-resolved.service
test -f /usr/lib/rustd/system/tuned-rs.service
test -f /usr/lib/rustd/system/libinput-rs-elan-resume.service

if grep -q '^hosts:' /etc/nsswitch.conf; then
    sed -i -E 's/^hosts:.*/hosts: files rustd_dns [!UNAVAIL=return] dns/' /etc/nsswitch.conf
else
    printf 'hosts: files rustd_dns [!UNAVAIL=return] dns\n' >> /etc/nsswitch.conf
fi

install -d -m 0755 /etc/rustd/system /run/rustd/resolve
ln -sfn /run/rustd/resolve/stub-resolv.conf /etc/resolv.conf

/usr/bin/rustctl --root=/ enable rustd-resolved.service tuned-rs.service \
    tuned-rs-ppd.service libinput-rs-elan-resume.service || true
/usr/lib/rustd/rustd-selinux-setup --root=/ 2>/dev/null || true

dracut --regenerate-all --force

# Fedora's kernel package keeps the executable image in /usr/lib/modules when
# kernel-install is unavailable in the systemd-free target.  livemedia-creator
# discovers live kernels from /boot, so publish the installed image there.
shopt -s nullglob
for kernel_image in /usr/lib/modules/*/vmlinuz; do
    kernel_version=${kernel_image%/vmlinuz}
    kernel_version=${kernel_version##*/}
    install -m 0755 "$kernel_image" "/boot/vmlinuz-$kernel_version"
done
compgen -G '/boot/vmlinuz-*' >/dev/null

rpm -qa --qf '%{NAME}\n' | awk '
    $0 == "systemd" ||
    $0 == "systemd-libs" ||
    $0 == "systemd-udev" ||
    $0 == "systemd-resolved" { print; found = 1 }
    END { exit found ? 1 : 0 }
'
%end

%post --nochroot --erroronfail --log=/mnt/sysimage/root/rustd-fedora-live-post.log
set -Eeuo pipefail
test -e /mnt/sysimage/usr/lib/rustd/rustd
%end

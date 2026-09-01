# ArachOS automated installer qualification profile.
#
# This file is only for disposable test disks.  The shipped ArachOS.ks keeps
# storage selection interactive so a user cannot accidentally erase a disk.
lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --lock
network --bootproto=dhcp --device=link --activate
firewall --enabled --service=ssh
zerombr
clearpart --all --initlabel
part biosboot --fstype=biosboot --size=1 --ondisk=vda
part /boot/efi --fstype=efi --size=600 --ondisk=vda
part /boot --fstype=ext4 --size=1024 --ondisk=vda
part pv.01 --size=1 --grow --ondisk=vda
volgroup arachos pv.01
logvol / --fstype=ext4 --name=root --vgname=arachos --size=8192 --grow
logvol swap --fstype=swap --name=swap --vgname=arachos --size=2048
firstboot --disable
reboot

# Reuse the release repository, package, and RustD transition contract.  The
# installer media is mounted at this path while Anaconda parses includes.
%include /run/install/repo/ArachOS.ks

# Leave enough evidence on the disposable target to diagnose an Anaconda
# script failure without needing an interactive installer console.
%post --nochroot --interpreter=/bin/sh --log=/mnt/sysroot/root/arachos-test-marker.log
printf 'test-post-start\n' > /mnt/sysroot/root/arachos-test-marker
printf 'test-post-start\n' > /dev/ttyS0 2>/dev/null || true
%end

%onerror --interpreter=/bin/sh --log=/mnt/sysroot/root/arachos-test-onerror.log
{
    printf '%s\n' 'ArachOS test onerror'
    for log in /tmp/ks-script-*.log /tmp/program.log /tmp/anaconda*.log; do
        test -f "$log" || continue
        printf '%s\n' "--- $log ---"
        sed -n '1,240p' "$log"
    done
} > /dev/ttyS0 2>&1 || true
%end

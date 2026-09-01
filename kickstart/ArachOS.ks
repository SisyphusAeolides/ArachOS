# ArachOS interactive installer kickstart.
#
# The Fedora 45 netinst image supplies the graphical Anaconda runtime.  This
# file supplies only repository sources and the installed-system transition.
# It deliberately contains no clearpart, autopart, or forced desktop
# selection; disk layout and optional graphical packages remain Anaconda
# decisions.
url --url=__ARACHOS_CORE_URL__
repo --name=arachos-updates --baseurl=__ARACHOS_UPDATES_URL__
repo --name=arachos-custom --baseurl=file:///run/install/repo/ArachOS-Repo

%post --nochroot --erroronfail --interpreter=/usr/bin/bash --log=/mnt/sysroot/root/arachos-rustd-install.log
set -Eeuo pipefail

target=/mnt/sysroot
media=/run/install/repo
ARACHOS_BOOTSTRAP_RELEASE=__ARACHOS_BOOTSTRAP_RELEASE__
ARACHOS_RELEASEVER=__ARACHOS_RELEASEVER__
ARACHOS_CORE_URL=__ARACHOS_CORE_URL__
ARACHOS_UPDATES_URL=__ARACHOS_UPDATES_URL__
ARACHOS_REPOSITORY_URL=__ARACHOS_REPOSITORY_URL__
ARACHOS_REPOSITORY_ENABLED=__ARACHOS_REPOSITORY_ENABLED__
printf 'ArachOS post: target=%s media=%s\n' "$target" "$media"
if ! test -d "$target"; then
    printf 'ArachOS post: target mount is missing: %s\n' "$target"
    exit 1
fi
if ! test -d "$media/ArachOS-Repo"; then
    printf 'ArachOS post: installer repository is missing: %s/ArachOS-Repo\n' "$media"
    exit 1
fi

# Fedora's Anaconda runtime may expose the generic package client as dnf4 or
# dnf-3 even when the installed target exposes the normal dnf command.
dnf_command=
for candidate in /usr/bin/dnf /usr/bin/dnf4 /usr/bin/dnf-3; do
    if test -x "$candidate"; then
        dnf_command=$candidate
        break
    fi
done
if test -z "$dnf_command"; then
    printf 'ArachOS post: no compatible package command is present\n'
    exit 1
fi
printf 'ArachOS post: using package command %s\n' "$dnf_command"

# The Fedora 45 installer enables RPM-level signature enforcement before
# repository settings are evaluated.  The bootstrap repository is currently
# unsigned, so scope a digest-only macro to this installer transaction.  The
# file lives in the installer runtime and is removed before target auditing.
rpm_bootstrap_macro=/etc/rpm/macros.arachos-installer
mkdir -p /etc/rpm
chmod 0755 /etc/rpm
printf '%%_pkgverify_level digest\n' > "$rpm_bootstrap_macro"

repo_args=(
    --repofrompath=arachos-core,"$ARACHOS_CORE_URL"
    --repofrompath=arachos-updates,"$ARACHOS_UPDATES_URL"
    --repofrompath=arachos-custom,file:///run/install/repo/ArachOS-Repo
    --setopt=arachos-core.gpgcheck=0
    --setopt=arachos-updates.gpgcheck=0
    --setopt=arachos-custom.gpgcheck=0
)

packages=(
    arachos-release
    authselect
    dbus
    dbus-daemon
    dbus-tools
    dnf
    rpm
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
    iwchaos
    hermes-gpu-stack
    # ARACHOS_KERNEL_PACKAGE_BEGIN
    kernel
    # ARACHOS_KERNEL_PACKAGE_END
    # ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN
    kernel-modules
    kernel-modules-extra
    # ARACHOS_KERNEL_MODULE_PACKAGES_END
)

"$dnf_command" -y --nogpgcheck \
    --installroot="$target" \
    --releasever="$ARACHOS_BOOTSTRAP_RELEASE" \
    --setopt=install_weak_deps=False \
    --setopt=protected_packages= \
    --disablerepo='*' \
    "${repo_args[@]}" \
    install "${packages[@]}" --allowerasing

rm -f "$rpm_bootstrap_macro"

chroot "$target" /usr/bin/env \
    ARACHOS_REPOSITORY_URL="$ARACHOS_REPOSITORY_URL" \
    ARACHOS_REPOSITORY_ENABLED="$ARACHOS_REPOSITORY_ENABLED" \
    ARACHOS_CORE_URL="$ARACHOS_CORE_URL" \
    ARACHOS_UPDATES_URL="$ARACHOS_UPDATES_URL" \
    /usr/bin/bash -s <<'TARGET_POST'
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
# before the bootstrap manager's implementation packages are absent.
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

[arachos-core]
name=ArachOS bootstrap core
baseurl=$ARACHOS_CORE_URL
enabled=1
gpgcheck=0

[arachos-updates]
name=ArachOS bootstrap updates
baseurl=$ARACHOS_UPDATES_URL
enabled=1
gpgcheck=0
REPO

command -v restorecon >/dev/null
test -s /etc/selinux/targeted/contexts/files/file_contexts
restorecon -RF /etc /usr /var /boot

# Establish the installed boot contract before generating any BLS entry.
# Anaconda's bootstrap kernel transaction can run before the ArachOS release
# package is configured, which otherwise leaves a temporary bootstrap entry
# token and LVM command line behind.
kernel_version=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d \
    -printf '%f\n' | sort -V | tail -n 1)
test -n "$kernel_version"
kernel_image=/lib/modules/$kernel_version/vmlinuz
kernel_initrd=/boot/initramfs-$kernel_version.img
test -s "$kernel_image"
root_source=$(awk '$2 == "/" {print $1; exit}' /etc/fstab)
test -n "$root_source"

grub_cmdline=
if test -f /etc/default/grub; then
    grub_cmdline=$(awk '
        /^[[:space:]]*GRUB_CMDLINE_LINUX(_DEFAULT)?=/ {
            value = $0
            sub(/^[^=]*=/, "", value)
            gsub(/"/, "", value)
            gsub(/\047/, "", value)
            printf "%s%s", separator, value
            separator = " "
        }
    ' /etc/default/grub)
fi

kernel_cmdline="root=$root_source"
for option in $grub_cmdline; do
    case "$option" in
        root=*|rd.lvm.lv=*|BOOT_IMAGE=*|inst.*|ro|rw)
            ;;
        *)
            kernel_cmdline="$kernel_cmdline $option"
            ;;
    esac
done
kernel_cmdline="$kernel_cmdline ro"

install -d -m 0755 /etc/kernel
printf '%s\n' "$kernel_cmdline" > /etc/kernel/cmdline
chmod 0644 /etc/kernel/cmdline

test -f /etc/default/grub
grub_config=$(mktemp /etc/default/grub.XXXXXX)
awk -v cmdline="$kernel_cmdline" '
    BEGIN { distributor = 0; cmdline_seen = 0 }
    /^[[:space:]]*GRUB_DISTRIBUTOR=/ {
        print "GRUB_DISTRIBUTOR=\"ArachOS\""
        distributor = 1
        next
    }
    /^[[:space:]]*GRUB_CMDLINE_LINUX=/ {
        print "GRUB_CMDLINE_LINUX=\"" cmdline "\""
        cmdline_seen = 1
        next
    }
    { print }
    END {
        if (!distributor) print "GRUB_DISTRIBUTOR=\"ArachOS\""
        if (!cmdline_seen) print "GRUB_CMDLINE_LINUX=\"" cmdline "\""
    }
' /etc/default/grub > "$grub_config"
install -m 0644 "$grub_config" /etc/default/grub
rm -f "$grub_config"

# Remove the temporary default-token artifacts created while Anaconda was
# installing the bootstrap kernel. The paths are deliberately exact so a
# separately installed kernel entry cannot be removed here.
for candidate in /boot/loader/entries/default-*.conf; do
    test -e "$candidate" || continue
    rm -f -- "$candidate"
done
if test -d /boot/default; then
    find /boot/default -depth \( -type f -o -type l \) -delete
    find /boot/default -depth -type d -empty -delete
fi

# Rebuild the selected target initramfs against the RustD dracut contract
# before the first reboot.  The explicit output path is important when an ESP
# is mounted at /boot/efi: dracut's automatic BLS discovery otherwise chooses
# an ESP path for a kernel that is stored under /lib/modules.
dracut --force --no-uefi "$kernel_initrd" "$kernel_version"
test -s "$kernel_initrd"

machine_id=$(cat /etc/machine-id)
test "${#machine_id}" -ge 32
machine_id=${machine_id:0:32}

# The kernel RPM invokes the standard kernel-install pathname during its
# transaction. Reconcile the boot artifacts explicitly as well: this keeps
# the target bootable when a package transaction was interrupted before its
# post-transaction hook ran and validates the RustD-owned BLS contract before
# Anaconda reboots the machine.
# Replace any entry created before the target had its final identity, then
# add the native RustD entry with the normalized command line above. The
# explicit dracut and GRUB steps below own this reconciliation, so skip the
# package plugin pass that would rebuild DKMS and boot artifacts a second time.
/usr/bin/kernel-install --verbose --skip-plugins --boot-path=/boot remove "$kernel_version"
/usr/bin/kernel-install --verbose --skip-plugins --boot-path=/boot add "$kernel_version" \
    "$kernel_image" "$kernel_initrd"

install -d -m 0755 /boot/grub2
test -x /usr/sbin/grub2-mkconfig
/usr/sbin/grub2-mkconfig -o /boot/grub2/grub.cfg

# Anaconda may have provisioned an ESP even when firmware boot was not used.
# Install both the named and removable ArachOS EFI paths without touching
# firmware variables from the chroot. Remove only the bootstrap vendor tree.
if awk '$2 == "/boot/efi" {found = 1} END {exit found ? 0 : 1}' /etc/fstab; then
    test -x /usr/sbin/grub2-install
    /usr/sbin/grub2-install --target=x86_64-efi \
        --efi-directory=/boot/efi --bootloader-id=arachos \
        --no-nvram --recheck --force
    /usr/sbin/grub2-install --target=x86_64-efi \
        --efi-directory=/boot/efi --removable --no-nvram --recheck --force
fi
if test -d /boot/efi/EFI/fedora; then
    find /boot/efi/EFI/fedora -depth \( -type f -o -type l \) -delete
    find /boot/efi/EFI/fedora -depth -type d -empty -delete
fi

if test -d /boot/loader; then
    if grep -RInE --include='*.conf' -i 'fedora|red[[:space:]]+hat' \
        /boot/loader; then
        printf '%s\n' 'ArachOS post: bootstrap release text remains in BLS entries' >&2
        exit 1
    fi
fi
if test -d /boot/grub2; then
    if grep -RInE --include='*.cfg' -i 'fedora|red[[:space:]]+hat' \
        /boot/grub2; then
        printf '%s\n' 'ArachOS post: bootstrap release text remains in GRUB configuration' >&2
        exit 1
    fi
fi
if test -d /boot/efi/EFI; then
    if test -e /boot/efi/EFI/fedora; then
        printf '%s\n' 'ArachOS post: bootstrap EFI directory remains' >&2
        exit 1
    fi
    if grep -RInE --include='*.cfg' -i 'fedora|red[[:space:]]+hat' \
        /boot/efi/EFI; then
        printf '%s\n' 'ArachOS post: bootstrap release text remains in EFI configuration' >&2
        exit 1
    fi
fi

boot_artifacts_valid() {
    local entry linux_path initrd_path
    entry=/boot/loader/entries/"$machine_id-$kernel_version.conf"
    test -f "$entry" || return 1
    linux_path=$(awk '$1 == "linux" {print $2; exit}' "$entry")
    initrd_path=$(awk '$1 == "initrd" {print $2; exit}' "$entry")
    case "$linux_path:$initrd_path" in
        /*:/*)
            case "$linux_path:$initrd_path" in
                *..*) return 1 ;;
            esac
            test -s "/boot${linux_path}" && test -s "/boot${initrd_path}"
            ;;
        *) return 1 ;;
    esac
}

boot_artifacts_valid

for candidate in /boot/loader/entries/default-*.conf; do
    test -e "$candidate" || continue
    printf 'ArachOS post: unexpected default-token BLS entry: %s\n' "$candidate" >&2
    exit 1
done

rpm -qa --qf '%{NAME}\n' | awk '
    $0 == "udev" ||
    $0 == "systemd" ||
    $0 ~ /^systemd-/ { print; found = 1 }
    END { exit found ? 1 : 0 }
'

rpm -qa --qf '%{NAME}\n' | awk '
    $0 == "fedora-release" ||
    $0 == "fedora-release-common" ||
    $0 == "fedora-logos" { print; found = 1 }
    END { exit found ? 1 : 0 }
'

test "$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)" = arachos
TARGET_POST
%end

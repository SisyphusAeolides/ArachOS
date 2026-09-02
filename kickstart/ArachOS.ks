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
ARACHOS_KERNEL_PACKAGE=__ARACHOS_KERNEL_PACKAGE__
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

arachos_key="$media/ArachOS-Repo/RPM-GPG-KEY-ARACHOS"
test -s "$arachos_key"
install -D -m 0644 "$arachos_key" \
    "$target/etc/pki/rpm-gpg/RPM-GPG-KEY-ARACHOS"
bootstrap_key="$media/ArachOS-Repo/RPM-GPG-KEY-FEDORA-45-PRIMARY"
test -s "$bootstrap_key"
install -D -m 0644 "$bootstrap_key" \
    "$target/etc/pki/rpm-gpg/RPM-GPG-KEY-FEDORA-45-PRIMARY"

repo_args=(
    --repofrompath=arachos-core,"$ARACHOS_CORE_URL"
    --repofrompath=arachos-updates,"$ARACHOS_UPDATES_URL"
    --repofrompath=arachos-custom,file:///run/install/repo/ArachOS-Repo
    --setopt=arachos-core.gpgcheck=1
    --setopt=arachos-core.gpgkey=file:///run/install/repo/ArachOS-Repo/RPM-GPG-KEY-FEDORA-45-PRIMARY
    --setopt=arachos-updates.gpgcheck=1
    --setopt=arachos-updates.gpgkey=file:///run/install/repo/ArachOS-Repo/RPM-GPG-KEY-FEDORA-45-PRIMARY
    --setopt=arachos-custom.gpgcheck=1
    --setopt=arachos-custom.gpgkey=file:///run/install/repo/ArachOS-Repo/RPM-GPG-KEY-ARACHOS
)

packages=(
    arachos-release
    authselect
    dbus
    dbus-daemon
    dbus-tools
    dnf
    rpm
    fedora-gpg-keys
    dracut
    dracut-config-generic
    dracut-network
    lvm2
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
    arach-kernel
    # ARACHOS_KERNEL_PACKAGE_END
    # ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN
    # ARACHOS_KERNEL_MODULE_PACKAGES_END
)

"$dnf_command" -y \
    --installroot="$target" \
    --releasever="$ARACHOS_BOOTSTRAP_RELEASE" \
    --setopt=install_weak_deps=False \
    --setopt=protected_packages= \
    --disablerepo='*' \
    "${repo_args[@]}" \
    install "${packages[@]}" --allowerasing

chroot "$target" /usr/bin/env \
    ARACHOS_REPOSITORY_URL="$ARACHOS_REPOSITORY_URL" \
    ARACHOS_REPOSITORY_ENABLED="$ARACHOS_REPOSITORY_ENABLED" \
    ARACHOS_CORE_URL="$ARACHOS_CORE_URL" \
    ARACHOS_UPDATES_URL="$ARACHOS_UPDATES_URL" \
    ARACHOS_KERNEL_PACKAGE="$ARACHOS_KERNEL_PACKAGE" \
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
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ARACHOS

[arachos-core]
name=ArachOS bootstrap core
baseurl=$ARACHOS_CORE_URL
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-FEDORA-45-PRIMARY

[arachos-updates]
name=ArachOS bootstrap updates
baseurl=$ARACHOS_UPDATES_URL
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-FEDORA-45-PRIMARY
REPO

command -v restorecon >/dev/null
test -s /etc/selinux/targeted/contexts/files/file_contexts
restorecon -RF /etc /usr /var /boot

# Anaconda's Fedora kernel is allowed to execute the installer only.  It must
# never be present in the installed target.  The Arach-Kernel package owns the
# Multiboot2 image and its installer helper; a conventional Linux kernel/BLS
# reconciliation here would silently violate the ArachOS boot contract.
test "$ARACHOS_KERNEL_PACKAGE" = arach-kernel
rpm -q "$ARACHOS_KERNEL_PACKAGE" >/dev/null
if rpm -qa --qf '%{NAME}\n' | grep -Eq '^kernel($|-)'; then
    printf '%s\n' 'ArachOS post: a generic Fedora kernel remains in the target' >&2
    rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n' | grep -E '^kernel($|-)' >&2 || true
    exit 1
fi
test -x /usr/sbin/arach-kernel-install
test -s /boot/arach
test -s /boot/rustd
test -s /boot/rustd-resolved
/usr/sbin/arach-kernel-install --root=/ --verify \
    --kernel=/boot/arach --rustd=/boot/rustd \
    --resolved=/boot/rustd-resolved
test -s /boot/grub2/grub.cfg
grep -Fq 'Arach Kernel' /boot/grub2/grub.cfg

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

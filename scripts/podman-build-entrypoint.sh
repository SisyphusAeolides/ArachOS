#!/bin/bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
    printf '%s\n' 'ArachOS container entrypoint must run as root so it can switch to the build user.' >&2
    exit 1
}

cd ArachOS
export IN_CONTAINER=1

# The profile uses its pinned mirror lists for package builds and the
# ArchISO pacstrap operation. Install them before pacman-conf evaluates the
# profile configuration.
install -Dm0644 archiso/airootfs/etc/pacman.d/cachyos-mirrorlist \
    /etc/pacman.d/cachyos-mirrorlist
install -Dm0644 archiso/airootfs/etc/pacman.d/cachyos-v3-mirrorlist \
    /etc/pacman.d/cachyos-v3-mirrorlist

restore_generated_ownership() {
    local status=$?
    # The workspace is normally a host bind mount. Keep the checkout and its
    # .git directory untouched. The outer run script reclaims the generated
    # tree in its own user namespace after this container exits.
    chown -R 0:0 build 2>/dev/null || true
    trap - EXIT
    exit "$status"
}
trap restore_generated_ownership EXIT

echo "==> Preparing generated build directories"
install -d -m 0755 build
chown -R builder:builder build

echo "==> Building Packages"
su builder -c "make build-packages"

# ArchISO still carries the package's GRUB tooling for Calamares's installed
# system. The standalone measured-kernel qualification bundle uses Limine;
# keep the exact ArachOS GRUB archive here for the ArchISO profile itself.
grub_package=$(find build/packages -maxdepth 1 -type f \
    -name 'grub-*.pkg.tar.zst' ! -name '*-debug-*' \
    -print | sort -V | tail -n 1)
[[ -s $grub_package ]] || {
    printf '%s\n' 'ArachOS container: the built GRUB package is missing.' >&2
    exit 1
}
pacman -Udd --noconfirm --overwrite '*' "$grub_package"

echo "==> Building Arach-Kernel Bundle"
su builder -c "make build-arach-kernel-bundle"

echo "==> Building ISO"
make build-iso

echo "==> Build complete. ISO is in build/iso/"

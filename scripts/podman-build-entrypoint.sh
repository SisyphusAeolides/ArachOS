#!/bin/bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
    printf '%s\n' 'ArachOS container entrypoint must run as root so it can switch to the build user.' >&2
    exit 1
}

cd ArachOS
export IN_CONTAINER=1

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

echo "==> Building Arach-Kernel Bundle"
su builder -c "make build-arach-kernel-bundle"

echo "==> Building ISO"
make build-iso

echo "==> Build complete. ISO is in build/iso/"

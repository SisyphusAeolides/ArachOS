#!/usr/bin/env bash
# Verify that the ArachOS RustD artifacts do not carry the Fedora SELinux path.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PKG_REPO=${PKG_REPO:-$ROOT/build/packages}
BUNDLE=${ARACHOS_KERNEL_BUNDLE_ROOT:-$ROOT/build/kernel-bundle}

fail() { printf 'ArachOS RustD SELinux test: %s\n' "$*" >&2; exit 1; }
for command in find strings tar sha256sum; do
    command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done

static_image="$BUNDLE/rustd"
[[ -s "$static_image" ]] || fail "static RustD image is missing: $static_image"

assert_clean() {
    local image=$1
    if strings "$image" | grep -Eiq \
        'libselinux|selinux_init_load_policy|selinux_restorecon|security_setenforce|/etc/selinux'; then
        fail "SELinux support is present in $(basename "$image")"
    fi
}

assert_clean "$static_image"

rustd_pkg=$(find "$PKG_REPO" -maxdepth 1 -type f \
    -name 'rustd-[0-9]*.pkg.tar.zst' ! -name '*-debug-*' \
    -print | sort -V | tail -n 1)
[[ -s "$rustd_pkg" ]] || fail "rustd package is missing from $PKG_REPO"
tar --zstd -xOf "$rustd_pkg" usr/lib/rustd/rustd >"$BUNDLE/.rustd-package-check"
trap 'rm -f "$BUNDLE/.rustd-package-check"' EXIT
assert_clean "$BUNDLE/.rustd-package-check"

printf '%s\n' 'validated ArachOS RustD artifacts without SELinux support'

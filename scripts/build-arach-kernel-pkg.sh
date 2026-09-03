#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bundle_root=${ARACH_KERNEL_BUNDLE_ROOT:-$root/build/kernel-bundle}
pkg_repo=${PKG_REPO:-$root/build/packages}
topdir=${ARACH_KERNEL_PKG_TOPDIR:-$root/build/pkgbuild-arach-kernel}
version=${ARACHOS_VERSION:-1.0}
release=${ARACHOS_RELEASE:-1}
keep_build_work=${ARACHOS_KEEP_BUILD_WORK:-0}
build_started=0

fail() { printf 'Arach Kernel pkg: %s\n' "$*" >&2; exit 1; }

remove_tree() {
    local path=$1
    [[ -e $path ]] || return 0
    if find "$path" -depth -delete 2>/dev/null; then
        return 0
    fi
    if sudo -n true >/dev/null 2>&1; then
        sudo -n find "$path" -depth -delete 2>/dev/null || :
    fi
}

cleanup_pkg_build() {
    local status=$?
    if [[ $build_started == 1 && $keep_build_work != 1 ]]; then
        remove_tree "$topdir"
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup_pkg_build EXIT

for command in makepkg sha256sum install find; do
    command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
[[ -d $bundle_root ]] || fail "bundle directory is missing: $bundle_root"
[[ -d $pkg_repo ]] || fail "package repository is missing: $pkg_repo"
for file in arach rustd rustd-resolved manifest.txt install-manifest.txt; do
    [[ -s $bundle_root/$file ]] || fail "bundle artifact is missing: $bundle_root/$file"
done

build_started=1
remove_tree "$topdir"
mkdir -p "$topdir"
install -m 0644 "$bundle_root/arach" "$topdir/arach"
install -m 0644 "$bundle_root/rustd" "$topdir/rustd"
install -m 0644 "$bundle_root/rustd-resolved" "$topdir/rustd-resolved"
install -m 0755 "$root/packaging/rpm/arach-kernel-install" "$topdir/arach-kernel-install"
install -m 0644 "$bundle_root/manifest.txt" "$topdir/arach-kernel-bundle-manifest.txt"
install -m 0644 "$bundle_root/install-manifest.txt" "$topdir/arach-kernel-install-manifest.txt"

cat > "$topdir/PKGBUILD" << PKG
pkgname=arach-kernel
pkgver=$version
pkgrel=$release
pkgdesc="Arach Kernel and measured RustD boot payloads"
arch=('x86_64')
url="https://github.com/SisyphusAeolides/Arach-Kernel"
license=('GPL-2.0-only')
depends=('bash' 'coreutils' 'grub')

source=("arach"
        "rustd"
        "rustd-resolved"
        "arach-kernel-install"
        "arach-kernel-bundle-manifest.txt"
        "arach-kernel-install-manifest.txt")
sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')

package() {
  install -Dm0644 "\$srcdir/arach" "\$pkgdir/boot/arach"
  install -Dm0644 "\$srcdir/rustd" "\$pkgdir/boot/rustd"
  install -Dm0644 "\$srcdir/rustd-resolved" "\$pkgdir/boot/rustd-resolved"
  install -Dm0755 "\$srcdir/arach-kernel-install" "\$pkgdir/usr/sbin/arach-kernel-install"
  install -Dm0644 "\$srcdir/arach-kernel-bundle-manifest.txt" "\$pkgdir/usr/share/arachos/arach-kernel/bundle-manifest.txt"
  install -Dm0644 "\$srcdir/arach-kernel-install-manifest.txt" "\$pkgdir/usr/share/arachos/arach-kernel/install-manifest.txt"
}
PKG

pushd "$topdir" >/dev/null
if [[ -n "${ARACHOS_GPG_KEY_ID:-}" && -n "${ARACHOS_GPG_HOME:-}" ]]; then
    GNUPGHOME="${ARACHOS_GPG_HOME:-}" makepkg -f --sign --noconfirm
else
    makepkg -f --noconfirm
fi
popd >/dev/null

pkg_path=$(find "$topdir" -maxdepth 1 -type f -name 'arach-kernel-*.pkg.tar.zst' -print -quit)
[[ -n $pkg_path && -s $pkg_path ]] || fail 'makepkg produced no binary package'

install -m 0644 "$pkg_path" "$pkg_repo/$(basename "$pkg_path")"
if [[ -f "$pkg_path.sig" ]]; then
    install -m 0644 "$pkg_path.sig" "$pkg_repo/$(basename "$pkg_path").sig"
fi
printf 'Arach Kernel package: %s\n' "$pkg_repo/$(basename "$pkg_path")"

# Update repo db with new kernel
pushd "$pkg_repo" >/dev/null
if [[ -n "${ARACHOS_GPG_KEY_ID:-}" && -n "${ARACHOS_GPG_HOME:-}" ]]; then
    GNUPGHOME="${ARACHOS_GPG_HOME:-}" repo-add -s -n arachos.db.tar.gz $(basename "$pkg_path")
else
    repo-add -n arachos.db.tar.gz $(basename "$pkg_path")
fi
popd >/dev/null

#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bundle_root=${ARACH_KERNEL_BUNDLE_ROOT:-$root/build/kernel-bundle}
rpm_repo=${RPM_REPO:-$root/build/repo}
topdir=${ARACH_KERNEL_RPM_TOPDIR:-$root/build/rpmbuild-arach-kernel}
version=${ARACHOS_VERSION:-1.0}
release=${ARACHOS_RELEASE:-1}
dist=${ARACHOS_RPM_DIST:-.arachos}
keep_build_work=${ARACHOS_KEEP_BUILD_WORK:-0}
build_started=0

fail() { printf 'Arach Kernel RPM: %s\n' "$*" >&2; exit 1; }

remove_tree() {
    local path=$1
    [[ -e $path ]] || return 0
    if find "$path" -depth -delete 2>/dev/null; then
        return 0
    fi
    if sudo -n true >/dev/null 2>&1; then
        sudo -n find "$path" -depth -delete 2>/dev/null || :
    else
        printf 'warning: cannot clean Arach Kernel RPM tree without privilege: %s\n' "$path" >&2
    fi
}

cleanup_rpm_build() {
    local status=$?
    if [[ $build_started == 1 && $keep_build_work != 1 ]]; then
        remove_tree "$topdir"
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup_rpm_build EXIT

for command in rpmbuild rpm sha256sum install find; do
    command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done
[[ -d $bundle_root ]] || fail "bundle directory is missing: $bundle_root"
[[ -d $rpm_repo ]] || fail "RPM repository is missing: $rpm_repo"
for file in arach rustd rustd-resolved manifest.txt install-manifest.txt; do
    [[ -s $bundle_root/$file ]] || fail "bundle artifact is missing: $bundle_root/$file"
done

build_started=1
remove_tree "$topdir"
mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
install -m 0644 "$bundle_root/arach" "$topdir/SOURCES/arach"
install -m 0644 "$bundle_root/rustd" "$topdir/SOURCES/rustd"
install -m 0644 "$bundle_root/rustd-resolved" "$topdir/SOURCES/rustd-resolved"
install -m 0755 "$root/packaging/rpm/arach-kernel-install" \
    "$topdir/SOURCES/arach-kernel-install"
install -m 0644 "$bundle_root/manifest.txt" \
    "$topdir/SOURCES/arach-kernel-bundle-manifest.txt"
install -m 0644 "$bundle_root/install-manifest.txt" \
    "$topdir/SOURCES/arach-kernel-install-manifest.txt"
install -m 0644 "$root/packaging/rpm/arach-kernel.spec" \
    "$topdir/SPECS/arach-kernel.spec"

rpmbuild -bb \
    --define "_topdir $topdir" \
    --define "dist $dist" \
    --define "arachos_version $version" \
    --define "arachos_release $release" \
    "$topdir/SPECS/arach-kernel.spec"

rpm_path=$(find "$topdir/RPMS" -type f -name 'arach-kernel-*.rpm' \
    ! -name '*.src.rpm' -print -quit)
[[ -n $rpm_path && -s $rpm_path ]] || fail 'rpmbuild produced no binary package'

if [[ -n ${ARACHOS_GPG_KEY_ID:-} || -n ${ARACHOS_GPG_HOME:-} ]]; then
    command -v rpmsign >/dev/null 2>&1 || fail 'rpmsign is required to sign Arach Kernel'
    GNUPGHOME="${ARACHOS_GPG_HOME:-}" rpmsign --addsign \
        --define "_gpg_name ${ARACHOS_GPG_KEY_ID:-}" "$rpm_path"
else
    fail 'Arach Kernel RPM would be unsigned; set ARACHOS_GPG_HOME and ARACHOS_GPG_KEY_ID'
fi
install -m 0644 "$rpm_path" "$rpm_repo/$(basename "$rpm_path")"
printf 'Arach Kernel RPM: %s\n' "$rpm_repo/$(basename "$rpm_path")"

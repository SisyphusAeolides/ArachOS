#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_REPO=${RPM_REPO:-$ROOT/build/repo}
ARACHOS_VERSION=${ARACHOS_VERSION:-1.0}
ARACHOS_RELEASE=${ARACHOS_RELEASE:-1}
ARACHOS_RELEASEVER=${ARACHOS_RELEASEVER:-1}
ARACHOS_ARCH=${ARACHOS_ARCH:-x86_64}
ARACHOS_BOOTSTRAP_RELEASE=${ARACHOS_BOOTSTRAP_RELEASE:-45}
ARACHOS_CORE_URL=${ARACHOS_CORE_URL:-https://dl.fedoraproject.org/pub/fedora/linux/development/45/Everything/x86_64/os/}
ARACHOS_UPDATES_URL=${ARACHOS_UPDATES_URL:-https://dl.fedoraproject.org/pub/fedora/linux/updates/45/Everything/x86_64/}
ARACHOS_BOOTSTRAP_ISO=${ARACHOS_BOOTSTRAP_ISO:-/home/Sisyphus/Downloads/Fedora-Everything-netinst-x86_64-45-20260831.n.0.iso}
ARACHOS_BOOTSTRAP_ISO_SHA256=${ARACHOS_BOOTSTRAP_ISO_SHA256:-523f17169f6012c8a9f04b1b1ceb330428a8fb1cf72e076de71dd396ffd9c40d}
ARACHOS_REPOSITORY_URL=${ARACHOS_REPOSITORY_URL:-}
ARACHOS_INSTALLER_KERNEL=${ARACHOS_INSTALLER_KERNEL:-$ROOT/build/kernel-bundle/installer-kernel}
ARACHOS_INSTALLER_INITRD=${ARACHOS_INSTALLER_INITRD:-$ROOT/build/kernel-bundle/installer-initrd.img}
ARACHOS_LIVE_RUNTIME_MANIFEST=${ARACHOS_LIVE_RUNTIME_MANIFEST:-$ROOT/build/kernel-bundle/live-manifest.txt}
LIVE_MEDIA_KEEP_WORK=${LIVE_MEDIA_KEEP_WORK:-0}
ARACHOS_KEEP_BUILD_WORK=${ARACHOS_KEEP_BUILD_WORK:-0}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-arach-kernel}
KERNEL_MODULE_PACKAGES=${KERNEL_MODULE_PACKAGES:-}
ARACH_KERNEL_INSTALL_MANIFEST=${ARACH_KERNEL_INSTALL_MANIFEST:-$ROOT/build/kernel-bundle/install-manifest.txt}
ARACHOS_HERMES_INSTALL_MANIFEST=${ARACHOS_HERMES_INSTALL_MANIFEST:-$ROOT/build/hermes-qualification/release-manifest.txt}
BUILDER_IMAGE=${ARACHOS_BUILDER_IMAGE:-localhost/arachos-build:fedora45}

fail() { printf 'ArachOS container installer build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
need podman
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"
[[ $ARACHOS_ARCH == x86_64 ]] || fail 'the container installer builder currently supports x86_64 only'
[[ -f $ARACHOS_BOOTSTRAP_ISO ]] || fail \
    "bootstrap installer ISO is missing: $ARACHOS_BOOTSTRAP_ISO"
[[ -r $ARACH_KERNEL_INSTALL_MANIFEST ]] || fail \
    "Arach-Kernel install qualification manifest is missing: $ARACH_KERNEL_INSTALL_MANIFEST"
[[ -r $ARACHOS_HERMES_INSTALL_MANIFEST ]] || fail \
    "Hermes release qualification manifest is missing: $ARACHOS_HERMES_INSTALL_MANIFEST"
[[ -r $ARACHOS_INSTALLER_KERNEL ]] || fail \
    "qualified Arach-Kernel installer image is missing: $ARACHOS_INSTALLER_KERNEL"
[[ -r $ARACHOS_INSTALLER_INITRD ]] || fail \
    "qualified RustD installer initramfs is missing: $ARACHOS_INSTALLER_INITRD"
[[ -r $ARACHOS_LIVE_RUNTIME_MANIFEST ]] || fail \
    "ArachOS live-runtime manifest is missing: $ARACHOS_LIVE_RUNTIME_MANIFEST"

if [[ $EUID -eq 0 ]]; then
    podman_cmd=(podman)
else
    podman_cmd=(sudo -n podman)
fi
"${podman_cmd[@]}" image exists "$BUILDER_IMAGE" \
    || fail "builder image is missing: $BUILDER_IMAGE"

if [[ -n ${ARACHOS_CONTAINER_BUILD_ROOT:-} ]]; then
    build_root=$ARACHOS_CONTAINER_BUILD_ROOT
    [[ ! -e $build_root ]] || fail "build root already exists: $build_root"
    mkdir -p "$build_root"
    cleanup_build_root=0
else
    build_root=$(mktemp -d /tmp/arachos-installer-build.XXXXXX)
    cleanup_build_root=1
fi

# A failed privileged container can leave root-owned RPMs and ISO work files
# behind.  Remove only the automatically allocated directory on failure;
# operator-supplied build roots are intentionally retained for diagnosis.
cleanup_container_work() {
    local status=$?
    if [[ $status -ne 0 && $cleanup_build_root == 1 && -d $build_root ]]; then
        if [[ $EUID -eq 0 ]]; then
            find "$build_root" -depth -delete 2>/dev/null || :
        elif sudo -n true >/dev/null 2>&1; then
            sudo -n find "$build_root" -depth -delete 2>/dev/null || :
        fi
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup_container_work EXIT
mkdir -p "$build_root/repo"
cp -a "$RPM_REPO"/. "$build_root/repo"/

printf 'Container build root: %s\n' "$build_root"
"${podman_cmd[@]}" run --rm --privileged --network host \
    --security-opt label=disable --pids-limit 2048 \
    --volume "$build_root:/out:rw,rprivate,rbind" \
    --volume "$ROOT:/workspace:ro,rprivate,rbind" \
    --env "ARACHOS_VERSION=$ARACHOS_VERSION" \
    --env "ARACHOS_RELEASE=$ARACHOS_RELEASE" \
    --env "ARACHOS_RELEASEVER=$ARACHOS_RELEASEVER" \
    --env "ARACHOS_ARCH=$ARACHOS_ARCH" \
    --env "ARACHOS_BOOTSTRAP_RELEASE=$ARACHOS_BOOTSTRAP_RELEASE" \
    --env "ARACHOS_CORE_URL=$ARACHOS_CORE_URL" \
    --env "ARACHOS_UPDATES_URL=$ARACHOS_UPDATES_URL" \
    --env "ARACHOS_BOOTSTRAP_ISO=/input/arachos-bootstrap.iso" \
    --env "ARACHOS_BOOTSTRAP_ISO_SHA256=$ARACHOS_BOOTSTRAP_ISO_SHA256" \
    --env "ARACHOS_REPOSITORY_URL=$ARACHOS_REPOSITORY_URL" \
    --env "ARACHOS_INSTALLER_KERNEL=/input/arachos-installer-kernel" \
    --env "ARACHOS_INSTALLER_INITRD=/input/arachos-installer-initrd.img" \
    --env "ARACHOS_LIVE_RUNTIME_MANIFEST=/input/arachos-live-runtime-manifest.txt" \
    --env "LIVE_MEDIA_KEEP_WORK=$LIVE_MEDIA_KEEP_WORK" \
    --env "ARACHOS_KEEP_BUILD_WORK=$ARACHOS_KEEP_BUILD_WORK" \
    --env "KERNEL_PACKAGE=$KERNEL_PACKAGE" \
    --env "KERNEL_MODULE_PACKAGES=$KERNEL_MODULE_PACKAGES" \
    --env "ARACH_KERNEL_INSTALL_MANIFEST=/input/arach-kernel-install-manifest.txt" \
    --env "ARACHOS_HERMES_INSTALL_MANIFEST=/input/hermes-release-manifest.txt" \
    --volume "$ARACHOS_BOOTSTRAP_ISO:/input/arachos-bootstrap.iso:ro,rprivate" \
    --volume "$ARACHOS_INSTALLER_KERNEL:/input/arachos-installer-kernel:ro,rprivate" \
    --volume "$ARACHOS_INSTALLER_INITRD:/input/arachos-installer-initrd.img:ro,rprivate" \
    --volume "$ARACHOS_LIVE_RUNTIME_MANIFEST:/input/arachos-live-runtime-manifest.txt:ro,rprivate" \
    --volume "$ARACH_KERNEL_INSTALL_MANIFEST:/input/arach-kernel-install-manifest.txt:ro,rprivate" \
    --volume "$ARACHOS_HERMES_INSTALL_MANIFEST:/input/hermes-release-manifest.txt:ro,rprivate" \
    "$BUILDER_IMAGE" \
    bash -lc '
        set -Eeuo pipefail
        for path in /usr/bin/make /usr/bin/mkksiso /usr/bin/xorriso; do
            test -x "$path" || { printf "builder is missing %s\\n" "$path" >&2; exit 1; }
        done
        BUILD_DIR=/out RPM_REPO=/out/repo ISO_OUTPUT=/out/iso \
            LIVE_MEDIA_WORK=/out/work make -C /workspace build-live-existing
    '

printf 'ArachOS container installer: %s/iso/ArachOS-%s-%s-installer-%s.iso\n' \
    "$build_root" "$ARACHOS_VERSION" "$ARACHOS_RELEASE" "$ARACHOS_ARCH"

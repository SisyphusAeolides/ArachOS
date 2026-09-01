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
KERNEL_PACKAGE=${KERNEL_PACKAGE:-kernel}
KERNEL_MODULE_PACKAGES=${KERNEL_MODULE_PACKAGES:-}
BUILDER_IMAGE=${ARACHOS_BUILDER_IMAGE:-localhost/arachos-build:fedora45}

fail() { printf 'ArachOS container installer build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
need podman
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"
[[ $ARACHOS_ARCH == x86_64 ]] || fail 'the container installer builder currently supports x86_64 only'
[[ -f $ARACHOS_BOOTSTRAP_ISO ]] || fail \
    "bootstrap installer ISO is missing: $ARACHOS_BOOTSTRAP_ISO"

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
else
    build_root=$(mktemp -d /tmp/arachos-installer-build.XXXXXX)
fi
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
    --env "KERNEL_PACKAGE=$KERNEL_PACKAGE" \
    --env "KERNEL_MODULE_PACKAGES=$KERNEL_MODULE_PACKAGES" \
    --volume "$ARACHOS_BOOTSTRAP_ISO:/input/arachos-bootstrap.iso:ro,rprivate" \
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

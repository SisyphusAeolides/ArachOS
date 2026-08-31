#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_REPO=${RPM_REPO:-$ROOT/build/repo}
RLC_RELEASE=${RLC_RELEASE:-10.2}
RLC_ARCH=${RLC_ARCH:-x86_64}
RLC_INSTALL_TREE_URL=${RLC_INSTALL_TREE_URL:-}
RLC_SOURCE_ISO=${RLC_SOURCE_ISO:-}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-kernel}
KERNEL_MODULE_PACKAGES=${KERNEL_MODULE_PACKAGES:-kernel-modules kernel-modules-extra}
BUILDER_IMAGE=${ARACHOS_BUILDER_IMAGE:-localhost/arachos-build:el10-xfs-ready}

fail() { printf 'container live build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
need podman
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"
[[ $RLC_RELEASE == 10.2 ]] || fail 'this pipeline is pinned to CIQ RLC 10.2'
[[ -n $RLC_INSTALL_TREE_URL || -n $RLC_SOURCE_ISO ]] || fail \
    'set RLC_SOURCE_ISO or RLC_INSTALL_TREE_URL'
[[ -z $RLC_SOURCE_ISO || -f $RLC_SOURCE_ISO ]] || \
    fail "RLC source ISO is missing: $RLC_SOURCE_ISO"

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
    build_root=$(mktemp -d /tmp/arachos-rlc-live-build.XXXXXX)
fi
mkdir -p "$build_root/repo"
cp -a "$RPM_REPO"/. "$build_root/repo"/

source_mount=()
source_env=(
    --env "RLC_INSTALL_TREE_URL=$RLC_INSTALL_TREE_URL"
    --env "RLC_SOURCE_ISO="
)
if [[ -n $RLC_SOURCE_ISO ]]; then
    source_mount=(
        --volume "$RLC_SOURCE_ISO:/mnt/rlc-source.iso:ro,nosuid,nodev,noexec"
    )
    source_env=(
        --env 'RLC_INSTALL_TREE_URL='
        --env 'RLC_SOURCE_ISO=/mnt/rlc-source.iso'
    )
fi

printf 'Container build root: %s\n' "$build_root"
"${podman_cmd[@]}" run --rm --privileged --network host \
    --security-opt label=disable --pids-limit 2048 \
    --volume "$build_root:/out:rw,rprivate,rbind" \
    --volume /lib/modules:/lib/modules:ro,rprivate,rbind \
    --volume "$ROOT:/workspace:ro,rprivate,rbind" \
    "${source_mount[@]}" \
    "${source_env[@]}" \
    --env "RLC_RELEASE=$RLC_RELEASE" \
    --env "RLC_ARCH=$RLC_ARCH" \
    --env "KERNEL_PACKAGE=$KERNEL_PACKAGE" \
    --env "KERNEL_MODULE_PACKAGES=$KERNEL_MODULE_PACKAGES" \
    "$BUILDER_IMAGE" \
    bash -lc '
        set -Eeuo pipefail
        for path in /usr/bin/make /usr/sbin/livemedia-creator /usr/sbin/chroot; do
            test -x "$path" || { printf "builder is missing %s\\n" "$path" >&2; exit 1; }
        done
        BUILD_DIR=/out LIVE_MEDIA_WORK=/out/work \
            make -C /workspace build-live-existing
    '

printf 'Container live build complete: %s/iso/ArachOS-RLC-%s-live-%s.iso\n' \
    "$build_root" "$RLC_RELEASE" "$RLC_ARCH"

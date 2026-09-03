#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARACHOS_VERSION=${ARACHOS_VERSION:-1.0}
ARACHOS_RELEASE=${ARACHOS_RELEASE:-1}
ARACHOS_BOOTSTRAP_RELEASE=${ARACHOS_BOOTSTRAP_RELEASE:-45}
KOJI_PROFILE=${KOJI_PROFILE:-arachos}
KOJI_TARGET=${KOJI_TARGET:-arachos-${ARACHOS_VERSION}-build}
KOJI_CONFIG=${KOJI_CONFIG:-/etc/koji.conf}
KOJI_BUILD_RPMS=${KOJI_BUILD_RPMS:-1}
KOJI_EXPORT_REPO=${KOJI_EXPORT_REPO:-}
KOJI_TOPURL=${KOJI_TOPURL:-}
KOJI_EXPORT_ARCH=${KOJI_EXPORT_ARCH:-x86_64}
ARACH_KERNEL_PACKAGE=${ARACH_KERNEL_PACKAGE:-kernel-clk6.18}
ARACH_KERNEL_SRPM=${ARACH_KERNEL_SRPM:-}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-$ARACH_KERNEL_PACKAGE}
SRPM_DIR=${SRPM_DIR:-${RPM_REPO:-$ROOT/build/repo}}
WORK=${KOJI_WORK:-$ROOT/build/koji-$(date +%Y%m%d%H%M%S)-$$}

fail() { printf 'Koji ArachOS build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in koji git awk rpm rpmbuild sha256sum; do need "$command"; done

[[ -r $KOJI_CONFIG ]] || fail "Koji configuration is missing: $KOJI_CONFIG"
[[ $KOJI_EXPORT_ARCH =~ ^[[:alnum:]_.+-]+$ ]] || fail \
    "invalid Koji export architecture: $KOJI_EXPORT_ARCH"

# Koji is an optional build farm for an independent distribution. Require an
# explicitly configured HTTPS hub and never silently fall back to a public
# distribution's build service.
profile_server=$(awk -v wanted="[$KOJI_PROFILE]" '
    $0 == wanted { in_profile = 1; next }
    in_profile && /^\[/ { exit }
    in_profile && /^[[:space:]]*server[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); print; exit
    }
' "$KOJI_CONFIG")
[[ -n $profile_server ]] || fail \
    "Koji profile [$KOJI_PROFILE] has no server in $KOJI_CONFIG"
case $profile_server in
    https://*) ;;
    *) fail 'the ArachOS Koji hub must use HTTPS' ;;
esac

mkdir -p "$WORK"
koji_args=(--config "$KOJI_CONFIG" --profile "$KOJI_PROFILE")
koji_call() { koji "${koji_args[@]}" "$@"; }

koji_call list-targets --name="$KOJI_TARGET" >/dev/null \
    || fail "cannot access Koji profile [$KOJI_PROFILE]"

build_tag=$(koji_call list-targets --name="$KOJI_TARGET" --quiet \
    | awk 'NF >= 3 { print $2; exit }')
[[ -n $build_tag ]] || fail "cannot determine the build tag for $KOJI_TARGET"

prepare_branding_srpm() {
    local existing branding_top
    existing=$(find "$SRPM_DIR" -maxdepth 1 -type f \
        -name 'arachos-release-*.src.rpm' -print -quit 2>/dev/null || true)
    if [[ -n $existing ]]; then
        printf '%s\n' "$existing"
        return
    fi

    branding_top="$WORK/branding-rpmbuild"
    mkdir -p "$branding_top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    cp "$ROOT/packaging/branding/arachos-release.spec" "$branding_top/SPECS/"
    cp "$ROOT/docs/ArachOS.png" "$branding_top/SOURCES/ArachOS.png"
    cp "$ROOT/packaging/branding/chaos.png" "$branding_top/SOURCES/chaos.png"
    cp "$ROOT/packaging/branding/arachos-fastfetch.jsonc" \
        "$branding_top/SOURCES/arachos-fastfetch.jsonc"
    cp "$ROOT/packaging/branding/arachos-profile.sh" \
        "$branding_top/SOURCES/arachos-profile.sh"
    rpmbuild -bs \
        --define "_topdir $branding_top" \
        --define 'dist .arachos' \
        --define "arachos_version $ARACHOS_VERSION" \
        --define "arachos_release $ARACHOS_RELEASE" \
        --define "arachos_bootstrap_release $ARACHOS_BOOTSTRAP_RELEASE" \
        "$branding_top/SPECS/arachos-release.spec" >/dev/null
    find "$branding_top/SRPMS" -maxdepth 1 -type f -name 'arachos-release-*.src.rpm' \
        -print -quit
}

declare -A source_rpms=()
if [[ $KOJI_BUILD_RPMS == 1 ]]; then
    [[ -d $SRPM_DIR ]] || fail "SRPM directory is missing: $SRPM_DIR"
    while IFS= read -r srpm; do
        name=$(rpm -qp --qf '%{NAME}' "$srpm") \
            || fail "cannot inspect $(basename "$srpm")"
        case $name in
            kernel|kernel-clk6.18|kernel-clk6.12|rustd|rustd-selinux|\
            rustd-fedora-compat|rustd-compat-libs|rustd-resolved|tuned-rs|\
            libinput-rs|blerust|ccze-rs|iwchaos|hermes-gpu-stack|arachos-release)
                [[ -z ${source_rpms[$name]+x} ]] || fail "duplicate SRPM for $name"
                source_rpms[$name]=$srpm
                ;;
        esac
    done < <(find "$SRPM_DIR" -maxdepth 1 -type f -name '*.src.rpm' -print | sort)

    if [[ -n $ARACH_KERNEL_SRPM ]]; then
        [[ -f $ARACH_KERNEL_SRPM ]] || fail "Arach Kernel SRPM is missing: $ARACH_KERNEL_SRPM"
        kernel_name=$(rpm -qp --qf '%{NAME}' "$ARACH_KERNEL_SRPM") \
            || fail "cannot inspect $(basename "$ARACH_KERNEL_SRPM")"
        [[ $kernel_name == "$ARACH_KERNEL_PACKAGE" ]] || fail \
            "Arach Kernel SRPM is $kernel_name, expected $ARACH_KERNEL_PACKAGE"
        [[ -z ${source_rpms[$kernel_name]+x} ]] || fail "duplicate SRPM for $kernel_name"
        source_rpms[$kernel_name]=$ARACH_KERNEL_SRPM
    fi

    if [[ -z ${source_rpms[arachos-release]+x} ]]; then
        source_rpms[arachos-release]=$(prepare_branding_srpm)
        [[ -n ${source_rpms[arachos-release]} ]] || fail 'could not prepare arachos-release SRPM'
    fi

    build_order=(
        "$KERNEL_PACKAGE"
        rustd
        rustd-selinux
        rustd-compat-libs
        rustd-fedora-compat
        rustd-resolved
        arachos-release
        tuned-rs
        libinput-rs
        blerust
        ccze-rs
        iwchaos
        hermes-gpu-stack
    )
    for name in "${build_order[@]}"; do
        [[ -n ${source_rpms[$name]+x} ]] || fail \
            "missing $name SRPM in $SRPM_DIR; complete Koji builds require source RPMs"
        srpm=${source_rpms[$name]}
        printf 'Submitting %s\n' "$(basename "$srpm")"
        koji_call build --wait --wait-repo "$KOJI_TARGET" "$srpm"
    done
else
    [[ $KOJI_BUILD_RPMS == 0 ]] || fail 'KOJI_BUILD_RPMS must be 0 or 1'
    printf '%s\n' 'Using the already-tagged ArachOS RPM builds in the Koji target.'
fi

koji_call wait-repo --target --timeout 180 "$KOJI_TARGET"

koji_build_packages=(
    "$KERNEL_PACKAGE"
    rustd
    rustd-selinux
    rustd-compat-libs
    rustd-fedora-compat
    rustd-resolved
    arachos-release
    tuned-rs
    libinput-rs
    blerust
    ccze-rs
    iwchaos
    hermes-gpu-stack
)
for name in "${koji_build_packages[@]}"; do
    latest=$(koji_call latest-build --quiet "$build_tag" "$name") \
        || fail "Koji could not query the latest build for $name"
    [[ -n $latest ]] || fail "Koji build tag $build_tag lacks a latest build for $name"
done

if [[ -n $KOJI_EXPORT_REPO ]]; then
    need createrepo_c
    [[ -n $KOJI_TOPURL ]] || fail \
        'KOJI_TOPURL is required when KOJI_EXPORT_REPO is requested'
    [[ -d $KOJI_EXPORT_REPO || ! -e $KOJI_EXPORT_REPO ]] || fail \
        "Koji export path is not a directory: $KOJI_EXPORT_REPO"

    export_work="$WORK/exported-rpms"
    mkdir -p "$export_work" "$KOJI_EXPORT_REPO"
    for name in "${koji_build_packages[@]}"; do
        printf 'Exporting %s from Koji\n' "$name"
        (
            cd "$export_work"
            koji "${koji_args[@]}" \
                --topurl "$KOJI_TOPURL" \
                download-build --latestfrom "$build_tag" \
                --arch "$KOJI_EXPORT_ARCH" --noprogress "$name"
        )
    done
    find "$export_work" -maxdepth 1 -type f -name '*.rpm' \
        -exec cp -a {} "$KOJI_EXPORT_REPO/" \;
    createrepo_c --update "$KOJI_EXPORT_REPO"
    printf 'Koji RPM repository exported to %s\n' "$KOJI_EXPORT_REPO"
fi

printf 'ArachOS Koji RPM pipeline completed for target %s (build tag %s)\n' \
    "$KOJI_TARGET" "$build_tag"
printf 'The exported repository is consumed by scripts/build-live.sh.\n'
printf 'Koji work files: %s\n' "$WORK"

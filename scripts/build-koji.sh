#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RLC_RELEASE=${RLC_RELEASE:-10.2}
KOJI_PROFILE=${KOJI_PROFILE:-rlc10.2}
KOJI_TARGET=${KOJI_TARGET:-rlc-10.2-build}
KOJI_CONFIG=${KOJI_CONFIG:-/etc/koji.conf}
KOJI_BUILD_RPMS=${KOJI_BUILD_RPMS:-1}
KOJI_EXPORT_REPO=${KOJI_EXPORT_REPO:-}
KOJI_TOPURL=${KOJI_TOPURL:-}
KOJI_EXPORT_ARCH=${KOJI_EXPORT_ARCH:-x86_64}
CHAOS_KERNEL_PACKAGE=${CHAOS_KERNEL_PACKAGE:-kernel-clk6.18}
CHAOS_KERNEL_SRPM=${CHAOS_KERNEL_SRPM:-}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-$CHAOS_KERNEL_PACKAGE}
SRPM_DIR=${SRPM_DIR:-${RPM_REPO:-$ROOT/build/repo}}
WORK=${KOJI_WORK:-$ROOT/build/koji-$(date +%Y%m%d%H%M%S)-$$}

fail() { printf 'Koji ArachOS build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in koji git awk rpm rpmbuild sha256sum; do need "$command"; done

[[ $RLC_RELEASE == 10.2 ]] || fail 'this pipeline is pinned to CIQ RLC 10.2'
[[ -r $KOJI_CONFIG ]] || fail "Koji configuration is missing: $KOJI_CONFIG"
[[ $KOJI_EXPORT_ARCH =~ ^[[:alnum:]_.+-]+$ ]] || fail \
    "invalid Koji export architecture: $KOJI_EXPORT_ARCH"

# Never allow an unset profile to fall through to the public Fedora Koji
# service. The RLC hub, target, and repository must be supplied by the
# private CIQ/user Koji deployment.
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
    *koji.fedoraproject.org*) fail 'refusing to submit an RLC build to Fedora Koji' ;;
    https://*) ;;
    *) fail 'the RLC Koji hub must use HTTPS' ;;
esac

mkdir -p "$WORK"
koji_args=(--config "$KOJI_CONFIG" --profile "$KOJI_PROFILE")
koji_call() { koji "${koji_args[@]}" "$@"; }

# Check authentication and target visibility before uploading any source RPM.
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
    rpmbuild -bs \
        --define "_topdir $branding_top" \
        --define 'dist .el10' \
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
            # RustD's RLC/RHEL compatibility integration is intentionally split into several
            # SRPMs. Submit each one so the Koji target can solve the complete
            # installed-system cutover transaction.
            kernel|kernel-clk6.18|kernel-clk6.12|rustd|rustd-selinux|rustd-fedora-compat|rustd-compat-libs|\
            rustd-resolved|tuned-rs|libinput-rs|blerust|ccze-rs|arachos-release)
                [[ -z ${source_rpms[$name]+x} ]] || fail "duplicate SRPM for $name"
                source_rpms[$name]=$srpm
                ;;
        esac
    done < <(find "$SRPM_DIR" -maxdepth 1 -type f -name '*.src.rpm' -print | sort)

    if [[ -n $CHAOS_KERNEL_SRPM ]]; then
        [[ -f $CHAOS_KERNEL_SRPM ]] || fail "Chaos Kernel SRPM is missing: $CHAOS_KERNEL_SRPM"
        kernel_name=$(rpm -qp --qf '%{NAME}' "$CHAOS_KERNEL_SRPM") \
            || fail "cannot inspect $(basename "$CHAOS_KERNEL_SRPM")"
        [[ $kernel_name == "$CHAOS_KERNEL_PACKAGE" ]] || fail \
            "Chaos Kernel SRPM is $kernel_name, expected $CHAOS_KERNEL_PACKAGE"
        [[ -z ${source_rpms[$kernel_name]+x} ]] || fail "duplicate SRPM for $kernel_name"
        source_rpms[$kernel_name]=$CHAOS_KERNEL_SRPM
    fi

    if [[ -z ${source_rpms[arachos-release]+x} ]]; then
        source_rpms[arachos-release]=$(prepare_branding_srpm)
        [[ -n ${source_rpms[arachos-release]} ]] || fail 'could not prepare arachos-release SRPM'
    fi

    build_order=(
        "$CHAOS_KERNEL_PACKAGE"
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
    printf '%s\n' 'Using the already-tagged custom RPM builds in the Koji target.'
fi

koji_call wait-repo --target --timeout 180 "$KOJI_TARGET"

# Validate the tagged build repository for both fresh and already-built runs.
# latest-build takes the build tag, not the build-target name.
koji_build_packages=(
    "$CHAOS_KERNEL_PACKAGE"
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

# Standard Koji's spin-livemedia/spin-livecd tasks synthesize a live root. That
# is deliberately not ArachOS's installer model: CIQ RLC's DVD already boots
# Anaconda directly. The tagged RPM repository is consumed by the RLC DVD
# remaster step (scripts/build-live.sh), which preserves that boot contract.
printf 'Koji ArachOS RPM pipeline completed for target %s (build tag %s)\n' \
    "$KOJI_TARGET" "$build_tag"
printf 'No live-media task was submitted; use the RLC DVD remaster step for the installer ISO.\n'
printf 'Koji work files: %s\n' "$WORK"

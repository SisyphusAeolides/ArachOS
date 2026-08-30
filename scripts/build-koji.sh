#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RLC_RELEASE=${RLC_RELEASE:-10.2}
RLC_INSTALL_TREE_URL=${RLC_INSTALL_TREE_URL:-}
KOJI_PROFILE=${KOJI_PROFILE:-rlc10.2}
KOJI_TARGET=${KOJI_TARGET:-rlc-10.2-build}
KOJI_ARCHES=${KOJI_ARCHES:-x86_64}
KOJI_CONFIG=${KOJI_CONFIG:-/etc/koji.conf}
KOJI_BUILD_RPMS=${KOJI_BUILD_RPMS:-1}
CHAOS_KERNEL_PACKAGE=${CHAOS_KERNEL_PACKAGE:-kernel-clk6.12}
CHAOS_KERNEL_SRPM=${CHAOS_KERNEL_SRPM:-}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-$CHAOS_KERNEL_PACKAGE}
# The namespaced Chaos Kernel package pulls its own core/modules packages.
# Callers selecting the stock RLC kernel can set both variables explicitly.
KERNEL_MODULE_PACKAGES=${KERNEL_MODULE_PACKAGES-}
SRPM_DIR=${SRPM_DIR:-${RPM_REPO:-$ROOT/build/repo}}
WORK=${KOJI_WORK:-$ROOT/build/koji-$(date +%Y%m%d%H%M%S)-$$}

fail() { printf 'Koji ArachOS build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in koji git awk rpm rpmbuild sha256sum; do need "$command"; done

[[ $RLC_RELEASE == 10.2 ]] || fail 'this pipeline is pinned to CIQ RLC 10.2'
[[ $KOJI_ARCHES != *,* ]] || fail 'spin-livemedia accepts one image architecture per invocation'
[[ $KOJI_ARCHES =~ ^[[:alnum:]_.+-]+$ ]] || fail "invalid image architecture: $KOJI_ARCHES"
[[ -r $KOJI_CONFIG ]] || fail "Koji configuration is missing: $KOJI_CONFIG"
[[ -n $RLC_INSTALL_TREE_URL ]] || fail \
    'set RLC_INSTALL_TREE_URL to an HTTPS-exposed CIQ RLC 10.2 install tree'
case $RLC_INSTALL_TREE_URL in
    https://*) ;;
    *) fail 'Koji LiveMedia builds require an HTTPS install tree; a local ISO is for make build-live-existing' ;;
esac

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
koji_call list-targets >/dev/null \
    || fail "cannot access Koji profile [$KOJI_PROFILE]"

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
            # RustD's Fedora integration is intentionally split into several
            # SRPMs. Submit each one so the Koji target can solve the complete
            # cutover transaction before the LiveMedia task starts.
            kernel|kernel-clk6.12|rustd|rustd-selinux|rustd-fedora-compat|rustd-compat-libs|\
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

# Validate that the target contains the package set which the kickstart asks
# for when the caller intentionally skips source-RPM submission.
if [[ $KOJI_BUILD_RPMS == 0 ]]; then
    runtime_packages=(
        "$KERNEL_PACKAGE"
        rustd
        rustd-cutover-tools
        rustd-selinux
        rustd-compat-libs
        rustd-fedora-compat
        rustd-resolved
        rustd-resolved-nss
        arachos-release
        tuned-rs
        libinput-rs
        blerust
        ccze-rs
    )
    for name in "${runtime_packages[@]}"; do
        koji_call latest-build "$KOJI_TARGET" "$name" >/dev/null \
            || fail "Koji target lacks a latest build for $name"
    done
fi

rendered_ks="$WORK/ArachOS.ks"
awk -v install_tree="$RLC_INSTALL_TREE_URL" '
    BEGIN {
        module_count = split("'"$KERNEL_MODULE_PACKAGES"'", module_list, /[[:space:]]+/)
        in_kernel = ""
    }
    /^url[[:space:]]+--url=/ {
        print "url --url=" install_tree
        next
    }
    /^# ARACHOS_KERNEL_PACKAGE_BEGIN$/ {
        print "'"$KERNEL_PACKAGE"'"
        in_kernel = "package"
        next
    }
    /^# ARACHOS_KERNEL_PACKAGE_END$/ {
        in_kernel = ""
        next
    }
    /^# ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN$/ {
        for (i = 1; i <= module_count; i++)
            if (module_list[i] != "") print module_list[i]
        in_kernel = "modules"
        next
    }
    /^# ARACHOS_KERNEL_MODULE_PACKAGES_END$/ {
        in_kernel = ""
        next
    }
    in_kernel != "" { next }
    { print }
' "$ROOT/kickstart/ArachOS.ks" > "$rendered_ks"
grep -q '^url --url=https://' "$rendered_ks" \
    || fail 'rendered Koji kickstart does not point at HTTPS RLC media'

remote=$(git -C "$ROOT" remote get-url origin)
commit=$(git -C "$ROOT" rev-parse HEAD)
case $remote in
    https://*) lorax_url="git+$remote?#$commit" ;;
    *) fail 'ArachOS origin must be an HTTPS Git remote for the Koji builder' ;;
esac

printf 'Submitting ArachOS RLC %s LiveMedia build\n' "$RLC_RELEASE"
koji_call spin-livemedia --wait \
    --install-tree-url "$RLC_INSTALL_TREE_URL" \
    --release "$RLC_RELEASE" \
    --volid "ARACHOS${RLC_RELEASE//./}" \
    --lorax_url "$lorax_url" \
    --lorax_dir packaging/lorax/live \
    "ArachOS-live" "$RLC_RELEASE" "$KOJI_TARGET" "$KOJI_ARCHES" "$rendered_ks"

printf 'Koji ArachOS build submitted successfully; work files: %s\n' "$WORK"

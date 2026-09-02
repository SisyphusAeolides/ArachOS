#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
kernel_root=${ARACH_KERNEL_SOURCE_ROOT:-$root/../Arach-Kernel}
rustd_root=${RUSTD_SOURCE_ROOT:-$root/../rustd}
build_root=${ARACH_KERNEL_BUILD_ROOT:-$root/build/arach-kernel}
rustd_static_root=${ARACH_RUSTD_STATIC_BUILD_ROOT:-$root/build/rustd-static}
bundle_root=${ARACH_KERNEL_BUNDLE_ROOT:-$root/build/kernel-bundle}
rpm_repo=${RPM_REPO:-$root/build/repo}
arachos_version=${ARACHOS_VERSION:-1.0}
arachos_release=${ARACHOS_RELEASE:-1}
arachos_arch=${ARACHOS_ARCH:-x86_64}
cargo_bin=${CARGO:-}

if [[ -z ${RUSTUP_TOOLCHAIN:-} && -x /usr/local/cargo/bin/rustup ]]; then
    export RUSTUP_TOOLCHAIN=nightly-2026-07-20
fi

fail() { printf 'ArachOS kernel bundle: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in git cargo readelf sha256sum rpm rpm2cpio cpio install; do need "$command"; done

[[ $arachos_arch == x86_64 ]] || fail 'the kernel bundle currently supports x86_64 only'
[[ -d $kernel_root/.git ]] || fail "Arach-Kernel checkout is missing: $kernel_root"
[[ -d $rustd_root/.git ]] || fail "RustD checkout is missing: $rustd_root"
[[ -d $rpm_repo ]] || fail "RPM repository is missing: $rpm_repo; run make build-rpms first"
rpm_repo=$(cd "$rpm_repo" && pwd)

RUSTD_SOURCE_ROOT="$rustd_root" \
RESOLVED_SOURCE_ROOT="${RESOLVED_SOURCE_ROOT:-$root/../rustd-resolved}" \
ARACH_KERNEL_SOURCE_ROOT="$kernel_root" \
IWCHAOS_SOURCE_ROOT="${IWCHAOS_SOURCE_ROOT:-$root/../iwchaos}" \
TUNED_SOURCE_ROOT="${TUNED_SOURCE_ROOT:-$root/../tuned-rs}" \
LIBINPUT_SOURCE_ROOT="${LIBINPUT_SOURCE_ROOT:-$root/../libinput-rs}" \
BLERUST_SOURCE_ROOT="${BLERUST_SOURCE_ROOT:-$root/../blerust}" \
CCZE_SOURCE_ROOT="${CCZE_SOURCE_ROOT:-$root/../ccze-rs}" \
HERMES_SOURCE_ROOT="${HERMES_SOURCE_ROOT:-$root/../Hermes}" \
    bash "$root/scripts/verify-sources.sh"

if [[ -z $cargo_bin ]]; then
    if [[ -x /usr/local/cargo/bin/cargo ]]; then
        cargo_bin=/usr/local/cargo/bin/cargo
        export RUSTUP_HOME=${RUSTUP_HOME:-/usr/local/lib/rustup}
    else
        cargo_bin=cargo
    fi
fi

kernel_target=$kernel_root/x86_64-arach.json
[[ -f $kernel_target ]] || fail "kernel target specification is missing: $kernel_target"
mkdir -p "$build_root" "$bundle_root" "$rustd_static_root"
build_root=$(cd "$build_root" && pwd)
bundle_root=$(cd "$bundle_root" && pwd)
rustd_static_root=$(cd "$rustd_static_root" && pwd)

extract_rpm_file() {
    local package=$1 path=$2 destination=$3
    rm -rf -- "$destination"
    mkdir -p "$destination"
    (cd "$destination" && rpm2cpio "$package" | cpio -idm --quiet)
    [[ -f $destination/$path ]] || fail "RPM $(basename "$package") has no $path"
    printf '%s\n' "$destination/$path"
}

find_binary_rpm() {
    local pattern=$1
    find "$rpm_repo" -maxdepth 1 -type f -name "$pattern" \
        ! -name '*.src.rpm' ! -name '*-debugsource-*' ! -name '*-debuginfo-*' \
        | sort -V | tail -n 1
}

rustd_image=${ARACH_RUSTD_IMAGE:-}
if [[ -z $rustd_image ]]; then
    [[ -x $rustd_root/scripts/build-static-rustd.sh ]] || fail \
        "RustD static build script is missing: $rustd_root/scripts/build-static-rustd.sh"
    RUSTD_STATIC_TARGET_DIR="$rustd_static_root" \
        bash "$rustd_root/scripts/build-static-rustd.sh"
    rustd_image=$rustd_static_root/x86_64-static-linux/release/rustd
fi

resolved_image=${ARACH_RESOLVED_IMAGE:-}
if [[ -z $resolved_image ]]; then
    resolved_rpm=$(find_binary_rpm 'rustd-resolved-[0-9]*.rpm')
    [[ -n $resolved_rpm ]] || fail \
        'set ARACH_RESOLVED_IMAGE or provide a rustd-resolved RPM in RPM_REPO'
    resolved_image=$(extract_rpm_file "$resolved_rpm" usr/lib/rustd/rustd-resolved \
        "$build_root/resolved-root")
fi

for artifact in "$rustd_image" "$resolved_image"; do
    [[ -f $artifact && -s $artifact ]] || fail "artifact is missing or empty: $artifact"
    readelf -hW "$artifact" | grep -Fq 'Class:                             ELF64' \
        || fail "artifact is not ELF64: $artifact"
done
readelf -lW "$rustd_image" | grep -Fq 'INTERP' \
    && fail 'RustD PID 1 artifact must be loader-free static ELF'

build_none() {
    local manifest=$1 target_dir=$2
    shift 2
    RUSTC_WRAPPER= CC=${CC:-/usr/bin/gcc} AR=${AR:-/usr/bin/ar} \
        CARGO_TARGET_DIR="$target_dir" "$cargo_bin" build \
        --locked --release --manifest-path "$manifest" --target "$kernel_target" \
        -Z json-target-spec -Z build-std=core,alloc,compiler_builtins \
        -Z build-std-features=compiler-builtins-mem "$@"
}

bootstrap_image=${ARACH_BOOTSTRAP_IMAGE:-}
if [[ -z $bootstrap_image ]]; then
    # The C0 probe exercises the measured Linux ABI boundary while the
    # installed ArachOS filesystem and service graph remain separate gates.
    c0_root=$build_root/c0
    shared_root=$c0_root/shared-object
    mkdir -p "$shared_root"
    "$kernel_root/scripts/build-shared-object-probe.sh" \
        "$shared_root/libarach-probe.so" \
        "$shared_root/libarach-provider.so" \
        "$shared_root/libarach-observer.so" \
        "$shared_root/libarach-core.so"
    runtime_linker=$c0_root/runtime-linker/arach-ld.so
    "$kernel_root/scripts/build-runtime-linker-probe.sh" "$runtime_linker"
    ARACH_SHARED_OBJECT_IMAGE="$shared_root/libarach-probe.so" \
        build_none "$kernel_root/probes/exec-target/Cargo.toml" "$c0_root/exec-target"
    exec_target=$c0_root/exec-target/x86_64-arach/release/arach-exec-target
    [[ -s $exec_target ]] || fail 'C0 exec target was not built'
    ARACH_EXEC_TARGET_IMAGE="$exec_target" \
    ARACH_RUNTIME_LINKER_IMAGE="$runtime_linker" \
    ARACH_SHARED_OBJECT_IMAGE="$shared_root/libarach-probe.so" \
    ARACH_SHARED_PROVIDER_IMAGE="$shared_root/libarach-provider.so" \
    ARACH_SHARED_OBSERVER_IMAGE="$shared_root/libarach-observer.so" \
    ARACH_SHARED_CORE_IMAGE="$shared_root/libarach-core.so" \
        build_none "$kernel_root/probes/c0/Cargo.toml" "$c0_root/probe"
    bootstrap_image=$c0_root/probe/x86_64-arach/release/arach-c0-probe
fi

[[ -f $bootstrap_image && -s $bootstrap_image ]] || \
    fail "bootstrap image is missing or empty: $bootstrap_image"
readelf -hW "$bootstrap_image" | grep -Fq 'Class:                             ELF64' \
    || fail "bootstrap image is not ELF64: $bootstrap_image"

kernel_image=${ARACH_KERNEL_IMAGE:-$build_root/kernel/x86_64-arach/release/arach}
if [[ -z ${ARACH_KERNEL_IMAGE:-} ]]; then
    (
        cd "$kernel_root"
        RUSTC_WRAPPER= CC=${CC:-/usr/bin/gcc} FC=${FC:-/usr/bin/gfortran} AR=${AR:-/usr/bin/ar} \
        ARACH_RUSTD_IMAGE="$rustd_image" \
        ARACH_RESOLVED_IMAGE="$resolved_image" \
        ARACH_BOOTSTRAP_IMAGE="$bootstrap_image" \
        ARACH_BOOTSTRAP_ABI="${ARACH_BOOTSTRAP_ABI:-linux}" \
            CARGO_TARGET_DIR="$build_root/kernel" "$cargo_bin" build \
            --locked --release -p arach --bin arach \
            --no-default-features --features kernel-bin,reference-driver,fortran-control \
            --target "$kernel_target" -Z json-target-spec \
            -Z build-std=core,alloc,compiler_builtins \
            -Z build-std-features=compiler-builtins-mem
    )
fi

[[ -f $kernel_image && -s $kernel_image ]] || fail "kernel image is missing or empty: $kernel_image"

output_iso=$bundle_root/ArachOS-${arachos_version}-${arachos_release}-Arach-Kernel-${arachos_arch}.iso
ARACH_KERNEL_IMAGE="$kernel_image" \
ARACH_RUSTD_IMAGE="$rustd_image" \
ARACH_BOOTSTRAP_IMAGE="$bootstrap_image" \
ARACH_RESOLVED_IMAGE="$resolved_image" \
ARACH_GRUB_ISO="$output_iso" \
    bash "$kernel_root/scripts/build-arachos-grub-bundle.sh"

install -m 0644 "$kernel_image" "$bundle_root/arach"
install -m 0644 "$rustd_image" "$bundle_root/rustd"
install -m 0644 "$bootstrap_image" "$bundle_root/bootstrap"
install -m 0644 "$resolved_image" "$bundle_root/rustd-resolved"
{
    printf 'schema=arachos-kernel-bundle-v1\n'
    printf 'arachos_version=%s\n' "$arachos_version"
    printf 'arachos_release=%s\n' "$arachos_release"
    printf 'architecture=%s\n' "$arachos_arch"
    for name in rustd rustd-resolved arach-kernel iwchaos tuned-rs libinput-rs \
                blerust ccze-rs hermes; do
        printf '%s=%s\n' "$name" "$(awk -v key="$name" '$1 == key {print $3}' "$root/sources.lock")"
    done
    for artifact in arach rustd bootstrap rustd-resolved; do
        printf 'artifact.%s.sha256=%s\n' "$artifact" \
            "$(sha256sum "$bundle_root/$artifact" | awk '{print $1}')"
        printf 'artifact.%s.bytes=%s\n' "$artifact" \
            "$(stat -c '%s' "$bundle_root/$artifact")"
    done
    printf 'toolchain=%s\n' "$($cargo_bin --version)"
} > "$bundle_root/manifest.txt"
sha256sum "$output_iso" > "$output_iso.sha256"
# Keep the qualification bundle usable for C0 regression work without making
# it look like an installable kernel.  The Anaconda builder consumes this
# separate contract and refuses every value other than status=pass; the
# persistent-root, Anaconda-target, and BIOS/UEFI gates are intentionally
# recorded as pending until Arach-Kernel implements them.
cat > "$bundle_root/install-manifest.txt" <<EOF
schema=arachos-kernel-install-v1
status=qualification-only
kernel_package=arach-kernel
persistent_root=pending
anaconda_target=pending
bios=pending
uefi=pending
rustd_pid1=pending
rustd_resolved=pending
EOF
printf 'ArachOS Arach Kernel bundle: %s\n' "$output_iso"

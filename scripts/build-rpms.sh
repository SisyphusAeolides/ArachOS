#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_OUTPUT=${RPM_OUTPUT:-$ROOT/build/repo}
TOPDIR=${RPM_TOPDIR:-$ROOT/build/rpmbuild}
RLC_SOURCE_ISO=${RLC_SOURCE_ISO:-}
RLC_INSTALL_TREE_URL=${RLC_INSTALL_TREE_URL:-}
RLC_SYSTEMD_EVR=${RLC_SYSTEMD_EVR:-${ARACHOS_SYSTEMD_EVR:-}}
RPMBUILD_DBPATH=${RPMBUILD_DBPATH:-}
RPMBUILD_TMPDIR=${RPMBUILD_TMPDIR:-}
SOURCE_ROOT=${RUSTD_SOURCE_ROOT:-$ROOT/../rustd}
RESOLVED_ROOT=${RESOLVED_SOURCE_ROOT:-$ROOT/../rustd-resolved}

# The shared Rustup installation is read-only for build users. Pinning the
# already-installed ArachOS nightly through the environment also overrides a
# component source's rust-toolchain file without asking Rustup to download a
# channel manifest during an offline/reproducible package build.
if [[ -z ${RUSTUP_TOOLCHAIN:-} && -x /usr/local/cargo/bin/rustup ]]; then
  export RUSTUP_TOOLCHAIN=nightly-2026-07-20
fi

fail() { printf 'RPM build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in git cargo rpmbuild rpm tar gzip sha256sum python3; do need "$command"; done

bash "$ROOT/scripts/verify-sources.sh"
rm -rf "$RPM_OUTPUT" "$TOPDIR"
mkdir -p "$RPM_OUTPUT" "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,work}

# The replacement package must advertise the exact manager capability of the
# install tree.  A build performed on EL9 otherwise inherits the host's EL9
# systemd EVR, which makes EL10 packages such as rpm and device-mapper reject
# the otherwise valid RustD replacement.  Reading the package header directly
# from the source ISO keeps local image builds independent of the build host.
if [[ -n "$RLC_SOURCE_ISO" && -z "$RLC_SYSTEMD_EVR" ]]; then
  [[ -f "$RLC_SOURCE_ISO" ]] || fail "RLC source ISO is missing: $RLC_SOURCE_ISO"
  need xorriso
  systemd_iso_path=$(xorriso -indev "$RLC_SOURCE_ISO" \
    -find / -name 'systemd-[0-9]*.rpm' -exec lsdl 2>/dev/null |
    awk -F"'" '/\/systemd-[0-9].*\.rpm/ {print $2; exit}')
  [[ -n "$systemd_iso_path" ]] || fail \
    "RLC source ISO has no systemd package header: $RLC_SOURCE_ISO"
  systemd_iso_rpm="$TOPDIR/work/rlc-systemd.rpm"
  xorriso -osirrox on -indev "$RLC_SOURCE_ISO" \
    -extract "$systemd_iso_path" "$systemd_iso_rpm" >/dev/null 2>&1 \
    || fail "cannot extract the RLC systemd package header"
  RLC_SYSTEMD_EVR=$(rpm -qp --qf '%{EVR}' "$systemd_iso_rpm")
  [[ -n "$RLC_SYSTEMD_EVR" ]] || fail "RLC systemd package has no EVR"
fi
if [[ -n "$RLC_INSTALL_TREE_URL" && -z "$RLC_SYSTEMD_EVR" &&
      -z "$RLC_SOURCE_ISO" ]]; then
  fail 'RLC_SYSTEMD_EVR is required when RLC_INSTALL_TREE_URL is not a local ISO'
fi

rustd_output=$RPM_OUTPUT/rustd-core
mkdir -p "$rustd_output"
RUSTD_RESOLVED_SOURCE_ROOT="$RESOLVED_ROOT" \
RUSTD_RPM_DIST="${ARACHOS_RPM_DIST:-.el10}" \
RUSTD_SELINUX_POLICY_VERSION="${SELINUX_POLICY_VERSION:-}" \
RUSTD_SYSTEMD_COMPAT_EVR="$RLC_SYSTEMD_EVR" \
RUSTD_FEDORA_RPM_OUTPUT="$rustd_output" \
RUSTD_FEDORA_RPM_TOPDIR="$TOPDIR/core" \
  bash "$SOURCE_ROOT/scripts/build-fedora-rpms.sh"
find "$rustd_output" -maxdepth 1 -type f -name '*.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;
rm -rf "$rustd_output"

make_source() {
  local name=$1 repo=$2 sha=$3 version=$4 dest=$5
  local work=$TOPDIR/work/$name-$version
  local timestamp
  timestamp=$(git -C "$repo" show -s --format=%ct "$sha")
  mkdir -p "$work"
  git -C "$repo" archive "$sha" | tar -xf - -C "$work"
  (
    cd "$work"
    CARGO_NET_OFFLINE=false cargo vendor --locked vendor-rpm > .cargo-config
    mkdir -p .cargo
    mv .cargo-config .cargo/config.toml
  )
  tar --sort=name --mtime="@$timestamp" --owner=0 --group=0 --numeric-owner \
    -C "$TOPDIR/work" -czf "$dest" "$name-$version"
}

version_from_cargo() {
  awk '/^\[package\]/{in_package=1; next} in_package && /^version = /{gsub(/[" ]/,"",$3); print $3; exit}' "$1/Cargo.toml"
}

declare -A roots=(
  [tuned-rs]="${TUNED_SOURCE_ROOT:-$ROOT/../tuned-rs}"
  [libinput-rs]="${LIBINPUT_SOURCE_ROOT:-$ROOT/../libinput-rs}"
  [blerust]="${BLERUST_SOURCE_ROOT:-$ROOT/../blerust}"
  [ccze-rs]="${CCZE_SOURCE_ROOT:-$ROOT/../ccze-rs}"
)
for name in tuned-rs libinput-rs blerust ccze-rs; do
  repo=${roots[$name]}
  sha=$(awk -v key="$name" '$1 == key {print $3}' "$ROOT/sources.lock")
  version=$(version_from_cargo "$repo")
  make_source "$name" "$repo" "$sha" "$version" "$TOPDIR/SOURCES/$name-$version.tar.gz"
done

cp "$ROOT"/packaging/fedora/*.spec "$TOPDIR/SPECS/"
cp "$ROOT"/packaging/branding/*.spec "$TOPDIR/SPECS/"
cp "$ROOT/docs/ArachOS.png" "$TOPDIR/SOURCES/ArachOS.png"
cp "$ROOT"/packaging/rustd/*.service "$TOPDIR/SOURCES/"

common=(--define "_topdir $TOPDIR" --define "dist ${ARACHOS_RPM_DIST:-.el10}")
if [[ -n "$RPMBUILD_DBPATH" ]]; then
  [[ -d "$RPMBUILD_DBPATH" ]] || fail "RPM build database is missing: $RPMBUILD_DBPATH"
  common+=(--dbpath "$RPMBUILD_DBPATH")
fi
if [[ -n "$RPMBUILD_TMPDIR" ]]; then
  [[ -d "$RPMBUILD_TMPDIR" ]] || fail "RPM build temporary directory is missing: $RPMBUILD_TMPDIR"
  common+=(--define "_tmppath $RPMBUILD_TMPDIR")
fi
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/tuned-rs-fedora.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/libinput-rs-fedora.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/blerust-fedora.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/ccze-rs-fedora.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/arachos-release.spec"
find "$TOPDIR/RPMS" -type f -name '*.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;
find "$TOPDIR/SRPMS" -type f -name '*.src.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;

{
  printf 'schema=arachos-rpm-set-v1\n'
  if [[ -n "$RLC_SYSTEMD_EVR" ]]; then
    printf 'systemd_reference_evr=%s\n' "$RLC_SYSTEMD_EVR"
  fi
  for name in rustd rustd-resolved arach-kernel iwchaos tuned-rs libinput-rs blerust ccze-rs; do
    printf '%s=%s\n' "$name" "$(awk -v key="$name" '$1 == key {print $3}' "$ROOT/sources.lock")"
  done
  find "$RPM_OUTPUT" -maxdepth 1 -type f -name '*.rpm' -print0 | sort -z |
    while IFS= read -r -d '' rpm_path; do
      printf 'rpm.%s.sha256=%s\n' "$(basename "$rpm_path")" "$(sha256sum "$rpm_path" | awk '{print $1}')"
    done
} > "$RPM_OUTPUT/manifest.txt"
printf 'RPM set written to %s\n' "$RPM_OUTPUT"

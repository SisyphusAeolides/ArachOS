#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_OUTPUT=${RPM_OUTPUT:-$ROOT/build/repo}
TOPDIR=${RPM_TOPDIR:-$ROOT/build/rpmbuild}
SOURCE_ROOT=${RUSTD_SOURCE_ROOT:-$ROOT/../rustd}
RESOLVED_ROOT=${RESOLVED_SOURCE_ROOT:-$ROOT/../rustd-resolved}

fail() { printf 'RPM build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in git cargo rpmbuild rpm tar gzip sha256sum python3; do need "$command"; done

bash "$ROOT/scripts/verify-sources.sh"
rm -rf "$RPM_OUTPUT" "$TOPDIR"
mkdir -p "$RPM_OUTPUT" "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

rustd_output=$RPM_OUTPUT/rustd-core
mkdir -p "$rustd_output"
RUSTD_RESOLVED_SOURCE_ROOT="$RESOLVED_ROOT" \
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
cp "$ROOT"/packaging/rustd/*.service "$TOPDIR/SOURCES/"

common=(--define "_topdir $TOPDIR")
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/tuned-rs-fedora.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/libinput-rs-fedora.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/blerust-fedora.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/ccze-rs-fedora.spec"
find "$TOPDIR/RPMS" -type f -name '*.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;
find "$TOPDIR/SRPMS" -type f -name '*.src.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;

{
  printf 'schema=rustd-fedora-rpm-set-v1\n'
  for name in rustd rustd-resolved tuned-rs libinput-rs blerust ccze-rs; do
    printf '%s=%s\n' "$name" "$(awk -v key="$name" '$1 == key {print $3}' "$ROOT/sources.lock")"
  done
  find "$RPM_OUTPUT" -maxdepth 1 -type f -name '*.rpm' -print0 | sort -z |
    while IFS= read -r -d '' rpm_path; do
      printf 'rpm.%s.sha256=%s\n' "$(basename "$rpm_path")" "$(sha256sum "$rpm_path" | awk '{print $1}')"
    done
} > "$RPM_OUTPUT/manifest.txt"
printf 'RPM set written to %s\n' "$RPM_OUTPUT"

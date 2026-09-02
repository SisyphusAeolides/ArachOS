#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_OUTPUT=${RPM_OUTPUT:-$ROOT/build/repo}
TOPDIR=${RPM_TOPDIR:-$ROOT/build/rpmbuild}
ARACHOS_VERSION=${ARACHOS_VERSION:-1.0}
ARACHOS_RELEASE=${ARACHOS_RELEASE:-1}
ARACHOS_RELEASEVER=${ARACHOS_RELEASEVER:-1}
ARACHOS_BOOTSTRAP_RELEASE=${ARACHOS_BOOTSTRAP_RELEASE:-45}
ARACHOS_CORE_URL=${ARACHOS_CORE_URL:-https://dl.fedoraproject.org/pub/fedora/linux/development/45/Everything/x86_64/os/}
ARACHOS_UPDATES_URL=${ARACHOS_UPDATES_URL:-https://dl.fedoraproject.org/pub/fedora/linux/updates/45/Everything/x86_64/}
ARACHOS_SYSTEMD_EVR=${ARACHOS_SYSTEMD_EVR:-}
ARACHOS_SELINUX_POLICY_EVR=${ARACHOS_SELINUX_POLICY_EVR:-}
ARACHOS_RPM_DIST=${ARACHOS_RPM_DIST:-.arachos}
RPMBUILD_DBPATH=${RPMBUILD_DBPATH:-}
RPMBUILD_TMPDIR=${RPMBUILD_TMPDIR:-}
ARACHOS_KEEP_BUILD_WORK=${ARACHOS_KEEP_BUILD_WORK:-0}
build_initialized=0
SOURCE_ROOT=${RUSTD_SOURCE_ROOT:-$ROOT/../rustd}
RESOLVED_ROOT=${RESOLVED_SOURCE_ROOT:-$ROOT/../rustd-resolved}
HERMES_ROOT=${HERMES_SOURCE_ROOT:-$ROOT/../Hermes}
IWCHAOS_ROOT=${IWCHAOS_SOURCE_ROOT:-$ROOT/../iwchaos}
IWCHAOS_LINUX_REPO=${IWCHAOS_LINUX_REPO:-https://github.com/gregkh/linux.git}
BOOTSTRAP_GPG_KEY=${ARACHOS_BOOTSTRAP_GPG_KEY:-$ROOT/packaging/keys/RPM-GPG-KEY-fedora-${ARACHOS_BOOTSTRAP_RELEASE}-primary}
BOOTSTRAP_GPG_FINGERPRINT=${ARACHOS_BOOTSTRAP_GPG_FINGERPRINT:-4F50A6114CD5C6976A7F1179655A4B02F577861E}
BOOTSTRAP_GPG_KEY_NAME="RPM-GPG-KEY-ARACHOS-BOOTSTRAP-${ARACHOS_BOOTSTRAP_RELEASE}-PRIMARY"

# The shared Rustup installation is read-only for build users. Pinning the
# already-installed ArachOS nightly through the environment also overrides a
# component source's rust-toolchain file without asking Rustup to download a
# channel manifest during an offline/reproducible package build.
if [[ -z ${RUSTUP_TOOLCHAIN:-} && -x /usr/local/cargo/bin/rustup ]]; then
  export RUSTUP_TOOLCHAIN=nightly-2026-07-20
fi

fail() { printf 'RPM build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

# RPM source archives and build roots can be large, especially after Cargo
# vendoring. Keep only the signed repository output by default. An operator
# may set ARACHOS_KEEP_BUILD_WORK=1 to retain the exact build tree for a
# forensic retry; cleanup is restricted to the two paths this invocation
# owns and never touches a caller's checkout.
remove_tree() {
  local path=$1
  [[ -e $path ]] || return 0
  if find "$path" -depth -delete 2>/dev/null; then
    return 0
  fi
  if sudo -n true >/dev/null 2>&1; then
    sudo -n find "$path" -depth -delete 2>/dev/null || :
  else
    printf 'warning: cannot clean build path without privilege: %s\n' "$path" >&2
  fi
}

cleanup_build() {
  local status=$?
  if [[ $build_initialized == 1 && $ARACHOS_KEEP_BUILD_WORK != 1 ]]; then
    remove_tree "$TOPDIR"
  fi
  if [[ $status -ne 0 && $build_initialized == 1 && $ARACHOS_KEEP_BUILD_WORK != 1 ]]; then
    remove_tree "$RPM_OUTPUT"
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup_build EXIT

for command in git cargo rpmbuild rpm tar gzip sha256sum python3 dnf createrepo_c gpg; do need "$command"; done

bash "$ROOT/scripts/verify-sources.sh"
remove_tree "$RPM_OUTPUT"
remove_tree "$TOPDIR"
mkdir -p "$RPM_OUTPUT" "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,work}
build_initialized=1

[[ $ARACHOS_BOOTSTRAP_RELEASE =~ ^[0-9]+$ ]] || fail \
  "bootstrap release must be numeric: $ARACHOS_BOOTSTRAP_RELEASE"
[[ -n $ARACHOS_CORE_URL && -n $ARACHOS_UPDATES_URL ]] || fail \
  'both ArachOS bootstrap repository URLs are required'
[[ -s $BOOTSTRAP_GPG_KEY ]] || fail \
  "bootstrap repository signing key is missing: $BOOTSTRAP_GPG_KEY"
bootstrap_gpg_fingerprint=$(gpg --show-keys --with-colons "$BOOTSTRAP_GPG_KEY" \
  | awk -F: '$1 == "fpr" {print $10; exit}')
[[ $bootstrap_gpg_fingerprint == "$BOOTSTRAP_GPG_FINGERPRINT" ]] || fail \
  "bootstrap repository signing key fingerprint mismatch: $bootstrap_gpg_fingerprint"

bootstrap_repo_args=(
  --repofrompath=arachos-core,"$ARACHOS_CORE_URL"
  --repofrompath=arachos-updates,"$ARACHOS_UPDATES_URL"
  --enablerepo=arachos-core,arachos-updates
  --releasever="$ARACHOS_BOOTSTRAP_RELEASE"
)

repo_query() {
  dnf -q --disablerepo='*' "${bootstrap_repo_args[@]}" \
    repoquery --latest-limit=1 --qf "$1" "$2" | head -n 1
}

# The compatibility providers must advertise the exact systemd capability of
# the selected base repository. Querying that repository keeps this build
# independent of whatever release is installed on the build host.
if [[ -z "$ARACHOS_SYSTEMD_EVR" ]]; then
  ARACHOS_SYSTEMD_EVR=$(repo_query '%{evr}' systemd)
fi
[[ -n "$ARACHOS_SYSTEMD_EVR" ]] || fail \
  "could not determine systemd EVR from ArachOS bootstrap repositories"

# RustD's SELinux package installs into the target policy store and therefore
# carries a post-install dependency on the targeted policy package.  Resolve
# that dependency from the same bootstrap repositories used by the installer,
# rather than inheriting the build host's (possibly newer) policy EVR.
if [[ -z "$ARACHOS_SELINUX_POLICY_EVR" ]]; then
  ARACHOS_SELINUX_POLICY_EVR=$(repo_query '%{evr}' selinux-policy-targeted)
fi
[[ -n "$ARACHOS_SELINUX_POLICY_EVR" ]] || fail \
  "could not determine selinux-policy-targeted EVR from ArachOS bootstrap repositories"

read -r iwchaos_kernel_version iwchaos_kernel_release iwchaos_kernel_arch \
  <<<"$(repo_query '%{version} %{release} %{arch}' kernel-devel)"
[[ $iwchaos_kernel_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail \
  "could not determine the bootstrap kernel-devel version"
[[ -n $iwchaos_kernel_release && $iwchaos_kernel_arch == x86_64 ]] || fail \
  "bootstrap kernel-devel must provide an x86_64 release"
kernel_metadata=$(repo_query '%{version} %{release} %{arch}' kernel)
[[ $kernel_metadata == "$iwchaos_kernel_version $iwchaos_kernel_release $iwchaos_kernel_arch" ]] \
  || fail "bootstrap kernel and kernel-devel versions do not match"
iwchaos_kernel_uname=${iwchaos_kernel_version}-${iwchaos_kernel_release}.${iwchaos_kernel_arch}
iwchaos_linux_ref=${IWCHAOS_LINUX_REF:-v${iwchaos_kernel_version%.*}}
iwchaos_linux_commit=$(awk '$1 == "iwchaos-linux" {print $3; exit}' "$ROOT/sources.lock")
[[ $iwchaos_linux_commit =~ ^[0-9a-f]{40}$ ]] || fail \
  'iwchaos-linux is missing a pinned commit in sources.lock'

rustd_output=$RPM_OUTPUT/rustd-core
mkdir -p "$rustd_output"
RUSTD_RESOLVED_SOURCE_ROOT="$RESOLVED_ROOT" \
RUSTD_RPM_DIST="$ARACHOS_RPM_DIST" \
RUSTD_SELINUX_POLICY_VERSION="$ARACHOS_SELINUX_POLICY_EVR" \
RUSTD_SYSTEMD_COMPAT_EVR="$ARACHOS_SYSTEMD_EVR" \
RUSTD_FEDORA_RPM_OUTPUT="$rustd_output" \
RUSTD_FEDORA_RPM_TOPDIR="$TOPDIR/core" \
  bash "$SOURCE_ROOT/scripts/build-fedora-rpms.sh"
find "$rustd_output" -maxdepth 1 -type f -name '*.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;
remove_tree "$rustd_output"

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

make_source_tree() {
  local name=$1 repo=$2 sha=$3 version=$4 dest=$5
  local work=$TOPDIR/work/$name-$version
  local timestamp
  timestamp=$(git -C "$repo" show -s --format=%ct "$sha")
  mkdir -p "$work"
  git -C "$repo" archive "$sha" | tar -xf - -C "$work"
  tar --sort=name --mtime="@$timestamp" --owner=0 --group=0 --numeric-owner \
    -C "$TOPDIR/work" -czf "$dest" "$name-$version"
}

make_iwchaos_source() {
  local name=iwchaos repo=$1 sha=$2 version=$3 dest=$4
  local work=$TOPDIR/work/$name-$version
  local linux_work=$TOPDIR/work/iwchaos-linux-$iwchaos_kernel_uname
  local linux_tree=$linux_work/linux
  local timestamp actual_commit
  timestamp=$(git -C "$repo" show -s --format=%ct "$sha")
  mkdir -p "$work"
  git -C "$repo" archive "$sha" | tar -xf - -C "$work"

  mkdir -p "$linux_work"
  git -c advice.detachedHead=false clone --filter=blob:none --no-checkout \
    --depth 1 --branch "$iwchaos_linux_ref" "$IWCHAOS_LINUX_REPO" "$linux_tree"
  actual_commit=$(git -C "$linux_tree" rev-parse "${iwchaos_linux_ref}^{commit}")
  [[ $actual_commit == "$iwchaos_linux_commit" ]] || fail \
    "iwchaos Linux source ref $iwchaos_linux_ref resolved to $actual_commit, expected $iwchaos_linux_commit"
  git -C "$linux_tree" sparse-checkout set \
    drivers/net/wireless/intel/iwlwifi
  git -C "$linux_tree" checkout --quiet "$iwchaos_linux_commit"
  [[ -f "$linux_tree/drivers/net/wireless/intel/iwlwifi/iwl-drv.c" ]] || fail \
    'pinned iwchaos Linux source has no iwlwifi driver tree'

  mkdir -p "$work/vendor"
  cp -a "$linux_tree/drivers/net/wireless/intel/iwlwifi" \
    "$work/vendor/iwlwifi-$iwchaos_kernel_uname"
  printf 'ref=%s\ncommit=%s\nkernel=%s\nbase=%s\n' \
    "$iwchaos_linux_ref" "$iwchaos_linux_commit" \
    "$iwchaos_kernel_uname" "$iwchaos_kernel_version" \
    > "$work/vendor/iwlwifi-$iwchaos_kernel_uname/.iwchaos-source"

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
  [hermes]="$HERMES_ROOT"
)
for name in tuned-rs libinput-rs blerust ccze-rs; do
  repo=${roots[$name]}
  sha=$(awk -v key="$name" '$1 == key {print $3}' "$ROOT/sources.lock")
  version=$(version_from_cargo "$repo")
  make_source "$name" "$repo" "$sha" "$version" "$TOPDIR/SOURCES/$name-$version.tar.gz"
done

hermes_sha=$(awk -v key="hermes" '$1 == key {print $3}' "$ROOT/sources.lock")
hermes_version=$(awk '
  /^\[workspace\.package\]$/ { in_workspace = 1; next }
  in_workspace && /^\[/ { exit }
  in_workspace && /^version = / { gsub(/[" ]/, "", $3); print $3; exit }
' "$HERMES_ROOT/Cargo.toml")
[[ -n "$hermes_version" ]] || fail "Hermes workspace version is missing: $HERMES_ROOT/Cargo.toml"
make_source hermes "$HERMES_ROOT" "$hermes_sha" "$hermes_version" \
  "$TOPDIR/SOURCES/hermes-$hermes_version.tar.gz"

iwchaos_sha=$(awk -v key="iwchaos" '$1 == key {print $3}' "$ROOT/sources.lock")
iwchaos_version=$(awk '$1 == "Version:" {print $2; exit}' "$IWCHAOS_ROOT/iwchaos.spec")
[[ -n "$iwchaos_version" ]] || fail "iwchaos version is missing: $IWCHAOS_ROOT/iwchaos.spec"
make_iwchaos_source "$IWCHAOS_ROOT" "$iwchaos_sha" "$iwchaos_version" \
  "$TOPDIR/SOURCES/iwchaos-$iwchaos_version.tar.gz"

cp "$ROOT"/packaging/rpm/*.spec "$TOPDIR/SPECS/"
cp "$ROOT"/packaging/branding/*.spec "$TOPDIR/SPECS/"
cp "$ROOT/docs/ArachOS.png" "$TOPDIR/SOURCES/ArachOS.png"
cp "$ROOT"/packaging/rustd/*.service "$TOPDIR/SOURCES/"

common=(
  --define "_topdir $TOPDIR"
  --define "dist ${ARACHOS_RPM_DIST:-.arachos}"
  --define "arachos_version $ARACHOS_VERSION"
  --define "arachos_release $ARACHOS_RELEASE"
  --define "arachos_releasever $ARACHOS_RELEASEVER"
  --define "arachos_bootstrap_release $ARACHOS_BOOTSTRAP_RELEASE"
)
if [[ -n "$RPMBUILD_DBPATH" ]]; then
  [[ -d "$RPMBUILD_DBPATH" ]] || fail "RPM build database is missing: $RPMBUILD_DBPATH"
  common+=(--dbpath "$RPMBUILD_DBPATH")
fi
if [[ -n "$RPMBUILD_TMPDIR" ]]; then
  [[ -d "$RPMBUILD_TMPDIR" ]] || fail "RPM build temporary directory is missing: $RPMBUILD_TMPDIR"
  common+=(--define "_tmppath $RPMBUILD_TMPDIR")
fi
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/tuned-rs.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/libinput-rs.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/blerust.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/ccze-rs.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/hermes-gpu-stack.spec"
rpmbuild -ba "${common[@]}" \
  --define "iwchaos_version $iwchaos_version" "$TOPDIR/SPECS/iwchaos.spec"
rpmbuild -ba "${common[@]}" "$TOPDIR/SPECS/arachos-release.spec"
find "$TOPDIR/RPMS" -type f -name '*.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;
find "$TOPDIR/SRPMS" -type f -name '*.src.rpm' -exec cp -a {} "$RPM_OUTPUT/" \;
install -D -m 0644 "$BOOTSTRAP_GPG_KEY" \
  "$RPM_OUTPUT/$BOOTSTRAP_GPG_KEY_NAME"
if [[ -n ${ARACHOS_GPG_KEY_ID:-} || -n ${ARACHOS_GPG_HOME:-} ]]; then
  ARACHOS_GPG_KEY_ID="${ARACHOS_GPG_KEY_ID:-}" \
  ARACHOS_GPG_HOME="${ARACHOS_GPG_HOME:-}" \
    bash "$ROOT/scripts/sign-rpm-repo.sh" "$RPM_OUTPUT"
else
  printf '%s\n' \
    'warning: RPM repository is unsigned; build-live requires ARACHOS_GPG_HOME and ARACHOS_GPG_KEY_ID' >&2
fi
groupfile="$ROOT/packaging/comps/arachos-comps.xml"
[[ -s "$groupfile" ]] || fail "ArachOS comps metadata is missing: $groupfile"
createrepo_c --update --groupfile "$groupfile" "$RPM_OUTPUT"
if [[ -n ${ARACHOS_GPG_KEY_ID:-} || -n ${ARACHOS_GPG_HOME:-} ]]; then
  [[ -f "$RPM_OUTPUT/repodata/repomd.xml" ]] || fail 'repository metadata was not generated'
  GNUPGHOME="${ARACHOS_GPG_HOME:-}" gpg --batch --yes --armor --detach-sign \
    --output "$RPM_OUTPUT/repodata/repomd.xml.asc" \
    "$RPM_OUTPUT/repodata/repomd.xml"
fi

{
  printf 'schema=arachos-rpm-set-v1\n'
  printf 'bootstrap_release=%s\n' "$ARACHOS_BOOTSTRAP_RELEASE"
  printf 'bootstrap_core_url=%s\n' "$ARACHOS_CORE_URL"
  printf 'bootstrap_updates_url=%s\n' "$ARACHOS_UPDATES_URL"
  if [[ -n "$ARACHOS_SYSTEMD_EVR" ]]; then
  printf 'systemd_reference_evr=%s\n' "$ARACHOS_SYSTEMD_EVR"
  fi
  printf 'selinux_policy_reference_evr=%s\n' "$ARACHOS_SELINUX_POLICY_EVR"
  printf 'iwchaos-linux-repository=%s\n' "$IWCHAOS_LINUX_REPO"
  printf 'iwchaos-linux-ref=%s\n' "$iwchaos_linux_ref"
  printf 'iwchaos-linux-commit=%s\n' "$iwchaos_linux_commit"
  printf 'iwchaos-kernel-release=%s\n' "$iwchaos_kernel_uname"
  if [[ -f "$RPM_OUTPUT/RPM-GPG-KEY-ARACHOS" ]]; then
    printf 'rpm_signing_key_sha256=%s\n' "$(sha256sum "$RPM_OUTPUT/RPM-GPG-KEY-ARACHOS" | awk '{print $1}')"
  else
    printf 'rpm_signing_key_sha256=absent\n'
  fi
  printf 'bootstrap_signing_key_fingerprint=%s\n' "$bootstrap_gpg_fingerprint"
  printf 'bootstrap_signing_key_filename=%s\n' "$BOOTSTRAP_GPG_KEY_NAME"
  printf 'bootstrap_signing_key_sha256=%s\n' "$(sha256sum "$RPM_OUTPUT/$BOOTSTRAP_GPG_KEY_NAME" | awk '{print $1}')"
  for name in rustd rustd-resolved arach-kernel iwchaos tuned-rs libinput-rs blerust ccze-rs hermes; do
    printf '%s=%s\n' "$name" "$(awk -v key="$name" '$1 == key {print $3}' "$ROOT/sources.lock")"
  done
  find "$RPM_OUTPUT" -maxdepth 1 -type f -name '*.rpm' -print0 | sort -z |
    while IFS= read -r -d '' rpm_path; do
      printf 'rpm.%s.sha256=%s\n' "$(basename "$rpm_path")" "$(sha256sum "$rpm_path" | awk '{print $1}')"
    done
} > "$RPM_OUTPUT/manifest.txt"
printf 'RPM set written to %s\n' "$RPM_OUTPUT"

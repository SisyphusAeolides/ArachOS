#!/usr/bin/env bash
# Build all ArachOS pacman packages from pinned source commits.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT="${PKG_OUTPUT:-$ROOT/build/packages}"
OUTPUT="$(realpath -m "$OUTPUT")"
SIGNING_KEY="${ARACHOS_GPG_KEY_ID:-}"
SIGNING_HOME="${ARACHOS_GPG_HOME:-}"
KEEP_WORK="${ARACHOS_KEEP_BUILD_WORK:-0}"
WORK="$ROOT/build/pkgwork"

fail() { printf 'ArachOS build-packages: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

cleanup_work() {
  local status=$?
  if [[ "$KEEP_WORK" != "1" && -d "$WORK" ]]; then
    if ! find "$WORK" -depth -delete 2>/dev/null; then
      # A privileged package install can leave fakeroot-owned entries in the
      # disposable tree.  Let the build user remove only this known work
      # root instead of turning a completed package build into a teardown
      # failure.
      sudo -n find "$WORK" -depth -delete 2>/dev/null ||
        printf 'warning: unable to clean package work tree: %s\n' "$WORK" >&2
    fi
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup_work EXIT

need makepkg
need git
need repo-add

[[ ! $EUID -eq 0 ]] || fail 'build-packages must not run as root (makepkg restriction)'

# Source roots (fall back to sibling directories)
RUSTD_SOURCE_ROOT="${RUSTD_SOURCE_ROOT:-$ROOT/../rustd}"
RESOLVED_SOURCE_ROOT="${RESOLVED_SOURCE_ROOT:-$ROOT/../rustd-resolved}"
ARACH_KERNEL_SOURCE_ROOT="${ARACH_KERNEL_SOURCE_ROOT:-$ROOT/../arach-kernel}"
IWCHAOS_SOURCE_ROOT="${IWCHAOS_SOURCE_ROOT:-$ROOT/../iwchaos}"
TUNED_SOURCE_ROOT="${TUNED_SOURCE_ROOT:-$ROOT/../tuned-rs}"
LIBINPUT_SOURCE_ROOT="${LIBINPUT_SOURCE_ROOT:-$ROOT/../libinput-rs}"
BLERUST_SOURCE_ROOT="${BLERUST_SOURCE_ROOT:-$ROOT/../blerust}"
CCZE_SOURCE_ROOT="${CCZE_SOURCE_ROOT:-$ROOT/../ccze-rs}"
HERMES_SOURCE_ROOT="${HERMES_SOURCE_ROOT:-$ROOT/../Hermes}"
ARACH_HWD_SOURCE_ROOT="${ARACH_HWD_SOURCE_ROOT:-$ROOT/../Arach-HWD}"
CORINTH_SOURCE_ROOT="${CORINTH_SOURCE_ROOT:-$ROOT/../Corinth}"

normalize_source_root() {
  local path=$1
  [[ "$path" == /* ]] || path="$ROOT/$path"
  realpath -m "$path"
}

RUSTD_SOURCE_ROOT=$(normalize_source_root "$RUSTD_SOURCE_ROOT")
RESOLVED_SOURCE_ROOT=$(normalize_source_root "$RESOLVED_SOURCE_ROOT")
ARACH_KERNEL_SOURCE_ROOT=$(normalize_source_root "$ARACH_KERNEL_SOURCE_ROOT")
IWCHAOS_SOURCE_ROOT=$(normalize_source_root "$IWCHAOS_SOURCE_ROOT")
TUNED_SOURCE_ROOT=$(normalize_source_root "$TUNED_SOURCE_ROOT")
LIBINPUT_SOURCE_ROOT=$(normalize_source_root "$LIBINPUT_SOURCE_ROOT")
BLERUST_SOURCE_ROOT=$(normalize_source_root "$BLERUST_SOURCE_ROOT")
CCZE_SOURCE_ROOT=$(normalize_source_root "$CCZE_SOURCE_ROOT")
HERMES_SOURCE_ROOT=$(normalize_source_root "$HERMES_SOURCE_ROOT")
ARACH_HWD_SOURCE_ROOT=$(normalize_source_root "$ARACH_HWD_SOURCE_ROOT")
CORINTH_SOURCE_ROOT=$(normalize_source_root "$CORINTH_SOURCE_ROOT")

lock_sha() {
  awk -v key="$1" '$1 == key {print $3}' "$ROOT/sources.lock"
}

mkdir -p "$OUTPUT" "$WORK"

stage_container_packages() {
  [[ "${IN_CONTAINER:-0}" == "1" ]] || return 0
  ((${#@} > 0)) || fail 'no package archives available for container staging'

  # ArachOS replacement packages intentionally conflict with their legacy
  # providers (RustD replaces systemd, for example).  The build container
  # still needs the legacy files while later PKGBUILDs resolve dependencies,
  # so remove only the old package database entries before staging the new
  # archives.  --dbonly leaves every file in the container untouched.
  local archive conflict installed
  local -a conflicts=()
  for archive in "$@"; do
    while IFS= read -r conflict; do
      [[ -n "$conflict" ]] || continue
      conflict="${conflict%%[<>=]*}"
      [[ -n "$conflict" ]] || continue
      # Query output is the owning package name, which matters when a
      # conflict is declared through a virtual provide (grub-bios, etc.).
      while IFS= read -r installed; do
        [[ -n "$installed" ]] && conflicts+=("$installed")
      done < <(sudo pacman -Qq "$conflict" 2>/dev/null || true)
    done < <(tar --zstd -xOf "$archive" .PKGINFO 2>/dev/null \
      | awk -F' = ' '$1 == "conflict" {print $2}')
  done
  if ((${#conflicts[@]} > 0)); then
    mapfile -t conflicts < <(printf '%s\n' "${conflicts[@]}" | sort -u)
    sudo pacman -Rdd --dbonly --noconfirm "${conflicts[@]}"
  fi
  sudo pacman -Udd --dbonly --noconfirm --overwrite '*' "$@"
}

build_pkg() {
  local name=$1 pkgdir=$2
  local builddir="$WORK/$name"
  rm -rf "$builddir"
  cp -a "$pkgdir" "$builddir"
  case "$name" in
    arachos-release)
      cp "$ROOT/packaging/branding/arachos-profile.sh" "$builddir/arachos-branding.sh"
      cp "$ROOT/packaging/branding/arachos-fastfetch.jsonc" "$builddir/arachos-fastfetch.jsonc"
      cp "$ROOT/docs/ArachOS.png" "$builddir/ArachOS.png"
      cp "$ROOT/packaging/branding/chaos.png" "$builddir/chaos.png"
      ;;
    tuned-rs)
      cp "$ROOT/packaging/rustd/tuned-rs.service" "$builddir/tuned-rs.service"
      cp "$ROOT/packaging/rustd/tuned-rs-ppd.service" "$builddir/tuned-rs-ppd.service"
      ;;
    hermes-gpu-stack)
      cp "$ROOT/packaging/rustd/hermes-gpu.service" "$builddir/hermes-gpu.service"
      ;;
    libinput-rs)
      cp "$ROOT/packaging/rustd/libinput-rs-elan-resume.service" \
        "$builddir/libinput-rs-elan-resume.service"
      ;;
  esac
  if lock_key=$(source_lock_key "$name"); then
    patch_commit "$builddir/PKGBUILD" "$lock_key"
  fi

  pushd "$builddir" >/dev/null
  mapfile -t package_list < <(makepkg --packagelist)
  ((${#package_list[@]} > 0)) || fail "makepkg did not report output packages for $name"
  if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
    if local_source_is_complete "$name"; then
      # A complete checkout is mounted into the builder so makepkg can build
      # without another network fetch. Keep the source URL pinned to the
      # exact commit while changing only its transport to that checkout.
      sed -i "s|https://github.com/SisyphusAeolides|file:///home/builder/workspace|g" PKGBUILD
      sed -i "s|\.git#|#|g" PKGBUILD
    else
      # Partial or shallow checkouts cannot provide makepkg's mirror clone:
      # Git would ask the promisor for missing history and may fail after the
      # commit itself has already been verified. Use the pinned HTTPS source
      # in that case; the source lock still controls the revision.
      printf 'Package %s: local checkout is incomplete; using pinned HTTPS source.\n' "$name" >&2
    fi
  fi
  if [[ -n "$SIGNING_KEY" ]]; then
    if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
      GNUPGHOME="$SIGNING_HOME" makepkg -sf --sign --noconfirm
    else
      GNUPGHOME="$SIGNING_HOME" makepkg -sf --sign --noconfirm
    fi
  else
    if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
      makepkg -sf --noconfirm
    else
      makepkg -sf --noconfirm
    fi
  fi
  local -a built_packages=()
  for package in "${package_list[@]}"; do
    if [[ ! -s "$package" ]]; then
      # makepkg can list a debug split package even when the package contains
      # no ELF files (iwchaos is source-only DKMS content), in which case no
      # debug archive is produced.  Every real package remains mandatory.
      [[ "$package" == *-debug-*.pkg.tar.zst ]] \
        || fail "makepkg did not create expected package: $package"
      continue
    fi
    built_packages+=("$package")
    cp -a "$package" "$OUTPUT/"
    [[ -s "$package.sig" ]] && cp -a "$package.sig" "$OUTPUT/"
  done
  # Make split packages available to later PKGBUILDs in this same isolated
  # build.  The output repository is assembled only after all packages finish,
  # so pacman cannot otherwise resolve a dependency on a package built one
  # step earlier (for example tuned-rs -> rustd).
  stage_container_packages "${built_packages[@]}"
  popd >/dev/null
}

patch_commit() {
  local pkgbuild=$1 key=$2
  local sha; sha=$(lock_sha "$key")
  [[ -n $sha ]] || fail "sources.lock has no entry for $key"
  if grep -q '^_commit=' "$pkgbuild"; then
    sed -i -E "s|^_commit=.*|_commit=$sha|" "$pkgbuild"
  else
    local placeholder=$(echo "$key" | tr 'a-z-' 'A-Z_')_COMMIT
    grep -q "$placeholder" "$pkgbuild" \
      || fail "$pkgbuild does not declare a pinned source commit"
    sed -i "s/${placeholder}/$sha/" "$pkgbuild"
  fi
}

source_lock_key() {
  case "$1" in
    hermes-gpu-stack) printf '%s\n' hermes ;;
    arachos-release|grub) return 1 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

source_root_for_package() {
  case "$1" in
    rustd) printf '%s\n' "$RUSTD_SOURCE_ROOT" ;;
    rustd-resolved) printf '%s\n' "$RESOLVED_SOURCE_ROOT" ;;
    tuned-rs) printf '%s\n' "$TUNED_SOURCE_ROOT" ;;
    hermes-gpu-stack) printf '%s\n' "$HERMES_SOURCE_ROOT" ;;
    iwchaos) printf '%s\n' "$IWCHAOS_SOURCE_ROOT" ;;
    blerust) printf '%s\n' "$BLERUST_SOURCE_ROOT" ;;
    ccze-rs) printf '%s\n' "$CCZE_SOURCE_ROOT" ;;
    libinput-rs) printf '%s\n' "$LIBINPUT_SOURCE_ROOT" ;;
    arach-hwd) printf '%s\n' "$ARACH_HWD_SOURCE_ROOT" ;;
    corinth) printf '%s\n' "$CORINTH_SOURCE_ROOT" ;;
    *) return 1 ;;
  esac
}

local_source_is_complete() {
  local name=$1 root
  root=$(source_root_for_package "$name") || return 1
  [[ -d "$root/.git" ]] || return 1
  [[ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null || true)" != true ]] \
    || return 1
  [[ "$(git -C "$root" config --get remote.origin.promisor 2>/dev/null || true)" != true ]] \
    || return 1
  [[ -z "$(git -C "$root" config --get remote.origin.partialclonefilter 2>/dev/null || true)" ]]
}

package_outputs_ready() {
  local name=$1 pkgdir=$2 path archive
  local -a package_names=()

  package_metadata "$name" "$pkgdir"
  ((${#PACKAGE_OUTPUT_PATHS[@]} > 0)) || return 1

  # A release bump must not leave an older archive for one of this PKGBUILD's
  # package names in the shared output directory.  Such archives are easy to
  # pick up accidentally when staging dependencies and make pacman reject the
  # transaction as a duplicate target.
  mapfile -t package_names < <(makepkg_package_names "$name" "$pkgdir")
  prune_stale_outputs "${package_names[@]}"

  # Compare the exact filenames makepkg would produce for this PKGBUILD. A
  # prefix-only glob would mistake rustd-resolved for rustd and can leave a
  # dependency unstaged after a package release is bumped.
  for path in "${PACKAGE_OUTPUT_PATHS[@]}"; do
    archive="$OUTPUT/$(basename "$path")"
    if [[ "$archive" == *-debug-*.pkg.tar.zst && ! -s "$archive" ]]; then
      continue
    fi
    [[ -s "$archive" ]] || return 1
  done
}

PACKAGE_OUTPUT_PATHS=()

package_metadata() {
  local name=$1 pkgdir=$2 metadata_dir
  PACKAGE_OUTPUT_PATHS=()
  metadata_dir=$(mktemp -d "$WORK/.metadata-${name}.XXXXXX")
  cp "$pkgdir/PKGBUILD" "$metadata_dir/PKGBUILD"
  pushd "$metadata_dir" >/dev/null
  mapfile -t PACKAGE_OUTPUT_PATHS < <(makepkg --packagelist)
  popd >/dev/null
  find "$metadata_dir" -depth -delete
}

makepkg_package_names() {
  local name=$1 pkgdir=$2 metadata_dir
  metadata_dir=$(mktemp -d "$WORK/.srcinfo-${name}.XXXXXX")
  cp "$pkgdir/PKGBUILD" "$metadata_dir/PKGBUILD"
  pushd "$metadata_dir" >/dev/null
  # makepkg creates split debug archives without listing them in
  # --printsrcinfo, so include both conventional debug suffixes when
  # identifying stale output files.
  makepkg --printsrcinfo | awk '$1 == "pkgname" {
    print $3
    print $3 "-debug"
    print $3 "-debuginfo"
  }'
  popd >/dev/null
  find "$metadata_dir" -depth -delete
}

prune_stale_outputs() {
  local archive package_name expected path
  local -a package_names=("$@")
  for archive in "$OUTPUT"/*.pkg.tar.zst; do
    [[ -f "$archive" ]] || continue
    package_name=$(tar --zstd -xOf "$archive" .PKGINFO 2>/dev/null \
      | awk -F' = ' '$1 == "pkgname" {print $2; exit}')
    [[ -n "$package_name" ]] || continue
    if ! printf '%s\n' "${package_names[@]}" | grep -Fqx "$package_name"; then
      continue
    fi
    expected=0
    for path in "${PACKAGE_OUTPUT_PATHS[@]}"; do
      if [[ "$(basename "$path")" == "$(basename "$archive")" ]]; then
        expected=1
        break
      fi
    done
    if [[ $expected == 0 ]]; then
      rm -f -- "$archive" "$archive.sig"
    fi
  done
}

pkgs_order=(
  "grub"
  "rustd"
  "rustd-resolved"
  "tuned-rs"
  "hermes-gpu-stack"
  "iwchaos"
  "blerust"
  "ccze-rs"
  "libinput-rs"
  "arach-hwd"
  "corinth"
  "arachos-release"
)

declare -A pkgs=(
  [grub]="$ROOT/packaging/pkgbuild/grub"
  [rustd]="$ROOT/packaging/pkgbuild/rustd"
  [rustd-resolved]="$ROOT/packaging/pkgbuild/rustd-resolved"
  [libinput-rs]="$ROOT/packaging/pkgbuild/libinput-rs"
  [blerust]="$ROOT/packaging/pkgbuild/blerust"
  [ccze-rs]="$ROOT/packaging/pkgbuild/ccze-rs"
  [tuned-rs]="$ROOT/packaging/pkgbuild/tuned-rs"
  [hermes-gpu-stack]="$ROOT/packaging/pkgbuild/hermes-gpu-stack"
  [iwchaos]="$ROOT/packaging/pkgbuild/iwchaos"
  [arach-hwd]="$ROOT/packaging/pkgbuild/arach-hwd"
  [corinth]="$ROOT/packaging/pkgbuild/corinth"
  [arachos-release]="$ROOT/packaging/pkgbuild/arachos-release"
)

for name in "${pkgs_order[@]}"; do
  if package_outputs_ready "$name" "${pkgs[$name]}"; then
    if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
      existing_packages=()
      for path in "${PACKAGE_OUTPUT_PATHS[@]}"; do
        archive="$OUTPUT/$(basename "$path")"
        [[ -s "$archive" ]] && existing_packages+=("$archive")
      done
      if ((${#existing_packages[@]} > 0)); then
        stage_container_packages "${existing_packages[@]}"
      fi
    fi
    echo "Package $name already built. Skipping."
    continue
  fi
  pkgbuild="${pkgs[$name]}/PKGBUILD"
  build_pkg "$name" "${pkgs[$name]}"
done

# Update pacman repo database
pushd "$OUTPUT" >/dev/null
if [[ -n "$SIGNING_KEY" && -n "$SIGNING_HOME" ]]; then
  GNUPGHOME="$SIGNING_HOME" repo-add -s arachos.db.tar.gz *.pkg.tar.zst
else
  repo-add arachos.db.tar.gz *.pkg.tar.zst
fi
popd >/dev/null

printf 'ArachOS packages written to %s\n' "$OUTPUT"

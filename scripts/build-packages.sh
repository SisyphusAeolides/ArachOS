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
    find "$WORK" -depth -delete
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
  local archive conflict
  local -a conflicts=()
  for archive in "$@"; do
    while IFS= read -r conflict; do
      [[ -n "$conflict" ]] || continue
      conflict="${conflict%%[<>=]*}"
      [[ -n "$conflict" ]] || continue
      if sudo pacman -Qq "$conflict" >/dev/null 2>&1; then
        conflicts+=("$conflict")
      fi
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
    sed -i "s|https://github.com/SisyphusAeolides|file:///home/builder/workspace|g" PKGBUILD
    sed -i "s|\.git#|#|g" PKGBUILD
    sed -i "s|iwchaos-linux|linux|g" PKGBUILD || true
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
  for package in "${package_list[@]}"; do
    [[ -s "$package" ]] || fail "makepkg did not create expected package: $package"
    cp -a "$package" "$OUTPUT/"
    [[ -s "$package.sig" ]] && cp -a "$package.sig" "$OUTPUT/"
  done
  # Make split packages available to later PKGBUILDs in this same isolated
  # build.  The output repository is assembled only after all packages finish,
  # so pacman cannot otherwise resolve a dependency on a package built one
  # step earlier (for example tuned-rs -> rustd).
  stage_container_packages "${package_list[@]}"
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
  [arachos-release]="$ROOT/packaging/pkgbuild/arachos-release"
)

for name in "${pkgs_order[@]}"; do
  if ls "$OUTPUT/${name}-"*.pkg.tar.zst >/dev/null 2>&1; then
    if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
      mapfile -t existing_packages < <(find "$OUTPUT" -maxdepth 1 -type f \
        -name "${name}-*.pkg.tar.zst" -print | sort -V)
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
  GNUPGHOME="$SIGNING_HOME" repo-add -s -n arachos.db.tar.gz *.pkg.tar.zst
else
  repo-add -n arachos.db.tar.gz *.pkg.tar.zst
fi
popd >/dev/null

printf 'ArachOS packages written to %s\n' "$OUTPUT"

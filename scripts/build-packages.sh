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
  pushd "$builddir" >/dev/null
  if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
    sed -i "s|https://github.com/SisyphusAeolides|file:///home/builder/workspace|g" PKGBUILD
    sed -i "s|\.git#|#|g" PKGBUILD
    sed -i "s|iwchaos-linux|linux|g" PKGBUILD || true
  fi
  if [[ -n "$ARACHOS_GPG_KEY_ID" ]]; then
    if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
      GNUPGHOME="$SIGNING_HOME" makepkg -sf --sign --noconfirm
      yes | sudo pacman -Udd --overwrite '*' *.pkg.tar.zst || true
    else
      GNUPGHOME="$SIGNING_HOME" makepkg -sf --sign --noconfirm
    fi
  else
    if [[ "${IN_CONTAINER:-0}" == "1" ]]; then
      makepkg -sf --noconfirm
      yes | sudo pacman -Udd --overwrite '*' *.pkg.tar.zst || true
    else
      makepkg -sf --noconfirm
    fi
  fi
  find . -maxdepth 1 -name '*.pkg.tar.zst' -exec cp -a {} "$OUTPUT/" \;
  find . -maxdepth 1 -name '*.pkg.tar.zst.sig' -exec cp -a {} "$OUTPUT/" \;
  popd >/dev/null
}

patch_commit() {
  local pkgbuild=$1 key=$2
  local sha; sha=$(lock_sha "$key")
  [[ -n $sha ]] || fail "sources.lock has no entry for $key"
  local placeholder=$(echo "$key" | tr 'a-z-' 'A-Z_')_COMMIT
  sed -i "s/${placeholder}/$sha/" "$pkgbuild"
}

pkgs_order=(
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
    echo "Package $name already built. Skipping."
    continue
  fi
  pkgbuild="${pkgs[$name]}/PKGBUILD"
  # Patch commit placeholders dynamically
  if grep -q "$(echo $name | tr 'a-z-' 'A-Z_' )_COMMIT\|BLERUST_COMMIT\|CCZE_RS_COMMIT\|TUNED_RS_COMMIT\|HERMES_COMMIT\|IWCHAOS_COMMIT\|LIBINPUT_RS_COMMIT" "$pkgbuild" 2>/dev/null; then
    patch_commit "$pkgbuild" "$name" || true
  fi
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

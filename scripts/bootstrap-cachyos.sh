#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  printf '%s\n' 'CachyOS repository bootstrap must run as root.' >&2
  exit 1
fi

readonly CACHYOS_PACKAGE_BASE_URL="${CACHYOS_PACKAGE_BASE_URL:-https://cdn77.cachyos.org/repo/x86_64/cachyos}"
readonly CACHYOS_KEY_FINGERPRINT='882DCFE48E2051D48E2562ABF3B607488DB35A47'
readonly KEYRING_PACKAGE='cachyos-keyring-20240331-1-any.pkg.tar.zst'
readonly MIRRORLIST_PACKAGE='cachyos-mirrorlist-27-1-any.pkg.tar.zst'
readonly KEYRING_SHA256='a0df7a06ddd0f315b46ca9353886f786922083d0a4a4502e440473005a20d6a4'
readonly MIRRORLIST_SHA256='69c6a033d45ecc105f632dcdc41528d0a2c84c927df0e2728bee2a8bd22d2015'
readonly TRUST_ANCHOR='/usr/share/arachos/cachyos.gpg'

work_dir=$(mktemp -d /var/tmp/arachos-cachyos-bootstrap.XXXXXXXX)
cleanup() {
  local status=$?
  if [[ -d "$work_dir" ]]; then
    find "$work_dir" -depth -delete
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

[[ -r "$TRUST_ANCHOR" ]] || {
  printf 'CachyOS trust anchor is missing: %s\n' "$TRUST_ANCHOR" >&2
  exit 1
}

keyring_package="$work_dir/$KEYRING_PACKAGE"
mirrorlist_package="$work_dir/$MIRRORLIST_PACKAGE"
for package in "$KEYRING_PACKAGE" "$MIRRORLIST_PACKAGE"; do
  curl --fail --location --silent --show-error \
    "$CACHYOS_PACKAGE_BASE_URL/$package" \
    --output "$work_dir/$package"
  curl --fail --location --silent --show-error \
    "$CACHYOS_PACKAGE_BASE_URL/$package.sig" \
    --output "$work_dir/$package.sig"
done

printf '%s  %s\n' "$KEYRING_SHA256" "$keyring_package" \
  | sha256sum --check --status -
printf '%s  %s\n' "$MIRRORLIST_SHA256" "$mirrorlist_package" \
  | sha256sum --check --status -

gpg --batch --yes --dearmor --output "$work_dir/cachyos.gpg" "$TRUST_ANCHOR"
gpgv --keyring "$work_dir/cachyos.gpg" \
  "$keyring_package.sig" "$keyring_package" >/dev/null
gpgv --keyring "$work_dir/cachyos.gpg" \
  "$mirrorlist_package.sig" "$mirrorlist_package" >/dev/null

fingerprint=$(gpg --batch --with-colons --show-keys "$TRUST_ANCHOR" \
  | awk -F: '$1 == "fpr" {print $10; exit}')
[[ "$fingerprint" == "$CACHYOS_KEY_FINGERPRINT" ]] || {
  printf 'Unexpected CachyOS key fingerprint: %s\n' "$fingerprint" >&2
  exit 1
}

pacman-key --init
pacman-key --populate archlinux
pacman-key --add "$TRUST_ANCHOR"
pacman-key --lsign-key "$CACHYOS_KEY_FINGERPRINT"
pacman -U --noconfirm "$keyring_package" "$mirrorlist_package"
pacman-key --populate cachyos

if ! grep -q '^\[cachyos\]$' /etc/pacman.conf; then
  printf '\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' \
    >> /etc/pacman.conf
fi

pacman -Sy --noconfirm
pacman -Si cachyos-calamares >/dev/null

unlink "$TRUST_ANCHOR"

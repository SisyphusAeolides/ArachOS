#!/usr/bin/env bash
# Stage a signed Corinth service deployment into a disposable ArchISO root.
set -Eeuo pipefail

PROFILE_ROOT=${1:?usage: stage-corinth-deployment.sh ARCHISO_PROFILE_ROOT}
TARGET_ROOT="$PROFILE_ROOT/airootfs"

fail() { printf 'ArachOS stage-corinth-deployment: %s\n' "$*" >&2; exit 1; }

config=${ARACHOS_CORINTH_SERVICE_CONFIG:-}
signature=${ARACHOS_CORINTH_SERVICE_SIGNATURE:-}
keyring=${ARACHOS_CORINTH_KEYRING:-}
required=${ARACHOS_CORINTH_DEPLOYMENT_REQUIRED:-0}
hwd_catalog=${ARACHOS_HWD_CATALOG_ROOT:-}

case "$required" in
    0|1) ;;
    *) fail 'ARACHOS_CORINTH_DEPLOYMENT_REQUIRED must be 0 or 1' ;;
esac

if [[ -z "$config" && -z "$signature" && -z "$keyring" ]]; then
    [[ -z "$hwd_catalog" ]] ||
        fail 'Arach-HWD catalog requires the complete signed Corinth deployment'
    [[ "$required" == 0 ]] ||
        fail 'a signed service config, signature, and keyring are required'
    printf 'no signed Corinth deployment supplied; retaining qualification-only image\n'
    exit 0
fi

[[ -n "$config" && -n "$signature" && -n "$keyring" ]] ||
    fail 'service config, signature, and keyring must be supplied together'

for path in "$config" "$signature" "$keyring"; do
    [[ "$path" == /* ]] || fail "deployment input must be an absolute path: $path"
    [[ -e "$path" ]] || fail "deployment input does not exist: $path"
    [[ ! -L "$path" && -f "$path" ]] ||
        fail "deployment input must be a regular non-symlink file: $path"
done

config_bytes=$(stat -c '%s' -- "$config")
signature_bytes=$(stat -c '%s' -- "$signature")
keyring_bytes=$(stat -c '%s' -- "$keyring")
(( config_bytes > 0 && config_bytes <= 4 * 1024 * 1024 )) ||
    fail "service config is empty or too large: $config"
(( signature_bytes > 0 && signature_bytes <= 16 * 1024 )) ||
    fail "service signature is empty or too large: $signature"
(( keyring_bytes > 0 && keyring_bytes <= 4 * 1024 * 1024 )) ||
    fail "Corinth keyring is empty or too large: $keyring"

# A registry is what makes the eight-provider route automatic. Static service
# repositories remain useful for diagnostics, but a release deployment must
# name a signed rotating registry rather than silently claiming full coverage.
grep -Eq '^[[:space:]]*\[registry\][[:space:]]*$' "$config" ||
    fail 'service config has no signed provider registry section'
grep -Eq '^[[:space:]]*manifest[[:space:]]*=[[:space:]]*"(https://|/)' "$config" ||
    fail 'provider registry manifest is missing or uses an unsupported location'
grep -Eq '^[[:space:]]*signature[[:space:]]*=[[:space:]]*"(https://|/)' "$config" ||
    fail 'provider registry signature is missing or uses an unsupported location'

install -d -m 0755 "$TARGET_ROOT/etc/corinth" "$TARGET_ROOT/etc/arach/hwd"
install -m 0644 -- "$config" "$TARGET_ROOT/etc/corinth/service.toml"
install -m 0644 -- "$signature" "$TARGET_ROOT/etc/corinth/service.toml.sig"
install -m 0644 -- "$keyring" "$TARGET_ROOT/etc/arach/hwd/keys.toml"

if [[ -n "$hwd_catalog" ]]; then
    [[ "$hwd_catalog" == /* ]] ||
        fail "Arach-HWD catalog must be an absolute path: $hwd_catalog"
    [[ -d "$hwd_catalog" && ! -L "$hwd_catalog" ]] ||
        fail "Arach-HWD catalog root is not a real directory: $hwd_catalog"
    [[ -f "$hwd_catalog/catalog.lock" && ! -L "$hwd_catalog/catalog.lock" ]] ||
        fail 'Arach-HWD catalog.lock is missing or not a regular file'
    [[ -f "$hwd_catalog/keys.toml" && ! -L "$hwd_catalog/keys.toml" ]] ||
        fail 'Arach-HWD catalog keys.toml is missing or not a regular file'
    [[ -d "$hwd_catalog/profiles" && ! -L "$hwd_catalog/profiles" ]] ||
        fail 'Arach-HWD catalog profiles directory is missing or not real'
    symlink=$(find "$hwd_catalog" -type l -print -quit)
    if [[ -n "$symlink" ]]; then
        fail 'Arach-HWD catalog must not contain symlinks'
    fi
    install -d -m 0755 "$TARGET_ROOT/etc/arach/hwd/catalog"
    cp -a --no-preserve=ownership "$hwd_catalog/." \
        "$TARGET_ROOT/etc/arach/hwd/catalog/"
    printf 'staged signed Arach-HWD catalog in %s\n' \
        "$TARGET_ROOT/etc/arach/hwd/catalog"
fi

printf 'staged signed Corinth deployment in %s\n' "$TARGET_ROOT/etc/corinth"

#!/usr/bin/env bash
# Check that an image has either no Corinth deployment or a complete one.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE="$ROOT/archiso/airootfs"

fail() { printf 'ArachOS validate-corinth-deployment: %s\n' "$*" >&2; exit 1; }

config="$PROFILE/etc/corinth/service.toml"
signature="$PROFILE/etc/corinth/service.toml.sig"
keyring="$PROFILE/etc/arach/hwd/keys.toml"
catalog="$PROFILE/etc/arach/hwd/catalog"
present=0
for path in "$config" "$signature" "$keyring"; do
    [[ -e "$path" ]] && present=$((present + 1))
done

if (( present == 0 )); then
    printf 'no signed Corinth deployment staged (qualification image)\n'
    exit 0
fi
(( present == 3 )) || fail 'Corinth deployment is incomplete'

for path in "$config" "$signature" "$keyring"; do
    [[ ! -L "$path" && -f "$path" ]] ||
        fail "deployment file is not a regular non-symlink file: $path"
    bytes=$(stat -c '%s' -- "$path")
    (( bytes > 0 && bytes <= 4 * 1024 * 1024 )) ||
        fail "deployment file is empty or too large: $path"
done

grep -Eq '^[[:space:]]*format[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$config" ||
    fail 'service config does not declare format=1'
grep -Eq '^[[:space:]]*\[registry\][[:space:]]*$' "$config" ||
    fail 'service config does not declare a provider registry'
grep -Eq '^[[:space:]]*manifest[[:space:]]*=[[:space:]]*"(https://|/)' "$config" ||
    fail 'provider registry manifest is missing or unsupported'
grep -Eq '^[[:space:]]*signature[[:space:]]*=[[:space:]]*"(https://|/)' "$config" ||
    fail 'provider registry signature is missing or unsupported'

# Cryptographic verification is intentionally performed by PackageService at
# image boot. This check only prevents a partial or obviously malformed copy
# from being published by the ArchISO builder.
printf 'validated complete Corinth deployment inputs in %s\n' "$PROFILE"

if [[ -e "$catalog" ]]; then
    [[ -d "$catalog" && ! -L "$catalog" ]] ||
        fail 'Arach-HWD catalog root is not a real directory'
    [[ -f "$catalog/catalog.lock" && ! -L "$catalog/catalog.lock" ]] ||
        fail 'Arach-HWD catalog.lock is not a regular file'
    [[ -f "$catalog/keys.toml" && ! -L "$catalog/keys.toml" ]] ||
        fail 'Arach-HWD catalog keys.toml is not a regular file'
    [[ -d "$catalog/profiles" && ! -L "$catalog/profiles" ]] ||
        fail 'Arach-HWD catalog profiles is not a real directory'
    symlink=$(find "$catalog" -type l -print -quit)
    [[ -z "$symlink" ]] || fail 'Arach-HWD catalog contains a symlink'
    printf 'validated complete Arach-HWD catalog inputs in %s\n' "$catalog"
fi

#!/usr/bin/env bash
# Remove disposable temporary paths created by ArachOS and its pinned
# qualification helpers.  Every entry is an exact, project-owned prefix.
set -Eeuo pipefail

temp_root=${TMPDIR:-/tmp}

fail() {
    printf 'ArachOS clean-temp: %s\n' "$*" >&2
    exit 1
}

[[ "$temp_root" == /* && -d "$temp_root" && "$temp_root" != / ]] \
    || fail "refusing unsafe temporary root: $temp_root"

patterns=(
    'arachos-grub.*'
    'arachos-limine.*'
    'arachos-qemu.*'
    'arachos-dm.*'
    'arachos-rustd-services.*'
    'arach-formal.*'
    'arach-hwd-formal.*'
    'corinth-formal.*'
    'hermes-formal.*'
    'hermes-qualification.*'
    'rustd-container-host-sentinel.*'
    'rustd-container-root.*'
    'rustd-cutover.*'
    'rustd-formal.*'
    'rustd-mac-context.*'
    'rustd-reproducible.*'
    'rustd-resolved-formal.*'
    'rustd-resolved-privileges.*'
    'rustd-resolved-release.*'
    'rustd-avahi-*'
    'rustd-feature-boundary-*'
    'rustd-dnssec-ad-*'
    'tuned-formal.*'
    'libinput-formal.*'
    'libinput-rs-abi.*'
    'libinput-rs-public-abi.*'
    'libinput-rs-rpm.*'
    'ccze-formal.*'
)
removed=0
for pattern in "${patterns[@]}"; do
    while IFS= read -r -d '' path; do
        [[ -e "$path" && ! -L "$path" ]] || continue
        if find "$path" -depth -delete 2>/dev/null; then
            removed=$((removed + 1))
        elif sudo -n find "$path" -depth -delete 2>/dev/null; then
            removed=$((removed + 1))
        else
            fail "unable to remove ArachOS temporary directory: $path"
        fi
    done < <(find "$temp_root" -mindepth 1 -maxdepth 1 \
        \( -type d -o -type f \) \
        -name "$pattern" -print0)
done

printf 'removed %d ArachOS temporary paths from %s\n' "$removed" "$temp_root"

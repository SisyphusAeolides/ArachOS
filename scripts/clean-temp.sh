#!/usr/bin/env bash
# Remove disposable temporary directories created by ArachOS test and image jobs.
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
)
removed=0
for pattern in "${patterns[@]}"; do
    while IFS= read -r -d '' path; do
        [[ -d "$path" ]] || continue
        if find "$path" -depth -delete 2>/dev/null; then
            removed=$((removed + 1))
        elif sudo -n find "$path" -depth -delete 2>/dev/null; then
            removed=$((removed + 1))
        else
            fail "unable to remove ArachOS temporary directory: $path"
        fi
    done < <(find "$temp_root" -mindepth 1 -maxdepth 1 -type d \
        -name "$pattern" -print0)
done

printf 'removed %d ArachOS temporary directories from %s\n' "$removed" "$temp_root"

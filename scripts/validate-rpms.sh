#!/usr/bin/env bash
set -Eeuo pipefail

repo=${RPM_REPO:-build/repo}
fail() { printf 'RPM validation: %s\n' "$*" >&2; exit 1; }
[[ -d $repo ]] || fail "RPM repository is missing: $repo"
command -v rpm >/dev/null 2>&1 || fail 'rpm is required'
mapfile -t rpms < <(find "$repo" -maxdepth 1 -type f -name '*.rpm' ! -name '*.src.rpm' | sort)
((${#rpms[@]} > 0)) || fail 'no binary RPMs found'

for package in rustd rustd-resolved rustd-fedora-compat rustd-compat-libs \
              rustd-selinux rustd-resolved-nss tuned-rs libinput-rs blerust ccze-rs; do
  printf '%s\n' "${rpms[@]}" | grep -Eq "/${package}-[^/]+\.rpm$" \
    || fail "required package is missing: $package"
done

compat=$(printf '%s\n' "${rpms[@]}" | grep '/rustd-fedora-compat-[^/]*\.rpm$' | head -1)
resolved=$(printf '%s\n' "${rpms[@]}" | grep '/rustd-resolved-[^/]*\.rpm$' | grep -v -- '-nss-' | head -1)
for path in /usr/sbin/init /usr/bin/systemctl /usr/bin/systemd-tmpfiles \
            /usr/bin/systemd-sysusers /usr/lib/systemd/systemd-udevd; do
  rpm -qpl "$compat" | grep -Fxq "$path" || fail "compatibility RPM does not own $path"
done
rpm -qpl "$resolved" | grep -Fxq /usr/lib/rustd/rustd-resolved \
  || fail 'resolver daemon is not installed at its native path'
for archive in "${rpms[@]}"; do
  rpm -qpl "$archive" | grep -Eq '^/usr/lib/systemd/system/|^/run/systemd/' \
    && fail "outgoing unit/runtime root found in $(basename "$archive")"
done
printf 'validated %d binary RPMs in %s\n' "${#rpms[@]}" "$repo"

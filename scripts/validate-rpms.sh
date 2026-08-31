#!/usr/bin/env bash
set -Eeuo pipefail

repo=${RPM_REPO:-build/repo}
fail() { printf 'RPM validation: %s\n' "$*" >&2; exit 1; }
[[ -d $repo ]] || fail "RPM repository is missing: $repo"
command -v rpm >/dev/null 2>&1 || fail 'rpm is required'
mapfile -t rpms < <(find "$repo" -maxdepth 1 -type f -name '*.rpm' \
  ! -name '*.src.rpm' ! -name '*-debuginfo*.rpm' ! -name '*-debugsource*.rpm' | sort)
((${#rpms[@]} > 0)) || fail 'no binary RPMs found'

# This repository contains ArachOS-owned packages only. The installer keeps
# the RLC DVD's baseos/appstream repositories as the source for packages such
# as dracut, kernel, Anaconda, and the graphical environment.
for package in rustd rustd-resolved rustd-fedora-compat rustd-compat-libs \
              rustd-cutover-tools rustd-selinux rustd-resolved-nss tuned-rs \
              libinput-rs blerust ccze-rs arachos-release; do
  printf '%s\n' "${rpms[@]}" | grep -Eq "/${package}-[^/]+\.rpm$" \
    || fail "required package is missing: $package"
done

compat=$(printf '%s\n' "${rpms[@]}" | grep -E '/rustd-fedora-compat-[0-9][^/]*\.(x86_64|noarch)\.rpm$' | head -1)
[[ -n $compat ]] || fail 'RustD RLC compatibility provider RPM is missing (rustd-fedora-compat)'
resolved=$(printf '%s\n' "${rpms[@]}" | grep -E '/rustd-resolved-[0-9][^/]*\.x86_64\.rpm$' | head -1)
[[ -n $resolved ]] || fail 'rustd-resolved binary RPM is missing'
mapfile -t compat_files < <(rpm -qpl "$compat") \
  || fail "cannot read file list from $(basename "$compat")"
for path in /usr/sbin/init /usr/bin/systemctl /usr/bin/systemd-tmpfiles \
            /usr/bin/systemd-sysusers /usr/lib/systemd/systemd-udevd; do
  printf '%s\n' "${compat_files[@]}" | grep -Fxq "$path" \
    || fail "compatibility RPM does not own $path"
done
udevd_mode=$(rpm -qp --qf '[%{filemodes:perms} %{filenames}\n]' "$compat" \
  | awk '$2 == "/usr/lib/systemd/systemd-udevd" {print $1}')
[[ $udevd_mode == -* ]] || fail 'udev compatibility path must be a regular executable file'
mapfile -t resolved_files < <(rpm -qpl "$resolved") \
  || fail "cannot read file list from $(basename "$resolved")"
printf '%s\n' "${resolved_files[@]}" | grep -Fxq /usr/lib/rustd/rustd-resolved \
  || fail 'resolver daemon is not installed at its native path'
branding=$(printf '%s\n' "${rpms[@]}" | grep -E '/arachos-release-[0-9][^/]*\.noarch\.rpm$' | head -1)
[[ -n $branding ]] || fail 'ArachOS branding RPM is missing'
mapfile -t branding_files < <(rpm -qpl "$branding") \
  || fail "cannot read file list from $(basename "$branding")"
for path in /etc/arachos-release /etc/anaconda/profile.d/z-arachos.conf \
            /etc/issue.d/20-arachos.issue /usr/share/pixmaps/arachos.png \
            /usr/share/backgrounds/arachos/ArachOS.png; do
  printf '%s\n' "${branding_files[@]}" | grep -Fxq "$path" \
    || fail "branding RPM does not own $path"
done
for archive in "${rpms[@]}"; do
  rpm -qpl "$archive" | grep -Eq '^/usr/lib/systemd/system/|^/run/systemd/' \
    && fail "outgoing unit/runtime root found in $(basename "$archive")"
done
printf 'validated %d binary RPMs in %s\n' "${#rpms[@]}" "$repo"

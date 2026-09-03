#!/usr/bin/env bash
set -Eeuo pipefail

repo=${RPM_REPO:-build/repo}
fail() { printf 'RPM validation: %s\n' "$*" >&2; exit 1; }
[[ -d $repo ]] || fail "RPM repository is missing: $repo"
command -v rpm >/dev/null 2>&1 || fail 'rpm is required'
mapfile -t rpms < <(find "$repo" -maxdepth 1 -type f -name '*.rpm' \
  ! -name '*.src.rpm' ! -name '*-debuginfo*.rpm' ! -name '*-debugsource*.rpm' | sort)
((${#rpms[@]} > 0)) || fail 'no binary RPMs found'

# This repository contains ArachOS-owned packages only. The installer obtains
# the generic kernel, Anaconda, and supporting userspace from the configured
# bootstrap repositories; this repository supplies the ArachOS integration.
for package in rustd rustd-resolved rustd-fedora-compat rustd-compat-libs \
              rustd-cutover-tools rustd-selinux rustd-resolved-nss tuned-rs \
              libinput-rs blerust ccze-rs iwchaos hermes-gpu-stack arachos-release; do
  printf '%s\n' "${rpms[@]}" | grep -E "/${package}-[^/]+\.rpm$" >/dev/null \
    || fail "required package is missing: $package"
done

iwchaos=$(printf '%s\n' "${rpms[@]}" \
  | grep -E '/iwchaos-[0-9][^/]*\.(x86_64|noarch)\.rpm$' \
  | sed -n '1p')
[[ -n $iwchaos ]] || fail 'iwchaos DKMS source RPM is missing'
mapfile -t iwchaos_files < <(rpm -qpl "$iwchaos") \
  || fail "cannot read file list from $(basename "$iwchaos")"
for pattern in \
    '^/usr/src/iwchaos-[^/]+/dkms\.conf$' \
    '^/usr/src/iwchaos-[^/]+/Makefile$' \
    '^/usr/src/iwchaos-[^/]+/scripts/prepare-source\.sh$' \
    '^/usr/src/iwchaos-[^/]+/rust/Cargo\.lock$' \
    '^/usr/src/iwchaos-[^/]+/vendor/iwlwifi-[^/]+/\.iwchaos-source$' \
    '^/usr/src/iwchaos-[^/]+/vendor/iwlwifi-[^/]+/iwl-drv\.c$'; do
  printf '%s\n' "${iwchaos_files[@]}" | grep -E "$pattern" >/dev/null \
    || fail "iwchaos RPM does not own a required source path matching $pattern"
done
printf '%s\n' "${iwchaos_files[@]}" | grep -Fx /usr/share/licenses/iwchaos/LICENSE >/dev/null \
  || fail 'iwchaos RPM does not own its license'

rustd=$(printf '%s\n' "${rpms[@]}" \
  | grep -E '/rustd-[0-9][^/]*\.x86_64\.rpm$' \
  | grep -Ev '/rustd-(resolved|selinux|compat|fedora|cutover|devel)-' \
  | sed -n '1p')
[[ -n $rustd ]] || fail 'RustD native RPM is missing'
mapfile -t rustd_files < <(rpm -qpl "$rustd") \
  || fail "cannot read file list from $(basename "$rustd")"
printf '%s\n' "${rustd_files[@]}" | grep -Fx /usr/bin/rustkernel-install >/dev/null \
  || fail 'RustD native kernel installer is missing'

compat=$(printf '%s\n' "${rpms[@]}" \
  | grep -E '/rustd-fedora-compat-[0-9][^/]*\.(x86_64|noarch)\.rpm$' \
  | sed -n '1p')
[[ -n $compat ]] || fail 'RustD RPM compatibility provider is missing (rustd-fedora-compat)'
resolved=$(printf '%s\n' "${rpms[@]}" \
  | grep -E '/rustd-resolved-[0-9][^/]*\.x86_64\.rpm$' \
  | sed -n '1p')
[[ -n $resolved ]] || fail 'rustd-resolved binary RPM is missing'
mapfile -t compat_files < <(rpm -qpl "$compat") \
  || fail "cannot read file list from $(basename "$compat")"
for path in /usr/sbin/init /usr/bin/systemctl /usr/bin/systemd-tmpfiles \
            /usr/bin/systemd-sysusers /usr/lib/systemd/systemd-udevd; do
  printf '%s\n' "${compat_files[@]}" | grep -Fx "$path" >/dev/null \
    || fail "compatibility RPM does not own $path"
done
udevd_mode=$(rpm -qp --qf '[%{filemodes:perms} %{filenames}\n]' "$compat" \
  | awk '$2 == "/usr/lib/systemd/systemd-udevd" {print $1}')
[[ $udevd_mode == -* ]] || fail 'udev compatibility path must be a regular executable file'
mapfile -t resolved_files < <(rpm -qpl "$resolved") \
  || fail "cannot read file list from $(basename "$resolved")"
printf '%s\n' "${resolved_files[@]}" | grep -Fx /usr/lib/rustd/rustd-resolved >/dev/null \
  || fail 'resolver daemon is not installed at its native path'
hermes=$(printf '%s\n' "${rpms[@]}" \
  | grep -E '/hermes-gpu-stack-[0-9][^/]*\.(x86_64|noarch)\.rpm$' \
  | sed -n '1p')
[[ -n $hermes ]] || fail 'Hermes GPU compatibility RPM is missing'
mapfile -t hermes_files < <(rpm -qpl "$hermes") \
  || fail "cannot read file list from $(basename "$hermes")"
for path in /usr/bin/hermes-ctl /usr/bin/nvidia-smi \
            /usr/bin/nvidia-modprobe /usr/bin/nvidia-settings \
            /usr/lib/rustd/system/hermes-gpu.service \
            /usr/share/hermes/DROPIN_CATALOG.txt \
            /usr/lib64/libnvidia-ml.so.1 /usr/lib64/libcuda.so.1 \
            /usr/lib64/libcudart.so.12 /usr/lib64/libGLX_nvidia.so.0 \
            /usr/lib64/libEGL_nvidia.so.0; do
  printf '%s\n' "${hermes_files[@]}" | grep -Fx "$path" >/dev/null \
    || fail "Hermes RPM does not own $path"
done
branding=$(printf '%s\n' "${rpms[@]}" \
  | grep -E '/arachos-release-[0-9][^/]*\.noarch\.rpm$' \
  | sed -n '1p')
[[ -n $branding ]] || fail 'ArachOS branding RPM is missing'
grep -Eq '^system-release = [^[:space:]]+$' <(rpm -qp --provides "$branding") \
  || fail 'branding RPM does not provide the ArachOS system-release capability'
grep -Eq '^system-logos = [^[:space:]]+$' <(rpm -qp --provides "$branding") \
  || fail 'branding RPM does not provide the ArachOS system-logos capability'
mapfile -t branding_files < <(rpm -qpl "$branding") \
  || fail "cannot read file list from $(basename "$branding")"
for path in /etc/arachos-release /etc/anaconda/profile.d/z-arachos.conf \
            /etc/anaconda/conf.d/10-arachos.conf \
            /etc/profile.d/arachos-branding.sh \
            /etc/issue.d/20-arachos.issue /usr/share/pixmaps/arachos.png \
            /usr/share/pixmaps/arachos-chaos.png \
            /usr/share/backgrounds/arachos/ArachOS.png \
            /usr/share/anaconda/boot/splash.png \
            /usr/share/anaconda/pixmaps/anaconda_header.png \
            /usr/share/anaconda/pixmaps/arachos.css \
            /usr/share/anaconda/pixmaps/sidebar-bg.png \
            /usr/share/anaconda/pixmaps/sidebar-logo.png \
            /usr/share/anaconda/pixmaps/org.arachos.ArachOSInstaller.png \
            /usr/share/anaconda/pixmaps/topbar-bg.png \
            /usr/share/icons/hicolor/48x48/apps/org.arachos.ArachOSInstaller.png \
            /usr/share/fastfetch/presets/arachos.jsonc; do
  printf '%s\n' "${branding_files[@]}" | grep -Fx "$path" >/dev/null \
    || fail "branding RPM does not own $path"
done
for archive in "${rpms[@]}"; do
  rpm -qpl "$archive" | grep -E '^/usr/lib/systemd/system/|^/run/systemd/' >/dev/null \
    && fail "outgoing unit/runtime root found in $(basename "$archive")"
done
manifest="$repo/manifest.txt"
[[ -f $manifest ]] || fail 'RPM manifest is missing'
grep -Fxq 'schema=arachos-rpm-set-v1' "$manifest" \
  || fail 'RPM manifest has the wrong schema'
printf 'validated %d binary RPMs in %s\n' "${#rpms[@]}" "$repo"

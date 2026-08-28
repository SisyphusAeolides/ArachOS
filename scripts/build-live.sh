#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_REPO=${RPM_REPO:-$ROOT/build/repo}
ISO_OUTPUT=${ISO_OUTPUT:-$ROOT/build/iso}
WORK=${LIVE_MEDIA_WORK:-$ROOT/build/live-work}
FEDORA_RELEASE=${FEDORA_RELEASE:-45}
FEDORA_ARCH=${FEDORA_ARCH:-x86_64}

fail() { printf 'live media build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in livemedia-creator createrepo_c sha256sum; do need "$command"; done
[[ $EUID -eq 0 ]] || fail 'livemedia-creator must run as root'
[[ -d $RPM_REPO ]] || fail "RPM repository is missing: $RPM_REPO"

rm -rf "$ISO_OUTPUT" "$WORK"
mkdir -p "$WORK" "$RPM_REPO"
createrepo_c --update "$RPM_REPO"

# Clear stale Anaconda state from an interrupted build before starting a new
# installation attempt. These exact runtime markers are recreated by Anaconda.
rm -f /run/anaconda/installation-error-msg /run/user/0/anaconda.pid

# Do not let GRUB's post-transaction OS probe inspect the build host's disks.
# The target is an isolated image, so host OS entries would be incorrect and
# probing physical partitions can block the transaction.
export GRUB_DISABLE_OS_PROBER=true

rendered_ks="$WORK/ArachOS.ks"
sed "s#^url --url=.*#&\nrepo --name=rustd-local --baseurl=file://$RPM_REPO#" \
  "$ROOT/kickstart/ArachOS.ks" > "$rendered_ks"

livemedia-creator \
  --make-iso \
  --ks "$rendered_ks" \
  --anaconda-arg=--noninteractive \
  --releasever "$FEDORA_RELEASE" \
  --project "ArachOS" \
  --volid ARACHOS \
  --image-name ArachOS-live-"$FEDORA_ARCH" \
  --resultdir "$ISO_OUTPUT" \
  --tmp "$WORK" \
  --logfile "$WORK/livemedia-creator.log" \
  --no-virt

iso=$(find "$ISO_OUTPUT" -maxdepth 2 -type f -name '*.iso' -print -quit)
[[ -n $iso ]] || fail 'livemedia-creator did not produce an ISO'
final_iso="$ISO_OUTPUT/ArachOS-live-$FEDORA_ARCH.iso"
if [[ $iso != "$final_iso" ]]; then
    cp "$iso" "$final_iso"
    iso="$final_iso"
fi
sha256sum "$iso" > "$iso.sha256"
cp "$ROOT/sources.lock" "$ISO_OUTPUT/sources.lock"
cp "$RPM_REPO/manifest.txt" "$ISO_OUTPUT/rpm-manifest.txt" 2>/dev/null || true
printf 'ISO: %s\n' "$iso"

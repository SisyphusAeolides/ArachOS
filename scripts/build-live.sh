#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPM_REPO=${RPM_REPO:-$ROOT/build/repo}
ISO_OUTPUT=${ISO_OUTPUT:-$ROOT/build/iso}
WORK=${LIVE_MEDIA_WORK:-$ROOT/build/live-work}
RLC_RELEASE=${RLC_RELEASE:-10.2}
RLC_ARCH=${RLC_ARCH:-x86_64}
RLC_INSTALL_TREE_URL=${RLC_INSTALL_TREE_URL:-}
RLC_SOURCE_ISO=${RLC_SOURCE_ISO:-}
KERNEL_PACKAGE=${KERNEL_PACKAGE:-kernel}
KERNEL_MODULE_PACKAGES=${KERNEL_MODULE_PACKAGES:-kernel-modules kernel-modules-extra}

fail() { printf 'live media build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
for command in livemedia-creator createrepo_c sha256sum awk; do need "$command"; done
[[ $EUID -eq 0 ]] || fail 'livemedia-creator must run as root'
[[ -d $RPM_REPO ]] || fail "ArachOS RPM repository is missing: $RPM_REPO"

rm -rf "$ISO_OUTPUT" "$WORK"
mkdir -p "$WORK"

mounted_tree=
cleanup_tree() {
    if [[ -n $mounted_tree ]]; then
        umount "$mounted_tree" >/dev/null 2>&1 || true
    fi
}
trap cleanup_tree EXIT

if [[ -z $RLC_INSTALL_TREE_URL && -n $RLC_SOURCE_ISO ]]; then
    [[ -f $RLC_SOURCE_ISO ]] || fail "RLC source ISO is missing: $RLC_SOURCE_ISO"
    command -v mount >/dev/null 2>&1 || fail 'mount is required for RLC_SOURCE_ISO'
    command -v umount >/dev/null 2>&1 || fail 'umount is required for RLC_SOURCE_ISO'
    mounted_tree="$WORK/rlc-install-tree"
    mkdir -p "$mounted_tree"
    mount -o loop,ro "$RLC_SOURCE_ISO" "$mounted_tree"
    RLC_INSTALL_TREE_URL="file://$mounted_tree"
fi
[[ -n $RLC_INSTALL_TREE_URL ]] || fail \
    'set RLC_INSTALL_TREE_URL or RLC_SOURCE_ISO for the CIQ RLC 10.2 install tree'
case $RLC_INSTALL_TREE_URL in
    https://*|http://*|file://*) ;;
    *) fail 'RLC_INSTALL_TREE_URL must use http(s):// or file://';;
esac

createrepo_c --update "$RPM_REPO"

# Keep the host Lorax templates as the baseline, but carry the live-media
# boot-menu policy in this repository.  The stock templates default to the
# media-check entry and a Plymouth splash; that is the wrong default for an
# installer image whose first userspace is a text Anaconda session.
if [[ -n ${LORAX_TEMPLATE_ROOT:-} ]]; then
    lorax_base=$LORAX_TEMPLATE_ROOT
else
    lorax_base=$(find /usr/share/lorax/templates.d -mindepth 1 -maxdepth 1 \
        -type d -print | sort -V | tail -n 1)
fi
[[ -n "$lorax_base" && -d "$lorax_base" ]] || fail 'Lorax generic templates are missing'
lorax_templates="$WORK/lorax-templates"
mkdir -p "$lorax_templates"
cp -a "$lorax_base"/. "$lorax_templates"/
cp "$ROOT/packaging/lorax/live/config_files/x86/grub2-bios.cfg" \
    "$lorax_templates/live/config_files/x86/grub2-bios.cfg"
cp "$ROOT/packaging/lorax/live/config_files/x86/grub2-efi.cfg" \
    "$lorax_templates/live/config_files/x86/grub2-efi.cfg"

# Clear stale Anaconda state from an interrupted build before starting a new
# installation attempt. These exact runtime markers are recreated by Anaconda.
rm -f /run/anaconda/installation-error-msg /run/user/0/anaconda.pid

# Do not let GRUB's post-transaction OS probe inspect the build host's disks.
# The target is an isolated image, so host OS entries would be incorrect and
# probing physical partitions can block the transaction.
export GRUB_DISABLE_OS_PROBER=true

rendered_ks="$WORK/ArachOS.ks"
awk -v install_tree="$RLC_INSTALL_TREE_URL" -v custom_repo="$RPM_REPO" \
    -v kernel_package="$KERNEL_PACKAGE" -v kernel_modules="$KERNEL_MODULE_PACKAGES" '
  BEGIN {
    module_count = split(kernel_modules, module_list, /[[:space:]]+/)
    in_kernel = ""
  }
  /^url[[:space:]]+--url=/ {
    print "url --url=" install_tree
    print "repo --name=arachos-custom --baseurl=file://" custom_repo
    next
  }
  /^repo[[:space:]]+--name=arachos-custom([[:space:]]|$)/ { next }
  /^# ARACHOS_KERNEL_PACKAGE_BEGIN$/ {
    print kernel_package
    in_kernel = "package"
    next
  }
  /^# ARACHOS_KERNEL_PACKAGE_END$/ {
    in_kernel = ""
    next
  }
  /^# ARACHOS_KERNEL_MODULE_PACKAGES_BEGIN$/ {
    for (i = 1; i <= module_count; i++)
      if (module_list[i] != "") print module_list[i]
    in_kernel = "modules"
    next
  }
  /^# ARACHOS_KERNEL_MODULE_PACKAGES_END$/ {
    in_kernel = ""
    next
  }
  in_kernel != "" { next }
  { print }
' "$ROOT/kickstart/ArachOS.ks" > "$rendered_ks"
grep -q '^url --url=' "$rendered_ks" || fail 'rendered kickstart has no install tree'

livemedia-creator \
  --make-iso \
  --ks "$rendered_ks" \
  --lorax-templates "$lorax_templates" \
  --anaconda-arg=--noninteractive \
  --releasever "$RLC_RELEASE" \
  --project "ArachOS" \
  --volid "ARACHOS${RLC_RELEASE//./}" \
  --image-name ArachOS-RLC-"$RLC_RELEASE"-live-"$RLC_ARCH" \
  --resultdir "$ISO_OUTPUT" \
  --tmp "$WORK" \
  --logfile "$WORK/livemedia-creator.log" \
  --no-virt

iso=$(find "$ISO_OUTPUT" -maxdepth 2 -type f -name '*.iso' -print -quit)
[[ -n $iso ]] || fail 'livemedia-creator did not produce an ISO'
final_iso="$ISO_OUTPUT/ArachOS-RLC-$RLC_RELEASE-live-$RLC_ARCH.iso"
if [[ $iso != "$final_iso" ]]; then
    cp "$iso" "$final_iso"
    iso="$final_iso"
fi
sha256sum "$iso" > "$iso.sha256"
cp "$ROOT/sources.lock" "$ISO_OUTPUT/sources.lock"
cp "$RPM_REPO/manifest.txt" "$ISO_OUTPUT/rpm-manifest.txt" 2>/dev/null || true
printf 'ISO: %s\n' "$iso"

#!/usr/bin/env bash
# Rebuild the Anaconda stage2 with the ArachOS identity and product payload.
#
# The supplied Everything image is a bootstrap input. It is never copied
# unchanged into release media: the squashfs stage2 is unpacked, overlaid with
# the exact ArachOS release package, and rebuilt before mkksiso composes the
# final image.

set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
    printf 'usage: %s SOURCE_INSTALL_IMG OUTPUT_INSTALL_IMG PRODUCT_ROOT WORK_ROOT\n' \
        "${0##*/}" >&2
    exit 64
fi

source_img=$1
output_img=$2
product_root=$3
work_root=$4
stage2_version=${ARACHOS_VERSION:-1.0}

fail() { printf 'ArachOS Anaconda stage2: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

for command in unsquashfs mksquashfs install find grep sed sha256sum awk; do
    need "$command"
done

[[ -r $source_img ]] || fail "bootstrap install image is unreadable: $source_img"
[[ -d $product_root ]] || fail "ArachOS product root is missing: $product_root"
[[ $EUID -eq 0 ]] || fail 'stage2 rebuild must run as root so ownership and xattrs are deterministic'

mkdir -p "$work_root"
stage2_root="$work_root/root"
stage2_output="$work_root/install.img"

# Keep the extraction in a caller-owned, scoped work directory. The caller
# removes that directory after the ISO is verified; this helper never touches
# an unrelated path.
unsquashfs -quiet -d "$stage2_root" "$source_img" \
    || fail 'could not unpack the bootstrap Anaconda stage2'
[[ -x $stage2_root/usr/bin/anaconda ]] || fail \
    'bootstrap stage2 has no Anaconda entry point'

# Overlay the canonical release payload, including os-release, the selected
# Anaconda profile, stylesheet, artwork, and product buildstamp. ArachOS owns
# these paths in both product.img and stage2 so profile detection cannot fall
# back to the bootstrap identity if product.img is unavailable.
cp -a "$product_root"/. "$stage2_root"/

cat > "$stage2_root/etc/os-release" <<EOF
NAME="ArachOS"
ID=arachos
VERSION="$stage2_version"
VERSION_ID=$stage2_version
PLATFORM_ID="platform:arachos"
PRETTY_NAME="ArachOS $stage2_version"
ANSI_COLOR="0;35"
LOGO=arachos
HOME_URL="https://github.com/SisyphusAeolides/ArachOS"
DOCUMENTATION_URL="https://github.com/SisyphusAeolides/ArachOS"
SUPPORT_URL="https://github.com/SisyphusAeolides/ArachOS/issues"
BUG_REPORT_URL="https://github.com/SisyphusAeolides/ArachOS/issues"
EOF
printf 'ArachOS %s\n' "$stage2_version" > "$stage2_root/etc/system-release"
printf 'ArachOS %s\n' "$stage2_version" > "$stage2_root/etc/redhat-release"
if [[ -e $stage2_root/etc/fedora-release || -L $stage2_root/etc/fedora-release ]]; then
    unlink "$stage2_root/etc/fedora-release"
fi

# Only the selected profile is allowed to participate in stage2 detection.
# Leaving Fedora/Alma/CentOS profile fragments in the rebuilt image makes the
# installer a vendor multiplexer rather than an ArachOS installer.
profile_dir="$stage2_root/etc/anaconda/profile.d"
if [[ -d $profile_dir ]]; then
    while IFS= read -r -d '' profile; do
        [[ ${profile##*/} == z-arachos.conf ]] || unlink "$profile"
    done < <(find "$profile_dir" -maxdepth 1 -type f -print0)
fi

# Anaconda's upstream runtime derives the product name from .buildstamp, but
# two visible GTK defaults are compiled into its Python modules: the window
# title and the task-bar icon.  Patch those exact upstream lines in the
# rebuilt stage2 and fail if the bootstrap changes them unexpectedly.  This
# keeps the rebrand deterministic without replacing Anaconda's DBus protocol
# namespace, which is an implementation API rather than product identity.
anaconda_constants=$(find "$stage2_root/usr" -type f \
    -path '*/pyanaconda/core/constants.py' -print -quit)
anaconda_gui=$(find "$stage2_root/usr" -type f \
    -path '*/pyanaconda/ui/gui/__init__.py' -print -quit)
[[ -f $anaconda_constants && -f $anaconda_gui ]] || fail \
    'bootstrap stage2 has no patchable graphical Anaconda product modules'
sed -i \
    's/^WINDOW_TITLE_TEXT = N_("Anaconda Installer")$/WINDOW_TITLE_TEXT = N_("ArachOS Installer")/' \
    "$anaconda_constants"
grep -Fxq 'WINDOW_TITLE_TEXT = N_("ArachOS Installer")' "$anaconda_constants" \
    || fail 'could not set the ArachOS Anaconda window title'
sed -i \
    's/org\.fedoraproject\.AnacondaInstaller/org.arachos.ArachOSInstaller/g' \
    "$anaconda_gui"
grep -Fq 'set_icon_name("org.arachos.ArachOSInstaller")' "$anaconda_gui" \
    || fail 'could not set the ArachOS Anaconda task-bar icon'
# The stage2 is immutable at runtime, so stale bytecode must not win over the
# patched source.  The bootstrap image normally contains empty __pycache__
# directories, but remove any files if a future compose starts shipping them.
find "$stage2_root/usr" -type f -path '*/pyanaconda/*/__pycache__/*' \
    \( -name 'constants*.pyc' -o -name '__init__*.pyc' \) -delete

# Remove bootstrap release/logo files that could be displayed if a fallback
# code path is reached.  The ArachOS equivalents are already overlaid from the
# release package.  Legal attribution files outside stage2 are retained by
# the media composer and are not OS identity.
for path in \
    "$stage2_root/usr/lib/fedora-release" \
    "$stage2_root/usr/lib/system-release-cpe"; do
    if [[ -e $path || -L $path ]]; then
        unlink "$path"
    fi
done
find "$stage2_root/usr/share/anaconda/pixmaps" \
    "$stage2_root/usr/share/pixmaps" \
    "$stage2_root/usr/share/icons" \
    -type f -iname '*fedora*' -delete 2>/dev/null || true
find "$stage2_root/usr/share/oxygen" -type f -iname '*fedora*' \
    -delete 2>/dev/null || true
if [[ -d $stage2_root/usr/share/fedora-logos ]]; then
    find "$stage2_root/usr/share/fedora-logos" -depth -delete
fi

# Remove bootstrap repository and desktop-integration defaults as well. These
# are not required by Anaconda's module ABI and would otherwise make the
# installer advertise or contact Fedora before the ArachOS kickstart selects
# its configured package sources. Keep the upstream Anaconda D-Bus names and
# the RPM-GPG keys: those are implementation and verification inputs, not
# displayed product identity.
for path in \
    "$stage2_root/usr/share/dnf5/libdnf.conf.d/20-fedora-defaults.conf" \
    "$stage2_root/usr/lib/systemd/system/flatpak-add-fedora-repos.service" \
    "$stage2_root/usr/share/libreport/workflows/workflow_AnacondaFedora.xml" \
    "$stage2_root/usr/lib/bootc/fedora-bootc-destructive-cleanup"; do
    if [[ -e $path || -L $path ]]; then
        unlink "$path"
    fi
done
find "$stage2_root/etc/yum.repos.d" "$stage2_root/usr/share/dnf5/repos.d" \
    -type f -iname '*fedora*' -delete 2>/dev/null || true
find "$stage2_root/etc/fonts/conf.d" "$stage2_root/usr/share/crypto-policies/policies" \
    -type f -iname '*fedora*' -delete 2>/dev/null || true
find "$stage2_root/usr/lib/swidtag" "$stage2_root/usr/lib/systemd/oci-registry" \
    "$stage2_root/usr/share/metainfo" -depth -iname '*fedora*' \
    -delete 2>/dev/null || true

# Preserve the bootstrap license/source-availability notice, but do not leave
# a distribution-branded filename in the ArachOS stage2.  Its text remains
# unchanged and explicitly identifies the third-party bootstrap material.
bootstrap_legal="$stage2_root/usr/share/licenses/fedora-release-common/Fedora-Legal-README.txt"
if [[ -f $bootstrap_legal ]]; then
    install -Dpm0644 "$bootstrap_legal" \
        "$stage2_root/usr/share/licenses/arachos-release/ArachOS-Third-Party-Bootstrap-Licenses.txt"
    unlink "$bootstrap_legal"
fi
bootstrap_license_dir="$stage2_root/usr/share/licenses/fedora-release-common"
if [[ -d $bootstrap_license_dir ]]; then
    mkdir -p "$stage2_root/usr/share/licenses/arachos-bootstrap"
    cp -a "$bootstrap_license_dir"/. \
        "$stage2_root/usr/share/licenses/arachos-bootstrap"/
    find "$bootstrap_license_dir" -depth -delete
fi
# Move any other Fedora-owned license directories (not just the release
# package) below the neutral bootstrap attribution directory.
while IFS= read -r -d '' license_dir; do
    license_name=${license_dir##*/}
    license_target="$stage2_root/usr/share/licenses/arachos-bootstrap/${license_name#fedora-}"
    mkdir -p "$license_target"
    cp -a "$license_dir"/. "$license_target"/
    find "$license_dir" -depth -delete
done < <(find "$stage2_root/usr/share/licenses" -mindepth 1 -maxdepth 1 \
    -type d -name 'fedora-*' -print0)

# Keep release compatibility paths concrete and ArachOS-owned; do not leave a
# symlink to a removed bootstrap release file behind.
for path in etc/system-release etc/redhat-release etc/system-release-cpe; do
    if [[ -L $stage2_root/$path ]]; then
        unlink "$stage2_root/$path"
    fi
done
cat > "$stage2_root/etc/system-release-cpe" <<EOF
cpe:/o:arachos:arachos:$stage2_version
EOF
printf 'ArachOS %s\n' "$stage2_version" > "$stage2_root/etc/redhat-release"
printf 'ArachOS %s\n' "$stage2_version" > "$stage2_root/etc/system-release"
install -Dpm0644 "$product_root/usr/share/anaconda/pixmaps/org.arachos.ArachOSInstaller.png" \
    "$stage2_root/usr/share/anaconda/pixmaps/org.arachos.ArachOSInstaller.png"
install -Dpm0644 "$product_root/usr/share/icons/hicolor/48x48/apps/org.arachos.ArachOSInstaller.png" \
    "$stage2_root/usr/share/icons/hicolor/48x48/apps/org.arachos.ArachOSInstaller.png"

# Keep an auditable marker in the stage2 itself. This is deliberately plain
# text so an ISO auditor can prove which product owns the running installer.
install -Dpm0644 /dev/stdin "$stage2_root/usr/share/arachos/installer-stage2" <<EOF
schema=arachos-installer-stage2-v1
product=ArachOS
profile=arachos
bootstrap_stage2_sha256=$(sha256sum "$source_img" | awk '{print $1}')
EOF

# mksquashfs may otherwise inherit host-specific labels and timestamps. The
# release pipeline supplies its own reproducible environment; keeping xattrs
# enabled preserves the SELinux metadata extracted from the source stage2.
mksquashfs "$stage2_root" "$stage2_output" -comp xz -b 131072 -noappend -all-root -xattrs \
    >/dev/null || fail 'could not rebuild the ArachOS Anaconda stage2'
install -m0644 "$stage2_output" "$output_img"

# Verify the rebuilt image before it is handed to mkksiso. The checks cover
# identity and profile selection, not just the existence of a replacement
# squashfs file.
verify_root="$work_root/verify"
unsquashfs -quiet -d "$verify_root" "$output_img" \
    || fail 'could not inspect the rebuilt ArachOS Anaconda stage2'
grep -Fxq 'ID=arachos' "$verify_root/etc/os-release" \
    || fail 'rebuilt stage2 does not report ID=arachos'
grep -Fxq 'profile_id = arachos' "$verify_root/etc/anaconda/profile.d/z-arachos.conf" \
    || fail 'rebuilt stage2 has no ArachOS Anaconda profile'
grep -Fxq 'Product=ArachOS' "$verify_root/.buildstamp" \
    || fail 'rebuilt stage2 buildstamp has no ArachOS product'
grep -Fxq 'Variant=ArachOS' "$verify_root/.buildstamp" \
    || fail 'rebuilt stage2 buildstamp has no ArachOS variant'
grep -Fxq 'WINDOW_TITLE_TEXT = N_("ArachOS Installer")' \
    "$(find "$verify_root/usr" -type f -path '*/pyanaconda/core/constants.py' -print -quit)" \
    || fail 'rebuilt stage2 Anaconda window title is not ArachOS'
grep -Fq 'set_icon_name("org.arachos.ArachOSInstaller")' \
    "$(find "$verify_root/usr" -type f -path '*/pyanaconda/ui/gui/__init__.py' -print -quit)" \
    || fail 'rebuilt stage2 Anaconda icon is not ArachOS'
grep -Fxq 'flatpak_remote =' "$verify_root/etc/anaconda/conf.d/10-arachos.conf" \
    || fail 'rebuilt stage2 leaves the bootstrap Flatpak remote enabled'
! [[ -e $verify_root/etc/fedora-release || -L $verify_root/etc/fedora-release ]] \
    || fail 'rebuilt stage2 retains /etc/fedora-release'
! find "$verify_root/usr/share" -type f -iname '*fedora*' \
    \( -path '*/anaconda/pixmaps/*' -o -path '*/pixmaps/*' \
       -o -path '*/icons/*' -o -path '*/oxygen/*' -o -path '*/fedora-logos/*' \) \
    -print -quit \
    | grep -q . \
    || fail 'rebuilt stage2 retains a Fedora-branded logo asset'
! find "$verify_root/usr/share/licenses" -iname '*fedora*' -print -quit \
    | grep -q . \
    || fail 'rebuilt stage2 retains a Fedora-branded license filename'
! find "$verify_root/etc/yum.repos.d" "$verify_root/usr/share/dnf5/repos.d" \
    -type f -iname '*fedora*' -print -quit 2>/dev/null \
    | grep -q . \
    || fail 'rebuilt stage2 retains a Fedora repository definition'
! find "$verify_root/usr/share/metainfo" "$verify_root/usr/lib/swidtag" \
    -iname '*fedora*' -print -quit 2>/dev/null \
    | grep -q . \
    || fail 'rebuilt stage2 retains Fedora identity metadata'
! [[ -e $verify_root/usr/share/libreport/workflows/workflow_AnacondaFedora.xml ]] \
    || fail 'rebuilt stage2 retains the Fedora Anaconda report workflow'
grep -Fxq 'product=ArachOS' "$verify_root/usr/share/arachos/installer-stage2" \
    || fail 'rebuilt stage2 has no ArachOS ownership marker'

printf 'ArachOS Anaconda stage2: %s\n' "$output_img"

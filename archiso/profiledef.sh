#!/usr/bin/env bash
# ArachOS archiso profile definition

iso_name="ArachOS"
iso_label="ARACHOS_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="ArachOS <https://github.com/SisyphusAeolides/ArachOS>"
iso_application="ArachOS Live/Installation Medium"
iso_version="${ARACHOS_VERSION:-1.0}"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="${ARACHOS_PACMAN_CONF:-pacman.conf}"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/home/arachos"]="1000:1000:750"
  ["/home/arachos/Desktop"]="1000:1000:750"
  ["/home/arachos/Desktop/calamares.desktop"]="1000:1000:755"
  ["/usr/sbin/arach-kernel-install"]="0:0:755"
)

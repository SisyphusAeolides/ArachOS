#!/bin/bash
set -Eeuo pipefail

override_root=/root/overrides
if [[ -d "$override_root/etc" ]]; then
    cp -a "$override_root/etc/." /etc/
fi
if [[ -e "$override_root" ]]; then
    find "$override_root" -depth -delete
fi

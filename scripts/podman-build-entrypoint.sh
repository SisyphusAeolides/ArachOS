#!/bin/bash
set -Eeuo pipefail

cd ArachOS
export IN_CONTAINER=1

echo "==> Building Packages"
su builder -c "make build-packages"

echo "==> Building Arach-Kernel Bundle"
su builder -c "make build-arach-kernel-bundle"

echo "==> Building ISO"
make build-iso

echo "==> Build complete. ISO is in build/iso/"

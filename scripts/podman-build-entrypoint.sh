#!/bin/bash
set -Eeuo pipefail

cd ArachOS
export IN_CONTAINER=1

echo "==> Building Packages"
make build-packages

echo "==> Building Arach-Kernel Bundle"
make build-arach-kernel-bundle

echo "==> Building ISO"
sudo make build-iso

echo "==> Build complete. ISO is in build/iso/"

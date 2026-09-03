#!/bin/bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
echo "==> Building Podman image"
podman build -t arachos-builder -f Dockerfile.build .

echo "==> Running Build Container"
# Mount the parent Projects directory so all sibling repos are available
podman run --rm -it \
  --userns=keep-id \
  --security-opt label=disable \
  --privileged \
  -v /home/Sisyphus/Projects:/home/builder/workspace:z \
  arachos-builder

#!/bin/bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
echo "==> Building Podman image"
podman build -t arachos-builder -f Dockerfile.build .

echo "==> Running Build Container"
podman unshare podman run --rm -it \
  --user root \
  --security-opt label=disable \
  --privileged \
  --env ARACHOS_REPOSITORY_URL \
  --env ARACHOS_GPG_HOME \
  --env ARACHOS_GPG_KEY_ID \
  -v /home/Sisyphus/Projects:/home/builder/workspace:z \
  arachos-builder bash ArachOS/scripts/podman-build-entrypoint.sh

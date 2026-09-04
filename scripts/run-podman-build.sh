#!/bin/bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
PROJECTS_ROOT=$(cd .. && pwd)
echo "==> Building Podman image"
podman build -t arachos-builder -f Dockerfile.build .

echo "==> Running Build Container"
status=0
if podman unshare podman run --rm -it \
    --user root \
    --security-opt label=disable \
    --privileged \
    --env ARACHOS_REPOSITORY_URL \
    --env ARACHOS_GPG_HOME \
    --env ARACHOS_GPG_KEY_ID \
    -v "$PROJECTS_ROOT:/home/builder/workspace:z" \
    arachos-builder bash ArachOS/scripts/podman-build-entrypoint.sh; then
  status=0
else
  status=$?
fi

# The nested rootless container maps its build user to a subordinate host UID.
# Reclaim generated files in the outer user namespace so a failed or successful
# run never leaves the host checkout owned by an inaccessible container UID.
podman unshare chown -R 0:0 "$PROJECTS_ROOT/ArachOS/build" 2>/dev/null || true
exit "$status"

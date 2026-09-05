#!/bin/bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
PROJECTS_ROOT=$(cd .. && pwd)
echo "==> Building Podman image"
podman build -t arachos-builder -f Dockerfile.build .

container_args=(
  run --rm -it
  --user root
  --security-opt label=disable
  --privileged
  --env ARACHOS_REPOSITORY_URL
  --env ARACHOS_GPG_HOME
  --env ARACHOS_GPG_KEY_ID
  --env ARACHOS_CORINTH_SERVICE_CONFIG
  --env ARACHOS_CORINTH_SERVICE_SIGNATURE
  --env ARACHOS_CORINTH_KEYRING
  --env ARACHOS_CORINTH_DEPLOYMENT_REQUIRED
  --env ARACHOS_HWD_CATALOG_ROOT
  -v "$PROJECTS_ROOT:/home/builder/workspace:z"
  # Keep host-side paths usable when an operator supplies release inputs from
  # the adjacent checkout or another explicitly named directory.
  -v "$PROJECTS_ROOT:$PROJECTS_ROOT:z"
)

mount_release_input() {
  local path=$1
  [[ -z "$path" ]] && return 0
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *:* ]] || {
    printf 'error: release input path is not an absolute path without newline/colon: %s\n' "$path" >&2
    return 1
  }
  [[ -e "$path" ]] || {
    printf 'error: release input does not exist: %s\n' "$path" >&2
    return 1
  }
  case "$path" in
    "$PROJECTS_ROOT"|"$PROJECTS_ROOT"/*) ;;
    *) container_args+=( -v "$path:$path:ro" ) ;;
  esac
}

mount_release_input "${ARACHOS_GPG_HOME:-}"
mount_release_input "${ARACHOS_CORINTH_SERVICE_CONFIG:-}"
mount_release_input "${ARACHOS_CORINTH_SERVICE_SIGNATURE:-}"
mount_release_input "${ARACHOS_CORINTH_KEYRING:-}"
mount_release_input "${ARACHOS_HWD_CATALOG_ROOT:-}"
container_args+=( arachos-builder bash ArachOS/scripts/podman-build-entrypoint.sh )

echo "==> Running Build Container"
status=0
if podman unshare podman "${container_args[@]}"; then
  status=0
else
  status=$?
fi

# The nested rootless container maps its build user to a subordinate host UID.
# Reclaim generated files in the outer user namespace so a failed or successful
# run never leaves the host checkout owned by an inaccessible container UID.
podman unshare chown -R 0:0 "$PROJECTS_ROOT/ArachOS/build" 2>/dev/null || true
exit "$status"

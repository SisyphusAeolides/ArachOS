#!/usr/bin/env bash
# Check the Podman wrapper's release-input forwarding without starting a build.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d -t arachos-podman-wrapper.XXXXXXXX)
trap 'find "$WORK" -depth -delete 2>/dev/null || :' EXIT
RECORD="$WORK/arguments"
export RECORD

podman() {
    case "$1" in
        build)
            return 0
            ;;
        unshare)
            shift
            if [[ "$1" == podman ]]; then
                shift
                printf '%s\n' "$@" >"$RECORD"
            fi
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
export -f podman

ARACHOS_GPG_HOME=/usr/share \
ARACHOS_CORINTH_SERVICE_CONFIG=/etc/hosts \
ARACHOS_CORINTH_SERVICE_SIGNATURE=/etc/hosts \
ARACHOS_CORINTH_KEYRING=/etc/hosts \
ARACHOS_HWD_CATALOG_ROOT=/usr/share \
    "$ROOT/scripts/run-podman-build.sh" >/dev/null

for setting in \
    'ARACHOS_CORINTH_SERVICE_CONFIG' \
    'ARACHOS_CORINTH_SERVICE_SIGNATURE' \
    'ARACHOS_CORINTH_KEYRING' \
    'ARACHOS_CORINTH_DEPLOYMENT_REQUIRED' \
    'ARACHOS_HWD_CATALOG_ROOT'; do
    grep -Fxq -- "$setting" "$RECORD" || {
        printf 'missing forwarded environment setting: %s\n' "$setting" >&2
        exit 1
    }
done

grep -Fxq -- "/etc/hosts:/etc/hosts:ro" "$RECORD" || {
    printf '%s\n' 'signed input file was not mounted read-only' >&2
    exit 1
}
grep -Fxq -- "/usr/share:/usr/share:ro" "$RECORD" || {
    printf '%s\n' 'signed input directory was not mounted read-only' >&2
    exit 1
}

printf '%s\n' 'validated Podman release-input forwarding'

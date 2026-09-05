#!/usr/bin/env bash
# Exercise the RustD service graph and its compatibility-unit bridge.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/archiso/airootfs/usr/libexec/arachos-enable-rustd-services"
WORK=$(mktemp -d -t arachos-rustd-services.XXXXXXXX)

fail() {
    printf 'ArachOS RustD service test: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    find "$WORK" -depth -delete 2>/dev/null || :
}
trap cleanup EXIT

[[ -x "$HELPER" ]] || fail "RustD service helper is not executable: $HELPER"
install -d "$WORK/usr/bin" "$WORK/usr/lib/rustd/system" \
    "$WORK/usr/lib/systemd/system"

units=(
    NetworkManager.service
    rustd-journald.service
    rustd-tmpfiles-setup-dev.service
    rustd-udevd.service
    rustd-udev-trigger.service
    rustd-udev-settle.service
    dbus.service
    rustd-resolved.service
    rustd-logind.service
    rustd-user-sessions.service
    tuned-rs.service
    tuned-rs-ppd.service
    libinput-rs-elan-resume.service
    hermes-gpu.service
)
for unit in "${units[@]}"; do
    if [[ "$unit" == NetworkManager.service ]]; then
        touch "$WORK/usr/lib/systemd/system/$unit"
    else
        touch "$WORK/usr/lib/rustd/system/$unit"
    fi
done

cat >"$WORK/usr/bin/rustctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >"$RUSTCTL_ARGS"
touch "$RUSTCTL_MARKER"
EOF
chmod 0755 "$WORK/usr/bin/rustctl"
export RUSTCTL_ARGS="$WORK/rustctl.args"
export RUSTCTL_MARKER="$WORK/rustctl.called"

ARACHOS_TARGET_ROOT="$WORK" "$HELPER"
[[ -L "$WORK/etc/rustd/system/NetworkManager.service" ]] ||
    fail 'the compatibility NetworkManager unit was not bridged'
[[ "$(readlink "$WORK/etc/rustd/system/NetworkManager.service")" == \
    /usr/lib/systemd/system/NetworkManager.service ]] ||
    fail 'the NetworkManager bridge points at the wrong unit'
grep -Fxq -- "--root=$WORK" "$RUSTCTL_ARGS" ||
    fail 'RustD was not given the target root'
grep -Fxq -- enable "$RUSTCTL_ARGS" ||
    fail 'RustD enable was not requested'
for unit in "${units[@]}"; do
    grep -Fxq -- "$unit" "$RUSTCTL_ARGS" ||
        fail "RustD service graph omits $unit"
done
[[ -e "$RUSTCTL_MARKER" ]] || fail 'RustD control client was not executed'

rm -f "$WORK/usr/lib/rustd/system/hermes-gpu.service" "$RUSTCTL_MARKER" \
    "$RUSTCTL_ARGS"
if ARACHOS_TARGET_ROOT="$WORK" "$HELPER" >"$WORK/missing.out" 2>"$WORK/missing.err"; then
    fail 'the helper succeeded with a required service missing'
fi
grep -Fq 'required RustD unit is missing: hermes-gpu.service' "$WORK/missing.err" ||
    fail 'missing RustD service was not reported'

printf '%s\n' 'validated RustD service activation and compatibility bridge'

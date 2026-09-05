#!/usr/bin/env bash
# Exercise the native RustD display-manager handoff in a disposable target.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/archiso/airootfs/usr/libexec/arachos-enable-display-manager"
WORK=$(mktemp -d -t arachos-dm.XXXXXXXX)

fail() {
    printf 'ArachOS display-manager test: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    find "$WORK" -depth -delete 2>/dev/null || :
}
trap cleanup EXIT

[[ -x "$HELPER" ]] || fail "display-manager helper is not executable: $HELPER"
install -d "$WORK/usr/bin" "$WORK/usr/lib/rustd/system"
touch "$WORK/usr/bin/plasmalogin" "$WORK/usr/lib/rustd/system/plasmalogin.service"
chmod 0755 "$WORK/usr/bin/plasmalogin"

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
grep -Fxq -- "--root=$WORK" "$RUSTCTL_ARGS" ||
    fail 'RustD was not given the target root'
grep -Fxq -- enable "$RUSTCTL_ARGS" ||
    fail 'RustD enable was not requested'
grep -Fxq -- plasmalogin.service "$RUSTCTL_ARGS" ||
    fail 'the installed Plasma login manager was not selected'
[[ -e "$RUSTCTL_MARKER" ]] || fail 'RustD control client was not executed'

install -d "$WORK/usr/lib/rustd" "$WORK/usr/lib/systemd/system"
mv "$WORK/usr/bin/rustctl" "$WORK/usr/lib/rustd/rustctl"
rm -f "$WORK/usr/bin/plasmalogin" "$WORK/usr/lib/rustd/system/plasmalogin.service" \
    "$RUSTCTL_MARKER" "$RUSTCTL_ARGS"
touch "$WORK/usr/bin/sddm" "$WORK/usr/lib/systemd/system/sddm.service"
chmod 0755 "$WORK/usr/bin/sddm"
ARACHOS_TARGET_ROOT="$WORK" "$HELPER"
[[ -L "$WORK/etc/rustd/system/sddm.service" ]] ||
    fail 'the compatibility display-manager unit was not bridged'
[[ "$(readlink "$WORK/etc/rustd/system/sddm.service")" == \
    /usr/lib/systemd/system/sddm.service ]] ||
    fail 'the display-manager bridge points at the wrong unit'
grep -Fxq -- sddm.service "$RUSTCTL_ARGS" ||
    fail 'the fallback RustD client did not select SDDM'

rm -f "$WORK/usr/bin/sddm" "$WORK/usr/lib/systemd/system/sddm.service" \
    "$RUSTCTL_MARKER" "$RUSTCTL_ARGS"
if ARACHOS_TARGET_ROOT="$WORK" "$HELPER" >"$WORK/no-manager.out" 2>"$WORK/no-manager.err"; then
    fail 'the helper succeeded without a display manager'
fi
grep -Fq 'no supported display manager was installed' "$WORK/no-manager.err" ||
    fail 'missing display-manager failure was not reported'

printf '%s\n' 'validated native RustD display-manager activation'

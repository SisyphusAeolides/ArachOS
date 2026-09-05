#!/usr/bin/env bash
# Exercise the Arach Kernel installer handoff in a disposable target root.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/archiso/airootfs/usr/sbin/arach-kernel-install"
WORK=$(mktemp -d -t arachos-kernel-install.XXXXXXXX)
TARGET="$WORK/target"
TOOLS="$WORK/tools"

fail() {
    printf 'ArachOS Arach Kernel install test: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    find "$WORK" -depth -delete 2>/dev/null || :
}
trap cleanup EXIT

[[ -x "$HELPER" ]] || fail "Arach Kernel installer helper is not executable: $HELPER"
for command in cc readelf sha256sum; do
    command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done

install -d "$TARGET/boot/grub" "$TARGET/boot/efi/EFI/BOOT" \
    "$TARGET/usr/share/arachos/arach-kernel" "$TOOLS"

# Build a loader-free ELF fixture. The helper's boot-format check is supplied
# by the fake grub-file below; the ELF checks remain the host readelf checks.
cat >"$WORK/fixture.c" <<'EOF'
void _start(void) {}
EOF
cc -static -nostdlib -Wl,-e,_start -o "$WORK/fixture" "$WORK/fixture.c" \
    || fail 'could not build the loader-free ELF fixture'
for artifact in arach rustd rustd-resolved; do
    cp "$WORK/fixture" "$TARGET/boot/$artifact"
done
printf '%s\n' loader >"$TARGET/boot/efi/EFI/BOOT/BOOTX64.EFI"

digest=$(sha256sum "$TARGET/boot/arach" | awk '{print $1}')
cat >"$TARGET/usr/share/arachos/arach-kernel/bundle-manifest.txt" <<EOF
artifact.arach.sha256=$digest
artifact.rustd.sha256=$digest
artifact.rustd-resolved.sha256=$digest
EOF
cat >"$TARGET/boot/grub/grub.cfg" <<'EOF'
menuentry 'ArachOS — Arach Kernel' {
    multiboot2 /boot/arach arachos=1 init=/usr/lib/rustd/rustd
    module2 /boot/rustd rustd
    module2 /boot/rustd-resolved rustd-resolved
}
EOF

cat >"$TOOLS/grub-file" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == --is-x86-multiboot2 ]]
EOF
cat >"$TOOLS/findmnt" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "${ARACHOS_TEST_FSTYPE:-ext4}"
EOF
cat >"$TOOLS/grub-mkconfig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == -o && -n "${2:-}" ]]
output=$2
install -d "$(dirname "$output")"
cat >"$output" <<'GRUB'
menuentry 'ArachOS — Arach Kernel' {
    multiboot2 /boot/arach arachos=1 init=/usr/lib/rustd/rustd
    module2 /boot/rustd rustd
    module2 /boot/rustd-resolved rustd-resolved
}
GRUB
EOF
chmod 0755 "$TOOLS/grub-file" "$TOOLS/findmnt" "$TOOLS/grub-mkconfig"
export PATH="$TOOLS:$PATH"

ARACHOS_TEST_FSTYPE=ext4 "$HELPER" \
    --root="$TARGET" --verify \
    --kernel=/boot/arach --rustd=/boot/rustd --resolved=/boot/rustd-resolved \
    || fail 'a valid target failed boot-contract verification'

ARACHOS_TEST_FSTYPE=ext4 "$HELPER" \
    --root="$TARGET" --install \
    --kernel=/boot/arach --rustd=/boot/rustd --resolved=/boot/rustd-resolved \
    || fail 'a valid persistent target failed installation'
[[ -x "$TARGET/etc/grub.d/40_arachos" ]] ||
    fail 'installation did not install the ArachOS GRUB generator'
grep -Fq 'multiboot2 /boot/arach' "$TARGET/etc/grub.d/40_arachos" ||
    fail 'the GRUB generator does not load Arach Kernel'
grep -Fq 'module2 /boot/rustd rustd' "$TARGET/boot/grub/grub.cfg" ||
    fail 'generated GRUB configuration does not load RustD'

if ARACHOS_TEST_FSTYPE=tmpfs "$HELPER" \
    --root="$TARGET" --install \
    --kernel=/boot/arach --rustd=/boot/rustd --resolved=/boot/rustd-resolved \
    >"$WORK/tmpfs.out" 2>"$WORK/tmpfs.err"; then
    fail 'installation succeeded on a tmpfs target'
fi
grep -Fq 'root is not persistent: tmpfs' "$WORK/tmpfs.err" ||
    fail 'tmpfs installation rejection was not reported'

printf '\220' | dd of="$TARGET/boot/rustd" bs=1 seek=64 conv=notrunc status=none
if "$HELPER" --root="$TARGET" --verify \
    --kernel=/boot/arach --rustd=/boot/rustd --resolved=/boot/rustd-resolved \
    >"$WORK/digest.out" 2>"$WORK/digest.err"; then
    fail 'verification succeeded after RustD digest tampering'
fi
grep -Fq 'digest mismatch for rustd' "$WORK/digest.err" ||
    fail 'digest tampering rejection was not reported'

printf '%s\n' 'validated Arach Kernel install, persistence, and digest gates'

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ISO=${ARACHOS_KERNEL_TEST_ISO:-$ROOT/build/kernel-bundle/ArachOS-1.0-1-Arach-Kernel-x86_64.iso}
MEMORY_MB=${ARACHOS_QEMU_MEMORY_MB:-2048}
TIMEOUT=${ARACHOS_QEMU_TIMEOUT:-90}
READY_PATTERN=${ARACHOS_QEMU_READY_PATTERN:-ArachOS: runtime ready}
OVMF_CODE=${ARACHOS_OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}
OVMF_VARS=${ARACHOS_OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}
WORK=$(mktemp -d -t arachos-qemu.XXXXXXXX)

fail() { printf 'ArachOS QEMU test: %s\n' "$*" >&2; exit 1; }
cleanup() {
  local status=$?
  find "$WORK" -depth -delete
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

command -v qemu-system-x86_64 >/dev/null || fail 'qemu-system-x86_64 is required'
[[ -s "$ISO" ]] || fail "kernel qualification ISO is missing: $ISO"

run_boot() {
  local firmware=$1
  local log="$WORK/$firmware.log"
  local -a firmware_args=()
  if [[ "$firmware" == uefi ]]; then
    [[ -r "$OVMF_CODE" && -r "$OVMF_VARS" ]] || fail 'OVMF firmware files are missing'
    cp "$OVMF_VARS" "$WORK/OVMF_VARS.fd"
    firmware_args=(
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
      -drive "if=pflash,format=raw,file=$WORK/OVMF_VARS.fd"
    )
  fi

  set +e
  timeout --signal=TERM --kill-after=5s "${TIMEOUT}s" \
    qemu-system-x86_64 -machine q35,accel=kvm:tcg -cpu max \
    -m "$MEMORY_MB" -smp 2 -cdrom "$ISO" -boot d \
    -display none -serial "file:$log" -monitor none -no-reboot \
    "${firmware_args[@]}"
  local status=$?
  set -e

  if rg -q 'ACPI MADT discovery failed|PID1 exit requested|panic|qualification failed' "$log"; then
    tail -80 "$log" >&2
    fail "$firmware boot reported a terminal failure"
  fi
  if ! rg -q -- "$READY_PATTERN" "$log"; then
    tail -80 "$log" >&2
    fail "$firmware boot did not report the runtime-ready marker (QEMU status $status)"
  fi
  printf 'ArachOS QEMU test: %s boot passed\n' "$firmware"
}

run_boot bios
run_boot uefi

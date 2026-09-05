#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ISO=${ARACHOS_KERNEL_TEST_ISO:-$ROOT/build/kernel-bundle/ArachOS-1.0-1-Arach-Kernel-x86_64.iso}
MEMORY_MB=${ARACHOS_QEMU_MEMORY_MB:-2048}
TIMEOUT=${ARACHOS_QEMU_TIMEOUT:-90}
READY_PATTERN=${ARACHOS_QEMU_READY_PATTERN:-ArachOS: runtime ready}
GPT_PATTERN=${ARACHOS_QEMU_GPT_PATTERN:-Arach: NVMe GPT metadata validated}
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
command -v qemu-img >/dev/null || fail 'qemu-img is required'
command -v python3 >/dev/null || fail 'python3 is required'
[[ -s "$ISO" ]] || fail "kernel qualification ISO is missing: $ISO"

NVME_DISK="$WORK/nvme-test.img"
qemu-img create -q -f raw "$NVME_DISK" 64M || fail 'could not create the temporary NVMe test disk'
python3 - "$NVME_DISK" <<'PY' || fail 'could not create the temporary GPT test disk'
import struct
import sys
import zlib

path = sys.argv[1]
sector_bytes = 512
sector_count = (64 * 1024 * 1024) // sector_bytes
entry_count = 4
entry_size = 128

entries = bytearray(sector_bytes)
entries[:16] = bytes([1]) * 16
entries[16:32] = bytes([2]) * 16
struct.pack_into('<QQ', entries, 32, 2048, 4095)
name = 'ArachOS QEMU'.encode('utf-16le')
entries[56:56 + len(name)] = name

header = bytearray(sector_bytes)
header[:8] = b'EFI PART'
struct.pack_into('<I', header, 8, 0x00010000)
struct.pack_into('<I', header, 12, 92)
struct.pack_into('<Q', header, 24, 1)
struct.pack_into('<Q', header, 32, sector_count - 1)
struct.pack_into('<Q', header, 40, 34)
struct.pack_into('<Q', header, 48, sector_count - 34)
header[56:72] = bytes([3]) * 16
struct.pack_into('<Q', header, 72, 2)
struct.pack_into('<I', header, 80, entry_count)
struct.pack_into('<I', header, 84, entry_size)
struct.pack_into('<I', header, 88, zlib.crc32(entries) & 0xffffffff)
struct.pack_into('<I', header, 16, zlib.crc32(header[:92]) & 0xffffffff)

with open(path, 'r+b') as image:
    image.seek(sector_bytes)
    image.write(header)
    image.seek(2 * sector_bytes)
    image.write(entries)
PY

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
    -drive "if=none,format=raw,id=arachos-nvme,file=$NVME_DISK" \
    -device "nvme,drive=arachos-nvme,serial=ARACHOS-QEMU" \
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
  if ! rg -q -- "$GPT_PATTERN" "$log"; then
    tail -80 "$log" >&2
    fail "$firmware boot did not validate the NVMe GPT metadata (QEMU status $status)"
  fi
  printf 'ArachOS QEMU test: %s boot passed\n' "$firmware"
}

run_boot bios
run_boot uefi

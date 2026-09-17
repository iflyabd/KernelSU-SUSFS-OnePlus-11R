#!/system/bin/sh
# tools/repack-test-boot.sh — LOCAL helper (run on device, NOT in CI).
# Builds a RAM-only test image for `fastboot boot` by swapping ONLY the kernel
# inside your own Magisk-patched boot image. Never flashes anything.
#
# Requires: magiskboot in PATH, stock + magisk backups present (defaults below).
# Usage: sh tools/repack-test-boot.sh [CI-Image] [magisk-boot] [out]
# Output DrainsTo: test-boot-ksu-11r.img  ->  Bugjaeger: fastboot boot <img>
set -eu
CI_IMAGE="${1:-$HOME/ksu-11r-CI/Image}"
MAGISK_BOOT="${2:-/sdcard/Download/magisk_patched-30700_Bjo66.img}"
OUT="${3:-$HOME/test-boot-ksu-11r.img}"
WORKDIR=/data/local/tmp/repack-ksu-11r

for f in "$CI_IMAGE" "$MAGISK_BOOT"; do
  [ -f "$f" ] || { echo "[!] missing: $f"; exit 1; }
done
command -v magiskboot >/dev/null || { echo "[!] magiskboot not in PATH"; exit 1; }

rm -rf "$WORKDIR" && mkdir -p "$WORKDIR" && cd "$WORKDIR"
magiskboot unpack -h "$MAGISK_BOOT" >/dev/null
cp "$CI_IMAGE" kernel
magiskboot repack "$MAGISK_BOOT" "$OUT" >/dev/null
echo "[+] test image: $OUT ($(du -h "$OUT" | cut -f1))"
echo "[+] Bugjaeger: fastboot boot $OUT   (RAM-only, slot _a, _b untouched)"
echo "[+] Validate: uname -r | lsusb 148f:7601 / 0bda:b812 | iw dev | hciconfig"

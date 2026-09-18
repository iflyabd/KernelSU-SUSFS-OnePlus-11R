#!/system/bin/sh
# tools/repack-test-boot.sh — LOCAL helper (run on device, NOT in CI).
# Builds a RAM-only test image for `fastboot boot` by swapping ONLY the kernel
# inside your own STOCK boot image. No Magisk involved (KSU lives in the
# kernel itself). Never flashes anything.
#
# Requires: magiskboot binary in PATH (repack tool only), stock backup present.
# Usage: sh tools/repack-test-boot.sh [CI-Image] [stock-boot] [out]
# Output: test-boot-ksu-11r.img  ->  Bugjaeger: fastboot boot <img>
set -eu
CI_IMAGE="${1:-$HOME/ksu-11r-CI/Image}"
STOCK_BOOT="${2:-/sdcard/Download/boot-stock-16.0.5.1002.img}"
OUT="${3:-$HOME/test-boot-ksu-11r.img}"
WORKDIR=/data/local/tmp/repack-ksu-11r

for f in "$CI_IMAGE" "$STOCK_BOOT"; do
  [ -f "$f" ] || { echo "[!] missing: $f"; exit 1; }
done
command -v magiskboot >/dev/null || { echo "[!] magiskboot not in PATH"; exit 1; }

rm -rf "$WORKDIR" && mkdir -p "$WORKDIR" && cd "$WORKDIR"
magiskboot unpack -h "$STOCK_BOOT" >/dev/null
cp "$CI_IMAGE" kernel
magiskboot repack "$STOCK_BOOT" "$OUT" >/dev/null
echo "[+] test image: $OUT ($(du -h "$OUT" | cut -f1))"
echo "[+] Bugjaeger: fastboot boot $OUT   (RAM-only, slot _a, _b untouched)"
echo "[+] Validate: uname -r | lsusb 148f:7601 / 0bda:b812 | iw dev | hciconfig"

#!/bin/bash
# build.sh — KernelSU-Next + SUSFS OnePlus 11R (SM8475) cloud build (GKI flow).
# Base: WildKernels oneplus_11r_w.xml sources @ pinned SHAs (see base-pin.env).
# Produces: Image/Image.gz, modules (mt7601u, btusb, bnep, 88x2bu),
#           AnyKernel3 flashable zip, Magisk driver zip.
# Usage: bash scripts/build.sh   (env: JOBS, WORKSPACE, KSU_REF, SUSFS_REF)
set -euo pipefail

ROOT="${WORKSPACE:-$PWD}"
# shellcheck disable=SC1091
source "$ROOT/base-pin.env"
KSU_REF="${KSU_REF:-$KSU_NEXT_REF}"
SUSFS_REF="${SUSFS_REF:-$SUSFS_SHA}"
SRC="$ROOT/src"
OUT="$ROOT/out"
KDIR="$SRC/common"
JOBS="${JOBS:-$(nproc)}"
LOG="$ROOT/build.log"

echo "[*] KSU-SUSFS OP11R build | jobs=$JOBS | root=$ROOT"
date -u | tee "$LOG"

# Heartbeat: links print nothing for minutes; prove alive + watch RAM.
heartbeat() { while sleep 120; do echo "[hb] $(date -u) mem=$(free -m | awk '/^Mem:/{print $3"/"$2"MB"}') disk_free=$(df -h "$ROOT" | awk 'END{print $4}')"; done; }
heartbeat & HB=$!
trap 'kill $HB 2>/dev/null || true' EXIT

export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_TRIPLE=aarch64-linux-gnu-
export CC="ccache clang"
export LD=ld.lld
export KCFLAGS="-w -Wno-error"
# lld has no legacy bcmp: host kconfig/conf needs this (proven on-device too).
export HOSTCFLAGS="-Dbcmp=memcmp -D__KBUILD_HOSTBUILD__ -include $ROOT/build-aux/host-compat.h"
export PYTHON=python3
export CCACHE_BASEDIR="$ROOT"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
mkdir -p "$ROOT/build-aux"
cp "$ROOT/build/host-compat.h" "$ROOT/build-aux/host-compat.h"

clone_sha() { # $1=url $2=sha $3=dest
  if [ -d "$3/.git" ]; then echo "[=] exists $3"; return; fi
  git init -q "$3" && git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
  echo "[+] cloned $3 @ $(git -C "$3" rev-parse --short HEAD)"
}

echo "[*] Cloning pinned sources..."
mkdir -p "$SRC"
clone_sha "$COMMON_REPO" "$COMMON_SHA" "$SRC/common"
clone_sha "$MODS_REPO" "$MODS_SHA" "$SRC/mods"
clone_sha "$AK3_REPO" "$AK3_SHA" "$SRC/AnyKernel3"

# --- KernelSU-Next (pinned ref, WildKernels convention) ---
echo "[*] Adding KernelSU-Next @ ${KSU_REF:0:8}..."
cd "$SRC"
curl --fail --location --proto '=https' -LSs "$KSU_NEXT_SETUP" | bash -s "$KSU_REF"
test -d "$SRC/KernelSU-Next/kernel" || { echo "[!] KernelSU-Next setup failed"; exit 1; }
echo "[+] KernelSU-Next present"

# --- SUSFS (pinned SHA, gki-android12-5.10) ---
echo "[*] Fetching SUSFS @ ${SUSFS_REF:0:8}..."
if [ ! -d "$SRC/susfs4ksu/.git" ]; then
  git init -q "$SRC/susfs4ksu" && git -C "$SRC/susfs4ksu" remote add origin "$SUSFS_REPO"
fi
git -C "$SRC/susfs4ksu" fetch -q --depth 1 origin "$SUSFS_REF"
git -C "$SRC/susfs4ksu" checkout -q FETCH_HEAD
echo "[*] Applying SUSFS GKI patch..."
cd "$KDIR"
patch -p1 --forward < "$SRC/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch" \
  || { echo "[!] susfs 50_add failed"; exit 1; }
cp "$SRC/susfs4ksu/kernel_patches/fs/"* "$KDIR/fs/"
cp "$SRC/susfs4ksu/kernel_patches/include/linux/"* "$KDIR/include/linux/"
echo "[*] Enabling SUSFS for KernelSU-Next..."
cd "$SRC/KernelSU-Next"
patch -p1 --forward < "$SRC/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" \
  || { echo "[!] susfs ksu glue failed"; exit 1; }
cd "$KDIR"

# --- OPLUS kernel-code fixes (apply only where the tree needs them) ---
if git -C "$KDIR" apply --check "$ROOT/patches/msm-kernel-fixes.patch" 2>/dev/null; then
  echo "[*] Applying OPLUS code fixes (vmscan/binder/thermal)..."
  git -C "$KDIR" apply "$ROOT/patches/msm-kernel-fixes.patch"
else
  echo "[=] OPLUS code fixes not applicable to common tree, skipping"
fi

# --- defconfig: stock GKI + KSU/SUSFS + monitor fragment ---
echo "[*] Configuring..."
mkdir -p "$OUT"
make O="$OUT" gki_defconfig 2>&1 | tail -n 2
cat "$ROOT/configs/monitor-wifi-bt.fragment" >> "$OUT/.config"
grep -q "config KSU$" "$KDIR/drivers/kernelsu/Kconfig" 2>/dev/null && echo "CONFIG_KSU=y" >> "$OUT/.config" || echo "CONFIG_KSU=y" >> "$OUT/.config"
if grep -rq "config KSU_SUSFS$" "$KDIR/fs/" 2>/dev/null; then echo "CONFIG_KSU_SUSFS=y" >> "$OUT/.config"; fi
make O="$OUT" olddefconfig 2>&1 | tee -a "$LOG" | tail -n 5
test "${PIPESTATUS[0]}" -eq 0 || { echo "[!] olddefconfig failed"; exit 1; }

echo "[*] Verifying config..."
for k in CONFIG_KSU CONFIG_MT7601U CONFIG_WLAN_VENDOR_MEDIATEK CONFIG_CFG80211 \
         CONFIG_MAC80211 CONFIG_BT_HCIBTUSB CONFIG_CFI_CLANG CONFIG_SECURITY_SELINUX; do
  grep -qE "^$k=(y|m)" "$OUT/.config" || { echo "[!] FAIL $k"; exit 1; }
  echo "  [OK] $(grep -E "^$k=" "$OUT/.config")"
done

# --- built-in firmware blobs (EXTRA_FIRMWARE_DIR=/lib/firmware => host path) ---
sudo mkdir -p /lib/firmware/rtl_bt
sudo cp "$ROOT/firmware/rtl_bt/"* /lib/firmware/rtl_bt/

# --- kernel + in-tree modules ---
echo "[*] Building Image.gz + modules..."
make O="$OUT" -j"$JOBS" Image.gz modules 2>&1 | tee -a "$LOG" | tail -n 3
test "${PIPESTATUS[0]}" -eq 0 || { echo "[!] kernel build failed"; exit 1; }
test -f "$OUT/arch/arm64/boot/Image.gz" || { echo "[!] Image.gz missing"; exit 1; }

# --- out-of-tree 88x2bu (DWA-185 0bda:b812, monitor-capable) ---
echo "[*] Building 88x2bu..."
cd "$ROOT/drivers/rtl88x2bu-cilynx"
make KSRC="$OUT" ARCH=arm64 R_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  LLVM=1 LLVM_IAS=1 KCFLAGS="-w -Wno-error" EXTRA_CFLAGS="-w" \
  CONFIG_WIFI_MONITOR=y -j"$JOBS" 2>&1 | tee -a "$LOG" | tail -n 5
test "${PIPESTATUS[0]}" -eq 0 || { echo "[!] 88x2bu build failed"; exit 1; }

# --- verify gates ---
echo "[*] Verify gates..."
MTKO=$(find "$OUT" -name "mt7601u.ko" | head -n 1)
test -n "$MTKO" || { echo "[!] mt7601u.ko missing"; exit 1; }
X2BU=$(find "$ROOT/drivers" -name "88x2bu.ko" | head -n 1)
test -n "$X2BU" || { echo "[!] 88x2bu.ko missing"; exit 1; }
modinfo "$X2BU" | grep -qi "B812" || echo "[WARN] b812 alias not seen"
grep -q "__cfi_check" "$OUT/Module.symvers" || echo "[WARN] no __cfi_check"
echo "[+] UTS: $(strings "$OUT/arch/arm64/boot/Image" | grep -m1 'Linux version 5.10' || echo '?')"
echo "[+] all gates passed"

# --- stage artifacts + AnyKernel3 zip + Magisk zip ---
echo "[*] Staging..."
ART="$ROOT/artifacts"; rm -rf "$ART"; mkdir -p "$ART/modules" "$ART/firmware"
cp "$OUT/arch/arm64/boot/Image" "$OUT/arch/arm64/boot/Image.gz" "$ART/"
cp "$MTKO" "$X2BU" "$ART/modules/"
for m in btusb.ko bnep.ko btintel.ko; do find "$OUT" -name "$m" -exec cp {} "$ART/modules/" \; 2>/dev/null || true; done
cp "$OUT/Module.symvers" "$OUT/.config" "$ART/"
cp "$ROOT/firmware/mt7601u.bin" "$ART/firmware/"; cp -r "$ROOT/firmware/rtl_bt" "$ART/firmware/"

AK3="$ART/AnyKernel3"; rm -rf "$AK3"; cp -r "$SRC/AnyKernel3" "$AK3"
rm -rf "$AK3/.git"
cp "$ART/Image" "$AK3/Image"
mkdir -p "$AK3/modules"
cp "$ART/modules/"*.ko "$AK3/modules/"
cat > "$AK3/modules/load-modules.sh" <<'EOF'
#!/system/bin/sh
# Installed by KernelSU-SUSFS-OnePlus-11R AK3: 3rd-party wifi/BT modules.
for m in /vendor/lib/modules/88x2bu.ko /vendor/lib/modules/mt7601u.ko /vendor/lib/modules/btusb.ko; do
  [ -f "$m" ] && insmod "$m" 2>/dev/null || true
done
EOF
( cd "$AK3" && zip -r -X "$ART/ksu-11r-ak3.zip" . -x ".*" > /dev/null )
ls -lh "$ART/ksu-11r-ak3.zip"

MOD="$ART/magisk"; rm -rf "$MOD"; mkdir -p "$MOD/vendor/lib/modules" "$MOD/lib/firmware"
cp -r "$ROOT/magisk-module/META-INF" "$ROOT/magisk-module/etc" \
    "$ROOT/magisk-module/module.prop" "$ROOT/magisk-module/post-finit.sh" "$MOD/"
cp "$ART/modules/"*.ko "$MOD/vendor/lib/modules/"
cp -r "$ART/firmware/"* "$MOD/lib/firmware/"
( cd "$MOD" && zip -r -X "$ART/magisk-ksu-11r-wifi-bt.zip" . -x ".*" > /dev/null )
ls -lh "$ART/magisk-ksu-11r-wifi-bt.zip"
echo "[+] staged at $ART"

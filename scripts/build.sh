#!/bin/bash
# build.sh — KernelSU-Next + SUSFS OnePlus 11R (SM8475) cloud build (GKI flow).
# Base: WildKernels oneplus_11r_w.xml sources @ pinned SHAs (see base-pin.env).
# Produces: Image/Image.gz, modules (mt7601u, btusb, bnep, 88x2bu),
#           AnyKernel3 flashable zip (drivers ride in AK3 modules/).
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
# Stock-exact UTS: setlocalversion appends "+" when $LOCALVERSION is unset and
# the tree is dirty (KSU/SUSFS always dirty it). Stock build env exports it
# (empty but set) — do the same so vermagic matches vendor_dlkm exactly.
export LOCALVERSION=
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

# --- vendor overlay (proven local layout): $ROOT/vendor + oplus links ---
# common Kconfig references kernel/oplus_cpu + drivers/soc/oplus/storage,
# which live in mods/vendor/oplus.
ln -sfn "$SRC/mods/vendor" "$ROOT/vendor"
mkdir -p "$KDIR/kernel" "$KDIR/drivers/soc/oplus"
ln -sfn ../../../vendor/oplus/kernel/cpu "$KDIR/kernel/oplus_cpu"
ln -sfn ../../../../../vendor/oplus/kernel/storage "$KDIR/drivers/soc/oplus/storage"
test -e "$KDIR/kernel/oplus_cpu/sched/Kconfig" || { echo "[!] overlay broken"; exit 1; }
echo "[+] overlay links OK"

# --- KernelSU (official tiann, pinned ref) ---
echo "[*] Adding KernelSU @ ${KSU_REF:0:8}..."
cd "$SRC"
curl --fail --location --proto '=https' -LSs "$KSU_SETUP" | bash -s "$KSU_REF"
test -d "$SRC/KernelSU/kernel" || { echo "[!] KernelSU setup failed"; exit 1; }
echo "[+] KernelSU present"

# --- SUSFS (pinned SHA, gki-android12-5.10) ---
echo "[*] Fetching SUSFS @ ${SUSFS_REF:0:8}..."
if [ ! -d "$SRC/susfs4ksu/.git" ]; then
  git init -q "$SRC/susfs4ksu" && git -C "$SRC/susfs4ksu" remote add origin "$SUSFS_REPO"
fi
git -C "$SRC/susfs4ksu" fetch -q --depth 1 origin "$SUSFS_REF"
git -C "$SRC/susfs4ksu" checkout -q FETCH_HEAD
SUSFS_VERSION=$(grep -m1 '#define SUSFS_VERSION' "$SRC/susfs4ksu/kernel_patches/include/linux/susfs.h" | awk -F'"' '{print $2}')
echo "[*] SUSFS version: $SUSFS_VERSION"
echo "[*] Applying SUSFS GKI patch..."
cd "$KDIR"
patch -p1 --forward < "$SRC/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch" \
  || { echo "[!] susfs 50_add failed"; exit 1; }
cp "$SRC/susfs4ksu/kernel_patches/fs/"* "$KDIR/fs/"
cp "$SRC/susfs4ksu/kernel_patches/include/linux/"* "$KDIR/include/linux/"
echo "[*] Enabling SUSFS for KernelSU (clean-apply verified)..."
cd "$SRC/KernelSU"
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

# --- Barrot/UGREEN RTL8761BU btusb quirk (0bda:8771, 5.10-adapted) ---
echo "[*] Applying btusb Barrot quirk..."
git -C "$KDIR" apply --check "$ROOT/patches/btusb-barrot-8771-quirk.patch" \
  || { echo "[!] btusb quirk check failed"; exit 1; }
git -C "$KDIR" apply "$ROOT/patches/btusb-barrot-8771-quirk.patch"
echo "[+] btusb quirk applied"

# --- defconfig: stock GKI + KSU/SUSFS + monitor fragment ---
echo "[*] Configuring..."
mkdir -p "$OUT"
make O="$OUT" gki_defconfig 2>&1 | tee -a "$LOG" | tail -n 5
test "${PIPESTATUS[0]}" -eq 0 || { echo "[!] gki_defconfig failed (see $LOG)"; exit 1; }
cat "$ROOT/configs/monitor-wifi-bt.fragment" >> "$OUT/.config"
echo "CONFIG_KSU=y" >> "$OUT/.config"
# Stock-exact UTS/vermagic so stock vendor_dlkm keeps loading (proven MSM flow):
# UTS becomes 5.10.236-android12-9-o-g74d132f4467a (no -dirty marker).
./scripts/config --file "$OUT/.config" --set-str CONFIG_LOCALVERSION "-android12-9-o-g74d132f4467a"
./scripts/config --file "$OUT/.config" --disable CONFIG_LOCALVERSION_AUTO
./scripts/config --file "$OUT/.config" --disable CONFIG_MODULE_SIG
./scripts/config --file "$OUT/.config" --disable CONFIG_MODULE_SIG_FORCE
./scripts/config --file "$OUT/.config" --disable CONFIG_MODULE_SIG_ALL
if grep -rq "config KSU_SUSFS$" "$KDIR/fs/" 2>/dev/null; then echo "CONFIG_KSU_SUSFS=y" >> "$OUT/.config"; fi
make O="$OUT" olddefconfig 2>&1 | tee -a "$LOG" | tail -n 5
test "${PIPESTATUS[0]}" -eq 0 || { echo "[!] olddefconfig failed"; exit 1; }

echo "[*] Verifying config..."
for k in CONFIG_KSU CONFIG_MT7601U CONFIG_WLAN_VENDOR_MEDIATEK CONFIG_CFG80211 \
         CONFIG_MAC80211 CONFIG_BT_HCIBTUSB CONFIG_CFI_CLANG CONFIG_SECURITY_SELINUX \
         CONFIG_PSTORE CONFIG_PSTORE_RAM; do
  grep -qE "^$k=(y|m)" "$OUT/.config" || { echo "[!] FAIL $k"; exit 1; }
  echo "  [OK] $(grep -E "^$k=" "$OUT/.config")"
done
for k in CONFIG_MODULE_SIG CONFIG_MODULE_SIG_FORCE CONFIG_MODULE_SIG_ALL; do
  grep -q "^$k=" "$OUT/.config" && { echo "[!] FAIL $k should be off"; exit 1; }
  echo "  [OK] $k off"
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
# Exact vermagic (anchored: a trailing "+" would break vendor_dlkm loading).
# NOTE: modinfo prints "vermagic:<spaces><value>" (colon, not equals).
modinfo "$MTKO" | grep -q "5.10.236-android12-9-o-g74d132f4467a SMP" \
  || { echo "[!] vermagic not stock-exact:"; modinfo "$MTKO" | grep vermagic; exit 1; }
echo "[+] vermagic stock-exact"
X2BU=$(find "$ROOT/drivers" -name "88x2bu.ko" | head -n 1)
test -n "$X2BU" || { echo "[!] 88x2bu.ko missing"; exit 1; }
modinfo "$X2BU" | grep -qi "B812" || echo "[WARN] b812 alias not seen"
grep -q "__cfi_check" "$OUT/Module.symvers" || echo "[WARN] no __cfi_check"
echo "[+] UTS: $(strings "$OUT/arch/arm64/boot/Image" | grep -m1 'Linux version 5.10' || echo '?')"
echo "[+] all gates passed"

# --- stage artifacts + AnyKernel3 zip ---
echo "[*] Staging..."
ART="$ROOT/artifacts"; rm -rf "$ART"; mkdir -p "$ART/modules" "$ART/firmware"
cp "$OUT/arch/arm64/boot/Image" "$OUT/arch/arm64/boot/Image.gz" "$ART/"
cp "$MTKO" "$X2BU" "$ART/modules/"
for m in btusb.ko bnep.ko btintel.ko; do find "$OUT" -name "$m" -exec cp {} "$ART/modules/" \; 2>/dev/null || true; done
cp "$OUT/Module.symvers" "$ART/"
cp "$OUT/.config" "$ART/final-.config"
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

echo "[+] staged at $ART"

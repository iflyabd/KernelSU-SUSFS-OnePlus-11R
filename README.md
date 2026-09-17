# KernelSU-SUSFS-OnePlus-11R

OnePlus 11R (CPH2487, SM8475 waipio) custom 5.10 GKI kernel:

- **Base:** WildKernels `oneplus_11r_w.xml` sources @ pinned SHAs (`base-pin.env`)
- **Root:** KernelSU-Next (pinned) + SUSFS `gki-android12-5.10` (pinned)
- **WiFi:** in-tree **MT7601U** (`148f:7601`) + out-of-tree **RTL8822BU**
  (DWA-185 `0bda:b812`, proven tree, `CONFIG_WIFI_MONITOR=y`)
- **BT:** in-tree `btusb` + `hci_uart_rtl` for RTL8761BU + firmware
- **Monitor mode:** `configs/monitor-wifi-bt.fragment` (cfg80211/mac80211,
  WEXT, NAT netfilter set) applied over stock `gki_defconfig`
- **Packaging:** AnyKernel3 flashable zip (Image + modules, stock dtbo kept)

## CI
Actions → `KSU-SUSFS OP11R boot build` → Run workflow (KSU/SUSFS refs
overridable, defaults pinned). Artifacts (30d): `ksu11r-ak3-image`,
`ksu11r-modules-magisk`, `ksu11r-build-log`.

## Test gate (mandatory — no flash before this passes)
1. `tools/repack-test-boot.sh` (on device) → `test-boot-ksu-11r.img`
2. Bugjaeger `fastboot boot` (RAM-only, slot `_a`; `_b` untouched fallback)
3. Validate: `uname -r`, `lsusb` (`148f:7601`/`0bda:b812`), `iw dev wlan1`,
   `hciconfig`, internal `wlan0` still up, no bootloop
4. Only then consider AK3 zip flash (keep
   `/sdcard/Download/boot-stock-16.0.5.1002.img` + magisk backup at hand)

## Notes
- Sources are never vendored (clean history, one commit): CI clones pins.
- `drivers/rtl8812au` (unused 103M variant) intentionally omitted.
- Pinned: KSU-Next `234f6e04` + SUSFS `ccb19186` (**v2.2.0**, proven combo
  per WildKernels fix-set history), AK3 `0b46673`,
  common `5b5ead1`, mods `46ba2a7`.

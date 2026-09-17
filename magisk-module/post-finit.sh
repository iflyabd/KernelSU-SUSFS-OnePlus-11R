#!/system/bin/sh
# ParrotOS Hardware Module - Post-Finit Script
# DWA-185 (RTL8822BU, 0bda:b812) + UGREEN CM748 (RTL8761BU) on OnePlus 11R
# Modules built from msm-kernel @ c6939a66, vermagic stock-exact.
MODDIR=/vendor/lib/modules

# USB + HCI device permissions
chmod 666 /dev/bus/usb/*/* 2>/dev/null || true
chmod 666 /dev/hci* 2>/dev/null || true
chmod 666 /sys/class/net/*/statistics/* 2>/dev/null || true

# IP forwarding + NAT (Parrot uplink via wlan0 or rmnet_data0)
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
iptables-legacy -t nat -A POSTROUTING -o wlan0 -j MASQUERADE 2>/dev/null || true
iptables-legacy -A FORWARD -i wlan0 -o rmnet_data0 -j ACCEPT 2>/dev/null || true

# Firmware (RTL8761B; placed by module into /lib/firmware/rtl_bt)
mkdir -p /lib/firmware/rtl_bt 2>/dev/null
chmod 644 /lib/firmware/rtl_bt/* 2>/dev/null || true

# Firmware MT7601U (148f:7601; module ships mt7601u.bin at lib/firmware root
# + mediatek/ for new paths; kernel requests "mt7601u.bin")
for _fw in /lib/firmware/mt7601u.bin /vendor/lib/firmware/mt7601u.bin; do
  [ -f "$_fw" ] && chmod 644 "$_fw" 2>/dev/null || true
done

# modprobe aliases (ko already carries usb:v0BDApB812d* alias; explicit file
# covers manual modprobe without depmod on Android)
mkdir -p /etc/modprobe.d /etc/modules-load.d 2>/dev/null
cat > /etc/modprobe.d/rtl88x2bu.conf << 'EOF'
alias usb:v0BDApB812d*dc*dsc*dp*ic* 88x2bu
options btusb enable_autosuspend=n
EOF

# Load order: btusb (CM748) then 88x2bu (DWA-185). bnep on demand for PAN.
# mt7601u (148f:7601) loads after full CFI Image + mt7601u.ko are installed;
# insmod is harmless no-op until then (module file absent).
insmod $MODDIR/btusb.ko 2>/dev/null || log -p i -t parrot-hw "btusb load rc=$?" 2>/dev/null || true
insmod $MODDIR/88x2bu.ko 2>/dev/null || log -p i -t parrot-hw "88x2bu load rc=$?" 2>/dev/null || true
insmod $MODDIR/mt7601u.ko 2>/dev/null || log -p i -t parrot-hw "mt7601u load rc=$?" 2>/dev/null || true

echo "btusb" > /etc/modules-load.d/bt-usb.conf 2>/dev/null || true
echo "88x2bu" > /etc/modules-load.d/realtek-wifi.conf 2>/dev/null || true
echo "mt7601u" > /etc/modules-load.d/mtk-wifi.conf 2>/dev/null || true

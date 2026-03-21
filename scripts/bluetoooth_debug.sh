#!/usr/bin/env bash
# bluetooth_enhanced_debug.sh - Enhanced debug for Bluetooth scanning
set -e

echo "╔════════════════════════════════════════╗"
echo "║    Enhanced Bluetooth Debug          ║"
echo "╚════════════════════════════════════════╝"
echo ""

TMPFILE="$(mktemp)"
SCAN_TIME=15

echo "Checking Bluetooth service status..."
echo "════════════════════════════════════════"
sudo systemctl status bluetooth --no-pager | head -10
echo ""

echo "Checking Bluetooth adapter power..."
echo "════════════════════════════════════════"
sudo systemctl start bluetooth 2>/dev/null || true
sleep 1
echo -e "power on\nshow\nquit" | bluetoothctl | grep -E "(Powered|Discovering|Controller)"
echo ""

echo "Getting controller MAC address..."
echo "════════════════════════════════════════"
CONTROLLER_MAC=$(bluetoothctl show | grep -oE "Controller [0-9A-Fa-f:]{17}" | awk '{print $2}' | head -1)
echo "Controller MAC: $CONTROLLER_MAC"
echo ""

echo "Checking for nearby Bluetooth devices with hcitool..."
echo "════════════════════════════════════════"
if command -v hcitool >/dev/null 2>&1; then
    echo "Running: sudo hcitool scan --flush"
    timeout 30 sudo hcitool scan --flush 2>&1 || echo "hcitool scan completed/timed out"
else
    echo "hcitool not found (install bluez-utils)"
fi
echo ""

echo "Running extended bluetoothctl scan ($SCAN_TIME seconds)..."
echo "════════════════════════════════════════"
echo "Starting scan with real-time output..."
{
    echo "power on"
    echo "scan on"
    sleep "$SCAN_TIME"
    echo "scan off"
    echo "devices"
    sleep 1
    echo "quit"
} | bluetoothctl 2>&1 | tee "$TMPFILE"

echo ""
echo "════════════════════════════════════════"
echo ""

echo "Analyzing scan results..."
echo "════════════════════════════════════════"
echo ""

echo "Total lines in output: $(wc -l < "$TMPFILE")"
echo ""

echo "Lines with 'Device' keyword:"
grep -c -i "device" "$TMPFILE" || echo "0"
echo ""

echo "Lines matching [NEW] Device pattern:"
grep -c "^\[NEW\] Device" "$TMPFILE" || echo "0"
echo ""

echo "Lines matching [CHG] Device pattern:"
grep -c "^\[CHG\] Device" "$TMPFILE" || echo "0"
echo ""

echo "Unique MAC addresses found:"
grep -oE "[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}" "$TMPFILE" | sort -u
echo ""

echo "Extracting [NEW] Device entries..."
echo "════════════════════════════════════════"
if grep -q "^\[NEW\] Device" "$TMPFILE"; then
    grep "^\[NEW\] Device" "$TMPFILE" | while read -r line; do
        mac=$(echo "$line" | grep -oE "[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}" | head -1)
        name=$(echo "$line" | sed -e 's/^\[NEW\] Device //' -e "s/^[0-9A-Fa-f:]\+ //" | xargs)
        
        if [[ "$mac" == "$CONTROLLER_MAC" ]]; then
            echo "  [CONTROLLER] $mac - $name (excluded)"
        else
            echo "  [DEVICE] $mac - $name"
        fi
    done
else
    echo "No [NEW] Device entries found"
fi
echo ""

echo "Checking if devices command shows anything..."
echo "════════════════════════════════════════"
echo "devices" | bluetoothctl 2>&1 | grep "Device" || echo "No devices in bluetoothctl cache"
echo ""

echo "Checking for pairable/discoverable devices..."
echo "════════════════════════════════════════"
{
    echo "power on"
    echo "pairable on"
    echo "discoverable on"
    sleep 2
    echo "scan on"
    sleep 5
    echo "devices"
    echo "scan off"
    echo "quit"
} | bluetoothctl 2>&1 | grep "Device" || echo "No devices found"
echo ""

echo "RF kill status..."
echo "════════════════════════════════════════"
if command -v rfkill >/dev/null 2>&1; then
    sudo rfkill list bluetooth
else
    echo "rfkill not available"
fi
echo ""

rm -f "$TMPFILE"

echo "════════════════════════════════════════"
echo "Enhanced debug complete!"
echo ""
echo "Troubleshooting tips:"
echo "  1. Make sure Bluetooth devices nearby are in pairing mode"
echo "  2. Check if Bluetooth is blocked by rfkill"
echo "  3. Try: sudo systemctl restart bluetooth"
echo "  4. Verify devices are in range (usually <10m)"
echo "  5. Some devices only broadcast when actively used"
echo "════════════════════════════════════════"

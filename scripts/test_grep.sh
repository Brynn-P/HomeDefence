#!/usr/bin/env bash
# test_grep.sh - Test grep patterns on sample bluetoothctl output

cat > /tmp/test_bt_output.txt << 'EOF'
[bluetooth]# power on
[bluetooth]# scan on
Agent registered
Changing power on succeeded
[CHG] Controller E4:5F:01:80:6F:32 Pairable: yes
Discovery started
[CHG] Controller E4:5F:01:80:6F:32 Discovering: yes
[NEW] Device 7C:78:B2:70:81:5A wyze_hub
[NEW] Device C8:84:47:4A:74:6D YamahaAV
[NEW] Device C5:0C:10:D5:75:44 M203T_4475d5
[CHG] Device 7C:78:B2:70:81:5A RSSI: -28
[CHG] Device C8:84:47:4A:74:6D RSSI: -80
[NEW] Device 8C:90:2D:83:6C:6E _hsxBm
[bluetooth]# scan off
[bluetooth]# devices
Device 7C:78:B2:70:81:5A wyze_hub
Device C8:84:47:4A:74:6D YamahaAV
Device C5:0C:10:D5:75:44 M203T_4475d5
Device 8C:90:2D:83:6C:6E _hsxBm
[CHG] Device 8C:90:2D:83:6C:6E RSSI is nil
[CHG] Device C5:0C:10:D5:75:44 TxPower is nil
[CHG] Device C5:0C:10:D5:75:44 RSSI is nil
[CHG] Device C8:84:47:4A:74:6D RSSI is nil
[CHG] Device 7C:78:B2:70:81:5A RSSI is nil
[CHG] Controller E4:5F:01:80:6F:32 Discovering: no
Discovery stopped
[bluetooth]# quit
EOF

echo "Test file created at /tmp/test_bt_output.txt"
echo ""

echo "1️⃣  Testing: grep '\[NEW\] Device'"
echo "════════════════════════════════════════"
grep '\[NEW\] Device' /tmp/test_bt_output.txt
echo "Result: $?"
echo ""

echo "2️⃣  Testing: grep -F '[NEW] Device'"
echo "════════════════════════════════════════"
grep -F '[NEW] Device' /tmp/test_bt_output.txt
echo "Result: $?"
echo ""

echo "3️⃣  Testing: grep -E '\[NEW\] Device'"
echo "════════════════════════════════════════"
grep -E '\[NEW\] Device' /tmp/test_bt_output.txt
echo "Result: $?"
echo ""

echo "4️⃣  Testing: grep 'Device' | grep MAC pattern"
echo "════════════════════════════════════════"
grep -F "Device" /tmp/test_bt_output.txt | grep -E "[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:"
echo "Result: $?"
echo ""

echo "5️⃣  Testing sed extraction on sample line"
echo "════════════════════════════════════════"
TEST_LINE="[NEW] Device 7C:78:B2:70:81:5A wyze_hub"
echo "Input: $TEST_LINE"
echo "MAC: $(echo "$TEST_LINE" | grep -oE "[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}")"
echo "Name: $(echo "$TEST_LINE" | sed -E 's/.*Device [0-9A-Fa-f:]{17} //')"
echo ""

rm /tmp/test_bt_output.txt
echo "✅ Test complete!"

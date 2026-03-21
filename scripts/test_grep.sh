#!/usr/bin/env bash
# test_grep.sh - Test grep patterns on sample bluetoothctl output

cat > /tmp/test_bt_output.txt << 'EOF'
[bluetooth]# power on
[bluetooth]# scan on
Agent registered
Changing power on succeeded
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

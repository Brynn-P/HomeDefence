#!/usr/bin/env bash
#bluetooth.sh
# HomeDefence Bluetooth Scanner
# Scans for nearby Bluetooth devices and logs them
# Identifies known vs unknown devices based on configuration

# Exit on error, undefined variables, and pipe failures
set -Eeuo pipefail

# ============================================================================
# CONFIGURATION - Paths and directories
# ============================================================================
PROJECT_ROOT="/homedefence"
LOGROOT="$PROJECT_ROOT/logs"
OUTDIR="$LOGROOT/bluetooth"
mkdir -p "$OUTDIR"

# File paths for logs and configuration
DEVICE_LOG="$OUTDIR/device_log.csv"              # Historical log of all devices ever seen
CURRENT_SCAN_LOG="$OUTDIR/current_scan.csv"      # ONLY devices from THIS scan (sent to Discord)
KNOWN_DEVICES_FILE="$PROJECT_ROOT/config/known_bluetooth.json"  # User's known devices
DEVICE_STATUS_FILE="$OUTDIR/device_status.json"  # Current online/offline status
BT_EVENTS_LOG="$OUTDIR/bluetooth_events.log"     # Event log for new devices

# Initialize CSV files with headers if they don't exist
[[ -f "$DEVICE_LOG" ]] || echo "timestamp,mac_address,device_name,device_class,signal_strength,status" > "$DEVICE_LOG"
mkdir -p "$(dirname "$KNOWN_DEVICES_FILE")"

# Generate timestamps for this scan
TS="$(date +%Y%m%d_%H%M%S)"           # Compact timestamp for CSV (e.g., 20240115_143022)
HUMAN_TS="$(date '+%Y-%m-%d %H:%M:%S')"  # Human-readable timestamp for logs

# Scan duration in seconds (how long to search for devices)
SCAN_DURATION=30

# ============================================================================
# KNOWN BLUETOOTH DEVICES MANAGEMENT
# ============================================================================

create_known_bluetooth_template() {
    # Create a template JSON file for user to configure their known Bluetooth devices
    # Returns:
    #   0 if template already exists
    #   1 if template was just created (user needs to edit it)
    
    if [[ ! -f "$KNOWN_DEVICES_FILE" ]]; then
        echo "Creating known Bluetooth devices template..."
        cat > "$KNOWN_DEVICES_FILE" << 'EOF'
{
  "devices": [
    {
      "name": "iPhone",
      "person": "person1",
      "mac_address": ["00:11:22:33:44:55"],
      "device_type": "phone",
      "welcome_message": "person1 is home! (Phone detected)"
    },
    {
      "name": "Headphones",
      "person": "person2",
      "mac_address": ["AA:BB:CC:DD:EE:FF"],
      "device_type": "audio",
      "welcome_message": "Alex's headphones detected (Audio device)"
    },
    {
      "name": "Smart Watch",
      "person": "Family",
      "mac_address": ["11:22:33:44:55:66"],
      "device_type": "wearable",
      "welcome_message": "Smart watch detected (Wearable)"
    }
  ]
}
EOF
        echo "SUCCESS: Template created! Edit $KNOWN_DEVICES_FILE with your devices"
        return 1
    fi
    return 0
}


get_bluetooth_info() {
    # Look up a Bluetooth MAC address in the known devices file
    # Args:
    #   $1 - MAC address to lookup
    # Returns:
    #   Pipe-separated string: device_name|welcome_message|is_known
    #   Example: "iPhone|Person1 is home!|true"
    
    local mac="$1"
    local device_name="Unknown"
    local welcome_msg=""
    local is_known="false"

    if [[ -f "$KNOWN_DEVICES_FILE" ]]; then
        # Use Python to parse JSON and lookup MAC address
        local bt_info
        bt_info=$(python3 -c "
import json, sys
try:
    with open('$KNOWN_DEVICES_FILE', 'r') as f:
        data = json.load(f)

    # Convert MAC to uppercase for case-insensitive comparison
    mac = '$mac'.upper()

    # Search through all known devices
    for device in data.get('devices', []):
        # Get list of MAC addresses for this device (uppercase)
        mac_list = [m.upper() for m in device.get('mac_address', [])]

        # Check if our MAC matches any in the list
        if mac in mac_list:
            print(f\"{device.get('name', 'Unknown')}|{device.get('welcome_message', '')}|true\")
            sys.exit(0)
    
    # MAC not found in known devices
    print('Unknown||false')
except Exception as e:
    # Error reading file - treat as unknown
    print('Unknown||false')
" 2>/dev/null)

        # Parse the pipe-separated result
        IFS='|' read -r device_name welcome_msg is_known <<< "$bt_info"
    fi

    echo "$device_name|$welcome_msg|$is_known"
}


log_bluetooth_event() {
    # Log a Bluetooth event to the events log file
    # Args:
    #   $1 - Message to log
    
    local message="$1"
    printf "[%s] %s\n" "$HUMAN_TS" "$message" >> "$BT_EVENTS_LOG"
    printf "[BT EVENT] %s\n" "$message"
}

# ============================================================================
# BLUETOOTH HARDWARE CONTROL
# ============================================================================

ensure_bluetooth_enabled() {
    # Ensure Bluetooth adapter is powered on and discoverable
    # Returns:
    #   0 if successful
    #   1 if failed
    
    echo "Checking Bluetooth adapter..."

    # Check if bluetoothctl command exists
    if ! command -v bluetoothctl >/dev/null 2>&1; then
        echo "ERROR: bluetoothctl not found. Install bluez package."
        return 1
    fi

    # Unblock Bluetooth radio if rfkill is available
    if command -v rfkill >/dev/null 2>&1; then
        sudo rfkill unblock bluetooth 2>/dev/null || true
    fi

    # Start Bluetooth service
    sudo systemctl start bluetooth 2>/dev/null || true
    sleep 1

    # Power on the adapter and make it discoverable
    {
        echo "power on"           # Turn on Bluetooth radio
        echo "pairable on"        # Allow pairing
        echo "discoverable on"    # Make visible to other devices
        echo "quit"
    } | bluetoothctl >/dev/null 2>&1 || true
    sleep 2

    # Verify adapter is powered on
    if bluetoothctl show | grep -q "Powered: yes"; then
        echo "SUCCESS: Bluetooth adapter enabled"
        return 0
    else
        echo "ERROR: Failed to enable Bluetooth adapter"
        bluetoothctl show
        return 1
    fi
}

# ============================================================================
# BLUETOOTH DEVICE SCANNING
# ============================================================================

scan_bluetooth_devices() {
    # Scan for Bluetooth devices using bluetoothctl and hcitool
    # Processes results and updates both current_scan.csv and device_log.csv
    
    echo "Scanning for Bluetooth devices for $SCAN_DURATION seconds..."
    echo "   (Logging all devices, reporting only current scan)"
    echo ""

    TMPFILE="$(mktemp)"
    
    # Clear the current scan log (this will ONLY contain devices found NOW)
    echo "timestamp,mac_address,device_name,device_class,signal_strength,status" > "$CURRENT_SCAN_LOG"

    # Get our own Bluetooth adapter MAC to exclude it from results
    CONTROLLER_MAC=$(bluetoothctl show | grep -oE "Controller [0-9A-Fa-f:]{17}" | awk '{print $2}' | head -1)
    echo "Controller MAC: $CONTROLLER_MAC"
    echo ""

    # ========================================================================
    # RUN BLUETOOTH DISCOVERY SCAN
    # ========================================================================
    echo "Running Bluetooth discovery..."
    {
        echo "power on"
        echo "scan on"                    # Start scanning
        sleep "$SCAN_DURATION"            # Wait for scan duration
        echo "scan off"                   # Stop scanning
        echo "devices"                    # List all discovered devices
        sleep 1
        echo "quit"
    } | bluetoothctl > "$TMPFILE" 2>&1

    # Also try hcitool if available (provides additional scan capability)
    if command -v hcitool >/dev/null 2>&1; then
        echo "Running hcitool scan..."
        timeout 15 sudo hcitool scan --flush 2>/dev/null | tail -n +2 >> "$TMPFILE" || true
    fi

    # ========================================================================
    # DEBUG OUTPUT - Show what was captured
    # ========================================================================
    echo ""
    echo "DEBUG: Raw bluetoothctl output:"
    echo "========================================"
    cat "$TMPFILE"
    echo "========================================"
    echo ""
    
    echo "DEBUG: Searching for Device patterns..."
    echo "Lines containing 'Device' and MAC address:"
    grep -i "Device" "$TMPFILE" | grep -E "[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:" || echo "No device+MAC lines found"
    echo ""

    # ========================================================================
    # PROCESS DISCOVERED DEVICES
    # ========================================================================
    local PROCESSED=0
    local KNOWN_COUNT=0
    local UNKNOWN_COUNT=0

    echo "========================================"
    echo "Processing Devices..."
    echo "========================================"
    echo ""

    # Use associative array to track already-processed MACs (avoid duplicates)
    declare -A seen_devices

    # FIXED: Parse all lines containing "Device" followed by a MAC address
    # This catches [NEW] Device, [CHG] Device, and plain Device lines
    while IFS= read -r line; do
        # Extract MAC address from line using regex
        mac=$(echo "$line" | grep -oE "[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}" | head -1)
        
        # Skip if no MAC found or if it's our own controller
        [[ -z "$mac" ]] && continue
        [[ "$mac" == "$CONTROLLER_MAC" ]] && continue
        
        # Skip if we've already processed this MAC (avoid duplicates)
        if [[ -v seen_devices[$mac] ]]; then
            continue
        fi
        seen_devices[$mac]=1
        
        # ====================================================================
        # EXTRACT DEVICE NAME
        # FIXED: Handle all formats - works with [NEW], [CHG], and plain Device lines
        # Strip apostrophes to avoid shell quoting issues
        # ====================================================================
        # Extract everything after "Device MAC_ADDRESS "
        # This handles: "[NEW] Device MAC NAME", "[CHG] Device MAC ...", and "Device MAC NAME"
        name=$(echo "$line" | sed -E 's/.*Device [0-9A-Fa-f:]{17} //' | tr -d "'" | xargs)
        
        # Default to "Unknown" if no name found or name is same as MAC
        [[ -z "$name" || "$name" == "$mac" ]] && name="Unknown"
        
        PROCESSED=$((PROCESSED + 1))

        # ====================================================================
        # GET ADDITIONAL DEVICE INFO (class, signal strength)
        # ====================================================================
        device_class="Unknown"
        signal_strength="N/A"

        # Query bluetoothctl for detailed device info
        device_info=$(echo -e "info $mac\nquit" | bluetoothctl 2>/dev/null)
        
        # Extract device class if available
        if echo "$device_info" | grep -q "Class:"; then
            device_class=$(echo "$device_info" | grep "Class:" | awk '{print $2}')
        fi
        
        # Extract signal strength (RSSI) if available
        if echo "$device_info" | grep -q "RSSI:"; then
            signal_strength=$(echo "$device_info" | grep "RSSI:" | awk '{print $2}')
        fi

        # ====================================================================
        # CHECK IF DEVICE IS KNOWN
        # ====================================================================
        bt_info=$(get_bluetooth_info "$mac")
        IFS='|' read -r known_name welcome_msg is_known <<< "$bt_info"

        if [[ "$is_known" == "true" ]]; then
            display_name="$known_name"
            status="known"
            KNOWN_COUNT=$((KNOWN_COUNT + 1))
            device_status="[KNOWN DEVICE]"
        else
            display_name="$name"
            status="unknown"
            UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
            device_status="[UNKNOWN DEVICE]"
        fi

        # ====================================================================
        # DISPLAY DEVICE INFO TO CONSOLE
        # ====================================================================
        echo "+-------------------------------------+"
        echo "| Bluetooth Device #$PROCESSED"
        echo "+-------------------------------------+"
        echo ""
        echo "  $device_status"
        echo "  ----------------------------------"
        echo "  Device Name:  $display_name"
        echo "  MAC Address:  $mac"
        echo "  Device Class: $device_class"
        echo "  Signal:       $signal_strength"
        echo "  Status:       $status"
        echo ""

        # ====================================================================
        # PREPARE SAFE CSV VALUES (escape quotes and commas)
        # ====================================================================
        # CSV-safe name: replace quotes with doubled quotes, handle commas
        csv_safe_name=$(echo "$display_name" | sed 's/"/""/g')
        
        # ====================================================================
        # WRITE TO CURRENT_SCAN.CSV (devices present NOW)
        # This is what gets sent to Discord!
        # ====================================================================
        echo "$TS,$mac,\"$csv_safe_name\",$device_class,$signal_strength,$status" >> "$CURRENT_SCAN_LOG"

        # ====================================================================
        # UPDATE HISTORICAL DEVICE_LOG.CSV
        # ====================================================================
        if grep -q ",$mac," "$DEVICE_LOG" 2>/dev/null; then
            # Device exists in historical log - update its entry
            echo "  Updating existing device in history"
            
            # Use Python for safe CSV update (handles all special characters)
            python3 -c "
import csv
import sys

mac = '''$mac'''
ts = '''$TS'''
name = '''$display_name'''
device_class = '''$device_class'''
signal = '''$signal_strength'''
status = '''$status'''

# Read existing CSV
rows = []
with open('$DEVICE_LOG', 'r') as f:
    reader = csv.reader(f)
    for row in reader:
        if len(row) >= 2 and row[1] == mac:
            # Update this row
            rows.append([ts, mac, name, device_class, signal, status])
        else:
            rows.append(row)

# Write back
with open('$DEVICE_LOG', 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerows(rows)
"
            
            # Note: Home event logic could be added here
            # Check if device was previously offline and is now back online
            if [[ "$is_known" == "true" && -n "$welcome_msg" ]]; then
                # Placeholder for future: detect when known device reconnects after being offline
                :
            fi
        else
            # New device - add to historical log
            echo "  New device - adding to history"
            # Use Python for safe CSV append
            python3 -c "
import csv

with open('$DEVICE_LOG', 'a', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['''$TS''', '''$mac''', '''$display_name''', '''$device_class''', '''$signal_strength''', '''$status'''])
"
            
            # Log event for new UNKNOWN devices (security alert)
            if [[ "$is_known" == "false" ]]; then
                printf "[%s] WARNING: NEW Bluetooth device first detected: %s (%s)\n" "$HUMAN_TS" "$display_name" "$mac" >> "$BT_EVENTS_LOG"
                printf "[BT EVENT] WARNING: NEW Bluetooth device first detected: %s (%s)\n" "$display_name" "$mac"
            fi
        fi
    done < <(grep -i "Device" "$TMPFILE" | grep -E "[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:")

    # Clean up temp file
    rm -f "$TMPFILE"

    # ========================================================================
    # PRINT SCAN SUMMARY
    # ========================================================================
    echo "========================================"
    echo ""
    echo "Current Scan Summary:"
    echo "  Devices Found:    $PROCESSED"
    echo "  Known Devices:    $KNOWN_COUNT [KNOWN]"
    echo "  Unknown Devices:  $UNKNOWN_COUNT [WARNING]"
    echo ""
    
    # Show total historical device count
    if [[ -f "$DEVICE_LOG" ]]; then
        TOTAL_HISTORICAL=$(( $(wc -l < "$DEVICE_LOG") - 1 ))
        echo "Historical Total: $TOTAL_HISTORICAL devices logged"
        echo ""
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
echo ""
echo "========================================"
echo "   HomeDefence Bluetooth Scanner"
echo "========================================"
echo ""

# Create template if needed
if ! create_known_bluetooth_template; then
    echo "[!] Please configure your known Bluetooth devices and run again"
    exit 0
fi

# Ensure Bluetooth is enabled
if ! ensure_bluetooth_enabled; then
    echo "ERROR: Failed to enable Bluetooth. Check your adapter."
    exit 1
fi

# Run the scan
scan_bluetooth_devices

# ============================================================================
# SEND DISCORD ALERT
# ============================================================================
# Send ONLY current scan results (from current_scan.csv) to Discord
echo "Sending Discord alert to Bluetooth channel..."
echo "   (Sending ONLY devices from this scan)"
if python3 "$PROJECT_ROOT/scripts/dis_alert.py" bluetooth; then
    echo "SUCCESS: Discord alert sent"
else
    echo "WARNING: Discord alert failed (check dis_alert.py)"
fi

# ============================================================================
# FINAL SUMMARY AND REPORTS
# ============================================================================
echo "========================================"
echo ""
echo "========================================"
echo "    BLUETOOTH SCAN COMPLETE"
echo "========================================"
echo ""
echo "Scan Completed: $HUMAN_TS"
echo ""

# Display current scan results
if [[ -f "$CURRENT_SCAN_LOG" ]]; then
    CURRENT_COUNT=$(( $(wc -l < "$CURRENT_SCAN_LOG") - 1 ))
    if [[ $CURRENT_COUNT -gt 0 ]]; then
        echo "========================================"
        echo "Current Scan Results ($CURRENT_COUNT devices)"
        echo "========================================"
        echo ""
        tail -$((CURRENT_COUNT + 1)) "$CURRENT_SCAN_LOG" | column -t -s',' 2>/dev/null
        echo ""
    fi
fi

# Display historical log (last 10 entries)
if [[ -f "$DEVICE_LOG" ]]; then
    echo "========================================"
    echo "All Historical Devices (Last 10)"
    echo "========================================"
    echo ""
    tail -11 "$DEVICE_LOG" | column -t -s',' 2>/dev/null
    echo ""
fi

# Display recent events
if [[ -f "$BT_EVENTS_LOG" ]] && [[ -s "$BT_EVENTS_LOG" ]]; then
    echo "========================================"
    echo "Recent Bluetooth Events"
    echo "========================================"
    echo ""
    tail -5 "$BT_EVENTS_LOG" 2>/dev/null
    echo ""
fi

echo "========================================"
echo "SUCCESS: Bluetooth Scan Complete!"
echo "========================================"
echo ""

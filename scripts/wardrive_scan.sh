#!/usr/bin/env bash
#wardrive_scan.sh
"""
HomeDefence Wardrive Scanner
Scans for WiFi networks using monitor mode
Detects SSIDs, BSSIDs, encryption, and signal strength
Identifies known vs unknown networks
"""

# Exit on error, undefined variables, and pipe failures
set -Eeuo pipefail

# ============================================================================
# CONFIGURATION - Paths and directories
# ============================================================================
PROJECT_ROOT="/homedefence"
LOGROOT="$PROJECT_ROOT/logs"
OUTDIR="$LOGROOT/wardrive"
mkdir -p "$OUTDIR"

# File paths for logs and configuration
DEVICE_LOG="$OUTDIR/device_log.csv"                    # Historical log of all WiFi networks
KNOWN_DEVICES_FILE="$PROJECT_ROOT/config/known_wifi.json"  # Known WiFi networks config
WIFI_EVENTS_LOG="$OUTDIR/wifi_events.log"              # Event log for WiFi detections

# Initialize CSV with header if it doesn't exist
[[ -f "$DEVICE_LOG" ]] || echo "timestamp,bssid,ssid,channel,signal_strength,encryption,status" > "$DEVICE_LOG"
mkdir -p "$(dirname "$KNOWN_DEVICES_FILE")"

# Generate timestamps for this scan
TS="$(date +%Y%m%d_%H%M%S)"              # Compact timestamp (e.g., 20240115_143022)
HUMAN_TS="$(date '+%Y-%m-%d %H:%M:%S')"  # Human-readable timestamp

# Wireless interface configuration
WIRELESS_IFACE="wlan0"    # Your wireless interface name
MONITOR_IFACE="wlan0"     # Interface name when in monitor mode

# Scan duration in seconds (how long to capture WiFi packets)
SCAN_DURATION=15

# ============================================================================
# KNOWN WIFI NETWORKS MANAGEMENT
# ============================================================================

create_known_wifi_template() {
    """
    Create a template JSON file for user to configure their known WiFi networks
    Returns:
        0 if template already exists
        1 if template was just created (user needs to edit it)
    """
    if [[ ! -f "$KNOWN_DEVICES_FILE" ]]; then
        echo "Creating known WiFi devices template..."
        cat > "$KNOWN_DEVICES_FILE" << 'EOF'
{
  "networks": [
    {
      "name": "Home WiFi",
      "ssid": "The_Slum5",
      "bssid": ["2C:7E:81:F7:EB:8E"],
      "type": "trusted",
      "alert_message": "Home WiFi detected (Network online)"
    }
  ]
}
EOF
        echo "SUCCESS: Template created! Edit $KNOWN_DEVICES_FILE with your networks"
        return 1
    fi
    return 0
}


get_wifi_info() {
    """
    Look up a WiFi network in the known networks configuration
    Matches by BSSID or SSID
    Args:
        $1 - BSSID (MAC address of access point)
        $2 - SSID (network name)
    Returns:
        Pipe-separated string: network_name|is_known
        Example: "Home WiFi|true"
    """
    local bssid="$1"
    local ssid="$2"
    local network_name="Unknown"
    local is_known="false"
    
    if [[ -f "$KNOWN_DEVICES_FILE" ]]; then
        # Use Python to parse JSON and lookup network
        local wifi_info=$(python3 -c "
import json, sys
try:
    with open('$KNOWN_DEVICES_FILE', 'r') as f:
        data = json.load(f)
    
    # Convert BSSID to uppercase for comparison
    bssid = '$bssid'.upper()
    ssid = '$ssid'
    
    # Search through all known networks
    for network in data.get('networks', []):
        # Get list of BSSIDs (access point MACs) for this network
        bssid_list = [b.upper() for b in network.get('bssid', [])]
        network_ssid = network.get('ssid', '')
        
        # Match by BSSID or SSID
        if bssid in bssid_list or ssid == network_ssid:
            print(f\"{network.get('name', 'Unknown')}|true\")
            sys.exit(0)
    
    # Network not found in known networks
    print('Unknown|false')
except Exception as e:
    # Error reading file - treat as unknown
    print('Unknown|false')
" 2>/dev/null)
        
        # Parse the pipe-separated result
        IFS='|' read -r network_name is_known <<< "$wifi_info"
    fi
    
    echo "$network_name|$is_known"
}

# ============================================================================
# MONITOR MODE CONTROL
# Monitor mode allows wireless adapter to capture all WiFi traffic
# ============================================================================

start_monitor_mode() {
    """
    Enable monitor mode on wireless interface
    Kills interfering processes and activates monitor mode
    Returns:
        0 if successful
        1 if failed
    """
    echo "Setting up monitor mode..."
    
    # Check if wireless interface exists
    if ! iwconfig 2>/dev/null | grep -q "$WIRELESS_IFACE"; then
        echo "ERROR: Wireless interface $WIRELESS_IFACE not found!"
        return 1
    fi
    
    # Kill processes that might interfere with monitor mode
    # (NetworkManager, wpa_supplicant, etc.)
    sudo airmon-ng check kill >/dev/null 2>&1 || true
    
    # Start monitor mode on interface
    sudo airmon-ng start "$WIRELESS_IFACE" >/dev/null 2>&1
    sleep 2
    
    # Verify monitor mode is enabled
    if iwconfig "$WIRELESS_IFACE" 2>/dev/null | grep -q "Mode:Monitor"; then
        echo "SUCCESS: Monitor mode enabled on $WIRELESS_IFACE"
        return 0
    else
        echo "ERROR: Failed to enable monitor mode"
        return 1
    fi
}


stop_monitor_mode() {
    """
    Disable monitor mode and restore normal operation
    Restarts NetworkManager to restore connectivity
    """
    echo "Stopping monitor mode..."
    
    # Kill any running airodump-ng processes
    sudo pkill -9 airodump-ng 2>/dev/null || true
    
    # Stop monitor mode
    sudo airmon-ng stop "$WIRELESS_IFACE" >/dev/null 2>&1 || true
    
    # Restart NetworkManager to restore normal WiFi
    sudo systemctl restart NetworkManager >/dev/null 2>&1 || true
    
    echo "SUCCESS: Monitor mode stopped"
}

# ============================================================================
# WIFI NETWORK SCANNING
# ============================================================================

scan_wifi_networks() {
    """
    Scan for WiFi networks using airodump-ng
    Captures beacon frames and probe responses
    Processes results and identifies known networks
    """
    echo "Scanning for WiFi networks for $SCAN_DURATION seconds..."
    
    TMPFILE="$(mktemp)"
    SCAN_OUTPUT="${TMPFILE}-01"  # airodump-ng appends "-01" to filename
    
    echo "   Starting airodump-ng..."
    
    # ========================================================================
    # RUN AIRODUMP-NG SCAN
    # Captures WiFi packets on all channels
    # Outputs to CSV format for easy parsing
    # ========================================================================
    sudo timeout "$SCAN_DURATION" airodump-ng "$MONITOR_IFACE" \
        -w "$TMPFILE" \
        --output-format csv \
        --write-interval 1 >/dev/null 2>&1 &
    
    AIRODUMP_PID=$!
    
    # Show progress dots while scanning
    for i in $(seq 1 "$SCAN_DURATION"); do
        echo -n "."
        sleep 1
    done
    echo ""
    
    # Wait for airodump to finish
    wait $AIRODUMP_PID 2>/dev/null || true
    
    # ========================================================================
    # FIND AND PARSE CSV FILE
    # ========================================================================
    CSV_FILE="${SCAN_OUTPUT}.csv"
    if [[ ! -f "$CSV_FILE" ]]; then
        echo "WARNING: No scan results found"
        rm -f "$TMPFILE"*
        return 1
    fi
    
    echo "   Found scan results, processing..."
    
    # Process networks
    local PROCESSED=0
    local KNOWN_COUNT=0
    local UNKNOWN_COUNT=0
    
    echo ""
    echo "========================================"
    echo ""
    
    # Create temp file for storing CSV updates
    TMPCSV="$(mktemp)"
    
    # ========================================================================
    # PARSE CSV FILE
    # airodump-ng CSV format (first 3 lines are header):
    # BSSID, First time seen, Last time seen, channel, Speed, Privacy, Cipher, Authentication, Power, # beacons, # IV, LAN IP, ID-length, ESSID, Key
    # ========================================================================
    tail -n +3 "$CSV_FILE" 2>/dev/null | while IFS=',' read -r bssid first_seen last_seen channel speed privacy cipher auth power beacons iv lan_ip id_length essid extra || [[ -n "$bssid" ]]; do
        
        # Stop parsing when we hit the "Station MAC" section (client devices)
        [[ "$bssid" =~ "Station MAC" ]] && break
        [[ -z "$bssid" ]] && continue
        
        # ====================================================================
        # CLEAN AND VALIDATE DATA
        # ====================================================================
        # Remove whitespace and extra characters
        bssid=$(echo "$bssid" | xargs | tr -d ' ')
        essid=$(echo "$essid" | xargs)
        channel=$(echo "$channel" | xargs)
        power=$(echo "$power" | xargs)
        privacy=$(echo "$privacy" | xargs)
        
        # Validate BSSID format (MAC address)
        # Format: XX:XX:XX:XX:XX:XX
        [[ ! "$bssid" =~ ^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$ ]] && continue
        
        PROCESSED=$((PROCESSED + 1))
        
        # ====================================================================
        # CHECK IF NETWORK IS KNOWN
        # ====================================================================
        wifi_info=$(get_wifi_info "$bssid" "$essid")
        IFS='|' read -r network_name is_known <<< "$wifi_info"
        
        if [[ "$is_known" == "true" ]]; then
            status="known"
            KNOWN_COUNT=$((KNOWN_COUNT + 1))
            icon="[KNOWN]"
        else
            status="unknown"
            UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
            icon="[UNKNOWN]"
        fi
        
        # Clean SSID for display (hidden networks have no SSID)
        display_ssid="${essid:-Hidden}"
        
        # ====================================================================
        # DISPLAY NETWORK INFO
        # ====================================================================
        echo "+-------------------------------------+"
        echo "| WiFi Network #$PROCESSED"
        echo "+-------------------------------------+"
        echo "  $icon ${network_name}"
        echo "  SSID: ${display_ssid}"
        echo "  BSSID: $bssid"
        echo "  Channel: $channel | Signal: ${power}dBm"
        echo "  Encryption: ${privacy:-Open}"
        echo ""
        
        # Write to temp CSV (will merge with device_log later)
        echo "$TS,$bssid,$display_ssid,$channel,$power,$privacy,$status" >> "$TMPCSV"
        
    done
    
    # ========================================================================
    # UPDATE MAIN CSV LOG
    # Merge new results with existing historical data
    # ========================================================================
    if [[ -f "$TMPCSV" ]] && [[ -s "$TMPCSV" ]]; then
        if [[ -f "$DEVICE_LOG" ]]; then
            {
                # Keep header from existing log
                head -1 "$DEVICE_LOG"
                
                # Add all new entries from this scan
                cat "$TMPCSV"
                
                # Keep old entries that weren't seen in this scan
                tail -n +2 "$DEVICE_LOG" | while IFS=',' read -r old_ts old_bssid old_rest; do
                    # If this BSSID wasn't in the current scan, keep the old entry
                    if ! grep -q ",$old_bssid," "$TMPCSV" 2>/dev/null; then
                        echo "$old_ts,$old_bssid,$old_rest"
                    fi
                done
            } > "${DEVICE_LOG}.new"
            mv "${DEVICE_LOG}.new" "$DEVICE_LOG"
        else
            # No existing log - create new one
            echo "timestamp,bssid,ssid,channel,signal_strength,encryption,status" > "$DEVICE_LOG"
            cat "$TMPCSV" >> "$DEVICE_LOG"
        fi
    fi
    
    # Clean up temp files
    rm -f "$TMPFILE"* "$TMPCSV" 2>/dev/null
    
    # ========================================================================
    # PRINT SCAN SUMMARY
    # ========================================================================
    echo "========================================"
    echo "Scan Complete: $PROCESSED network(s) found"
    echo "  Known Networks:   $KNOWN_COUNT [KNOWN]"
    echo "  Unknown Networks: $UNKNOWN_COUNT [WARNING]"
    echo ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
echo ""
echo "========================================"
echo "   HomeDefence Wardrive Scanner"
echo "========================================"
echo ""

# Create known networks template if needed
create_known_wifi_template

# Start monitor mode
if ! start_monitor_mode; then
    echo "ERROR: Failed to start monitor mode"
    exit 1
fi

# Ensure monitor mode is stopped on exit (even if script is interrupted)
trap stop_monitor_mode EXIT INT TERM

# Run the scan
scan_wifi_networks

# ============================================================================
# SEND DISCORD ALERT
# ============================================================================
echo "Sending Discord alert..."
if python3 "$PROJECT_ROOT/scripts/dis_alert.py" wardrive; then
    echo "SUCCESS: Discord alert sent"
else
    echo "WARNING: Discord alert failed (check dis_alert.py)"
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================
echo "========================================"
echo "Scan Completed: $HUMAN_TS"

# Display recent WiFi networks log
if [[ -f "$DEVICE_LOG" ]]; then
    echo ""
    echo "Recent WiFi Networks (Last 10):"
    tail -11 "$DEVICE_LOG" | column -t -s',' 2>/dev/null
fi

echo ""
echo "SUCCESS: Wardrive Scan Complete!"
echo "========================================"
echo ""

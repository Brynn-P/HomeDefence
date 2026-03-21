#!/usr/bin/env bash
#internal_defence.sh
"""
HomeDefence Network Scanner
Scans internal networks for active devices
Identifies devices by IP, hostname, and open ports
Tracks known vs unknown devices
"""

# Exit on error, undefined variables, and pipe failures
set -Eeuo pipefail

# ============================================================================
# CONFIGURATION - Paths and directories
# ============================================================================
PROJECT_ROOT="/homedefence"
LOGROOT="$PROJECT_ROOT/logs"
OUTDIR="$LOGROOT/network"
mkdir -p "$OUTDIR"

# File paths for logs and configuration
DEVICE_LOG="$OUTDIR/device_log.csv"                    # Historical log of all devices
KNOWN_DEVICES_FILE="$PROJECT_ROOT/config/known_devices.json"  # Known devices config
DEVICE_STATUS_FILE="$OUTDIR/device_status.json"        # Current online/offline status
HOME_EVENTS_LOG="$OUTDIR/home_events.log"              # Log of home/away events

# ============================================================================
# CSV FORMAT MIGRATION
# Check if old CSV format exists and migrate to new format
# Old: timestamp,ip,hostname,open_ports
# New: timestamp,ip,hostname,device_name,open_ports,status
# ============================================================================
if [[ -f "$DEVICE_LOG" ]]; then
    HEADER=$(head -1 "$DEVICE_LOG")
    if [[ "$HEADER" == "timestamp,ip,hostname,open_ports" ]]; then
        echo "WARNING: Migrating old CSV format to new format..."
        mv "$DEVICE_LOG" "$DEVICE_LOG.old"
        echo "timestamp,ip,hostname,device_name,open_ports,status" > "$DEVICE_LOG"
        echo "SUCCESS: Old CSV backed up to device_log.csv.old"
    fi
else
    # Create new file with proper header
    echo "timestamp,ip,hostname,device_name,open_ports,status" > "$DEVICE_LOG"
fi

mkdir -p "$(dirname "$KNOWN_DEVICES_FILE")"

# Generate timestamps for this scan
TS="$(date +%Y%m%d_%H%M%S)"              # Compact timestamp (e.g., 20240115_143022)
HUMAN_TS="$(date '+%Y-%m-%d %H:%M:%S')"  # Human-readable timestamp

# ============================================================================
# KNOWN DEVICES MANAGEMENT
# ============================================================================

create_known_devices_template() {
    """
    Create a template JSON file for user to configure their known network devices
    Returns:
        0 if template already exists
        1 if template was just created (user needs to edit it)
    """
    if [[ ! -f "$KNOWN_DEVICES_FILE" ]]; then
        echo "Creating known devices template..."
        cat > "$KNOWN_DEVICES_FILE" << 'EOF'
{
  "devices": [
    {
      "name": "Router",
      "person": "Network", 
      "ip_range": ["192.168.0.1"],
      "device_type": "router",
      "welcome_message": "Main router online (Network device)"
    },
    {
      "name": "Raspberry Pi",
      "person": "HomeDefence",
      "ip_range": ["10.0.10.101", "192.168.0.18"],
      "device_type": "computer",
      "welcome_message": "HomeDefence Pi is online (Computer)"
    },
    {
      "name": "Phone 1",
      "person": "Person1",
      "ip_range": ["192.168.0.50", "10.0.10.50"],
      "device_type": "phone",
      "welcome_message": "Person1 is home! (Phone detected)"
    },
    {
      "name": "Phone 2",
      "person": "Person2",
      "ip_range": ["192.168.0.57", "10.0.10.57"],
      "device_type": "phone",
      "welcome_message": "Person2 is home! (Phone detected)"
    }
  ]
}
EOF
        echo "SUCCESS: Template created! Edit $KNOWN_DEVICES_FILE with your devices"
        return 1
    fi
    return 0
}


get_device_info() {
    """
    Look up an IP address in the known devices configuration
    Args:
        $1 - IP address to lookup
    Returns:
        Pipe-separated string: device_name|welcome_message|is_known
        Example: "Router|Main router online|true"
    """
    local ip="$1"
    local device_name="Unknown"
    local welcome_msg=""
    local is_known="false"
    
    if [[ -f "$KNOWN_DEVICES_FILE" ]]; then
        # Use Python to parse JSON and lookup IP
        local device_info=$(python3 -c "
import json, sys
try:
    with open('$KNOWN_DEVICES_FILE', 'r') as f:
        data = json.load(f)
    
    ip = '$ip'
    
    # Search through all known devices
    for device in data.get('devices', []):
        ip_range = device.get('ip_range', [])
        
        # Check if our IP matches any in this device's IP range
        if ip in ip_range:
            print(f\"{device.get('name', 'Unknown')}|{device.get('welcome_message', '')}|true\")
            sys.exit(0)
    
    # IP not found in known devices
    print('Unknown||false')
except Exception as e:
    # Error reading file - treat as unknown
    print('Unknown||false')
" 2>/dev/null)
        
        # Parse the pipe-separated result
        IFS='|' read -r device_name welcome_msg is_known <<< "$device_info"
    fi
    
    echo "$device_name|$welcome_msg|$is_known"
}


log_home_event() {
    """
    Log a home/away event (e.g., "Person is home")
    Args:
        $1 - Message to log
    """
    local message="$1"
    echo "[$HUMAN_TS] $message" >> "$HOME_EVENTS_LOG"
    echo "[HOME EVENT] $message"
}


check_device_status() {
    """
    Track device online/offline status and log reconnection events
    Args:
        $1 - IP address
        $2 - Device name
        $3 - Welcome message (if known device)
        $4 - Is known (true/false)
    """
    local ip="$1"
    local device_name="$2" 
    local welcome_msg="$3"
    local is_known="$4"
    
    # Get previous status from status file
    local prev_status="offline"
    if [[ -f "$DEVICE_STATUS_FILE" ]]; then
        prev_status=$(python3 -c "
import json
try:
    with open('$DEVICE_STATUS_FILE', 'r') as f:
        data = json.load(f)
    print(data.get('$ip', {}).get('status', 'offline'))
except:
    print('offline')
" 2>/dev/null)
    fi
    
    # Update status to online
    python3 -c "
import json, os
data = {}

# Load existing status file
if os.path.exists('$DEVICE_STATUS_FILE'):
    try:
        with open('$DEVICE_STATUS_FILE', 'r') as f:
            data = json.load(f)
    except:
        pass

# Update this device's status
data['$ip'] = {
    'device_name': '$device_name',
    'status': 'online',
    'last_seen': '$HUMAN_TS',
    'is_known': $is_known
}

# Write back to file
with open('$DEVICE_STATUS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
    
    # Log reconnection events for known devices
    # Only log if device was previously offline (prevents spam on every scan)
    if [[ "$prev_status" == "offline" && "$is_known" == "true" && -n "$welcome_msg" ]]; then
        log_home_event "$welcome_msg"
    fi
}

# ============================================================================
# NETWORK SCANNING FUNCTIONS
# ============================================================================

get_hostname_simple() {
    """
    Attempt to resolve hostname from IP address using multiple methods
    Args:
        $1 - IP address
    Returns:
        Hostname or "unknown" if resolution fails
    """
    local ip="$1"
    local hostname="unknown"
    
    # Try multiple DNS resolution methods with short timeouts
    
    # Method 1: dig (DNS query tool)
    if command -v dig >/dev/null 2>&1; then
        hostname=$(timeout 2 dig +short -x "$ip" 2>/dev/null | sed 's/\.$//') || hostname="unknown"
    # Method 2: nslookup (alternative DNS tool)
    elif command -v nslookup >/dev/null 2>&1; then
        hostname=$(timeout 2 nslookup "$ip" 2>/dev/null | awk '/name =/ {print $4; exit}' | sed 's/\.$//') || hostname="unknown"
    # Method 3: getent (system database lookup)
    else
        hostname=$(timeout 2 getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}') || hostname="unknown"
    fi
    
    # If hostname is empty or same as IP, mark as unknown
    [[ -z "$hostname" || "$hostname" == "$ip" ]] && hostname="unknown"
    echo "$hostname"
}


get_ports_simple() {
    """
    Scan for open ports on a device using netcat or nmap
    Args:
        $1 - IP address to scan
    Returns:
        Comma-separated list of open ports or "none"
    """
    local ip="$1"
    local ports=""
    
    # Method 1: Use netcat (nc) for fast scanning of common ports
    if command -v nc >/dev/null 2>&1; then
        # Common ports to check
        local COMMON_PORTS="22 23 25 53 80 110 443 993 995 3389 5900 8080"
        local OPEN_PORTS=()
        
        # Test each port
        for port in $COMMON_PORTS; do
            if timeout 1 nc -z "$ip" "$port" 2>/dev/null; then
                OPEN_PORTS+=("$port")
            fi
        done
        
        # Join array into comma-separated string
        ports=$(IFS=,; echo "${OPEN_PORTS[*]}")
    else
        # Method 2: Fallback to nmap (more thorough but slower)
        if [[ -n "$SUDO" ]]; then
            # With sudo: can use SYN scan (faster)
            ports=$(timeout 15 $SUDO nmap -Pn -T4 --top-ports 20 --open "$ip" 2>/dev/null | \
                    awk '/^[0-9]+\/tcp.*open/ {gsub(/\/tcp.*/,"",$1); ports=ports $1 ","} END {sub(/,$/,"",ports); print ports}')
        else
            # Without sudo: use connect scan
            ports=$(timeout 15 nmap -Pn -T4 --top-ports 20 --open "$ip" 2>/dev/null | \
                    awk '/^[0-9]+\/tcp.*open/ {gsub(/\/tcp.*/,"",$1); ports=ports $1 ","} END {sub(/,$/,"",ports); print ports}')
        fi
    fi
    
    # If no ports found, mark as "none"
    [[ -z "$ports" ]] && ports="none"
    echo "$ports"
}

# ============================================================================
# NETWORK SCANNING - Process a single network
# ============================================================================

scan_network() {
    """
    Scan a network subnet for active devices
    Args:
        $1 - Network CIDR (e.g., "192.168.0.0/24")
        $2 - Network name (e.g., "Main Network")
    Returns:
        Pipe-separated counts: processed|known|unknown
    """
    local NETWORK="$1"
    local NETWORK_NAME="$2"
    
    echo ""
    echo "========================================"
    echo "   Scanning $NETWORK_NAME"
    echo "========================================"
    echo ""
    
    # ========================================================================
    # DEVICE DISCOVERY - Find all live hosts on network
    # Use nmap ping scan (-sn) to find active IPs
    # ========================================================================
    echo "Discovering live hosts on $NETWORK..."
    TMPFILE="$(mktemp)"
    
    # Run nmap and extract IPs marked as "Up"
    nmap -sn "$NETWORK" -oG - | awk '/Up$/{print $2}' > "$TMPFILE"
    
    LIVE_COUNT=$(wc -l < "$TMPFILE")
    echo "SUCCESS: Found $LIVE_COUNT live host(s) on $NETWORK"
    echo ""
    echo "========================================"
    echo ""
    
    # ========================================================================
    # PROCESS EACH DISCOVERED DEVICE
    # ========================================================================
    local PROCESSED=0
    local KNOWN_COUNT=0
    local UNKNOWN_COUNT=0
    
    while read -r ip; do
        # Skip empty lines and our own IP
        [[ -z "$ip" ]] && continue
        [[ "$ip" == "$SELF_IP" ]] && continue
        
        PROCESSED=$((PROCESSED + 1))
        
        echo "+-------------------------------------+"
        echo "| Scanning Device #$PROCESSED ($NETWORK_NAME)"
        echo "+-------------------------------------+"
        
        # ====================================================================
        # GET DEVICE IDENTIFICATION
        # ====================================================================
        device_info=$(get_device_info "$ip")
        IFS='|' read -r device_name welcome_msg is_known <<< "$device_info"
        
        # ====================================================================
        # GET NETWORK INFORMATION
        # ====================================================================
        hostname=$(get_hostname_simple "$ip")
        ports=$(get_ports_simple "$ip")
        
        # ====================================================================
        # DETERMINE STATUS (known vs unknown)
        # ====================================================================
        if [[ "$is_known" == "true" ]]; then
            status="known"
            KNOWN_COUNT=$((KNOWN_COUNT + 1))
            device_status="[KNOWN DEVICE]"
        else
            status="unknown"
            UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
            device_status="[UNKNOWN DEVICE]"
        fi
        
        # ====================================================================
        # DISPLAY DEVICE INFO
        # ====================================================================
        echo ""
        echo "  $device_status"
        echo "  ----------------------------------"
        echo "  Device Name:  $device_name"
        echo "  IP Address:   $ip"
        echo "  Hostname:     $hostname"
        echo "  Open Ports:   $ports"
        echo "  Status:       $status"
        echo "  Network:      $NETWORK_NAME"
        echo ""
        
        # ====================================================================
        # CHECK FOR HOME EVENTS (reconnections)
        # ====================================================================
        check_device_status "$ip" "$device_name" "$welcome_msg" "$is_known"
        
        # ====================================================================
        # UPDATE CSV LOG
        # Use file locking to prevent race conditions
        # ====================================================================
        (
            flock 200  # Acquire exclusive lock
            
            if grep -q ",$ip," "$DEVICE_LOG" 2>/dev/null; then
                # Device exists - update its record
                awk -F, -v ip="$ip" -v ts="$TS" -v host="$hostname" \
                    -v device="$device_name" -v ports="$ports" -v status="$status" '
                    BEGIN {OFS=","}
                    NR==1 {print; next}
                    $2==ip {$1=ts; $3=host; $4=device; $5=ports; $6=status}
                    {print}
                ' "$DEVICE_LOG" > "$DEVICE_LOG.tmp" && mv "$DEVICE_LOG.tmp" "$DEVICE_LOG"
            else
                # New device - add new record
                echo "$TS,$ip,$hostname,$device_name,$ports,$status" >> "$DEVICE_LOG"
            fi
        ) 200>"$DEVICE_LOG.lock"  # Release lock when done
        
    done < "$TMPFILE"
    
    rm -f "$TMPFILE"
    
    # Return counts as pipe-separated string
    echo "$PROCESSED|$KNOWN_COUNT|$UNKNOWN_COUNT"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
echo ""
echo "========================================"
echo "   HomeDefence Network Scanner"
echo "========================================"
echo ""

# Create template if needed
if ! create_known_devices_template; then
    echo "[!] Please configure your known devices and run again"
    exit 0
fi

# Get current network information
SELF_IP="$(hostname -I | awk '{print $1}')"
IFACE="$(ip route | awk '/default/ {print $5; exit}')"

echo "Interface: $IFACE"
echo "Your IP: $SELF_IP"

# Check if we have sudo access (needed for some scans)
if sudo -n true 2>/dev/null; then
    SUDO="sudo"
else
    SUDO=""
fi

# ============================================================================
# SCAN BOTH NETWORKS
# Main network (192.168.0.0/24) and Pi network (10.0.10.0/24)
# ============================================================================
TOTAL_DEVICES=0
TOTAL_KNOWN=0
TOTAL_UNKNOWN=0

# Scan main network
result=$(scan_network "192.168.0.0/24" "Main Network")
IFS='|' read -r devices known unknown <<< "$result"
TOTAL_DEVICES=$((TOTAL_DEVICES + devices))
TOTAL_KNOWN=$((TOTAL_KNOWN + known))
TOTAL_UNKNOWN=$((TOTAL_UNKNOWN + unknown))

# Scan Pi network
result=$(scan_network "10.0.10.0/24" "Pi Network")
IFS='|' read -r devices known unknown <<< "$result"
TOTAL_DEVICES=$((TOTAL_DEVICES + devices))
TOTAL_KNOWN=$((TOTAL_KNOWN + known))
TOTAL_UNKNOWN=$((TOTAL_UNKNOWN + unknown))

# Clean up lock file
rm -f "$DEVICE_LOG.lock"

# ============================================================================
# FINAL SUMMARY
# ============================================================================
echo "========================================"
echo ""
echo "========================================"
echo "       COMPLETE SCAN SUMMARY"
echo "========================================"
echo ""
echo "Scan Completed: $HUMAN_TS"
echo "Networks Scanned: 192.168.0.0/24 + 10.0.10.0/24"
echo ""
echo "Combined Results:"
echo "  Total Devices:    $TOTAL_DEVICES"
echo "  Known Devices:    $TOTAL_KNOWN [KNOWN]"
echo "  Unknown Devices:  $TOTAL_UNKNOWN [WARNING]"
echo ""

# Display recent device log
if [[ -f "$DEVICE_LOG" ]]; then
    echo "========================================"
    echo "Recent Device Log (Last 10)"
    echo "========================================"
    echo ""
    tail -11 "$DEVICE_LOG" | column -t -s',' 2>/dev/null
    echo ""
fi

# Display recent home events
if [[ -f "$HOME_EVENTS_LOG" ]] && [[ -s "$HOME_EVENTS_LOG" ]]; then
    echo "========================================"
    echo "Recent Home Events"
    echo "========================================"
    echo ""
    tail -5 "$HOME_EVENTS_LOG" 2>/dev/null
    echo ""
fi

echo "========================================"
echo "SUCCESS: Scan Complete!"
echo "========================================"
echo ""

# ============================================================================
# DISCORD ALERT (Optional)
# Note: This is called automatically by motion.py
# Uncomment below to send alerts for standalone runs
# ============================================================================
# echo "Sending Discord alert..."
# python3 "$PROJECT_ROOT/scripts/dis_alert.py" network 2>/dev/null || echo "WARNING: Discord alert skipped"

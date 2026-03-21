#!/usr/bin/env python3
#dis_alert.py
"""
HomeDefence Discord Alert System
Sends scan results to appropriate Discord channels via webhooks
"""

import os
import sys
import glob
import time
import json
import requests
from datetime import datetime
from dotenv import load_dotenv

# ============================================================================
# CONFIGURATION - Load Discord webhook URLs from environment file
# ============================================================================
load_dotenv("/homedefence/scripts/cord.env")
DISCORD_WEBHOOK_MAIN = os.getenv("DISCORD_WEBHOOK_URL")        # Main alerts channel
DISCORD_WEBHOOK_WIFI = os.getenv("DISCORD_WEBHOOK_WIFI")        # Wardrive/WiFi channel
DISCORD_WEBHOOK_BLUETOOTH = os.getenv("DISCORD_WEBHOOK_BLUETOOTH")  # Bluetooth channel

# ============================================================================
# CONSTANTS - File paths and settings
# ============================================================================
COOLDOWN_SECONDS = 3  # Delay between webhook calls to avoid rate limiting
IMAGES_FOLDER = "/homedefence/images"

# Map scan types to their log directories
SCAN_LOG_DIRS = {
    "Wi-Fi": "/homedefence/logs/network",
    "Bluetooth": "/homedefence/logs/bluetooth",
    "Wardrive": "/homedefence/logs/wardrive"
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def log_debug(message):
    """
    Print timestamped debug messages to console
    Args:
        message (str): Message to log
    """
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}")


def get_latest_image(folder=IMAGES_FOLDER):
    """
    Find the most recently created image file in the specified folder
    Args:
        folder (str): Path to images directory
    Returns:
        str or None: Path to latest image, or None if no images found
    """
    try:
        if not os.path.exists(folder):
            log_debug(f"Images folder does not exist: {folder}")
            return None
            
        # Get all .jpg files in folder
        list_of_files = glob.glob(f"{folder}/*.jpg")
        if not list_of_files:
            log_debug(f"No image files found in {folder}")
            return None
            
        # Find most recent by creation time
        latest_file = max(list_of_files, key=os.path.getctime)
        log_debug(f"Latest image: {latest_file}")
        return latest_file
        
    except Exception as e:
        log_debug(f"Error getting latest image: {e}")
        return None


def get_latest_device_log(scan_type):
    """
    Read and format device scan results from CSV files
    
    IMPORTANT: For Bluetooth, reads from current_scan.csv (current scan only)
               For other types, reads from device_log.csv (historical data)
    
    Args:
        scan_type (str): Type of scan ("Wi-Fi", "Bluetooth", or "Wardrive")
    
    Returns:
        str: Formatted string of device list with status markers and counts
    """
    # Get the correct log directory for this scan type
    folder = SCAN_LOG_DIRS.get(scan_type)
    if not folder:
        return "Scan type not found"
    
    # CRITICAL FIX: Use current_scan.csv for Bluetooth to get ONLY this scan's results
    # This ensures we show devices detected NOW, not historical devices
    if scan_type == "Bluetooth":
        csv_path = os.path.join(folder, "current_scan.csv")
        log_debug(f"Reading Bluetooth CURRENT scan from: {csv_path}")
    else:
        csv_path = os.path.join(folder, "device_log.csv")
        log_debug(f"Reading {scan_type} device log from: {csv_path}")
    
    # Check if file exists
    if not os.path.isfile(csv_path):
        log_debug(f"CSV file not found: {csv_path}")
        return "No scan data available"
    
    try:
        devices = []  # List to store formatted device strings
        device_count = 0
        known_count = 0
        unknown_count = 0
        
        # Read all lines from CSV
        with open(csv_path, "r") as f:
            lines = f.readlines()
        
        # Skip header row if present (starts with "timestamp" or "BSSID")
        if lines and (lines[0].startswith("timestamp") or lines[0].startswith("BSSID")):
            lines = lines[1:]
        
        # Process each line based on scan type
        for line in lines:
            line = line.strip()
            if not line:
                continue
                
            # Split CSV line by commas
            parts = line.split(",")
            
            # ================================================================
            # WI-FI NETWORK SCAN FORMAT
            # CSV: timestamp,ip,hostname,device_name,open_ports,status
            # ================================================================
            if scan_type == "Wi-Fi":
                if len(parts) < 6:
                    continue
                    
                device_count += 1
                timestamp, ip, hostname, device_name, open_ports, status = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
                
                # Determine status marker based on known/unknown status
                if status == "known":
                    known_count += 1
                    status_icon = "[KNOWN]"
                else:
                    unknown_count += 1
                    status_icon = "[UNKNOWN]"
                
                # Use device_name if available, otherwise use hostname
                device_name = device_name if device_name and device_name != "Unknown" else hostname
                open_ports = open_ports if open_ports and open_ports != "none" else "No open ports"
                
                # Format device info for Discord
                device_info = f"{status_icon} **{device_name}**\n  IP: {ip}\n  Ports: {open_ports}"
            
            # ================================================================
            # WARDRIVE (WiFi Discovery) SCAN FORMAT
            # CSV: timestamp,bssid,ssid,channel,signal_strength,encryption,status
            # ================================================================
            elif scan_type == "Wardrive":
                if len(parts) < 7:
                    continue
                    
                device_count += 1
                timestamp, bssid, ssid, channel, signal, encryption, status = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]
                
                # Determine status marker based on known/unknown status
                if status == "known":
                    known_count += 1
                    status_icon = "[KNOWN]"
                else:
                    unknown_count += 1
                    status_icon = "[UNKNOWN]"
                
                # Handle hidden SSIDs
                ssid = ssid if ssid and ssid != "Hidden" else "Hidden Network"
                
                # Format WiFi network info for Discord
                device_info = f"{status_icon} **{ssid}**\n  BSSID: {bssid}\n  Channel: {channel} | Signal: {signal}dBm\n  Encryption: {encryption}"
            
            # ================================================================
            # BLUETOOTH SCAN FORMAT
            # CSV: timestamp,mac_address,device_name,device_class,signal_strength,status
            # ================================================================
            elif scan_type == "Bluetooth":
                if len(parts) < 6:
                    continue
                    
                device_count += 1
                timestamp, mac, device_name, device_class, signal, status = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
                
                # Determine status marker based on known/unknown status
                if status == "known":
                    known_count += 1
                    status_icon = "[KNOWN]"
                else:
                    unknown_count += 1
                    status_icon = "[UNKNOWN]"
                
                # Handle unknown device names
                device_name = device_name if device_name and device_name != "Unknown" else "Unknown Device"
                
                # Format Bluetooth device info for Discord
                device_info = f"{status_icon} **{device_name}**\n  MAC: {mac}\n  Class: {device_class}"
            
            else:
                continue
            
            # Add this device to our list
            devices.append(device_info)
        
        # If no devices found, return empty message
        if not devices:
            return "No devices detected"
        
        # Build summary with counts - SHOW ALL DEVICES (no truncation)
        summary = f"**{device_count} device(s) found** ({known_count} known, {unknown_count} unknown)\n\n"
        summary += "\n\n".join(devices)
        
        return summary
        
    except Exception as e:
        log_debug(f"Error reading device log for {scan_type}: {e}")
        return f"ERROR: Error reading {scan_type} scan data: {e}"


def get_webhook_for_type(scan_type):
    """
    Get the appropriate Discord webhook URL for a scan type
    
    Args:
        scan_type (str): Type of scan
    
    Returns:
        str: Webhook URL (falls back to main channel if specific channel not configured)
    """
    if scan_type == "Wardrive":
        return DISCORD_WEBHOOK_WIFI or DISCORD_WEBHOOK_MAIN
    elif scan_type == "Bluetooth":
        return DISCORD_WEBHOOK_BLUETOOTH or DISCORD_WEBHOOK_MAIN
    else:
        return DISCORD_WEBHOOK_MAIN


# ============================================================================
# DISCORD WEBHOOK FUNCTIONS
# ============================================================================

def send_discord_alert_embed(title, fields=None, image_path=None, description=None, color=0xFF0000, webhook_url=None):
    """
    Send a rich embed message to Discord via webhook
    
    Args:
        title (str): Embed title (max 256 chars)
        fields (list): List of field dicts with 'name', 'value', 'inline'
        image_path (str): Path to image file to attach
        description (str): Main embed description (max 4096 chars)
        color (int): Embed color as hex integer (e.g., 0xFF0000 for red)
        webhook_url (str): Discord webhook URL to send to
    
    Returns:
        bool: True if successful, False otherwise
    """
    # Use provided webhook or default to main channel
    if not webhook_url:
        webhook_url = DISCORD_WEBHOOK_MAIN
        
    if not webhook_url:
        log_debug("ERROR: Discord webhook URL not configured!")
        return False
    
    try:
        # ================================================================
        # BUILD DISCORD EMBED OBJECT
        # ================================================================
        embed = {
            "title": title[:256],  # Discord max title length
            "color": color,
            "timestamp": datetime.utcnow().isoformat(),  # ISO format timestamp
            "footer": {"text": "HomeDefence Security System"}
        }
        
        # Add description if provided
        if description:
            # Truncate if too long (Discord limit is 4096 chars)
            if len(description) > 4096:
                embed["description"] = description[:4093] + "..."
            else:
                embed["description"] = description
        
        # Add fields if provided
        if fields:
            embed["fields"] = []
            for field in fields:
                if len(embed["fields"]) >= 25:  # Discord max 25 fields per embed
                    break
                
                field_value = str(field.get("value", "N/A"))
                field_name = str(field.get("name", "Unknown"))[:256]
                
                # Truncate field value if too long (Discord limit is 1024 chars per field)
                if len(field_value) > 1024:
                    # Try to truncate at a device boundary for cleaner display
                    truncate_at = field_value[:1000].rfind("Encryption:")
                    if truncate_at > 500:
                        field_value = field_value[:truncate_at] + "\n\n[List truncated - too many devices]"
                    else:
                        field_value = field_value[:1020] + "..."
                
                embed["fields"].append({
                    "name": field_name,
                    "value": field_value,
                    "inline": field.get("inline", False)
                })
        
        # Prepare webhook payload
        data = {"embeds": [embed]}
        files = None
        
        # ================================================================
        # ATTACH IMAGE IF PROVIDED
        # ================================================================
        if image_path and os.path.isfile(image_path):
            try:
                filename = os.path.basename(image_path)
                embed["image"] = {"url": f"attachment://{filename}"}  # Reference attachment
                files = {filename: open(image_path, "rb")}
                log_debug(f"Attaching image: {filename}")
            except Exception as e:
                log_debug(f"ERROR: Failed to attach image {image_path}: {e}")
        
        # ================================================================
        # SEND WEBHOOK REQUEST
        # ================================================================
        log_debug(f"Sending Discord alert to {webhook_url[-20:]}: {title}")
        response = requests.post(
            webhook_url,
            data={"payload_json": json.dumps(data)},
            files=files,
            timeout=10
        )
        
        # Close file handle if we opened one
        if files:
            try:
                files[filename].close()
            except:
                pass
        
        # Check if webhook was successful
        if response.status_code in (200, 204):
            log_debug("SUCCESS: Discord alert sent successfully")
            time.sleep(COOLDOWN_SECONDS)  # Rate limit cooldown
            return True
        else:
            log_debug(f"ERROR: Discord alert failed: {response.status_code} - {response.text}")
            return False
            
    except requests.exceptions.Timeout:
        log_debug("ERROR: Discord alert timed out")
        return False
    except requests.exceptions.RequestException as e:
        log_debug(f"ERROR: Discord request error: {e}")
        return False
    except Exception as e:
        log_debug(f"ERROR: Unexpected error sending Discord alert: {e}")
        return False


def send_scan_alert(scan_type):
    """
    Send a scan result alert to the appropriate Discord channel
    
    Args:
        scan_type (str): Type of scan ("Wi-Fi", "Bluetooth", "Wardrive")
    
    Returns:
        bool: True if successful, False otherwise
    """
    # Get formatted device list from CSV
    summary = get_latest_device_log(scan_type)
    
    # Get the correct webhook for this scan type
    webhook = get_webhook_for_type(scan_type)
    
    # Choose title prefix and color based on scan type
    if scan_type == "Wardrive":
        title_prefix = "[WARDRIVE]"
        color = 0x00AAFF  # Blue
    elif scan_type == "Bluetooth":
        title_prefix = "[BLUETOOTH]"
        color = 0x0099FF  # Light blue
    else:
        title_prefix = "[WIFI]"
        color = 0x00FF00  # Green
    
    # ================================================================
    # HANDLE EMPTY OR ERROR RESULTS
    # ================================================================
    if summary.startswith("No devices") or summary.startswith("ERROR"):
        # No data or error - send simple status message
        return send_discord_alert_embed(
            title=f"{title_prefix} HomeDefence {scan_type} Scan",
            description=summary,
            color=0xFFAA00,  # Orange for no data/error
            webhook_url=webhook
        )
    
    # ================================================================
    # SPLIT LONG DEVICE LISTS INTO MULTIPLE MESSAGES IF NEEDED
    # Discord field limit is 1024 characters per field
    # ================================================================
    MAX_FIELD_LENGTH = 1000  # Leave buffer for safety
    
    # If summary fits in one message, send it
    if len(summary) <= MAX_FIELD_LENGTH:
        return send_discord_alert_embed(
            title=f"{title_prefix} HomeDefence {scan_type} Scan",
            fields=[{"name": "Detected Devices", "value": summary, "inline": False}],
            color=color,
            webhook_url=webhook
        )
    
    # ================================================================
    # SUMMARY TOO LONG - SPLIT INTO MULTIPLE MESSAGES
    # ================================================================
    log_debug(f"WARNING: Device list too long ({len(summary)} chars), splitting into multiple messages...")
    
    # Extract the summary header (e.g., "19 device(s) found...")
    header_parts = summary.split("\n\n", 1)
    header = header_parts[0] if len(header_parts) > 0 else ""
    devices_text = header_parts[1] if len(header_parts) > 1 else summary
    
    # Split devices by double newline (each device is separated by \n\n)
    devices = devices_text.split("\n\n")
    
    # Build chunks that fit within Discord's limits
    chunk = header + "\n\n"
    chunk_devices = []
    success = True
    message_num = 1
    
    for device in devices:
        # Check if adding this device would exceed the limit
        if len(chunk + device + "\n\n") > MAX_FIELD_LENGTH:
            # Send current chunk
            log_debug(f"Sending chunk {message_num} ({len(chunk_devices)} devices)...")
            result = send_discord_alert_embed(
                title=f"{title_prefix} {scan_type} Scan (Part {message_num})",
                fields=[{"name": "Detected Devices", "value": chunk.strip(), "inline": False}],
                color=color,
                webhook_url=webhook
            )
            success = success and result
            
            # Start new chunk
            message_num += 1
            chunk = ""
            chunk_devices = []
        
        # Add device to current chunk
        chunk += device + "\n\n"
        chunk_devices.append(device)
    
    # Send final chunk if there's anything left
    if chunk_devices:
        log_debug(f"Sending final chunk {message_num} ({len(chunk_devices)} devices)...")
        result = send_discord_alert_embed(
            title=f"{title_prefix} {scan_type} Scan (Part {message_num})" if message_num > 1 else f"{title_prefix} HomeDefence {scan_type} Scan",
            fields=[{"name": "Detected Devices", "value": chunk.strip(), "inline": False}],
            color=color,
            webhook_url=webhook
        )
        success = success and result
    
    return success


def send_motion_alert_with_network_scan(motion_image_path=None):
    """
    Send motion detection alert to MAIN channel with attached image and network scan
    
    Args:
        motion_image_path (str): Path to motion capture image
    
    Returns:
        bool: True if successful, False otherwise
    """
    try:
        # Get Wi-Fi network scan data
        network_summary = get_latest_device_log("Wi-Fi")
        
        # Build fields for motion alert embed
        motion_fields = [
            {"name": "Location", "value": "Camera Zone 1", "inline": True},
            {"name": "Time", "value": datetime.now().strftime('%H:%M:%S'), "inline": True}
        ]
        
        # Add network scan results if available
        if network_summary and not network_summary.startswith("ERROR"):
            motion_fields.append({
                "name": "Internal Network Scan", 
                "value": network_summary, 
                "inline": False
            })
        
        # Send ONLY to main channel with image and network scan
        log_debug("Sending motion alert with network scan to main channel...")
        main_success = send_discord_alert_embed(
            title="[ALERT] HomeDefence Motion Alert",
            description=f"Motion detected at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            fields=motion_fields,
            image_path=motion_image_path,
            color=0xFF4444,  # Red
            webhook_url=DISCORD_WEBHOOK_MAIN
        )
        
        return main_success
        
    except Exception as e:
        log_debug(f"ERROR: Error in motion alert: {e}")
        return False


def test_all_webhooks():
    """
    Test all configured Discord webhooks
    
    Returns:
        list: List of tuples (channel_name, success_bool)
    """
    results = []
    
    # Test main webhook
    if DISCORD_WEBHOOK_MAIN:
        print("Testing Main Channel webhook...")
        success = send_discord_alert_embed(
            title="[TEST] HomeDefence Test - Main Channel",
            description="Testing main channel webhook connection...",
            fields=[
                {"name": "Status", "value": "Connection successful", "inline": True},
                {"name": "Timestamp", "value": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "inline": True}
            ],
            color=0x00FF00,
            webhook_url=DISCORD_WEBHOOK_MAIN
        )
        results.append(("Main Channel", success))
    
    # Test WiFi webhook
    if DISCORD_WEBHOOK_WIFI:
        print("Testing WiFi/Wardrive Channel webhook...")
        success = send_discord_alert_embed(
            title="[TEST] HomeDefence Test - WiFi Channel",
            description="Testing WiFi/Wardrive webhook connection...",
            fields=[
                {"name": "Status", "value": "Connection successful", "inline": True},
                {"name": "Timestamp", "value": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "inline": True}
            ],
            color=0x00AAFF,
            webhook_url=DISCORD_WEBHOOK_WIFI
        )
        results.append(("WiFi Channel", success))
    
    # Test Bluetooth webhook
    if DISCORD_WEBHOOK_BLUETOOTH:
        print("Testing Bluetooth Channel webhook...")
        success = send_discord_alert_embed(
            title="[TEST] HomeDefence Test - Bluetooth Channel",
            description="Testing Bluetooth webhook connection...",
            fields=[
                {"name": "Status", "value": "Connection successful", "inline": True},
                {"name": "Timestamp", "value": datetime.now().strftime('%Y-%m-%d %H:%M:%S'), "inline": True}
            ],
            color=0x0099FF,
            webhook_url=DISCORD_WEBHOOK_BLUETOOTH
        )
        results.append(("Bluetooth Channel", success))
    
    return results


# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

if __name__ == "__main__":
    # Check for command line arguments
    if len(sys.argv) > 1:
        scan_type = sys.argv[1].lower()
        
        # ================================================================
        # TEST MODE - Test all webhooks
        # ================================================================
        if scan_type == "test":
            print("Testing HomeDefence Discord webhooks...")
            print("")
            results = test_all_webhooks()
            print("")
            print("========================================")
            print("Test Results:")
            for channel, success in results:
                status = "SUCCESS" if success else "FAILED"
                print(f"  {channel}: {status}")
            print("========================================")
            sys.exit(0 if all(r[1] for r in results) else 1)
        
        # ================================================================
        # BLUETOOTH SCAN ALERT
        # ================================================================
        elif scan_type == "bluetooth":
            print("Sending Bluetooth scan alert to Bluetooth channel...")
            success = send_scan_alert("Bluetooth")
            sys.exit(0 if success else 1)
        
        # ================================================================
        # WARDRIVE SCAN ALERT
        # ================================================================
        elif scan_type == "wardrive" or scan_type == "wifi":
            print("Sending Wardrive scan alert to WiFi channel...")
            success = send_scan_alert("Wardrive")
            sys.exit(0 if success else 1)
        
        # ================================================================
        # NETWORK SCAN ALERT
        # ================================================================
        elif scan_type == "network" or scan_type == "wi-fi":
            print("Sending Wi-Fi network scan alert...")
            success = send_scan_alert("Wi-Fi")
            sys.exit(0 if success else 1)
        
        # ================================================================
        # MOTION ALERT
        # ================================================================
        elif scan_type == "motion":
            print("Sending motion alert with network scan to main channel...")
            latest_image = get_latest_image()
            success = send_motion_alert_with_network_scan(latest_image)
            sys.exit(0 if success else 1)
        
        # ================================================================
        # UNKNOWN SCAN TYPE
        # ================================================================
        else:
            print(f"ERROR: Unknown scan type: {scan_type}")
            print("Usage: dis_alert.py [test|bluetooth|wardrive|wifi|network|motion]")
            sys.exit(1)
    
    # ================================================================
    # NO ARGUMENTS - Run test mode
    # ================================================================
    else:
        print("Testing HomeDefence Discord webhooks...")
        print("Usage: dis_alert.py [test|bluetooth|wardrive|wifi|network|motion]")
        print("")
        results = test_all_webhooks()
        print("")
        print("========================================")
        print("Test Results:")
        for channel, success in results:
            status = "SUCCESS" if success else "FAILED"
            print(f"  {channel}: {status}")
        print("========================================")

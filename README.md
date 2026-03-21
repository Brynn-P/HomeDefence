# HomeDefence

Autonomous home security system for Raspberry Pi. Monitors for motion, unknown network devices, nearby Wi-Fi access points, and Bluetooth devices. Sends alerts to Discord.

Please note, I am currently working on a setup script to allow for easy set up and will add this to the build in the future

---

## What it does

When the camera detects motion, HomeDefence:

1. Saves a timestamped JPEG of the event
2. Scans both LAN subnets for live devices
3. Puts the Wi-Fi adapter into monitor mode and captures nearby SSIDs/BSSIDs
4. Scans for nearby Bluetooth devices
5. Sends the results to three Discord channels (main alert with image, Wi-Fi channel, Bluetooth channel)

All scanning and alerting happens in a background thread so the camera loop is never blocked.

---

## Repository structure

```
homedefence/
├── scripts/
│   ├── motion.py                  # Entry point — camera loop and scan orchestration
│   ├── internal_defence.sh        # LAN scanner (nmap + netcat)
│   ├── wardrive_scan.sh           # Wi-Fi scanner (aircrack-ng, monitor mode)
│   ├── bluetooth.sh               # Bluetooth scanner (bluetoothctl + hcitool)
│   ├── dis_alert.py               # Discord webhook dispatcher
│   ├── consolidate_devices.py     # Merges known-device config with live CSV
│   ├── clear_logs.py              # Wipes all log files
│   ├── test_grep.sh               # Validates bluetooth.sh grep/sed patterns
│   ├── bluetooth_enhanced_debug.sh# Verbose Bluetooth troubleshooting
│   └── cord.env                   # Discord webhook URLs (not in source control)
├── config/
│   ├── known_devices.json         # Trusted network devices (matched by IP)
│   ├── known_wifi.json            # Trusted Wi-Fi networks (matched by SSID/BSSID)
│   └── known_bluetooth.json       # Trusted Bluetooth devices (matched by MAC)
├── logs/
│   ├── network/device_log.csv     # Historical network scan results
│   ├── wardrive/device_log.csv    # Historical Wi-Fi scan results
│   └── bluetooth/
│       ├── device_log.csv         # All Bluetooth devices ever seen
│       └── current_scan.csv       # Devices from the most recent scan only
└── images/                        # Motion capture JPEGs
```

---

## How everything works together

### motion.py — orchestrator

`motion.py` is the only process you need to run. Everything else is triggered from it.

On startup it initialises the Raspberry Pi camera via `picamera2` at 1920x1080 and enters a detection loop at ~2 FPS.

**Motion detection algorithm:**
- Each frame is converted to grayscale and blurred (25x25 Gaussian kernel) to reduce noise
- The first frame captured becomes the background reference
- `cv2.absdiff()` computes the pixel-level difference between the current frame and the background
- The difference is thresholded and dilated, then `cv2.findContours()` finds regions of change
- Any contour with area >= `MIN_AREA` (25,000 px) sets a motion flag
- Three consecutive flagged frames are required to confirm a real event — this filters out lighting flickers and camera noise
- The background is slowly updated each frame (95% old + 5% new) to handle gradual lighting changes
- Every five minutes the background resets fully to handle sudden changes

**On confirmed motion:**
- The frame is saved as a JPEG in `/homedefence/images/`
- A background daemon thread (`scan_and_alert`) is spawned
- The camera loop continues immediately without waiting for scans to finish

---

### internal_defence.sh — network scanner

Scans `192.168.0.0/24` and `10.0.10.0/24` for live hosts.

- Uses `nmap -sn` (ping scan) to discover active IPs
- Resolves hostnames via `dig`, `nslookup`, or `getent`
- Scans for open ports using `netcat` against a list of common ports (22, 80, 443, 3389, 5900, 8080, etc.), falling back to `nmap --top-ports 20`
- Looks up each IP in `config/known_devices.json` using an inline Python call
- Writes results to `logs/network/device_log.csv` under a file lock
- Compares against the previous scan's `device_status.json` to detect reconnections — if a known device was offline and is now online, a home event is logged (e.g. "Person1 is home!")

---

### wardrive_scan.sh — Wi-Fi scanner

Passively surveys nearby Wi-Fi access points using monitor mode.

- Kills interfering processes (`NetworkManager`, `wpa_supplicant`) via `airmon-ng check kill`
- Enables monitor mode on `wlan0` with `airmon-ng start`
- Runs `airodump-ng` for 15 seconds, outputting a CSV of all heard beacon frames (BSSID, SSID, channel, signal strength, encryption)
- Parses the CSV and looks up each entry in `config/known_wifi.json` by BSSID or SSID
- Appends results to `logs/wardrive/device_log.csv`
- Stops monitor mode and restarts `NetworkManager` on exit (even if the script is interrupted, via `trap`)

> **Note:** Monitor mode causes a brief network interruption on the Pi. If the Pi uses Wi-Fi for internet access, Discord delivery will be delayed slightly until NetworkManager reconnects.

---

### bluetooth.sh — Bluetooth scanner

Discovers nearby Bluetooth devices using `bluetoothctl`.

- Powers on the adapter and sets it to pairable and discoverable
- Pipes commands into `bluetoothctl`: `scan on` → sleep 30s → `scan off` → `devices`
- Also runs `sudo hcitool scan --flush` if available, to catch Classic Bluetooth devices
- Parses all output lines containing a MAC address pattern
- Looks up each MAC in `config/known_bluetooth.json`
- Writes to two files:
  - `device_log.csv` — cumulative history of all devices ever seen
  - `current_scan.csv` — **only devices from this scan** (this is what gets sent to Discord)

The split between `device_log.csv` and `current_scan.csv` is important. Discord should only show what's nearby right now, not a growing list of every device ever detected.

---

### dis_alert.py — Discord dispatcher

Called three times after each scan run (once per channel).

Reads the appropriate CSV log, formats each device entry with a `[KNOWN]` or `[UNKNOWN]` tag, and posts a rich embed to the webhook URL. If the formatted content exceeds Discord's 1,024-character field limit, it splits automatically across multiple sequential messages.

| Invocation | Channel | Content |
|---|---|---|
| `dis_alert.py motion` | Main | Motion image (attached JPEG) + internal network scan results |
| `dis_alert.py bluetooth` | Bluetooth | Current-scan Bluetooth devices only |
| `dis_alert.py wardrive` | Wi-Fi | All detected SSIDs with BSSID, channel, signal, encryption |

---

### consolidate_devices.py — status utility

Standalone script. Cross-references `device_log.csv` with `known_devices.json` and prints a summary:

```
Router (192.168.0.1) [gateway]
Raspberry Pi (10.0.10.101) [homedefence]
Phone 1 (192.168.0.50) - Offline
Unknown:192.168.0.77 [unknown]
```

Also saves the merged result to `logs/network/device_status.json`. Run independently at any time for a snapshot of the network.

---

### clear_logs.py — maintenance utility

Deletes all `.csv`, `.log`, and `.txt` files from the three log directories. Useful when resetting state during development or after changing the known-device config.

---

### test_grep.sh — Bluetooth parser tests

Writes a sample `bluetoothctl` output to `/tmp`, then tests five grep/sed patterns against it to verify that `bluetooth.sh` can correctly extract MAC addresses and names from all three line formats bluetoothctl produces:

- `[NEW] Device AA:BB:CC:DD:EE:FF name`
- `[CHG] Device AA:BB:CC:DD:EE:FF RSSI: -50`
- `Device AA:BB:CC:DD:EE:FF name` (from the `devices` command)

Run this after any changes to `bluetooth.sh`.

---

## Data flow

```
Camera frame (every 0.5s)
  └─ Background subtraction + contour analysis
       └─ 3 consecutive frames with large motion?
            └─ Save JPEG to /images/
            └─ Spawn background thread
                 ├─ Cooldown check (60s minimum between scans)
                 ├─ internal_defence.sh  →  logs/network/device_log.csv
                 ├─ wardrive_scan.sh     →  logs/wardrive/device_log.csv
                 ├─ bluetooth.sh         →  logs/bluetooth/current_scan.csv
                 │
                 └─ dis_alert.py motion    →  Main Discord channel (image + network)
                 └─ dis_alert.py bluetooth →  Bluetooth Discord channel
                 └─ dis_alert.py wardrive  →  Wi-Fi Discord channel
```

---

## Configuration

All three config files are created automatically as templates on first run. Edit them to add your own devices.

**config/known_devices.json**
```json
{
  "devices": [
    {
      "name": "Router",
      "person": "Network",
      "ip_range": ["192.168.0.1"],
      "device_type": "router",
      "welcome_message": "Main router online"
    }
  ]
}
```

**config/known_wifi.json**
```json
{
  "networks": [
    {
      "name": "Home WiFi",
      "ssid": "MyNetwork",
      "bssid": ["AA:BB:CC:DD:EE:FF"],
      "type": "trusted"
    }
  ]
}
```

**config/known_bluetooth.json**
```json
{
  "devices": [
    {
      "name": "My Phone",
      "mac_address": ["AA:BB:CC:DD:EE:FF"],
      "device_type": "phone",
      "welcome_message": "Owner is home!"
    }
  ]
}
```

**scripts/cord.env**
```
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
DISCORD_WEBHOOK_WIFI=https://discord.com/api/webhooks/...
DISCORD_WEBHOOK_BLUETOOTH=https://discord.com/api/webhooks/...
```

> **Never commit `cord.env` to source control.** Add it to `.gitignore`.

---

## Installation

**Dependencies**

```bash
# Python packages
pip3 install picamera2 opencv-python python-dotenv requests

# System packages
sudo apt install nmap netcat-openbsd aircrack-ng bluez
```

`hcitool` (part of `bluez-utils`) is optional but improves Classic Bluetooth detection.

**Steps**

```bash
# 1. Copy project to the Pi
sudo cp -r homedefence/ /homedefence/

# 2. Create cord.env with your webhook URLs
nano /homedefence/scripts/cord.env

# 3. Run each scan script once to generate config templates
bash /homedefence/scripts/internal_defence.sh
bash /homedefence/scripts/wardrive_scan.sh
bash /homedefence/scripts/bluetooth.sh

# 4. Edit the three JSON config files with your own devices
nano /homedefence/config/known_devices.json
nano /homedefence/config/known_wifi.json
nano /homedefence/config/known_bluetooth.json

# 5. Run
python3 /homedefence/scripts/motion.py
```

**Run as a systemd service**

```ini
# /etc/systemd/system/homedefence.service
[Unit]
Description=HomeDefence Security System
After=network.target

[Service]
ExecStart=/usr/bin/python3 /homedefence/scripts/motion.py
WorkingDirectory=/homedefence/scripts
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now homedefence
```

---

## Requirements

- Raspberry Pi (tested on Pi 4) with Pi Camera Module
- Wireless adapter that supports monitor mode (for wardrive scanning)
- Bluetooth adapter (built-in on Pi 3/4/5)
- Discord server with three webhook URLs configured

---

## Known limitations

- Monitor mode briefly disconnects the Pi from Wi-Fi. If the Pi has no wired connection, Discord delivery is delayed by a few seconds while NetworkManager reconnects.
- Bluetooth range is approximately 10 m. Devices using MAC address randomisation (most modern phones) will not be consistently identified.
- The two hardcoded subnets (`192.168.0.0/24` and `10.0.10.0/24`) are not currently configurable without editing `internal_defence.sh`.
- There is no per-device alert cooldown — an unknown device present in every scan will be reported every time motion triggers.

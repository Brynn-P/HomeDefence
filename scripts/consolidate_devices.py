#!/usr/bin/env python3
#consolidate_devices.py
import os
import json
import csv
from datetime import datetime

BASE_DIR = "/homedefence"
LOG_FILE = os.path.join(BASE_DIR, "logs/network/device_log.csv")
KNOWN_FILE = os.path.join(BASE_DIR, "config/known_devices.json")
STATUS_FILE = os.path.join(BASE_DIR, "logs/network/device_status.json")

def load_known_devices():
    with open(KNOWN_FILE, "r") as f:
        return json.load(f)["devices"]

def load_online_devices():
    devices = {}
    if not os.path.exists(LOG_FILE):
        return devices
    with open(LOG_FILE, "r") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if len(row) < 3:
                continue
            timestamp, ip, hostname, *ports = row
            devices[ip] = {
                "timestamp": timestamp,
                "hostname": hostname if hostname and hostname != "unknown" else "Unknown",
                "ports": ports if ports else []
            }
    return devices

def consolidate():
    known = load_known_devices()
    online = load_online_devices()
    results = {}

    # Track known devices
    for dev in known:
        name = dev["name"]
        ip_list = dev.get("ip_range", [])
        matched_ip = None
        for ip in ip_list:
            if ip in online:
                matched_ip = ip
                break

        if matched_ip:
            results[name] = {
                "status": "online",
                "ip": matched_ip,
                "hostname": online[matched_ip]["hostname"],
                "ports": online[matched_ip]["ports"],
                "last_seen": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            }
        else:
            results[name] = {
                "status": "offline",
                "ip": ip_list[0] if ip_list else "unknown",
                "last_seen": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            }

    # Track unknown devices
    for ip, info in online.items():
        if not any(ip in dev.get("ip_range", []) for dev in known):
            results[f"Unknown:{ip}"] = {
                "status": "unknown",
                "ip": ip,
                "hostname": info["hostname"],
                "ports": info["ports"],
                "last_seen": info["timestamp"]
            }

    # Save consolidated status
    with open(STATUS_FILE, "w") as f:
        json.dump(results, f, indent=2)

    return results

if __name__ == "__main__":
    consolidated = consolidate()
    print("=========================================")
    print("Consolidated Device Status")
    print("=========================================")
    for name, info in consolidated.items():
        if info["status"] == "online":
            print(f"{name} ({info['ip']}) [{info.get('hostname')}]")
        elif info["status"] == "offline":
            print(f"{name} ({info['ip']}) - Offline")
        else:
            print(f"{name} ({info['ip']}) [{info.get('hostname')}]")

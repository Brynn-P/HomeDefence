#!/usr/bin/env python3
import os, glob

dirs = [
    "/homedefence/logs/network",
    "/homedefence/logs/bluetooth",
    "/homedefence/logs/wardrive",
]

# File extensions we want to clear
extensions = ["*.txt", "*.csv", "*.log"]

for d in dirs:
    for ext in extensions:
        for f in glob.glob(os.path.join(d, ext)):
            try:
                os.remove(f)
                print(f"Deleted: {f}")
            except Exception as e:
                print(f"Could not delete {f}: {e}")

print("[*] All logs cleared.")

import os
import json
import requests
from dotenv import load_dotenv
from datetime import datetime

# Load .env
load_dotenv("/homedefence/scripts/cord.env")
WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL")

if not WEBHOOK_URL:
    print("Webhook URL not set!")
    exit(1)

# Pick a test image (make sure this file exists)
TEST_IMAGE = "/homedefence/images/motion_20250827_180931.jpg"

embed = {
    "title": "Test Alert with Image",
    "description": "If you see this with an image, Discord uploads are working.",
    "color": 0xFF0000,
    "timestamp": datetime.utcnow().isoformat()
}

data = {"embeds": [embed]}
files = None

if os.path.isfile(TEST_IMAGE):
    filename = os.path.basename(TEST_IMAGE)
    embed["image"] = {"url": f"attachment://{filename}"}
    files = {filename: open(TEST_IMAGE, "rb")}  # key matches the filename

# Send webhook
response = requests.post(WEBHOOK_URL, data={"payload_json": json.dumps(data)}, files=files)

if files:
    files[filename].close()

print(f"Response: {response.status_code}, {response.text}")

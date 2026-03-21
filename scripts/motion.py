#!/usr/bin/env python3
#motion.py
"""
HomeDefence Motion Detection System
Uses Raspberry Pi camera to detect motion
Triggers security scans and sends Discord alerts when motion is detected
"""

import time
import cv2
import os
import subprocess
import threading
from datetime import datetime
from picamera2 import Picamera2
from dotenv import load_dotenv

# ============================================================================
# CONFIGURATION - Load environment variables
# ============================================================================
load_dotenv("/homedefence/scripts/cord.env")

# ============================================================================
# CONSTANTS - Directories and settings
# ============================================================================
IMAGE_DIR = "/homedefence/images"           # Where motion capture images are saved
LOG_FILE = "/homedefence/logs/motion.log"   # Motion detection event log
DEBOUNCE_TIME = 5                               # Seconds to wait between motion alerts
MIN_AREA = 25000                                # Minimum pixel area to trigger motion (larger = less sensitive)
LAST_SCAN_FILE = "/tmp/homewatch_last_motion_scan"  # Tracks when last scan occurred
SCAN_COOLDOWN = 60                              # Minimum seconds between full security scans

# Create directories if they don't exist
os.makedirs(IMAGE_DIR, exist_ok=True)
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

# ============================================================================
# LOGGING FUNCTION
# ============================================================================

def log_event(msg):
    """
    Log an event to both file and console with timestamp
    Args:
        msg (str): Message to log
    """
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{timestamp}] {msg}\n")
    print(f"[{timestamp}] {msg}")  # Also print to console

# ============================================================================
# SECURITY SCANS - Run all security scan scripts
# ============================================================================

def run_scans_blocking():
    """
    Run all security scan scripts synchronously (blocking)
    
    Executes:
        1. internal_defence.sh - Network device scan
        2. wardrive_scan.sh - WiFi network scan
        3. bluetooth.sh - Bluetooth device scan
    
    Implements cooldown timer to prevent excessive scanning
    
    Returns:
        bool: True if all scans completed successfully, False otherwise
    """
    now_ts = int(time.time())
    last_ts = 0
    
    # ========================================================================
    # CHECK COOLDOWN TIMER
    # Prevents running scans too frequently (default: 60 seconds)
    # ========================================================================
    if os.path.isfile(LAST_SCAN_FILE):
        try:
            with open(LAST_SCAN_FILE, "r") as f:
                last_ts = int(f.read().strip())
        except (ValueError, IOError):
            last_ts = 0

    # If not enough time has passed, skip the scan
    if now_ts - last_ts < SCAN_COOLDOWN:
        log_event(f"[SKIP] Scan skipped due to cooldown ({now_ts - last_ts}s elapsed)")
        return False

    # ========================================================================
    # UPDATE COOLDOWN TIMESTAMP
    # ========================================================================
    try:
        with open(LAST_SCAN_FILE, "w") as f:
            f.write(str(now_ts))
    except IOError as e:
        log_event(f"[ERROR] Failed to update scan timestamp: {e}")
        return False

    # ========================================================================
    # DEFINE SCRIPTS TO RUN
    # ========================================================================
    scripts_to_run = [
        "/homedefence/scripts/internal_defence.sh",  # Network scan
        "/homedefence/scripts/wardrive_scan.sh",      # WiFi scan
        "/homedefence/scripts/bluetooth.sh"           # Bluetooth scan
    ]
    
    all_success = True
    
    # ========================================================================
    # EXECUTE EACH SCRIPT
    # ========================================================================
    for script in scripts_to_run:
        # Check if script exists
        if not os.path.isfile(script):
            log_event(f"[WARNING] Script not found (skipping): {script}")
            continue
        
        # Check if script is executable
        if not os.access(script, os.X_OK):
            log_event(f"[WARNING] Script not executable, attempting to fix: {script}")
            try:
                os.chmod(script, 0o755)  # Make executable (rwxr-xr-x)
                log_event(f"[SUCCESS] Made script executable")
            except Exception as e:
                log_event(f"[ERROR] Failed to make script executable: {e}")
                continue
        
        # ====================================================================
        # RUN SCRIPT WITH BASH
        # ====================================================================
        try:
            log_event(f"[SCAN] Running {os.path.basename(script)}...")
            log_event(f"[INFO] Script path: {script}")
            
            # Execute script and capture output
            result = subprocess.run(
                ["bash", script],
                capture_output=True,   # Capture stdout and stderr
                text=True,             # Return output as string (not bytes)
                timeout=180,           # 3 minute timeout (increased for wardrive/bluetooth)
                cwd="/homedefence/scripts"  # Run from scripts directory
            )
            
            # ================================================================
            # LOG SCRIPT OUTPUT (last 500 chars to avoid spam)
            # ================================================================
            if result.stdout:
                log_event(f"[OUTPUT] {os.path.basename(script)} output:\n{result.stdout[-500:]}")
            if result.stderr:
                log_event(f"[WARNING] {os.path.basename(script)} stderr:\n{result.stderr[-500:]}")
            
            # ================================================================
            # CHECK RETURN CODE
            # ================================================================
            if result.returncode == 0:
                log_event(f"[SUCCESS] Successfully completed {os.path.basename(script)}")
            else:
                log_event(f"[ERROR] {os.path.basename(script)} returned code {result.returncode}")
                all_success = False
                    
        except subprocess.TimeoutExpired:
            log_event(f"[ERROR] {os.path.basename(script)} timed out after 3 minutes")
            all_success = False
        except Exception as e:
            log_event(f"[ERROR] Failed to run {os.path.basename(script)}: {e}")
            all_success = False
    
    return all_success

# ============================================================================
# DISCORD ALERTS - Send notifications to all channels
# ============================================================================

def send_discord_alerts(image_path=None):
    """
    Send Discord alerts to all configured channels after scans complete
    
    Sends:
        1. Motion alert to main channel (with image and network scan)
        2. Bluetooth scan to Bluetooth channel
        3. Wardrive scan to WiFi channel
    
    Args:
        image_path (str): Path to motion capture image (optional)
    """
    try:
        # ====================================================================
        # SEND MOTION ALERT TO MAIN CHANNEL
        # Includes: Image, timestamp, network scan results
        # ====================================================================
        log_event("[ALERT] Sending comprehensive motion alert to Discord...")
        
        result = subprocess.run(
            ["python3", "/homedefence/scripts/dis_alert.py", "motion"],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            log_event("[SUCCESS] Motion alert sent to main channel")
        else:
            log_event(f"[WARNING] Motion alert returned code {result.returncode}")
            if result.stderr:
                log_event(f"Error: {result.stderr[-200:]}")
        
        # Small delay between webhooks to avoid rate limiting
        time.sleep(2)
        
        # ====================================================================
        # SEND BLUETOOTH SCAN TO BLUETOOTH CHANNEL
        # ====================================================================
        log_event("[ALERT] Sending Bluetooth scan to dedicated channel...")
        result = subprocess.run(
            ["python3", "/homedefence/scripts/dis_alert.py", "bluetooth"],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            log_event("[SUCCESS] Bluetooth alert sent")
        else:
            log_event(f"[WARNING] Bluetooth alert returned code {result.returncode}")
        
        time.sleep(2)
        
        # ====================================================================
        # SEND WARDRIVE SCAN TO WIFI CHANNEL
        # ====================================================================
        log_event("[ALERT] Sending Wardrive scan to dedicated channel...")
        result = subprocess.run(
            ["python3", "/homedefence/scripts/dis_alert.py", "wardrive"],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            log_event("[SUCCESS] Wardrive alert sent")
        else:
            log_event(f"[WARNING] Wardrive alert returned code {result.returncode}")
        
        log_event("[SUCCESS] All Discord alerts processed")
        
    except Exception as e:
        log_event(f"[ERROR] Failed to send Discord alerts: {e}")

# ============================================================================
# CAMERA SETUP
# ============================================================================

def setup_camera():
    """
    Initialize Raspberry Pi camera with error handling and retries
    
    Configures camera for:
        - 1920x1080 resolution
        - RGB888 format (for OpenCV processing)
    
    Returns:
        Picamera2: Initialized camera object
    
    Raises:
        Exception: If camera fails to initialize after max_retries
    """
    max_retries = 3
    
    for attempt in range(max_retries):
        try:
            # Initialize camera
            picam2 = Picamera2()
            
            # Configure camera settings
            config = picam2.create_preview_configuration(
                main={"format": "RGB888", "size": (1920, 1080)}
            )
            picam2.configure(config)
            
            # Start camera
            picam2.start()
            time.sleep(2)  # Give camera time to warm up
            
            # Test capture to verify camera is working
            test_frame = picam2.capture_array()
            if test_frame is not None:
                log_event("[SUCCESS] Camera initialized successfully")
                return picam2
            else:
                raise Exception("Camera test capture failed")
                
        except Exception as e:
            log_event(f"[ERROR] Camera setup attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(5)  # Wait before retry
            else:
                raise Exception("Failed to initialize camera after multiple attempts")

# ============================================================================
# MOTION DETECTION - Main detection loop
# ============================================================================

def detect_motion():
    """
    Main motion detection loop
    
    Algorithm:
        1. Capture frame from camera
        2. Convert to grayscale and blur (reduce noise)
        3. Compare with background frame
        4. Detect significant changes (motion)
        5. If motion confirmed for MOTION_CONFIRM_FRAMES consecutive frames:
            - Save image
            - Run security scans
            - Send Discord alerts
    
    Uses background subtraction with slow adaptation to handle lighting changes
    """
    # Initialize camera
    picam2 = setup_camera()
    
    # Motion detection variables
    first_frame = None              # Background reference frame
    motion_counter = 0              # Count consecutive frames with motion
    MOTION_CONFIRM_FRAMES = 3       # Frames needed to confirm motion (reduce false positives)
    last_background_reset = time.time()  # Track when background was last reset
    frame_count = 0                 # Total frames processed
    
    log_event("[START] Motion detection started")
    
    # ========================================================================
    # MAIN DETECTION LOOP
    # ========================================================================
    while True:
        try:
            # ================================================================
            # CAPTURE FRAME
            # ================================================================
            try:
                frame = picam2.capture_array()
                if frame is None:
                    log_event("[WARNING] Warning: Captured frame is None")
                    continue
            except Exception as e:
                log_event(f"[ERROR] Frame capture error: {e}")
                time.sleep(1)
                continue
            
            frame_count += 1
            
            # ================================================================
            # PREPROCESS FRAME
            # Convert to grayscale and blur to reduce noise
            # ================================================================
            gray = cv2.cvtColor(frame, cv2.COLOR_RGB2GRAY)
            gray = cv2.GaussianBlur(gray, (25, 25), 0)  # 25x25 kernel blur

            # ================================================================
            # INITIALIZE BACKGROUND FRAME
            # First frame becomes the reference "no motion" state
            # ================================================================
            if first_frame is None:
                first_frame = gray
                log_event("[SUCCESS] Background frame initialized")
                continue

            # ================================================================
            # DETECT MOTION
            # Compare current frame with background
            # ================================================================
            # Calculate absolute difference between frames
            delta = cv2.absdiff(first_frame, gray)
            
            # Threshold to binary image (white = changed pixels)
            _, thresh = cv2.threshold(delta, 25, 255, cv2.THRESH_BINARY)
            
            # Dilate to fill in holes (join nearby motion areas)
            thresh = cv2.dilate(thresh, None, iterations=2)
            
            # Find contours (regions of motion)
            contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

            # Check if any contour is large enough to be significant motion
            motion_detected = any(cv2.contourArea(c) >= MIN_AREA for c in contours)

            # ================================================================
            # MOTION CONFIRMATION
            # Require multiple consecutive frames to reduce false positives
            # ================================================================
            if motion_detected:
                motion_counter += 1
                # Log progress every 10 frames (avoid spam)
                if frame_count % 10 == 0:
                    log_event(f"[DETECT] Motion detected (confidence: {motion_counter}/{MOTION_CONFIRM_FRAMES})")
            else:
                motion_counter = 0  # Reset if motion stops

            # ================================================================
            # CONFIRMED MOTION - TRIGGER SECURITY RESPONSE
            # ================================================================
            if motion_counter >= MOTION_CONFIRM_FRAMES:
                motion_counter = 0  # Reset counter
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                img_path = os.path.join(IMAGE_DIR, f"motion_{timestamp}.jpg")
                
                # ============================================================
                # SAVE IMAGE
                # ============================================================
                try:
                    bgr_frame = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
                    cv2.imwrite(img_path, bgr_frame)
                    log_event(f"[ALERT] Motion confirmed! Image saved: {img_path}")
                except Exception as e:
                    log_event(f"[ERROR] Failed to save image: {e}")
                    img_path = None

                # ============================================================
                # RUN SCANS AND SEND ALERTS IN BACKGROUND THREAD
                # Uses thread to avoid blocking motion detection
                # ============================================================
                def scan_and_alert():
                    """Background thread: run scans and send alerts"""
                    log_event("[THREAD] Starting scan and alert thread...")
                    
                    # Run all security scans (blocking)
                    scan_success = run_scans_blocking()
                    
                    if scan_success:
                        log_event("[SUCCESS] All scans completed successfully")
                    else:
                        log_event("[WARNING] Some scans failed or were skipped")
                    
                    # Give filesystem time to sync before reading CSVs
                    time.sleep(3)
                    
                    # Send all Discord alerts
                    send_discord_alerts(image_path=img_path)
                    
                    log_event("[SUCCESS] Scan and alert thread completed")
                
                # Start background thread
                alert_thread = threading.Thread(target=scan_and_alert, daemon=True)
                alert_thread.start()

            # ================================================================
            # UPDATE BACKGROUND FRAME
            # Slowly adapt to lighting changes (95% old, 5% new)
            # ================================================================
            if first_frame is not None:
                first_frame = cv2.addWeighted(first_frame, 0.95, gray, 0.05, 0)

            # ================================================================
            # PERIODIC BACKGROUND RESET
            # Reset background every 5 minutes to handle major lighting changes
            # ================================================================
            if time.time() - last_background_reset > 300:  # 300 seconds = 5 minutes
                first_frame = None
                last_background_reset = time.time()
                log_event("[RESET] Background frame reset")

            # Small delay between frames (0.5 seconds = ~2 FPS)
            time.sleep(0.5)

        # ====================================================================
        # ERROR HANDLING
        # ====================================================================
        except KeyboardInterrupt:
            log_event("[STOP] Motion detection stopped by user")
            break
        except Exception as e:
            log_event(f"[ERROR] Unexpected error in motion detection loop: {e}")
            time.sleep(5)
            
            # Try to reinitialize camera on error
            try:
                picam2.stop()
                time.sleep(2)
                picam2 = setup_camera()
            except Exception as cam_err:
                log_event(f"[ERROR] Failed to reinitialize camera: {cam_err}")

    # ========================================================================
    # CLEANUP
    # ========================================================================
    try:
        picam2.stop()
        log_event("[SUCCESS] Camera stopped successfully")
    except:
        pass

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

if __name__ == "__main__":
    try:
        detect_motion()
    except Exception as e:
        log_event(f"[FATAL] Fatal error: {e}")
        exit(1)

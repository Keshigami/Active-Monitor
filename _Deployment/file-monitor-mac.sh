#!/bin/bash
# File Activity Monitor for macOS
# With rate limiting, app tracking, and daily reports
VERSION="1.5"


WEBHOOK_URL="${WEBHOOK_URL:-http://192.168.1.171:5678/webhook/file-activity}"
# Default to watching HOME, but can include others
WATCH_DIRS="${WATCH_DIRS:-$HOME}"
LOG_FILE="/tmp/file-monitor.log"
EVENTS_LOG="$HOME/.file-events.json"

echo "=== File Activity Monitor Setup ==="

# Install dependencies
python3 -m pip install watchdog flask --user --quiet 2>/dev/null

# Create the monitor script
MONITOR_SCRIPT="$HOME/.file-monitor.py"
cat << 'PYTHON_SCRIPT' > "$MONITOR_SCRIPT"
#!/usr/bin/env python3
import os
import sys
import json
import time
import shutil
import subprocess
import urllib.request
import threading
from datetime import datetime, date, timedelta
from collections import deque
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from flask import Flask, jsonify

WEBHOOK_URL = os.environ.get('WEBHOOK_URL', 'http://192.168.1.171:5678/webhook/file-activity')
CURRENT_VERSION = "1.5"

def check_for_updates():
    try:
        url = "http://192.168.1.171:8888/file-monitor-mac.sh"
        print(f"Checking updates from {url}...")
        
        with urllib.request.urlopen(url, timeout=2) as response:
            content = response.read().decode('utf-8')
            
            # Simple parsing for VERSION="X.X"
            for line in content.splitlines():
                if line.startswith('VERSION='):
                    remote_ver = line.split('=')[1].strip('"')
                    if remote_ver != CURRENT_VERSION:
                        print(f"Update found: {remote_ver} (Current: {CURRENT_VERSION})")
                        
                        # Download and run
                        installer = "/tmp/file-monitor-mac.sh"
                        with open(installer, 'w') as f:
                            f.write(content)
                        
                        subprocess.run(["chmod", "+x", installer])
                        # Run installer in background and exit this process
                        subprocess.Popen(["bash", installer])
                        sys.exit(0)
                    else:
                        print("Monitor is up to date.")
                    break
    except Exception as e:
        print(f"Update check failed: {e}")


# Parse watch dirs from env (comma separated)
watch_dirs_env = os.environ.get('WATCH_DIRS', os.path.expanduser('~'))
WATCH_DIRS = [d.strip() for d in watch_dirs_env.split(',')]

# Auto-add /Volumes for external drives
if len(WATCH_DIRS) == 1 and WATCH_DIRS[0] == os.path.expanduser('~'):
    if os.path.exists('/Volumes'):
        WATCH_DIRS.append('/Volumes')

# --- SPECIAL PATHS FOR EVENT CLASSIFICATION ---
DOWNLOADS_PATH = os.path.expanduser('~/Downloads')

# Cloud sync folders (common macOS locations)
CLOUD_SYNC_PATHS = [
    os.path.expanduser('~/Library/Mobile Documents/com~apple~CloudDocs'),  # iCloud Drive
    os.path.expanduser('~/iCloud Drive'),
    os.path.expanduser('~/Dropbox'),
    os.path.expanduser('~/Google Drive'),
    os.path.expanduser('~/OneDrive'),
    os.path.expanduser('~/Box'),
    '/Library/CloudStorage',  # Newer macOS cloud storage location
    os.path.expanduser('~/Library/CloudStorage'),  # User-level cloud storage
]

# External drives path (macOS mounts external drives here)
EXTERNAL_VOLUMES_PATH = '/Volumes'

def classify_event(path, base_event_type):
    """Classify created events as download, external_copy, or cloud_upload"""
    if base_event_type != 'created':
        return base_event_type
    
    # Check Downloads folder
    if path.startswith(DOWNLOADS_PATH):
        return 'download'
    
    # Check cloud sync folders
    for cloud_path in CLOUD_SYNC_PATHS:
        if cloud_path and os.path.exists(cloud_path) and path.startswith(cloud_path):
            return 'cloud_upload'
    
    # Check external/USB drives (anything in /Volumes except the boot drive)
    if path.startswith(EXTERNAL_VOLUMES_PATH):
        # Get the volume name from path
        path_parts = path.split('/')
        if len(path_parts) >= 3:
            volume_name = path_parts[2]
            # Boot drive is usually "Macintosh HD" but let's check if it's not the root
            boot_volume = os.path.realpath('/')
            volume_path = f'/Volumes/{volume_name}'
            if os.path.realpath(volume_path) != boot_volume:
                return 'external_copy'
    
    return base_event_type

# Browser process names for detection
BROWSER_APPS = ['Safari', 'Google Chrome', 'Firefox', 'Microsoft Edge', 'Brave Browser', 'Opera', 'Arc', 'Vivaldi']

def is_browser_active():
    """Check if the active app is a browser"""
    try:
        current_app = get_active_app()
        return any(browser.lower() in current_app.lower() for browser in BROWSER_APPS)
    except:
        return False

# Clipboard monitoring
last_clipboard = ""

def get_clipboard_files():
    """Get file paths from macOS clipboard using pbpaste"""
    try:
        # Use osascript to get file paths from clipboard
        script = 'try\nset theFiles to (the clipboard as «class furl»)\nreturn POSIX path of theFiles\nend try'
        result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=2)
        if result.returncode == 0 and result.stdout.strip():
            path = result.stdout.strip()
            if os.path.isfile(path):
                return [path]
        return []
    except:
        return []

def clipboard_monitor():
    """Background thread to monitor clipboard for file paths"""
    global last_clipboard
    while True:
        try:
            time.sleep(30)  # Check every 30 seconds
            files = get_clipboard_files()
            if files:
                current_clip = '|'.join(files)
                if current_clip != last_clipboard:
                    last_clipboard = current_clip
                    for file_path in files:
                        if os.path.isfile(file_path):
                            event = {
                                "timestamp": datetime.now().astimezone().isoformat(),
                                "event": "clipboard_file",
                                "path": file_path,
                                "filename": os.path.basename(file_path),
                                "app": "Clipboard"
                            }
                            todays_events.append(event)
                            save_events()
                            
                            payload = {**event, "machine": os.uname().nodename}
                            try:
                                data = json.dumps(payload).encode('utf-8')
                                req = urllib.request.Request(WEBHOOK_URL, data=data,
                                    headers={'Content-Type': 'application/json'})
                                urllib.request.urlopen(req, timeout=5)
                                print(f"[clipboard_file] {os.path.basename(file_path)}")
                            except Exception as e:
                                print(f"Clipboard webhook failed: {e}")
        except Exception as e:
            pass  # Silently ignore clipboard errors to prevent crashes

EVENTS_LOG = os.path.expanduser('~/.file-events.json')

# Ignore system paths and high-frequency noise
IGNORE_PATTERNS = [
    '.git', 'node_modules', '.DS_Store', '__pycache__', '.tmp',
    'Library', '.Trash', '.cache', 'Caches', 'Cache', '.npm', '.config',
    'Application Support', 'Google/Chrome', '.local', '.vscode',
    'CrashReporter', 'Saved Application State', 'WebKit', '.file-events',
    'log.txt', '.parsec', 'Parsec', # Exclude Parsec specifically from general monitor
    '.wdc', '.log', '.tmp', '.idlk', 'Info.plist', '.plist', 'Render Files', 'Analysis Files', 'Transcoded Media', 'Proxies', 'Frame '
]

# Rate limiting - balanced for visibility without freezing
MAX_EVENTS_PER_MINUTE = 5
MAX_EVENTS_STORED = 1000  # Maximum events to keep in memory
event_times = deque(maxlen=MAX_EVENTS_PER_MINUTE)
last_sent = {}
MIN_EVENT_GAP = 10  # seconds between events for same file

# In-memory events
todays_events = deque(maxlen=MAX_EVENTS_STORED)

# Track connected Parsec users (clean usernames without #ID)
connected_users = set()
last_archive_check = time.time()

# Track active app
last_app = None
last_app_time = 0

def get_active_app():
    """Get the currently focused application using AppleScript"""
    try:
        script = 'tell application "System Events" to get name of first application process whose frontmost is true'
        result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=2)
        return result.stdout.strip() if result.returncode == 0 else "Unknown"
    except:
        return "Unknown"

def load_events():
    global today_date, todays_events
    today_date = date.today().isoformat()
    
    if os.path.exists(EVENTS_LOG):
        try:
            with open(EVENTS_LOG, 'r') as f:
                data = json.load(f)
                
            file_date = data.get('date')
            
            if file_date == today_date:
                todays_events = deque(data.get('events', []), maxlen=MAX_EVENTS_STORED)
            else:
                # New day: Archive previous log
                archive_dir = os.path.join(os.path.dirname(EVENTS_LOG), 'Archive')
                if not os.path.exists(archive_dir):
                    os.makedirs(archive_dir)
                
                archive_name = f'events-{file_date if file_date else "unknown"}.json'
                archive_path = os.path.join(archive_dir, archive_name)
                
                # Copy current log to archive
                shutil.copy2(EVENTS_LOG, archive_path)
                print(f"Archived usage log to {archive_name}")
                
                # Cleanup archives older than 30 days
                cutoff = datetime.now() - timedelta(days=30)
                for f in os.listdir(archive_dir):
                    fp = os.path.join(archive_dir, f)
                    if os.path.isfile(fp) and os.stat(fp).st_mtime < cutoff.timestamp():
                        os.remove(fp)
                
                # Reset for new day
                todays_events = deque(maxlen=MAX_EVENTS_STORED)
        except Exception as e:
            print(f"Failed to load events: {e}")
            todays_events = deque(maxlen=MAX_EVENTS_STORED)
    else:
        todays_events = deque(maxlen=MAX_EVENTS_STORED)

def save_events():
    global last_archive_check
    # Periodic archive check (every hour)
    now = time.time()
    if now - last_archive_check > 3600:  # 1 hour
        last_archive_check = now
        check_and_archive()
    
    with open(EVENTS_LOG, 'w') as f:
        json.dump({'date': str(date.today()), 'events': list(todays_events)}, f)

def check_and_archive():
    """Check if date changed and archive if needed"""
    global todays_events
    today_date = date.today().isoformat()
    
    if os.path.exists(EVENTS_LOG):
        try:
            with open(EVENTS_LOG, 'r') as f:
                data = json.load(f)
            file_date = data.get('date')
            
            if file_date and file_date != today_date:
                # Date changed: Archive and reset
                archive_dir = os.path.join(os.path.dirname(EVENTS_LOG), 'Archive')
                if not os.path.exists(archive_dir):
                    os.makedirs(archive_dir)
                
                archive_name = f'events-{file_date}.json'
                archive_path = os.path.join(archive_dir, archive_name)
                shutil.copy2(EVENTS_LOG, archive_path)
                print(f"[ARCHIVE] Archived log to {archive_name}")
                
                # Cleanup old archives (30 days)
                cutoff = datetime.now() - timedelta(days=30)
                for fn in os.listdir(archive_dir):
                    fp = os.path.join(archive_dir, fn)
                    if os.path.isfile(fp) and os.stat(fp).st_mtime < cutoff.timestamp():
                        os.remove(fp)
                
                # Reset events for new day
                todays_events = deque(maxlen=MAX_EVENTS_STORED)
                print(f"[ARCHIVE] Started new log for {today_date}")
        except Exception as e:
            print(f"Archive check failed: {e}")

def get_connected_users():
    """Return comma-separated list of connected users, or 'local' if none"""
    if connected_users:
        return ', '.join(sorted(connected_users))
    return 'local'


class FileMonitor(FileSystemEventHandler):
    def should_ignore(self, path):
        return any(p in path for p in IGNORE_PATTERNS)
    
    def log_event(self, event_type, path):
        global last_app, last_app_time
        
        if self.should_ignore(path):
            return
        
        event_key = f"{path}"
        now = time.time()
        if event_key in last_sent and (now - last_sent[event_key]) < MIN_EVENT_GAP:
            return
        
        while event_times and (now - event_times[0]) > 60:
            event_times.popleft()
        
        if len(event_times) >= MAX_EVENTS_PER_MINUTE:
            return
        
        last_sent[event_key] = now
        event_times.append(now)
        
        # Classify event type based on path
        classified_event = classify_event(path, event_type)
        
        # --- BROWSER UPLOAD DETECTION ---
        # If a file is modified while browser is active, it may be an upload
        if event_type == 'modified' and classified_event == 'modified':
            if is_browser_active():
                classified_event = 'browser_upload'
        
        # Get active app (cache for 30 seconds to reduce CPU usage from osascript)
        if now - last_app_time > 30:
            last_app = get_active_app()
            last_app_time = now
        
        event = {
            "timestamp": datetime.now().astimezone().isoformat(),
            "event": classified_event,
            "path": path,
            "filename": os.path.basename(path),
            "app": last_app,
            "connected_user": get_connected_users()
        }
        
        todays_events.append(event)
        save_events()
        
        # Send webhook
        payload = {**event, "machine": os.uname().nodename}
        try:
            data = json.dumps(payload).encode('utf-8')
            req = urllib.request.Request(WEBHOOK_URL, data=data, 
                headers={'Content-Type': 'application/json'})
            urllib.request.urlopen(req, timeout=5)
            print(f"[{classified_event}] [{last_app}] {path}")
        except Exception as e:
            print(f"Webhook failed: {e}")
    
    def on_modified(self, event):
        if not event.is_directory:
            self.log_event("modified", event.src_path)
    
    def on_created(self, event):
        if not event.is_directory:
            self.log_event("created", event.src_path)
    
    def on_deleted(self, event):
        if not event.is_directory:
            self.log_event("deleted", event.src_path)

class ParsecLogHandler(FileSystemEventHandler):
    def __init__(self, log_path, webhook_url):
        self.log_path = log_path
        self.webhook_url = webhook_url
        self.last_pos = os.path.getsize(log_path) if os.path.exists(log_path) else 0

    def on_modified(self, event):
        # Relaxed check: just match filename
        if os.path.basename(event.src_path) != os.path.basename(self.log_path): 
            return
        
        # print(f"DEBUG: Parsec log file modified: {event.src_path}")
        
        try:
            with open(self.log_path, 'r', encoding='utf-8', errors='ignore') as f:
                f.seek(self.last_pos)
                new_content = f.read()
                self.last_pos = f.tell()
                
                for line in new_content.splitlines():
                    # print(f"DEBUG: New line: {line}")
                    parts = line.split(']')
                    if len(parts) > 1:
                        msg = parts[1].strip()
                        # Strict check for user connection format (lowercase)
                        if " connected." in msg or " disconnected." in msg:
                            user_part = msg.split(' ')[0] 
                            status = "connected" if " connected." in msg else "disconnected"
                            
                            # Ignore false positives like "IPC"
                            if user_part in ["IPC", "Parsec", "Virtual", "Hosting"]:
                                continue
                            
                            # Rate limit: Skip if same user+status within 10 seconds
                            parsec_key = f"{user_part}-{status}"
                            now = time.time()
                            
                            if not hasattr(self, 'parsec_rate_limits'):
                                self.parsec_rate_limits = {}

                            if parsec_key in self.parsec_rate_limits:
                                if now - self.parsec_rate_limits[parsec_key] < 10:
                                    continue
                            
                            self.parsec_rate_limits[parsec_key] = now

                            # Extract clean username (remove #ID)
                            clean_user = user_part.split('#')[0]
                            
                            # Update connected users tracking
                            if status == "connected":
                                connected_users.add(clean_user)
                            else:
                                connected_users.discard(clean_user)

                            payload = {
                                "timestamp": datetime.now().astimezone().isoformat(),
                                "event": "parsec_connection",
                                "status": status,
                                "user": clean_user,
                                "machine": os.uname().nodename
                            }
                            
                            # Store Parsec event for daily summary
                            todays_events.append(payload)
                            save_events()
                            
                            req = urllib.request.Request(self.webhook_url, 
                                data=json.dumps(payload).encode('utf-8'), 
                                headers={'Content-Type': 'application/json'})
                            try:
                                urllib.request.urlopen(req, timeout=5)
                                print(f"[PARSEC] {user_part} {status}")
                            except:
                                pass
        except Exception as e:
            print(f"Error reading Parsec log: {e}")

# HTTP server for log retrieval
app = Flask(__name__)

@app.route('/logs')
def get_logs():
    return jsonify({'date': str(date.today()), 'events': list(todays_events), 'machine': os.uname().nodename})

@app.route('/logs/clear', methods=['POST'])
def clear_logs():
    global todays_events
    todays_events = []
    save_events()
    return jsonify({'status': 'cleared'})

def run_server():
    app.run(host='0.0.0.0', port=8080, debug=False, use_reloader=False)

if __name__ == "__main__":
    load_events()
    print(f"Watch Dirs: {WATCH_DIRS}")
    print(f"Webhook: {WEBHOOK_URL}")
    print(f"Log API: http://0.0.0.0:8080/logs")
    print(f"App tracking: Enabled")
    
    # --- AUTO-UPDATE CHECK ---
    check_for_updates()
    # -------------------------

    # Start HTTP server
    server_thread = threading.Thread(target=run_server, daemon=True)
    server_thread.start()
    
    # Start clipboard monitoring thread
    clipboard_thread = threading.Thread(target=clipboard_monitor, daemon=True)
    clipboard_thread.start()
    print("Clipboard monitoring: Enabled (checks every 30s)")
    
    # Start file watchers for each dir
    observer = Observer()
    for directory in WATCH_DIRS:
        if os.path.exists(directory):
            print(f" -> Adding watch: {directory}")
            observer.schedule(FileMonitor(), directory, recursive=True)
        else:
            print(f" -> Skipped (not found): {directory}")
            
    # Add Parsec Log Watcher - Check multiple possible locations
    parsec_log_paths = [
        os.path.expanduser('~/.parsec/log.txt'),
        '/Users/Shared/.parsec/log.txt',  # Shared installer
        os.path.expanduser('~/Library/Application Support/Parsec/log.txt'),
        os.path.expanduser('~/Library/Logs/Parsec/log.txt'),
        os.path.expanduser('~/Library/Preferences/Parsec/log.txt'),
        os.path.expanduser('~/Library/Containers/tv.parsec.www/Data/Library/Logs/log.txt'),
        '/tmp/parsec.log',
    ]
    
    parsec_log_found = None
    for log_path in parsec_log_paths:
        if os.path.exists(log_path):
            parsec_log_found = log_path
            break
    
    if parsec_log_found:
        print(f" -> Watching Parsec Log: {parsec_log_found}")
        observer.schedule(ParsecLogHandler(parsec_log_found, WEBHOOK_URL), os.path.dirname(parsec_log_found), recursive=False)
    else:
        print(f" -> Parsec log not found. Checked: {parsec_log_paths}")

    observer.start()
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
PYTHON_SCRIPT

chmod +x "$MONITOR_SCRIPT"

# Create LaunchAgent
PLIST_PATH="$HOME/Library/LaunchAgents/com.filemonitor.plist"
cat << EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.filemonitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$MONITOR_SCRIPT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>WEBHOOK_URL</key>
        <string>$WEBHOOK_URL</string>
        <key>WATCH_DIRS</key>
        <string>$WATCH_DIRS</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_PATH" 2>/dev/null
launchctl load "$PLIST_PATH"

echo ""
echo "✅ File Monitor with App Tracking installed!"
echo "   Watching: $WATCH_DIRS (and /Volumes)"
echo "   Webhook: $WEBHOOK_URL"
echo "   App Tracking: Enabled"
echo "   Log API: http://$(hostname):8080/logs"

# --- SELF-TEST VERIFICATION ---
echo ""
echo "🔄 Running self-test..."
echo ""

# Wait for monitor to start, then restart to ensure watchdog initializes
sleep 3
echo "   Restarting monitor to ensure watchdog initializes..."
pkill -f "file-monitor.py" 2>/dev/null
sleep 2
launchctl load "$PLIST_PATH" 2>/dev/null
sleep 3

TEST_FILE="$HOME/Desktop/monitor_selftest_$(date +%s)"
PASSED=0
FAILED=0

# --- TEST 1: FILE CREATED ---
echo "  [TEST 1] File Created..."
touch "$TEST_FILE"
sleep 12
LOGS=$(curl -s "http://localhost:8080/logs" 2>/dev/null)
if echo "$LOGS" | grep -q "monitor_selftest" && echo "$LOGS" | grep -q '"event".*"created"'; then
    echo "    ✅ Created event captured"
    PASSED=$((PASSED + 1))
else
    echo "    ⚠️  Created event not found (may be rate-limited)"
    FAILED=$((FAILED + 1))
fi

# --- TEST 2: FILE MODIFIED ---
echo "  [TEST 2] File Modified..."
echo "modified content" >> "$TEST_FILE"
sleep 12
LOGS=$(curl -s "http://localhost:8080/logs" 2>/dev/null)
if echo "$LOGS" | grep -q "monitor_selftest" && echo "$LOGS" | grep -q '"event".*"modified"'; then
    echo "    ✅ Modified event captured"
    PASSED=$((PASSED + 1))
else
    echo "    ⚠️  Modified event not found (may be rate-limited)"
    FAILED=$((FAILED + 1))
fi

# --- TEST 3: FILE DELETED ---
echo "  [TEST 3] File Deleted..."
rm -f "$TEST_FILE"
sleep 12
LOGS=$(curl -s "http://localhost:8080/logs" 2>/dev/null)
if echo "$LOGS" | grep -q "monitor_selftest" && echo "$LOGS" | grep -q '"event".*"deleted"'; then
    echo "    ✅ Deleted event captured"
    PASSED=$((PASSED + 1))
else
    echo "    ⚠️  Deleted event not found (may be rate-limited)"
    FAILED=$((FAILED + 1))
fi

# Summary
echo ""
if [ $PASSED -eq 3 ]; then
    echo "✅ All file event tests PASSED ($PASSED/3)"
elif [ $PASSED -gt 0 ]; then
    echo "⚠️  Partial success: $PASSED/3 tests passed"
    if ! pgrep -f "file-monitor.py" > /dev/null; then
        echo "   ❌ Monitor process not running! Check: tail -20 /tmp/file-monitor.log"
    fi
else
    echo "❌ All file event tests FAILED"
    if ! pgrep -f "file-monitor.py" > /dev/null; then
        echo "   Monitor process not running! Check: tail -20 /tmp/file-monitor.log"
    fi
fi

# Check Parsec log detection
if tail -50 /tmp/file-monitor.log 2>/dev/null | grep -q "Watching Parsec Log"; then
    PARSEC_LOG=$(tail -50 /tmp/file-monitor.log | grep "Watching Parsec Log" | tail -1)
    echo "✅ Parsec: $PARSEC_LOG"
    
    # Interactive Parsec test
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  PARSEC CONNECTION TEST                                        ║"
    echo "╠════════════════════════════════════════════════════════════════╣"
    echo "║  Please test Parsec now:                                       ║"
    echo "║    1. Connect to this Mac via Parsec from another device       ║"
    echo "║    2. Disconnect from Parsec                                   ║"
    echo "║  Watch for [PARSEC] messages in the terminal                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    read -p "Press Enter after testing Parsec (or type 'skip' to skip): " PARSEC_RESPONSE
    
    if [ "$PARSEC_RESPONSE" != "skip" ]; then
        # Check if any Parsec events were logged recently
        if tail -20 /tmp/file-monitor.log 2>/dev/null | grep -q "\[PARSEC\]"; then
            echo "✅ Parsec events detected in log!"
        else
            echo "⚠️  No Parsec events found in recent log. Did you see [PARSEC] messages above?"
        fi
    else
        echo "   Parsec test skipped."
    fi
    
elif tail -50 /tmp/file-monitor.log 2>/dev/null | grep -q "Parsec log not found"; then
    echo "⚠️  Parsec: Log file not found (Parsec may not be installed or running)"
else
    echo "⚠️  Parsec: Status unknown (check /tmp/file-monitor.log)"
fi

echo ""
echo "✅ Deployment complete! Monitor is running."
# --- END SELF-TEST ---

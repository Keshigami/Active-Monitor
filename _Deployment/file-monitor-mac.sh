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
import subprocess
import urllib.request
import threading
from datetime import datetime, date
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
                                "timestamp": datetime.now().isoformat(),
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
event_times = deque(maxlen=MAX_EVENTS_PER_MINUTE)
last_sent = {}
MIN_EVENT_GAP = 10  # seconds between events for same file

# In-memory events
todays_events = []

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
    with open(EVENTS_LOG, 'w') as f:
        json.dump({'date': str(date.today()), 'events': list(todays_events)}, f)

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
            "timestamp": datetime.now().isoformat(),
            "event": classified_event,
            "path": path,
            "filename": os.path.basename(path),
            "app": last_app
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

                            payload = {
                                "timestamp": datetime.now().isoformat(),
                                "event": "parsec_connection",
                                "status": status,
                                "user": user_part,
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
    return jsonify({'date': str(date.today()), 'events': todays_events, 'machine': os.uname().nodename})

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
            
    # Add Parsec Log Watcher
    parsec_log = os.path.expanduser('~/.parsec/log.txt')
    if os.path.exists(parsec_log):
        print(f" -> Watching Parsec Log: {parsec_log}")
        observer.schedule(ParsecLogHandler(parsec_log, WEBHOOK_URL), os.path.dirname(parsec_log), recursive=False)
    else:
        # Also check /Library/Application Support/Parsec/log.txt
        mac_parsec_log = os.path.expanduser('~/Library/Application Support/Parsec/log.txt')
        if os.path.exists(mac_parsec_log):
             print(f" -> Watching Mac Parsec Log: {mac_parsec_log}")
             observer.schedule(ParsecLogHandler(mac_parsec_log, WEBHOOK_URL), os.path.dirname(mac_parsec_log), recursive=False)
        else:
             print(f" -> Parsec log not found. Checked ~/.parsec/log.txt and ~/Library/Application Support/Parsec/log.txt")

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

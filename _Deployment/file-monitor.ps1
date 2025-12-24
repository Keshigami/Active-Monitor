<#
.SYNOPSIS
    File Activity Monitor for Windows with App Tracking and Logging
.DESCRIPTION
    Monitors file changes, tracks active applications, and sends events to a webhook.
    Parsec connection monitoring is handled by separate ParsecMonitorAdmin/Editor task.
    
    Event Types:
    - download: File created in Downloads folder
    - external_copy: File created on USB/removable drive
    - cloud_upload: File added to cloud sync folder (OneDrive/Google Drive/Dropbox)
    - browser_upload: File accessed by browser for upload
    - created/changed/deleted/renamed: Standard file events
#>

param(
    [string]$WebhookUrl = "http://192.168.1.171:5678/webhook/file-activity",
    [string]$LogDir = "$env:ProgramData\FileMonitor"
)

# Ensure log directory exists
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$LogFile = Join-Path $LogDir "monitor.log"

# --- SINGLE INSTANCE CHECK ---
$mutexName = "Global\FileActivityMonitor"
$mutexCreated = $false
try {
    $script:mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
    [void]$script:mutex # Silence unused variable warning
}
catch {
    $null # Mutex creation failed, ignore
}

if (-not $mutexCreated) {
    # If interactive, warn. If scheduled, just exit quietly to avoid log spam.
    Write-Host "Another instance is already running. Exiting." -ForegroundColor Yellow
    exit
}
# -----------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
    
    # Also write to console if running interactively
    switch ($Level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN" { Write-Host $logLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logLine -ForegroundColor Green }
        default { Write-Host $logLine }
    }
}

Write-Log "=== File Activity Monitor Starting ===" "INFO"
Write-Log "Webhook URL: $WebhookUrl" "INFO"
Write-Log "Log Directory: $LogDir" "INFO"
Write-Log "Computer: $env:COMPUTERNAME" "INFO"

# --- AUTO-UPDATE DISABLED ---
# Auto-update was causing crashes, disabled for stability
<#
try {
    $UpdateUrl = "http://192.168.1.171:8888/file-monitor.ps1"
    $CurrentScript = $MyInvocation.MyCommand.Definition
    
    # Only update if we are running from the final install location
    if ($CurrentScript -like "*ProgramData*") {
        Write-Log "Checking for updates..." "INFO"
        $NewScriptContent = Invoke-WebRequest -Uri $UpdateUrl -UseBasicParsing -TimeoutSec 5
        $NewContent = $NewScriptContent.Content
        
        # Calculate Hashes
        $CurrentHash = Get-FileHash -Path $CurrentScript -Algorithm MD5
        $NewHashString = $NewContent
        
        # Simple string comparison first (faster)
        $CurrentContent = Get-Content -Path $CurrentScript -Raw
        if ($CurrentContent.Length -ne $NewContent.Length -or $CurrentContent -ne $NewContent) {
            Write-Log "Update available! Installing..." "INFO"
            $NewContent | Out-File -FilePath "$CurrentScript.new" -Encoding UTF8 -Force
            
            # Verify the new file was written
            if (Test-Path "$CurrentScript.new") {
                Move-Item -Path "$CurrentScript.new" -Destination $CurrentScript -Force
                Write-Log "Update installed. Restarting..." "SUCCESS"
                
                # Restart the Scheduled Task to load new script
                Start-Sleep -Seconds 1
                Unregister-ScheduledTask -TaskName "FileActivityMonitor" -Confirm:$false -ErrorAction SilentlyContinue
                # Re-registering is safer but more complex here. 
                # Simplest: Just exit. The scheduled task settings should restart it on failure? 
                # No, better to just respawn powershell.
                
                # Restart via scheduled task instead of spawning new process
                Start-ScheduledTask -TaskName "FileActivityMonitor" -ErrorAction SilentlyContinue
                exit
            }
        }
        else {
            Write-Log "Monitor is up to date." "INFO"
        }
    } } catch {
    Write-Log "Update check failed: $($_.Exception.Message)" "WARN"
}
#>

# Load Win32 API for getting active window
try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@
    Write-Log "Win32 API loaded successfully" "SUCCESS" 
}
catch {
    Write-Log "Win32 API already loaded or failed: $_" "WARN"
}

function Get-ActiveApp {
    try {
        $hwnd = [Win32]::GetForegroundWindow()
        $processId = 0
        [Win32]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        return $process.ProcessName 
    }
    catch {
        return "Unknown"
    }
}

function Get-ConnectedUsers {
    # Read connected users from shared file (written by Parsec monitor)
    $ConnectedUsersFile = Join-Path $LogDir "connected_users.txt"
    try {
        if (Test-Path $ConnectedUsersFile) {
            $content = Get-Content $ConnectedUsersFile -Raw -ErrorAction SilentlyContinue
            if ($content) {
                # Format: user1|timestamp1,user2|timestamp2
                $users = @()
                foreach ($entry in $content.Split(',')) {
                    if ($entry -match '^([^|]+)\|(.+)$') {
                        $user = $matches[1].Trim()
                        $timestamp = [DateTime]::Parse($matches[2].Trim())
                        # Check if entry is less than 8 hours old
                        if ((Get-Date) - $timestamp -lt [TimeSpan]::FromHours(8)) {
                            $users += $user
                        }
                    }
                }
                if ($users.Count -gt 0) {
                    return ($users | Sort-Object -Unique) -join ', '
                }
            }
        }
    }
    catch {
        # Ignore errors reading file
    }
    return "local"
}

# --- SPECIAL PATHS FOR EVENT CLASSIFICATION ---
$DownloadsPath = Join-Path $env:USERPROFILE "Downloads"

# Cloud sync folders (common locations)
$CloudSyncPaths = @(
    (Join-Path $env:USERPROFILE "OneDrive"),
    (Join-Path $env:USERPROFILE "OneDrive - *"),  # Business OneDrive
    (Join-Path $env:USERPROFILE "Google Drive"),
    (Join-Path $env:USERPROFILE "Dropbox"),
    (Join-Path $env:USERPROFILE "iCloudDrive"),
    (Join-Path $env:USERPROFILE "Box")
)

# Detect actual OneDrive paths from registry
try {
    $oneDrivePath = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\OneDrive" -Name "UserFolder" -ErrorAction SilentlyContinue).UserFolder
    if ($oneDrivePath -and (Test-Path $oneDrivePath)) {
        $CloudSyncPaths += $oneDrivePath
    } 
}
catch { }

Write-Log "Downloads folder: $DownloadsPath" "INFO"
Write-Log "Cloud sync paths: $($CloudSyncPaths -join ', ')" "INFO"

# Browser temp/cache paths (used to detect file upload staging)
# Browser temp/cache paths (used to detect file upload staging)
# (variable removed as unused)

# Browser process names for detection
$BrowserProcesses = @('chrome', 'firefox', 'msedge', 'iexplore', 'brave', 'opera', 'vivaldi')

# Function to get removable/USB drives
function Get-RemovableDrives {
    try {
        $removable = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 }  # DriveType 2 = Removable
        return $removable | ForEach-Object { $_.DeviceID + "\" } 
    }
    catch {
        return @()
    }
}

# Function to classify event type based on path
function Get-EventType {
    param([string]$Path, [string]$BaseEventType)
    
    # Only classify "created" events specially (downloads, copies, uploads are all creations)
    if ($BaseEventType -ne "created") {
        return $BaseEventType
    }
    
    # Check if file is in Downloads folder
    if ($Path.StartsWith($DownloadsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "download"
    }
    
    # Check if file is in a cloud sync folder
    foreach ($cloudPath in $CloudSyncPaths) {
        if ($cloudPath -like "*\*") {
            # Wildcard path - use -like
            $parentDir = Split-Path $cloudPath -Parent
            $pattern = Split-Path $cloudPath -Leaf
            if ($Path -like "$parentDir\$pattern*") {
                return "cloud_upload"
            }
        }
        elseif ($Path.StartsWith($cloudPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "cloud_upload"
        }
    }
    
    # Check if file is on a removable/USB drive
    $removableDrives = Get-RemovableDrives
    foreach ($drive in $removableDrives) {
        if ($Path.StartsWith($drive, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "external_copy"
        }
    }
    
    return $BaseEventType
}

# Function to check if active app is a browser (for browser_upload detection)
function Test-BrowserActive {
    param([string]$AppName)
    $lowerApp = $AppName.ToLower()
    foreach ($browser in $BrowserProcesses) {
        if ($lowerApp -like "*$browser*") {
            return $true
        }
    }
    return $false
}

# Determine Watch Paths (Default: ALL Fixed Drives + Removable)
$WatchDirs = @()
$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { 
    $_.Used -ne $null -and $_.Free -ne $null  # Only drives with storage info
}
foreach ($drive in $drives) {
    $WatchDirs += $drive.Root
}

# Also add any removable drives currently connected
$removables = Get-RemovableDrives
foreach ($rd in $removables) {
    if ($rd -notin $WatchDirs) {
        $WatchDirs += $rd
        Write-Log "Found removable drive: $rd" "INFO"
    }
}

Write-Log "Watching directories: $($WatchDirs -join ', ')" "INFO"

# Create file system watchers
$watchers = @()
foreach ($dir in $WatchDirs) {
    if (Test-Path $dir) {
        try {
            $w = New-Object System.IO.FileSystemWatcher
            $w.Path = $dir
            $w.IncludeSubdirectories = $true
            $w.InternalBufferSize = 65536 # Increase to 64KB (Max) to prevent overflow
            $w.EnableRaisingEvents = $true
            $w.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor 
            [System.IO.NotifyFilters]::LastWrite -bor 
            [System.IO.NotifyFilters]::DirectoryName
            
            # CRITICAL: Increase buffer size to prevent overflow (default is 8KB)
            $w.InternalBufferSize = 65536  # 64KB buffer
            
            $watchers += $w
            Write-Log " -> Watching: $dir" "SUCCESS" 
        }
        catch {
            Write-Log " -> Failed to watch $dir : $_" "ERROR"
        }
    }
}

# System Exclusions
$systemExcludes = @(
    'C:\Windows', 
    'C:\Program Files', 
    'C:\Program Files (x86)', 
    'C:\ProgramData', 
    'C:\$Recycle.Bin', 
    'C:\System Volume Information'
)

$ignorePatterns = @('.git', 'node_modules', '.tmp', '~$', 'AppData', '.cache', 
    'Local\Microsoft', 'Local\Google', 'Local\Temp', 'ntuser', '.log', 'Parsec',
    'FileMonitor', 'Prefetch', 'SoftwareDistribution', 'n8ndata', 'database.sqlite',
    '-wal', '-shm', '-journal', 
    '.wdc', '.log', '.tmp', '.idlk', '.plist', 'Render Files', 'Analysis Files', 'Transcoded Media', 'Proxies')
$script:eventTimes = @()
$script:lastSent = @{}
$script:lastApp = ""
$script:lastAppTime = [datetime]::MinValue
$MAX_EVENTS_PER_MINUTE = 10
$MIN_EVENT_GAP = 5

# --- EVENT STORAGE FOR DAILY SUMMARY ---
$script:todaysEvents = @()
$EventsFile = Join-Path $LogDir "events.json"

function Save-TodaysEvents {
    try {
        $data = @{
            date    = (Get-Date -Format "yyyy-MM-dd")
            events  = $script:todaysEvents
            machine = $env:COMPUTERNAME
        }
        $json = $data | ConvertTo-Json -Depth 10
        $json | Out-File $EventsFile -Encoding UTF8 -Force 
    }
    catch {
        Write-Log "Failed to save events: $($_.Exception.Message)" "ERROR"
    }
}

function Initialize-TodaysEvents {
    $today = Get-Date -Format "yyyy-MM-dd"
    
    if (Test-Path $EventsFile) {
        try {
            $json = Get-Content $EventsFile -Raw -ErrorAction Stop
            $data = $json | ConvertFrom-Json
            
            if ($data.date -eq $today) {
                # Same day, load events
                $script:todaysEvents = $data.events
            }
            else {
                # New day: Archive previous log
                $ArchiveDir = Join-Path $LogDir "Archive"
                if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
                
                $fileDate = if ($data.date) { $data.date } else { "unknown" }
                $archiveName = "events-$fileDate.json"
                $archivePath = Join-Path $ArchiveDir $archiveName
                
                Copy-Item $EventsFile $archivePath -Force
                Write-Log "Archived usage log to $archiveName" "INFO"
                
                # Cleanup archives older than 30 days
                Get-ChildItem $ArchiveDir -Filter "events-*.json" | 
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | 
                Remove-Item -Force
                    
                # Reset for today
                $script:todaysEvents = @()
            } 
        }
        catch {
            Write-Log "Failed to load events: $($_.Exception.Message)" "ERROR"
            $script:todaysEvents = @()
        }
    }
}

Initialize-TodaysEvents
Write-Log "Loaded $($script:todaysEvents.Count) events from today" "INFO"


function Send-Webhook {
    param($EventType, $Path)
    
    # Check System Exclusions
    foreach ($sys in $systemExcludes) {
        if ($Path.StartsWith($sys, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    }

    # Check Patterns
    foreach ($pattern in $ignorePatterns) {
        if ($Path -like "*$pattern*") { return }
    }
    
    $now = (Get-Date)
    
    # Skip if same file modified recently
    if ($script:lastSent.ContainsKey($Path)) {
        $elapsed = ($now - $script:lastSent[$Path]).TotalSeconds
        if ($elapsed -lt $MIN_EVENT_GAP) { return }
    }
    
    # Rate limit check
    $script:eventTimes = $script:eventTimes | Where-Object { ($now - $_).TotalSeconds -lt 60 }
    if ($script:eventTimes.Count -ge $MAX_EVENTS_PER_MINUTE) {
        Write-Log "[RATE LIMITED] $Path" "WARN"
        return
    }
    
    # Get active app (cache for 2 seconds)
    if (($now - $script:lastAppTime).TotalSeconds -gt 2) {
        $script:lastApp = Get-ActiveApp
        $script:lastAppTime = $now
    }
    
    $script:lastSent[$Path] = $now
    $script:eventTimes += $now
    
    $payload = @{
        timestamp      = $now.ToString("o")
        event          = $EventType
        path           = $Path
        filename       = [System.IO.Path]::GetFileName($Path)
        machine        = $env:COMPUTERNAME
        app            = $script:lastApp
        connected_user = Get-ConnectedUsers
    }
    
    # Store event for daily summary
    $script:todaysEvents += $payload
    Save-TodaysEvents
    
    $payloadJson = $payload | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payloadJson -ContentType "application/json" -TimeoutSec 5 | Out-Null
        Write-Log "[$EventType] [$($script:lastApp)] $([System.IO.Path]::GetFileName($Path))" "INFO"
        
        # Update watchdog - we processed an event successfully
        $script:lastEventTime = Get-Date 
    }
    catch {
        Write-Log "Webhook failed for $Path : $($_.Exception.Message)" "ERROR"
    }
}

$action = {
    $baseEventType = $Event.SourceEventArgs.ChangeType.ToString().ToLower()
    $path = $Event.SourceEventArgs.FullPath
    
    # Get config from MessageData
    $config = $Event.MessageData
    $WebhookUrl = $config.WebhookUrl
    $LogFile = $config.LogFile
    $EventsFile = $config.EventsFile
    $systemExcludes = $config.systemExcludes
    $ignorePatterns = $config.ignorePatterns
    $DownloadsPath = $config.DownloadsPath
    $CloudSyncPaths = $config.CloudSyncPaths
    
    # Check System Exclusions
    foreach ($sys in $systemExcludes) {
        if ($path.StartsWith($sys, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    }
    
    # Check Patterns
    foreach ($pattern in $ignorePatterns) {
        if ($path -like "*$pattern*") { return }
    }
    
    # --- CLASSIFY EVENT TYPE ---
    $eventType = $baseEventType
    if ($baseEventType -eq "created") {
        # Check Downloads folder
        if ($path.StartsWith($DownloadsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $eventType = "download"
        }
        # Check cloud sync folders
        else {
            foreach ($cloudPath in $CloudSyncPaths) {
                if ($cloudPath -and $path.StartsWith($cloudPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $eventType = "cloud_upload"
                    break
                }
            }
        }
        # Check removable drives
        if ($eventType -eq "created") {
            try {
                $removable = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 }
                foreach ($drive in $removable) {
                    $drivePath = $drive.DeviceID + "\"
                    if ($path.StartsWith($drivePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $eventType = "external_copy"
                        break
                    }
                } 
            }
            catch { }
        }
    }
    
    # --- BROWSER UPLOAD DETECTION ---
    # If a file is accessed (changed) while browser is active, it may be an upload
    if ($baseEventType -eq "changed" -and $eventType -eq "changed") {
        # Get active app for browser check
        $checkApp = "Unknown"
        try {
            $hwnd = [Win32]::GetForegroundWindow()
            $procId = 0
            [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $checkApp = $proc.ProcessName 
        }
        catch { }
        
        $browserProcs = $config.BrowserProcesses
        $lowerApp = $checkApp.ToLower()
        foreach ($browser in $browserProcs) {
            if ($lowerApp -like "*$browser*") {
                $eventType = "browser_upload"
                break
            }
        }
    }
    
    # Get active app
    $app = "Unknown"
    try {
        $hwnd = [Win32]::GetForegroundWindow()
        $processId = 0
        [Win32]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        $app = $process.ProcessName 
    }
    catch { }
    
    # Get connected user from shared file
    $connectedUser = "local"
    $connectedUsersFile = Join-Path $config.LogDir "connected_users.txt"
    try {
        if (Test-Path $connectedUsersFile) {
            $cuContent = Get-Content $connectedUsersFile -Raw -ErrorAction SilentlyContinue
            if ($cuContent) {
                $cuUsers = @()
                foreach ($cuEntry in $cuContent.Split(',')) {
                    if ($cuEntry -match '^([^|]+)\|(.+)$') {
                        $cuUser = $matches[1].Trim()
                        $cuTimestamp = [DateTime]::Parse($matches[2].Trim())
                        if ((Get-Date) - $cuTimestamp -lt [TimeSpan]::FromHours(8)) {
                            $cuUsers += $cuUser
                        }
                    }
                }
                if ($cuUsers.Count -gt 0) {
                    $connectedUser = ($cuUsers | Sort-Object -Unique) -join ', '
                }
            }
        }
    }
    catch { }

    $eventData = @{
        timestamp      = (Get-Date).ToString("o")
        event          = $eventType
        path           = $path
        filename       = [System.IO.Path]::GetFileName($path)
        machine        = $env:COMPUTERNAME
        app            = $app
        connected_user = $connectedUser
    }
    
    $payload = $eventData | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 5 | Out-Null
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] [$eventType] [$app] $([System.IO.Path]::GetFileName($path))"
        Add-Content -Path $LogFile -Value $line
        Write-Host $line
        
        # Store event for daily report
        try {
            $today = Get-Date -Format "yyyy-MM-dd"
            $existingData = @{ date = $today; events = @(); machine = $env:COMPUTERNAME }
            
            if (Test-Path $EventsFile) {
                $content = Get-Content $EventsFile -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $existingData = $content | ConvertFrom-Json
                    if ($existingData.date -ne $today) {
                        $existingData = @{ date = $today; events = @(); machine = $env:COMPUTERNAME }
                    }
                }
            }
            
            $existingData.events += $eventData
            $existingData | ConvertTo-Json -Depth 10 | Out-File $EventsFile -Encoding UTF8 -Force 
        }
        catch { } 
    }
    catch {
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] Webhook failed: $($_.Exception.Message)"
        Add-Content -Path $LogFile -Value $line
    }
}

# Config to pass to event handlers
$eventConfig = @{
    WebhookUrl       = $WebhookUrl
    LogFile          = $LogFile
    LogDir           = $LogDir
    EventsFile       = Join-Path $LogDir "events.json"
    systemExcludes   = $systemExcludes
    ignorePatterns   = $ignorePatterns
    DownloadsPath    = $DownloadsPath
    CloudSyncPaths   = $CloudSyncPaths
    BrowserProcesses = $BrowserProcesses
}

foreach ($w in $watchers) {
    Register-ObjectEvent $w "Created" -Action $action -MessageData $eventConfig | Out-Null
    Register-ObjectEvent $w "Changed" -Action $action -MessageData $eventConfig | Out-Null
    Register-ObjectEvent $w "Deleted" -Action $action -MessageData $eventConfig | Out-Null
    Register-ObjectEvent $w "Renamed" -Action $action -MessageData $eventConfig | Out-Null
}

# --- PARSEC MONITORING DISABLED ---
# Parsec monitoring is now handled by the dedicated ParsecMonitorEditor task
# to avoid event subscriber conflicts and dictionary key errors.
# See: C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1


Write-Log "=== Monitor Running ===" "SUCCESS"
Write-Log "Note: HTTP Server runs as separate FileMonitorHttpServer task" "INFO"
Write-Log "Press Ctrl+C to stop..." "INFO"

# Watchdog: Restart if FileSystemWatcher stops working
$script:lastEventTime = Get-Date
$WATCHDOG_TIMEOUT = 600 # 10 minutes without events = restart
$lastWatchdogCheck = Get-Date

# Keep the script running - use short sleep to allow event processing
Write-Log "Watchdog enabled - will restart if no events for $($WATCHDOG_TIMEOUT/60) minutes" "INFO"

while ($true) {
    # Short sleep to allow PowerShell to process events
    Start-Sleep -Milliseconds 500
    
    $now = Get-Date
    
    # Check watchdog every minute
    if (($now - $lastWatchdogCheck).TotalSeconds -gt 60) {
        $lastWatchdogCheck = $now
        $timeSinceLastEvent = ($now - $script:lastEventTime).TotalSeconds
        
        if ($timeSinceLastEvent -gt $WATCHDOG_TIMEOUT) {
            Write-Log "WATCHDOG: No file events for $([math]::Round($timeSinceLastEvent/60, 1)) minutes - FileSystemWatcher may have failed" "WARN"
            Write-Log "WATCHDOG: Restarting monitor to recover..." "WARN"
            
            # Restart via scheduled task
            Start-Sleep -Seconds 2
            Start-ScheduledTask -TaskName "FileActivityMonitor" -ErrorAction SilentlyContinue
            exit
        }
    }
}



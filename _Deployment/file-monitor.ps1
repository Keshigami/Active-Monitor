<#
.SYNOPSIS
    File Activity Monitor for Windows with App Tracking and Logging
.DESCRIPTION
    Monitors file changes, tracks active applications, monitors Parsec logs,
    and sends events to a webhook. Includes local logging for debugging.
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
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
}
catch {
    $mutex = $null
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
    }
}
catch {
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

# Determine Watch Paths (Default: ALL Fixed Drives)
$WatchDirs = @()
$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { 
    $_.Used -ne $null -and $_.Free -ne $null  # Only drives with storage info (fixed drives)
}
foreach ($drive in $drives) {
    $WatchDirs += $drive.Root
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
    'FileMonitor', 'Prefetch', 'SoftwareDistribution')

# Rate limiting
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
        # Write-Log "Saved $($script:todaysEvents.Count) events to $EventsFile" "INFO"
    }
    catch {
        Write-Log "Failed to save events: $($_.Exception.Message)" "ERROR"
    }
}

function Initialize-TodaysEvents {
    if (Test-Path $EventsFile) {
        try {
            $data = Get-Content $EventsFile -Raw | ConvertFrom-Json
            if ($data.date -eq (Get-Date -Format "yyyy-MM-dd")) {
                $script:todaysEvents = @($data.events)
            }
            else {
                $script:todaysEvents = @()
            }
        }
        catch {
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
        timestamp = $now.ToString("o")
        event     = $EventType
        path      = $Path
        filename  = [System.IO.Path]::GetFileName($Path)
        machine   = $env:COMPUTERNAME
        app       = $script:lastApp
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
    $eventType = $Event.SourceEventArgs.ChangeType.ToString().ToLower()
    $path = $Event.SourceEventArgs.FullPath
    
    # Get config from MessageData
    $config = $Event.MessageData
    $WebhookUrl = $config.WebhookUrl
    $LogFile = $config.LogFile
    $EventsFile = $config.EventsFile
    $systemExcludes = $config.systemExcludes
    $ignorePatterns = $config.ignorePatterns
    
    # Check System Exclusions
    foreach ($sys in $systemExcludes) {
        if ($path.StartsWith($sys, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    }
    
    # Check Patterns
    foreach ($pattern in $ignorePatterns) {
        if ($path -like "*$pattern*") { return }
    }
    
    # Get active app
    $app = "Unknown"
    try {
        $hwnd = [Win32]::GetForegroundWindow()
        $processId = 0
        [Win32]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        $app = $process.ProcessName
    } catch { }
    
    $eventData = @{
        timestamp = (Get-Date).ToString("o")
        event     = $eventType
        path      = $path
        filename  = [System.IO.Path]::GetFileName($path)
        machine   = $env:COMPUTERNAME
        app       = $app
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
        } catch { }
    }
    catch {
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] Webhook failed: $($_.Exception.Message)"
        Add-Content -Path $LogFile -Value $line
    }
}

# Config to pass to event handlers
$eventConfig = @{
    WebhookUrl = $WebhookUrl
    LogFile = $LogFile
    EventsFile = Join-Path $LogDir "events.json"
    systemExcludes = $systemExcludes
    ignorePatterns = $ignorePatterns
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
    
    # Check watchdog every minute
    if (((Get-Date) - $lastWatchdogCheck).TotalSeconds -gt 60) {
        $lastWatchdogCheck = Get-Date
        $timeSinceLastEvent = ((Get-Date) - $script:lastEventTime).TotalSeconds
        
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

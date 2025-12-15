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
    # Keep reference to prevent GC from releasing mutex
    $null = $mutex
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

# File Activity Monitor with Auto-Update
$VERSION = "2.0.0"

Write-Log "=== File Activity Monitor Starting (v$VERSION) ===" "INFO"
Write-Log "Webhook URL: $WebhookUrl" "INFO"
Write-Log "Log Directory: $LogDir" "INFO"
Write-Log "Computer: $env:COMPUTERNAME" "INFO"

# --- AUTO-UPDATE CHECK ---
try {
    $UpdateUrl = "http://192.168.1.171:8888/file-monitor.ps1"
    $CurrentScript = $MyInvocation.MyCommand.Definition
    
    # Only update if we are running from the final install location
    if ($CurrentScript -like "*ProgramData*") {
        Write-Log "Checking for updates (Current: $VERSION)..." "INFO"
        try {
            $NewScriptContent = Invoke-WebRequest -Uri $UpdateUrl -UseBasicParsing -TimeoutSec 5
            $NewContent = $NewScriptContent.Content
            
            # Regex to find version in new content
            if ($NewContent -match '\$VERSION\s*=\s*"([^"]+)"') {
                $RemoteVersion = $matches[1]
                
                # Simple string compare (works for 1.0.1 vs 1.0.2)
                if ($RemoteVersion -gt $VERSION) {
                    Write-Log "Update found! ($VERSION -> $RemoteVersion). Installing..." "INFO"
                    $NewContent | Out-File -FilePath "$CurrentScript.new" -Encoding UTF8 -Force
                     
                    if (Test-Path "$CurrentScript.new") {
                        Move-Item -Path "$CurrentScript.new" -Destination $CurrentScript -Force
                        Write-Log "Update installed. Restarting..." "SUCCESS"
                        Start-Sleep -Seconds 1
                        
                        # Stop current instance if running via Task Scheduler (implicit, but we are the process)
                        # We just spawn the new one.
                        Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$CurrentScript`""
                        exit
                    }
                }
                else {
                    Write-Log "Monitor is up to date ($VERSION)." "INFO"
                }
            }
        }
        catch {
            Write-Log "Failed to check/parse update: $($_.Exception.Message)" "WARN"
        }
    }
}
catch {
    Write-Log "Update check logic failed: $($_.Exception.Message)" "WARN"
}
# -------------------------

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
$global:todaysEvents = @()
$EventsFile = Join-Path $LogDir "events.json"

function Save-TodaysEvents {
    try {
        $data = @{
            date    = (Get-Date -Format "yyyy-MM-dd")
            events  = $global:todaysEvents
            machine = $env:COMPUTERNAME
        }
        $json = $data | ConvertTo-Json -Depth 10
        $json | Out-File $EventsFile -Encoding UTF8 -Force
        # Write-Log "Saved $($global:todaysEvents.Count) events to $EventsFile" "INFO"
    }
    catch {
        Write-Log "Failed to save events: $($_.Exception.Message)" "ERROR"
    }
}

function Initialize-TodaysEvents {
    $global:todaysEvents = New-Object System.Collections.ArrayList
    if (Test-Path $EventsFile) {
        try {
            $data = Get-Content $EventsFile -Raw | ConvertFrom-Json
            if ($data.date -eq (Get-Date -Format "yyyy-MM-dd") -and $data.events) {
                foreach ($evt in $data.events) {
                    $global:todaysEvents.Add($evt) | Out-Null
                }
            }
        }
        catch {
            # Keep empty ArrayList
        }
    }
}

Initialize-TodaysEvents
Write-Log "Loaded $($global:todaysEvents.Count) events from today" "INFO"


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
    $global:todaysEvents.Add($payload) | Out-Null
    Save-TodaysEvents
    
    $payloadJson = $payload | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payloadJson -ContentType "application/json" -TimeoutSec 5 | Out-Null
        Write-Log "[$EventType] [$($script:lastApp)] $([System.IO.Path]::GetFileName($Path))" "INFO"
    }
    catch {
        Write-Log "Webhook failed for $Path : $($_.Exception.Message)" "ERROR"
    }
}

$action = {
    $eventType = $Event.SourceEventArgs.ChangeType.ToString().ToLower()
    $path = $Event.SourceEventArgs.FullPath
    Send-Webhook -EventType $eventType -Path $path
}

foreach ($w in $watchers) {
    Register-ObjectEvent $w "Created" -Action $action | Out-Null
    Register-ObjectEvent $w "Changed" -Action $action | Out-Null
    Register-ObjectEvent $w "Deleted" -Action $action | Out-Null
    Register-ObjectEvent $w "Renamed" -Action $action | Out-Null
}

# --- PARSEC LOG MONITORING ---
# Try current user's AppData first, then search all users
$ParsecLogPath = "$env:APPDATA\Parsec\log.txt"
if (-not (Test-Path $ParsecLogPath)) {
    Write-Log "Parsec log not at $ParsecLogPath, searching other profiles..." "WARN"
    # Search all user profiles
    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($userDir in $userProfiles) {
        $testPath = Join-Path $userDir.FullName "AppData\Roaming\Parsec\log.txt"
        if (Test-Path $testPath) {
            $ParsecLogPath = $testPath
            Write-Log "Found Parsec log at: $ParsecLogPath" "SUCCESS"
            break
        }
    }
}
if (Test-Path $ParsecLogPath) {
    Write-Log "Using Parsec Log: $ParsecLogPath" "SUCCESS"
    
    $global:ParsecLogLastPos = (Get-Item $ParsecLogPath).Length
    $global:ParsecRateLimits = @{}

    $pWatcher = New-Object System.IO.FileSystemWatcher
    $pWatcher.Path = [System.IO.Path]::GetDirectoryName($ParsecLogPath)
    $pWatcher.Filter = [System.IO.Path]::GetFileName($ParsecLogPath)
    $pWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
    $pWatcher.EnableRaisingEvents = $true

    $pAction = {
        $path = $Event.SourceEventArgs.FullPath
        
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            if ($fs.Length -lt $global:ParsecLogLastPos) { $global:ParsecLogLastPos = 0 }
            
            $newContent = ""
            if ($fs.Length -gt $global:ParsecLogLastPos) {
                if ($global:ParsecLogLastPos -gt 0) { $fs.Seek($global:ParsecLogLastPos, 'Begin') | Out-Null }
                $reader = New-Object System.IO.StreamReader($fs)
                $newContent = $reader.ReadToEnd()
                $global:ParsecLogLastPos = $fs.Position
                $reader.Close()
            }
            $fs.Close()

            if ($newContent) {
                $lines = $newContent -split "`n"
                foreach ($line in $lines) {
                    if ($line -match "\[I .*?\] (.*?) (connected|disconnected)\.") {
                        $pUser = $matches[1]
                        $pStatus = $matches[2]
                            
                        if ($pUser -in @("IPC", "Parsec", "Virtual", "Hosting")) { continue }
                        
                        # Rate limit: Skip if same user+status within 10 seconds
                        $parsecKey = "$pUser-$pStatus"
                        $now = Get-Date

                        if (-not $global:ParsecRateLimits) { $global:ParsecRateLimits = @{} }
                        
                        if ($global:ParsecRateLimits.ContainsKey($parsecKey)) {
                            $lastTime = $global:ParsecRateLimits[$parsecKey]
                            $elapsed = ($now - $lastTime).TotalSeconds
                            if ($elapsed -lt 10) { continue }
                        }
                        
                        $global:ParsecRateLimits[$parsecKey] = $now

                        # Build JSON string directly to avoid hashtable issues
                        $timestamp = (Get-Date).ToString("o")
                        $payloadJson = @"
{"timestamp":"$timestamp","event":"parsec_connection","status":"$pStatus","user":"$pUser","machine":"$env:COMPUTERNAME"}
"@
                        
                        # Store for daily summary using PSCustomObject
                        $eventObj = [PSCustomObject]@{
                            timestamp = $timestamp
                            event     = "parsec_connection"
                            status    = $pStatus
                            user      = $pUser
                            machine   = $env:COMPUTERNAME
                        }
                        $global:todaysEvents.Add($eventObj) | Out-Null
                        Save-TodaysEvents
                        
                        try {
                            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payloadJson -ContentType "application/json" -TimeoutSec 5 | Out-Null
                            Write-Log "[PARSEC] $pUser $pStatus" "SUCCESS"
                        }
                        catch {
                            Write-Log "[PARSEC] Failed to send: $($_.Exception.Message)" "ERROR"
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "Error reading Parsec log: $_" "ERROR"
        }
    }

    Register-ObjectEvent -InputObject $pWatcher -EventName "Changed" -SourceIdentifier "ParsecLogWatcher" -Action $pAction | Out-Null
}
else {
    Write-Log "Parsec log not found at $ParsecLogPath" "WARN"
}

Write-Log "=== Monitor Running ===" "SUCCESS"
Write-Log "HTTP Server: http://0.0.0.0:8080/logs" "INFO"
Write-Log "Press Ctrl+C to stop..." "INFO"


# Start HTTP listener in a background job
$HttpJob = Start-Job -ScriptBlock {
    param($LogDir)
    
    $EventsFile = Join-Path $LogDir "events.json"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:8080/")
    
    try {
        $listener.Start()
    }
    catch {
        # Try localhost only if + fails
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:8080/")
        $listener.Start()
    }
    
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            
            if ($request.Url.AbsolutePath -eq "/logs") {
                # Read events file
                $responseData = @{
                    date    = (Get-Date -Format "yyyy-MM-dd")
                    events  = @()
                    machine = $env:COMPUTERNAME
                }
                
                if (Test-Path $EventsFile) {
                    try {
                        $data = Get-Content $EventsFile -Raw | ConvertFrom-Json
                        $responseData = $data
                    }
                    catch {}
                }
                
                $json = $responseData | ConvertTo-Json -Depth 10
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            elseif ($request.Url.AbsolutePath -eq "/logs/clear" -and $request.HttpMethod -eq "POST") {
                # Clear events
                @{ date = (Get-Date -Format "yyyy-MM-dd"); events = @(); machine = $env:COMPUTERNAME } | 
                ConvertTo-Json | Out-File $EventsFile -Encoding UTF8 -Force
                $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"status":"cleared"}')
                $response.ContentType = "application/json"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            else {
                $response.StatusCode = 404
                $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Not Found"}')
                $response.ContentType = "application/json"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            
            $response.Close()
        }
        catch {
            # Ignore errors and continue
        }
    }
} -ArgumentList $LogDir

Write-Log "HTTP Server job started (Job ID: $($HttpJob.Id))" "SUCCESS"

# Override Send-Webhook to also store events
# Event storage initialized

# Keep the script running
while ($true) { Start-Sleep -Seconds 1 }

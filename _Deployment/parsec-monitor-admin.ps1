param(
    [string]$WebhookUrl = "http://192.168.1.171:5678/webhook/file-activity"
)

$LogDir = "$env:ProgramData\ParsecMonitor"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir "monitor.log"

function Write-Log {
    param($Message, $Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# --- SINGLE INSTANCE CHECK ---
$mutexName = "Global\ParsecMonitorAdmin"
$mutexCreated = $false
try {
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
    $null = $mutex
}
catch {
    $mutex = $null
}

if (-not $mutexCreated) {
    Write-Log "Another instance is already running. Exiting." "WARN"
    exit
}
# -----------------------------

Write-Log "=== Parsec Monitor (Admin PC) Starting ==="
Write-Log "Webhook: $WebhookUrl"
Write-Log "Computer: $env:COMPUTERNAME"

$ParsecLogPath = "$env:APPDATA\Parsec\log.txt"
if (-not (Test-Path $ParsecLogPath)) {
    Write-Log "Parsec log not found at $ParsecLogPath" "ERROR"
    exit 1
}

Write-Log "Found Parsec Log: $ParsecLogPath" "SUCCESS"

$global:ParsecLogLastPos = (Get-Item $ParsecLogPath).Length
$global:lastParsecKey = ""
$global:lastParsecEvent = $null

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = [System.IO.Path]::GetDirectoryName($ParsecLogPath)
$watcher.Filter = "log.txt"
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
$watcher.EnableRaisingEvents = $true

$action = {
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

                    $payload = @{
                        timestamp = $now.ToString("o")
                        event     = "parsec_connection"
                        status    = $pStatus
                        user      = $pUser
                        machine   = $env:COMPUTERNAME
                    } | ConvertTo-Json

                    try {
                        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 5 | Out-Null
                        Write-Log "[PARSEC] $pUser $pStatus" "SUCCESS"
                    }
                    catch {
                        Write-Log "[PARSEC] Send failed: $($_.Exception.Message)" "ERROR"
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Error reading Parsec log: $_" "ERROR"
    }
}

Register-ObjectEvent -InputObject $watcher -EventName "Changed" -SourceIdentifier "ParsecLogWatcher" -Action $action | Out-Null

Write-Log "=== Parsec Monitor Running ===" "SUCCESS"
Write-Log "Press Ctrl+C to stop..."

while ($true) { Start-Sleep -Seconds 1 }

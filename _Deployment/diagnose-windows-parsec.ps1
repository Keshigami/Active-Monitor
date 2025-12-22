# Comprehensive Parsec Detection Diagnostics for Windows Editor PC
Write-Host "=== PARSEC DETECTION DIAGNOSTICS ===" -ForegroundColor Cyan
Write-Host ""

# 1. Check if Parsec log exists
$parsecLog = "C:\Users\Jake\AppData\Roaming\Parsec\log.txt"
if (Test-Path $parsecLog) {
    Write-Host "[OK] Parsec log found: $parsecLog" -ForegroundColor Green
    $logInfo = Get-Item $parsecLog
    Write-Host "    Size: $($logInfo.Length) bytes" -ForegroundColor White
    Write-Host "    Last Modified: $($logInfo.LastWriteTime)" -ForegroundColor White
} else {
    Write-Host "[ERROR] Parsec log NOT found!" -ForegroundColor Red
    exit 1
}

# 2. Show last 30 lines of Parsec log
Write-Host ""
Write-Host "=== LAST 30 LINES OF PARSEC LOG ===" -ForegroundColor Cyan
Get-Content $parsecLog -Tail 30 | ForEach-Object { Write-Host $_ }

# 3. Test the regex pattern
Write-Host ""
Write-Host "=== TESTING REGEX PATTERN ===" -ForegroundColor Cyan
$pattern = '\[I .*?\] (.*?) (connected|disconnected)\.'
$recentLines = Get-Content $parsecLog -Tail 100

$matches = $recentLines | Where-Object { $_ -match $pattern }
if ($matches) {
    Write-Host "[FOUND] $($matches.Count) matching lines:" -ForegroundColor Green
    $matches | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
} else {
    Write-Host "[NOT FOUND] No lines match the pattern: $pattern" -ForegroundColor Red
    Write-Host "Showing sample lines to analyze:" -ForegroundColor Yellow
    $recentLines | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
}

# 4. Check monitor log for Parsec entries
Write-Host ""
Write-Host "=== MONITOR LOG - PARSEC ENTRIES ===" -ForegroundColor Cyan
$monitorLog = "C:\ProgramData\FileMonitor\monitor.log"
if (Test-Path $monitorLog) {
    $parsecEntries = Get-Content $monitorLog | Where-Object { $_ -like "*Parsec*" -or $_ -like "*PARSEC*" }
    if ($parsecEntries) {
        Write-Host "[FOUND] Parsec entries in monitor log:" -ForegroundColor Green
        $parsecEntries | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    } else {
        Write-Host "[NOT FOUND] No Parsec entries in monitor log" -ForegroundColor Yellow
    }
    
    # Show last 20 log lines
    Write-Host ""
    Write-Host "=== LAST 20 MONITOR LOG LINES ===" -ForegroundColor Cyan
    Get-Content $monitorLog -Tail 20 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "[ERROR] Monitor log not found" -ForegroundColor Red
}

# 5. Check if FileSystemWatcher is registered
Write-Host ""
Write-Host "=== REGISTERED EVENT SUBSCRIBERS ===" -ForegroundColor Cyan
$subscribers = Get-EventSubscriber | Where-Object { $_.SourceIdentifier -eq "ParsecLogWatcher" }
if ($subscribers) {
    Write-Host "[OK] ParsecLogWatcher event subscriber is registered" -ForegroundColor Green
    $subscribers | Format-List SourceIdentifier, EventName, SourceObject
} else {
    Write-Host "[ERROR] ParsecLogWatcher NOT registered!" -ForegroundColor Red
}

# 6. Check if monitor is running
Write-Host ""
Write-Host "=== MONITOR PROCESS STATUS ===" -ForegroundColor Cyan
$monitorProcs = Get-Process powershell | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*file-monitor.ps1*"
}
if ($monitorProcs) {
    Write-Host "[OK] Monitor process running:" -ForegroundColor Green
    $monitorProcs | Select-Object Id, StartTime, @{Name='Runtime';Expression={(Get-Date) - $_.StartTime}} | Format-Table
} else {
    Write-Host "[ERROR] Monitor NOT running!" -ForegroundColor Red
}

# 7. Simulate a file change to test detection
Write-Host ""
Write-Host "=== MANUAL FILE CHANGE TEST ===" -ForegroundColor Cyan
Write-Host "Creating test file in Parsec directory..." -ForegroundColor Yellow
$testFile = Join-Path (Split-Path $parsecLog) "test-$(Get-Date -Format 'HHmmss').txt"
"Test" | Out-File $testFile
Start-Sleep -Seconds 2
Remove-Item $testFile -Force
Write-Host "Test file created and deleted. Check monitor log for detection." -ForegroundColor Yellow

Write-Host ""
Write-Host "=== DIAGNOSTICS COMPLETE ===" -ForegroundColor Cyan

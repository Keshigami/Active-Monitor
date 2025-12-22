# Parsec Log Diagnostics for Windows
Write-Host "=== PARSEC LOG DIAGNOSTICS ===" -ForegroundColor Cyan
Write-Host ""

# Check multiple possible log locations
$possiblePaths = @(
    "$env:APPDATA\Parsec\log.txt",
    "$env:USERPROFILE\.parsec\log.txt",
    "C:\Users\$env:USERNAME\AppData\Roaming\Parsec\log.txt"
)

$foundLog = $null
foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        Write-Host "[FOUND] $path" -ForegroundColor Green
        $foundLog = $path
        break
    } else {
        Write-Host "[NOT FOUND] $path" -ForegroundColor Yellow
    }
}

if (-not $foundLog) {
    Write-Host ""
    Write-Host "[ERROR] No Parsec log found!" -ForegroundColor Red
    Write-Host "Make sure Parsec is installed and has been run at least once."
    exit 1
}

Write-Host ""
Write-Host "=== LOG FILE INFO ===" -ForegroundColor Cyan
Get-Item $foundLog | Select-Object FullName, Length, LastWriteTime | Format-List

Write-Host ""
Write-Host "=== LAST 30 LINES ===" -ForegroundColor Cyan
Get-Content $foundLog -Tail 30

Write-Host ""
Write-Host "=== SEARCHING FOR CONNECTION EVENTS ===" -ForegroundColor Cyan
$content = Get-Content $foundLog -Tail 100
$matches = $content | Where-Object { $_ -match '\[I .*?\] (.*?) (connected|disconnected)\.' }

if ($matches) {
    Write-Host "Found $($matches.Count) connection events in last 100 lines:" -ForegroundColor Green
    $matches | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
} else {
    Write-Host "No connection events found in last 100 lines" -ForegroundColor Red
    Write-Host ""
    Write-Host "Sample log lines (to check format):" -ForegroundColor Yellow
    $content | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ""
Write-Host "=== MONITOR STATUS ===" -ForegroundColor Cyan
$monitorLog = "C:\ProgramData\FileMonitor\monitor.log"
if (Test-Path $monitorLog) {
    Write-Host "Monitor log exists. Checking for Parsec entries..." -ForegroundColor Green
    $monitorContent = Get-Content $monitorLog
    
    $parsecFound = $monitorContent | Where-Object { $_ -like "*Parsec*" }
    if ($parsecFound) {
        Write-Host "Parsec-related entries:" -ForegroundColor Green
        $parsecFound | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "No Parsec entries in monitor log" -ForegroundColor Yellow
    }
} else {
    Write-Host "[WARN] Monitor log not found at $monitorLog" -ForegroundColor Red
}

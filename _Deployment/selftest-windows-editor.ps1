# Windows Editor PC - Complete Monitoring Self-Test
# Run this to verify both file and Parsec monitors are working properly

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   WINDOWS EDITOR PC - MONITORING SELF-TEST" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

$issues = @()

# TEST 1: FILE MONITOR
Write-Host "[TEST 1] FILE ACTIVITY MONITOR" -ForegroundColor Yellow
Write-Host ""

$fileTask = Get-ScheduledTask -TaskName "FileActivityMonitor" -ErrorAction SilentlyContinue
if ($fileTask -and $fileTask.State -eq "Running") {
    Write-Host "  OK - Task running" -ForegroundColor Green
} else {
    Write-Host "  ERROR - Task not running" -ForegroundColor Red
    $issues += "File monitor task stopped"
}

$fileProc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*file-monitor.ps1*"
}
if ($fileProc) {
    Write-Host "  OK - Process running (PID: $($fileProc.Id))" -ForegroundColor Green
} else {
    Write-Host "  ERROR - Process not running" -ForegroundColor Red
    $issues += "File monitor process stopped"
}

Write-Host "  Creating test file..."
$testFile = "$env:USERPROFILE\Desktop\SELFTEST-$(Get-Date -Format 'HHmmss').txt"
"Test" | Out-File $testFile
Start-Sleep -Seconds 8

$detected = Get-Content "C:\ProgramData\FileMonitor\monitor.log" -Tail 30 -ErrorAction SilentlyContinue | Select-String "SELFTEST"
if ($detected) {
    Write-Host "  OK - File detection working!" -ForegroundColor Green
} else {
    Write-Host "  ERROR - File not detected!" -ForegroundColor Red
    $issues += "File detection failed"
}
Remove-Item $testFile -Force -ErrorAction SilentlyContinue

Write-Host ""

# TEST 2: PARSEC MONITOR
Write-Host "[TEST 2] PARSEC MONITOR" -ForegroundColor Yellow
Write-Host ""

$parsecTask = Get-ScheduledTask -TaskName "ParsecMonitorEditor" -ErrorAction SilentlyContinue
if ($parsecTask -and $parsecTask.State -eq "Running") {
    Write-Host "  OK - Task running" -ForegroundColor Green
} else {
    Write-Host "  ERROR - Task not running" -ForegroundColor Red
    $issues += "Parsec monitor task stopped"
}

$parsecProc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*parsec-monitor*"
}
if ($parsecProc) {
    Write-Host "  OK - Process running (PID: $($parsecProc.Id))" -ForegroundColor Green
} else {
    Write-Host "  ERROR - Process not running" -ForegroundColor Red
    $issues += "Parsec monitor process stopped"
}

if (Test-Path "C:\Users\Jake\AppData\Roaming\Parsec\log.txt") {
    Write-Host "  OK - Parsec log found" -ForegroundColor Green
} else {
    Write-Host "  ERROR - Parsec log not found" -ForegroundColor Red
    $issues += "Parsec log missing"
}

Write-Host ""

# TEST 3: CONNECTIVITY
Write-Host "[TEST 3] NETWORK CONNECTIVITY" -ForegroundColor Yellow
Write-Host ""

try {
    $null = Invoke-WebRequest -Uri "http://192.168.1.171:5678" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "  OK - Webhook server reachable" -ForegroundColor Green
} catch {
    Write-Host "  ERROR - Webhook server unreachable" -ForegroundColor Red
    $issues += "Cannot reach webhook"
}

Write-Host ""

# SUMMARY
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if ($issues.Count -eq 0) {
    Write-Host "SUCCESS - All systems operational!" -ForegroundColor Green
    Write-Host ""
    Write-Host "What's working:"
    Write-Host "  - File Activity Monitor"
    Write-Host "  - Parsec Monitor"
    Write-Host "  - Webhook Server"
    Write-Host ""
    Write-Host "Next: Test by creating files or connecting via Parsec"
} else {
    Write-Host "WARNING - $($issues.Count) issue(s) detected:" -ForegroundColor Red
    Write-Host ""
    $issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Action: Check logs and restart services"
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

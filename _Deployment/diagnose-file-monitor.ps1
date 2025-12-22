# File Monitor Diagnostic Script for Windows Editor PC
Write-Host "=== FILE MONITOR DIAGNOSTICS ===" -ForegroundColor Cyan
Write-Host ""

# 1. Check if scheduled task exists
Write-Host "[1/6] Checking scheduled task..." -ForegroundColor Yellow
$task = Get-ScheduledTask -TaskName "FileActivityMonitor" -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "  [OK] Task exists" -ForegroundColor Green
    Write-Host "  State: $($task.State)" -ForegroundColor White
    $taskInfo = Get-ScheduledTaskInfo -TaskName "FileActivityMonitor"
    Write-Host "  Last Run: $($taskInfo.LastRunTime)" -ForegroundColor White
    Write-Host "  Last Result: $($taskInfo.LastTaskResult)" -ForegroundColor White
} else {
    Write-Host "  [ERROR] Task NOT found!" -ForegroundColor Red
}

# 2. Check if monitor process is running
Write-Host ""
Write-Host "[2/6] Checking monitor process..." -ForegroundColor Yellow
$monitorProc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*file-monitor.ps1*"
}
if ($monitorProc) {
    Write-Host "  [OK] Monitor running" -ForegroundColor Green
    $monitorProc | Select-Object Id, StartTime, @{Name='Runtime';Expression={(Get-Date) - $_.StartTime}} | Format-Table
} else {
    Write-Host "  [WARN] Monitor NOT running!" -ForegroundColor Red
}

# 3. Check monitor log
Write-Host ""
Write-Host "[3/6] Checking monitor log..." -ForegroundColor Yellow
if (Test-Path "C:\ProgramData\FileMonitor\monitor.log") {
    Write-Host "  [OK] Log file exists" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Last 15 lines:" -ForegroundColor White
    Get-Content "C:\ProgramData\FileMonitor\monitor.log" -Tail 15 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "  [ERROR] Log file not found!" -ForegroundColor Red
}

# 4. Check if file monitor script exists
Write-Host ""
Write-Host "[4/6] Checking monitor script..." -ForegroundColor Yellow
if (Test-Path "C:\ProgramData\FileMonitor\file-monitor.ps1") {
    $scriptInfo = Get-Item "C:\ProgramData\FileMonitor\file-monitor.ps1"
    Write-Host "  [OK] Script exists" -ForegroundColor Green
    Write-Host "  Size: $($scriptInfo.Length) bytes" -ForegroundColor White
    Write-Host "  Modified: $($scriptInfo.LastWriteTime)" -ForegroundColor White
} else {
    Write-Host "  [ERROR] Script not found!" -ForegroundColor Red
}

# 5. Check HTTP listener (log API)
Write-Host ""
Write-Host "[5/6] Checking HTTP listener..." -ForegroundColor Yellow
$listener = netstat -ano | Select-String ":8080.*LISTENING"
if ($listener) {
    Write-Host "  [OK] HTTP listener active on port 8080" -ForegroundColor Green
} else {
    Write-Host "  [WARN] HTTP listener not active" -ForegroundColor Yellow
}

# 6. Check webhook connectivity
Write-Host ""
Write-Host "[6/6] Testing webhook..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://192.168.1.171:5678" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "  [OK] Webhook server reachable" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Cannot reach webhook: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== DIAGNOSTICS COMPLETE ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "If monitor is NOT running, restart it with:" -ForegroundColor Yellow
Write-Host "  Start-ScheduledTask -TaskName 'FileActivityMonitor'" -ForegroundColor White

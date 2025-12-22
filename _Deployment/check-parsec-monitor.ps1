# Quick Parsec Monitor Check
Write-Host "=== PARSEC MONITOR STATUS ===" -ForegroundColor Cyan
Write-Host ""

# 1. Check scheduled task
Write-Host "[1/4] Checking ParsecMonitorEditor task..." -ForegroundColor Yellow
$task = Get-ScheduledTask -TaskName "ParsecMonitorEditor" -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "  [OK] Task exists - State: $($task.State)" -ForegroundColor Green
} else {
    Write-Host "  [ERROR] Task NOT found!" -ForegroundColor Red
}

# 2. Check process
Write-Host ""
Write-Host "[2/4] Checking process..." -ForegroundColor Yellow
$proc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*parsec-monitor-admin.ps1*"
}
if ($proc) {
    Write-Host "  [OK] Running (PID: $($proc.Id))" -ForegroundColor Green
} else {
    Write-Host "  [ERROR] NOT running!" -ForegroundColor Red
}

# 3. Check log
Write-Host ""
Write-Host "[3/4] Checking log..." -ForegroundColor Yellow
if (Test-Path "C:\ProgramData\ParsecMonitor\monitor.log") {
    Write-Host "  Last 10 lines:" -ForegroundColor White
    Get-Content "C:\ProgramData\ParsecMonitor\monitor.log" -Tail 10 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "  [ERROR] Log not found!" -ForegroundColor Red
}

# 4. Restart if needed
Write-Host ""
Write-Host "[4/4] Action..." -ForegroundColor Yellow
if (-not $proc) {
    Write-Host "  Restarting ParsecMonitorEditor..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName "ParsecMonitorEditor" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "  [OK] Restarted" -ForegroundColor Green
} else {
    Write-Host "  [OK] Already running" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== CHECK COMPLETE ===" -ForegroundColor Cyan

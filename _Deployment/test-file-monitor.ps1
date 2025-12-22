# File Monitor Test Script
Write-Host "=== FILE MONITOR TEST ===" -ForegroundColor Cyan
Write-Host ""

# 1. Check scheduled task
Write-Host "[1/5] Checking FileActivityMonitor task..." -ForegroundColor Yellow
$task = Get-ScheduledTask -TaskName "FileActivityMonitor" -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "  [OK] Task exists - State: $($task.State)" -ForegroundColor Green
} else {
    Write-Host "  [ERROR] Task NOT found!" -ForegroundColor Red
    Write-Host "  Run deployment script first!" -ForegroundColor Yellow
    exit 1
}

# 2. Check process
Write-Host ""
Write-Host "[2/5] Checking process..." -ForegroundColor Yellow
$proc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*file-monitor.ps1*"
}
if ($proc) {
    Write-Host "  [OK] Running (PID: $($proc.Id))" -ForegroundColor Green
} else {
    Write-Host "  [WARN] NOT running! Restarting..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName "FileActivityMonitor"
    Start-Sleep -Seconds 5
    Write-Host "  [OK] Restarted" -ForegroundColor Green
}

# 3. Show recent log
Write-Host ""
Write-Host "[3/5] Recent log entries..." -ForegroundColor Yellow
if (Test-Path "C:\ProgramData\FileMonitor\monitor.log") {
    Get-Content "C:\ProgramData\FileMonitor\monitor.log" -Tail 10 | ForEach-Object { 
        Write-Host "  $_" 
    }
} else {
    Write-Host "  [ERROR] Log not found!" -ForegroundColor Red
}

# 4. Create test file
Write-Host ""
Write-Host "[4/5] Creating test file..." -ForegroundColor Yellow
$testFile = "$env:USERPROFILE\Desktop\test-monitor-$(Get-Date -Format 'HHmmss').txt"
"File monitoring test - $(Get-Date)" | Out-File $testFile
Write-Host "  Created: $testFile" -ForegroundColor White
Write-Host "  Waiting 5 seconds for detection..." -ForegroundColor White
Start-Sleep -Seconds 5

# 5. Verify detection
Write-Host ""
Write-Host "[5/5] Checking if file was detected..." -ForegroundColor Yellow
$detected = Get-Content "C:\ProgramData\FileMonitor\monitor.log" -Tail 20 | Select-String "test-monitor"
if ($detected) {
    Write-Host "  [SUCCESS] File monitoring is WORKING!" -ForegroundColor Green
    Write-Host "  Detection log:" -ForegroundColor White
    $detected | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
} else {
    Write-Host "  [FAIL] File was NOT detected!" -ForegroundColor Red
    Write-Host "  Check monitor log for errors" -ForegroundColor Yellow
}

# Cleanup
Write-Host ""
Write-Host "Cleaning up test file..." -ForegroundColor Gray
Remove-Item $testFile -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== TEST COMPLETE ===" -ForegroundColor Cyan
Write-Host ""

if ($detected) {
    Write-Host "✅ File monitoring is working correctly!" -ForegroundColor Green
} else {
    Write-Host "❌ File monitoring needs troubleshooting" -ForegroundColor Red
}

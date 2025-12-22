# Complete Monitoring System Test - Windows Editor PC
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     COMPLETE MONITORING SYSTEM TEST - WINDOWS EDITOR PC" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$allPassed = $true

# ============================================================
# TEST 1: FILE ACTIVITY MONITOR
# ============================================================
Write-Host "[TEST 1] FILE ACTIVITY MONITOR" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Gray

# 1.1 Check task
Write-Host "  [1.1] Checking FileActivityMonitor task..." -ForegroundColor White
$fileTask = Get-ScheduledTask -TaskName "FileActivityMonitor" -ErrorAction SilentlyContinue
if ($fileTask -and $fileTask.State -eq "Running") {
    Write-Host "    ✅ Task running" -ForegroundColor Green
} else {
    Write-Host "    ❌ Task not running - Restarting..." -ForegroundColor Red
    Start-ScheduledTask -TaskName "FileActivityMonitor" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $allPassed = $false
}

# 1.2 Check process
Write-Host "  [1.2] Checking file monitor process..." -ForegroundColor White
$fileProc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*file-monitor.ps1*"
}
if ($fileProc) {
    Write-Host "    ✅ Process running (PID: $($fileProc.Id))" -ForegroundColor Green
} else {
    Write-Host "    ❌ Process NOT running!" -ForegroundColor Red
    $allPassed = $false
}

# 1.3 Test file detection
Write-Host "  [1.3] Testing file detection..." -ForegroundColor White
$testFile = "$env:USERPROFILE\Desktop\test-$(Get-Date -Format 'HHmmss').txt"
"Test - $(Get-Date)" | Out-File $testFile
Write-Host "    Created test file" -ForegroundColor Gray
Start-Sleep -Seconds 5
$fileDetected = Get-Content "C:\ProgramData\FileMonitor\monitor.log" -Tail 20 -ErrorAction SilentlyContinue | Select-String "test-"
Remove-Item $testFile -Force -ErrorAction SilentlyContinue
if ($fileDetected) {
    Write-Host "    ✅ File detection WORKING" -ForegroundColor Green
} else {
    Write-Host "    ❌ File NOT detected" -ForegroundColor Red
    $allPassed = $false
}

Write-Host ""

# ============================================================
# TEST 2: PARSEC MONITOR
# ============================================================
Write-Host "[TEST 2] PARSEC MONITOR" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Gray

# 2.1 Check task
Write-Host "  [2.1] Checking ParsecMonitorEditor task..." -ForegroundColor White
$parsecTask = Get-ScheduledTask -TaskName "ParsecMonitorEditor" -ErrorAction SilentlyContinue
if ($parsecTask -and $parsecTask.State -eq "Running") {
    Write-Host "    ✅ Task running" -ForegroundColor Green
} else {
    Write-Host "    ❌ Task not running - Restarting..." -ForegroundColor Red
    Start-ScheduledTask -TaskName "ParsecMonitorEditor" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $allPassed = $false
}

# 2.2 Check process
Write-Host "  [2.2] Checking Parsec monitor process..." -ForegroundColor White
$parsecProc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*parsec-monitor-admin.ps1*"
}
if ($parsecProc) {
    Write-Host "    ✅ Process running (PID: $($parsecProc.Id))" -ForegroundColor Green
} else {
    Write-Host "    ❌ Process NOT running!" -ForegroundColor Red
    $allPassed = $false
}

# 2.3 Check Parsec log exists
Write-Host "  [2.3] Checking Parsec log location..." -ForegroundColor White
$parsecLog = "C:\Users\Jake\AppData\Roaming\Parsec\log.txt"
if (Test-Path $parsecLog) {
    Write-Host "    ✅ Parsec log found: $parsecLog" -ForegroundColor Green
} else {
    Write-Host "    ❌ Parsec log NOT found!" -ForegroundColor Red
    $allPassed = $false
}

# 2.4 Check recent Parsec events
Write-Host "  [2.4] Checking recent Parsec events..." -ForegroundColor White
if (Test-Path "C:\ProgramData\ParsecMonitor\monitor.log") {
    $recentParsec = Get-Content "C:\ProgramData\ParsecMonitor\monitor.log" -Tail 5
    if ($recentParsec | Select-String "PARSEC") {
        Write-Host "    ✅ Parsec events logged:" -ForegroundColor Green
        $recentParsec | Select-String "PARSEC" | ForEach-Object { 
            Write-Host "      $_" -ForegroundColor Gray 
        }
    } else {
        Write-Host "    ⚠️  No recent Parsec events (may be normal)" -ForegroundColor Yellow
    }
} else {
    Write-Host "    ❌ Parsec monitor log NOT found!" -ForegroundColor Red
    $allPassed = $false
}

Write-Host ""

# ============================================================
# TEST 3: WEBHOOK CONNECTIVITY
# ============================================================
Write-Host "[TEST 3] WEBHOOK CONNECTIVITY" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Gray

Write-Host "  [3.1] Testing webhook server..." -ForegroundColor White
try {
    $response = Invoke-WebRequest -Uri "http://192.168.1.171:5678" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "    ✅ Webhook server reachable" -ForegroundColor Green
} catch {
    Write-Host "    ❌ Cannot reach webhook server!" -ForegroundColor Red
    $allPassed = $false
}

Write-Host ""

# ============================================================
# SUMMARY
# ============================================================
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                      TEST SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if ($allPassed) {
    Write-Host "✅ ALL SYSTEMS OPERATIONAL!" -ForegroundColor Green
    Write-Host ""
    Write-Host "What's working:" -ForegroundColor White
    Write-Host "  • File Activity Monitor - Detecting file changes" -ForegroundColor Green
    Write-Host "  • Parsec Monitor - Ready to detect connections" -ForegroundColor Green
    Write-Host "  • Webhook Server - Ready to receive events" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Connect/disconnect via Parsec to test" -ForegroundColor White
    Write-Host "  2. Check Discord for notifications" -ForegroundColor White
} else {
    Write-Host "⚠️  SOME ISSUES DETECTED" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Review the errors above and:" -ForegroundColor White
    Write-Host "  1. Check monitor logs for details" -ForegroundColor White
    Write-Host "  2. Verify scheduled tasks are enabled" -ForegroundColor White
    Write-Host "  3. Re-run deployment if needed" -ForegroundColor White
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

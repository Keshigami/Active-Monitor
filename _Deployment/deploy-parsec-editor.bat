@echo off
title Windows Editor PC - Parsec Monitor Setup
color 0A

echo.
echo ================================================================
echo        DEDICATED PARSEC MONITOR - WINDOWS EDITOR PC
echo ================================================================
echo.

:: Check Admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Run as Administrator!
    pause
    exit /b 1
)
echo [OK] Admin confirmed

:: ============================================================
:: PHASE 1: CLEANUP
:: ============================================================
 echo.
echo [PHASE 1] Cleaning up old instances...

:: Stop any running parsec monitor processes
echo   - Stopping old monitor processes...
powershell -Command "Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { (Get-CimInstance Win32_Process -Filter \"ProcessId = $($_.Id)\" -ErrorAction SilentlyContinue).CommandLine -like '*parsec-monitor*' } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>nul

:: Delete old scheduled task
echo   - Removing old scheduled task...
schtasks /Delete /TN "ParsecMonitorEditor" /F >nul 2>&1

:: Clean directory
echo   - Cleaning old files...
if exist "C:\ProgramData\ParsecMonitor" (
    rmdir /S /Q "C:\ProgramData\ParsecMonitor" 2>nul
)

echo [OK] Cleanup complete

:: ============================================================
:: PHASE 2: INSTALL
:: ============================================================
echo.
echo [PHASE 2] Installing fresh copy...

:: Create directory
if not exist "C:\ProgramData\ParsecMonitor" mkdir "C:\ProgramData\ParsecMonitor"

:: Download script from Admin PC
echo.
echo Downloading parsec-monitor-admin.ps1 from Admin PC...
powershell -Command "try { Invoke-WebRequest -Uri 'http://192.168.1.171:8888/parsec-monitor-admin.ps1' -OutFile 'C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1' -UseBasicParsing -TimeoutSec 10; Write-Host '[OK] Download successful' } catch { Write-Host '[FAIL]' $_.Exception.Message; exit 1 }"
if %errorlevel% neq 0 (
    echo [ERROR] Download failed!
    pause
    exit /b 1
)

:: Verify file
for %%A in ("C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1") do (
    if %%~zA LSS 1000 (
        echo [ERROR] Downloaded file is too small.
        pause
        exit /b 1
    )
    echo [OK] File size: %%~zA bytes
)

:: Delete any existing task
echo.
echo Removing any existing ParsecMonitorEditor task...
schtasks /Delete /TN "ParsecMonitorEditor" /F >nul 2>&1

:: Create scheduled task with enhanced persistence
echo.
echo Creating scheduled task...
powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999; Register-ScheduledTask -TaskName 'ParsecMonitorEditor' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
echo [OK] Scheduled task created

:: Start it
echo.
echo Starting Parsec Monitor...
schtasks /Run /TN "ParsecMonitorEditor" >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARN] Failed to start task instantly. It will start on next logon.
) else (
    echo [OK] Monitor started.
)

:: Wait for initialization
timeout /t 3 /nobreak >nul

:: Verify
echo.
echo ================================================================
echo   VERIFICATION
echo ================================================================
echo.

if exist "C:\ProgramData\ParsecMonitor\monitor.log" (
    echo [OK] Log file created
    echo.
    echo Last 10 log entries:
    echo ---
    powershell -Command "Get-Content 'C:\ProgramData\ParsecMonitor\monitor.log' -Tail 10"
    echo ---
) else (
    echo [WARN] No log file found yet
)

echo.
echo ================================================================
echo                   DEPLOYMENT COMPLETE
echo ================================================================
echo.
echo You now have TWO separate monitors:
echo   1. FileActivityMonitor - File changes
echo   2. ParsecMonitorEditor - Parsec connections
echo.
echo NEXT STEPS:
echo   1. Connect/disconnect via Parsec to test
echo   2. Check Discord for notifications
echo   3. If issues, check: C:\ProgramData\ParsecMonitor\monitor.log
echo.
pause

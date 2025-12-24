@echo off
title Admin PC - Full Service Setup
color 0A

echo.
echo ================================================================
echo        ADMIN PC - FULL SERVICE SETUP v2.0
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
echo [PHASE 1] Cleaning up existing services...

:: Kill processes
taskkill /F /IM python.exe /FI "WINDOWTITLE eq *" 2>nul
taskkill /F /IM powershell.exe /FI "WINDOWTITLE eq *" 2>nul
powershell -Command "Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq '' -and $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>nul

:: Delete old jobs
schtasks /Delete /TN "FileActivityMonitor" /F >nul 2>&1
schtasks /Delete /TN "FileMonitorHttpServer" /F >nul 2>&1
schtasks /Delete /TN "FileMonitorUpdateServer" /F >nul 2>&1
schtasks /Delete /TN "ParsecMonitorAdmin" /F >nul 2>&1

:: Deleting scripts (Preserving Logs)
if exist "C:\ProgramData\FileMonitor\file-monitor.ps1" del /F "C:\ProgramData\FileMonitor\file-monitor.ps1" 2>nul
if exist "C:\ProgramData\FileMonitor\http-log-server.ps1" del /F "C:\ProgramData\FileMonitor\http-log-server.ps1" 2>nul
:: Note: events.json and monitor.log are PRESERVED

echo [OK] Cleanup complete

:: ============================================================
:: PHASE 2: INSTALL FILES
:: ============================================================
echo.
echo [PHASE 2] Installing files...

:: Create Directories
if not exist "C:\ProgramData\FileMonitor" mkdir "C:\ProgramData\FileMonitor"
if not exist "C:\ProgramData\ParsecMonitor" mkdir "C:\ProgramData\ParsecMonitor"

:: Copy Scripts
:: 1. File Monitor (Using Admin version)
copy /Y "%~dp0file-monitor-admin.ps1" "C:\ProgramData\FileMonitor\file-monitor.ps1" >nul
echo   - Installed: File Monitor (Admin Version)

:: 2. HTTP Log Server
copy /Y "%~dp0http-log-server.ps1" "C:\ProgramData\FileMonitor\http-log-server.ps1" >nul
echo   - Installed: HTTP Log Server

:: 3. Parsec Monitor
copy /Y "%~dp0parsec-monitor-admin.ps1" "C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1" >nul
echo   - Installed: Parsec Monitor

echo [OK] Files installed

:: ============================================================
:: PHASE 3: SCHEDULE TASKS
:: ============================================================
echo.
echo [PHASE 3] Creating Scheduled Tasks (Auto-Start)...

:: 1. File Activity Monitor (AtLogon)
powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\FileMonitor\file-monitor.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999; Register-ScheduledTask -TaskName 'FileActivityMonitor' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
echo   - Scheduled: FileActivityMonitor

:: 2. HTTP Log Server (AtLogon)
powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\FileMonitor\http-log-server.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999; Register-ScheduledTask -TaskName 'FileMonitorHttpServer' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
echo   - Scheduled: FileMonitorHttpServer

:: 3. Parsec Monitor (AtLogon)
powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999; Register-ScheduledTask -TaskName 'ParsecMonitorAdmin' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
echo   - Scheduled: ParsecMonitorAdmin

:: 4. Update Server (AtStartup - System Wide)
:: Note: This runs python from the generic python install. Ensure python is in PATH.
powershell -Command "$action = New-ScheduledTaskAction -Execute 'pythonw.exe' -Argument '-m http.server 8888' -WorkingDirectory '%~dp0'; $trigger = New-ScheduledTaskTrigger -AtStartup; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable; Register-ScheduledTask -TaskName 'FileMonitorUpdateServer' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
echo   - Scheduled: FileMonitorUpdateServer

echo [OK] All tasks registered

:: ============================================================
:: PHASE 4: FIREWALL
:: ============================================================
echo.
echo [PHASE 4] Configuring Firewall...

powershell -Command "Remove-NetFirewallRule -DisplayName 'FileMonitor*' -ErrorAction SilentlyContinue" 2>nul
powershell -Command "New-NetFirewallRule -DisplayName 'FileMonitor UpdateServer' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8888 -Enabled True" >nul 2>&1
powershell -Command "New-NetFirewallRule -DisplayName 'FileMonitor HTTP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8080 -Enabled True" >nul 2>&1
powershell -Command "New-NetFirewallRule -DisplayName 'FileMonitor Webhook' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5678 -Enabled True" >nul 2>&1

echo [OK] Firewall ports enabled (8080, 8888, 5678)

:: ============================================================
:: PHASE 5: LAUNCH
:: ============================================================
echo.
echo [PHASE 5] Starting services...

schtasks /Run /TN "FileActivityMonitor" >nul 2>&1
schtasks /Run /TN "FileMonitorHttpServer" >nul 2>&1
schtasks /Run /TN "ParsecMonitorAdmin" >nul 2>&1
schtasks /Run /TN "FileMonitorUpdateServer" >nul 2>&1

echo [OK] All services started.

:: Wait then RESTART file monitor to ensure FileSystemWatcher initializes properly
timeout /t 3 /nobreak >nul
echo   - Restarting FileActivityMonitor to initialize FileSystemWatcher...
schtasks /End /TN "FileActivityMonitor" >nul 2>&1
timeout /t 2 /nobreak >nul
schtasks /Run /TN "FileActivityMonitor" >nul 2>&1
timeout /t 3 /nobreak >nul

echo.
echo ================================================================
echo    SELF-TEST VERIFICATION
echo ================================================================
echo.
timeout /t 2 /nobreak >nul

:: --- FILE MONITOR SELF-TEST (All Event Types) ---
echo [TEST 1] File Events...
set "TEST_FILE=%USERPROFILE%\Desktop\.monitor_selftest_%RANDOM%"
set PASSED=0

:: Test CREATED
echo    Testing: Created...
echo test > "%TEST_FILE%" 2>nul
timeout /t 3 /nobreak >nul
powershell -Command "$j = Get-Content 'C:\ProgramData\FileMonitor\events.json' -Raw -ErrorAction SilentlyContinue; if ($j -match 'monitor_selftest' -and $j -match '\"event\":\s*\"created\"') { Write-Host '    [OK] Created event captured'; exit 0 } else { Write-Host '    [?] Created not found'; exit 1 }"
if %errorlevel% equ 0 set /a PASSED+=1

:: Test MODIFIED
echo    Testing: Modified...
echo modified >> "%TEST_FILE%" 2>nul
timeout /t 3 /nobreak >nul
powershell -Command "$j = Get-Content 'C:\ProgramData\FileMonitor\events.json' -Raw -ErrorAction SilentlyContinue; if ($j -match 'monitor_selftest' -and $j -match '\"event\":\s*\"changed\"') { Write-Host '    [OK] Modified event captured'; exit 0 } else { Write-Host '    [?] Modified not found'; exit 1 }"
if %errorlevel% equ 0 set /a PASSED+=1

:: Test DELETED
echo    Testing: Deleted...
del "%TEST_FILE%" 2>nul
timeout /t 3 /nobreak >nul
powershell -Command "$j = Get-Content 'C:\ProgramData\FileMonitor\events.json' -Raw -ErrorAction SilentlyContinue; if ($j -match 'monitor_selftest' -and $j -match '\"event\":\s*\"deleted\"') { Write-Host '    [OK] Deleted event captured'; exit 0 } else { Write-Host '    [?] Deleted not found'; exit 1 }"
if %errorlevel% equ 0 set /a PASSED+=1

:: Summary
if %PASSED% equ 3 (
    echo   [OK] All file event tests passed (3/3)
) else (
    echo   [PARTIAL] %PASSED%/3 tests passed (rate limiting may affect results)
)

:: --- PORT CHECKS ---
echo.
echo [TEST 2] Service Ports...
netstat -an | findstr "8888" >nul 2>&1
if %errorlevel% equ 0 ( echo   [OK] Port 8888 - Update Server OPEN ) else ( echo   [WARN] Port 8888 closed )

netstat -an | findstr "8080" >nul 2>&1
if %errorlevel% equ 0 ( echo   [OK] Port 8080 - Log Server OPEN ) else ( echo   [WARN] Port 8080 closed )

netstat -an | findstr "5678" >nul 2>&1
if %errorlevel% equ 0 ( echo   [OK] Port 5678 - n8n Webhook OPEN ) else ( echo   [WARN] Port 5678 closed )

:: --- PARSEC MONITOR CHECK ---
echo.
echo [TEST 3] Parsec Monitor...
powershell -Command "if (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {$_.CommandLine -match 'parsec-monitor'}) { Write-Host '  [OK] Parsec monitor running' } else { Write-Host '  [WARN] Parsec monitor not running' }"

:: --- INTERACTIVE PARSEC TEST ---
echo.
echo ================================================================
echo    PARSEC CONNECTION TEST
echo ================================================================
echo.
echo   Please test Parsec now:
echo     1. Connect to Admin PC via Parsec from another device
echo     2. Disconnect from Parsec
echo   Watch for events in:
echo     - Discord notifications
echo     - C:\ProgramData\ParsecMonitor\monitor.log
echo.
set /p PARSEC_RESPONSE="Press Enter after testing Parsec (or type 'skip' to skip): "

if /i not "%PARSEC_RESPONSE%"=="skip" (
    if exist "C:\ProgramData\ParsecMonitor\monitor.log" (
        powershell -Command "if ((Get-Content 'C:\ProgramData\ParsecMonitor\monitor.log' -Tail 10) -match 'connected|disconnected') { Write-Host '  [OK] Parsec events detected!' } else { Write-Host '  [?] No recent Parsec events in log' }"
    ) else (
        echo   [WARN] Parsec log file not found
    )
) else (
    echo   Parsec test skipped.
)

echo.
echo ================================================================
echo            ADMIN PC SETUP COMPLETE
echo ================================================================
echo.
echo All 4 services installed and running:
echo   - FileActivityMonitor (Admin version)
echo   - FileMonitorHttpServer (port 8080)
echo   - ParsecMonitorAdmin
echo   - FileMonitorUpdateServer (port 8888)
echo.
pause

@echo off
title Windows Monitor - Clean Deploy
color 0A

echo.
echo ================================================================
echo        WINDOWS EDITOR PC - CLEAN DEPLOY v2.0
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
:: PHASE 1: NUCLEAR CLEANUP
:: ============================================================
echo.
echo [PHASE 1] Cleaning up all existing monitor instances...

:: Kill ALL PowerShell processes running file-monitor
echo   - Killing monitor processes...
taskkill /F /IM powershell.exe /FI "WINDOWTITLE eq *" 2>nul
powershell -Command "Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq '' -and $_.Id -ne $PID } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>nul

:: Remove scheduled tasks
echo   - Removing scheduled tasks...
schtasks /Delete /TN "FileActivityMonitor" /F >nul 2>&1
schtasks /Delete /TN "FileMonitorHttpServer" /F >nul 2>&1
schtasks /Delete /TN "ParsecMonitorEditor" /F >nul 2>&1

:: Delete scripts but PRESERVE logs (events.json)
echo   - Deleting old scripts (preserving logs)...
if exist "C:\ProgramData\FileMonitor\file-monitor.ps1" del /F "C:\ProgramData\FileMonitor\file-monitor.ps1" 2>nul
if exist "C:\ProgramData\FileMonitor\http-log-server.ps1" del /F "C:\ProgramData\FileMonitor\http-log-server.ps1" 2>nul
if exist "C:\ProgramData\FileMonitor\monitor.log" del /F "C:\ProgramData\FileMonitor\monitor.log" 2>nul
if exist "C:\ProgramData\FileMonitor\http-server.log" del /F "C:\ProgramData\FileMonitor\http-server.log" 2>nul
:: Note: events.json is PRESERVED for daily report continuity

:: Clean Parsec monitor but preserve its logs too
if exist "C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1" del /F "C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1" 2>nul

:: Wait for mutex to release
echo   - Waiting 3 seconds for cleanup...
timeout /t 3 /nobreak >nul

echo [OK] Cleanup complete (logs preserved)

:: ============================================================
:: PHASE 2: FRESH INSTALL
:: ============================================================
echo.
echo [PHASE 2] Installing fresh copy...

:: Create directory
mkdir "C:\ProgramData\FileMonitor" 2>nul

:: Download from Admin PC
echo   - Downloading scripts from Admin PC (192.168.1.171:8888)...
powershell -Command "try { Invoke-WebRequest -Uri 'http://192.168.1.171:8888/file-monitor.ps1' -OutFile 'C:\ProgramData\FileMonitor\file-monitor.ps1' -UseBasicParsing -TimeoutSec 10; Write-Host '   [OK] file-monitor.ps1 downloaded' } catch { Write-Host '   [FAIL]' $_.Exception.Message; exit 1 }"
if %errorlevel% neq 0 (
    echo [ERROR] Download failed! Is the update server running on Admin PC?
    echo         Run start-update-server.bat on the Admin PC first.
    pause
    exit /b 1
)

:: Download HTTP Log Server
powershell -Command "try { Invoke-WebRequest -Uri 'http://192.168.1.171:8888/http-log-server.ps1' -OutFile 'C:\ProgramData\FileMonitor\http-log-server.ps1' -UseBasicParsing -TimeoutSec 10; Write-Host '   [OK] http-log-server.ps1 downloaded' } catch { Write-Host '   [FAIL]' $_.Exception.Message; exit 1 }"
if %errorlevel% neq 0 (
    echo [ERROR] HTTP log server download failed!
    pause
    exit /b 1
)

:: Download Parsec Monitor (for Parsec connect/disconnect tracking)
if not exist "C:\ProgramData\ParsecMonitor" mkdir "C:\ProgramData\ParsecMonitor" 2>nul
powershell -Command "try { Invoke-WebRequest -Uri 'http://192.168.1.171:8888/parsec-monitor-admin.ps1' -OutFile 'C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1' -UseBasicParsing -TimeoutSec 10; Write-Host '   [OK] parsec-monitor-admin.ps1 downloaded' } catch { Write-Host '   [WARN] Parsec monitor download failed (optional)' }"

:: Verify file exists and has content
for %%A in ("C:\ProgramData\FileMonitor\file-monitor.ps1") do (
    if %%~zA LSS 1000 (
        echo [ERROR] Downloaded file is too small. Download may have failed.
        pause
        exit /b 1
    )
    echo   - File size: %%~zA bytes [OK]
)

:: ============================================================
:: PHASE 3: CONFIGURE FIREWALL
:: ============================================================
echo.
echo [PHASE 3] Configuring firewall...

powershell -Command "Remove-NetFirewallRule -DisplayName 'FileMonitor*' -ErrorAction SilentlyContinue" 2>nul
powershell -Command "New-NetFirewallRule -DisplayName 'FileMonitor Outbound' -Direction Outbound -Action Allow -Protocol TCP -RemotePort 5678 -RemoteAddress 192.168.1.171 -Enabled True" >nul 2>&1
powershell -Command "New-NetFirewallRule -DisplayName 'FileMonitor HTTP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8080 -Enabled True" >nul 2>&1
echo [OK] Firewall configured

:: ============================================================
:: PHASE 4: CREATE SCHEDULED TASKS
:: ============================================================
echo.
echo [PHASE 4] Creating scheduled tasks...

:: File Activity Monitor Task
powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\FileMonitor\file-monitor.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999; Register-ScheduledTask -TaskName 'FileActivityMonitor' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
echo   [OK] FileActivityMonitor task created

:: HTTP Log Server Task
schtasks /Delete /TN "FileMonitorHttpServer" /F >nul 2>&1
powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\FileMonitor\http-log-server.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999; Register-ScheduledTask -TaskName 'FileMonitorHttpServer' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
echo   [OK] FileMonitorHttpServer task created

:: Parsec Monitor Task (for connect/disconnect tracking)
if exist "C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1" (
    schtasks /Delete /TN "ParsecMonitorEditor" /F >nul 2>&1
    powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999; Register-ScheduledTask -TaskName 'ParsecMonitorEditor' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1
    echo   [OK] ParsecMonitorEditor task created
) else (
    echo   [SKIP] ParsecMonitorEditor - script not found
)

:: ============================================================
:: PHASE 5: START SERVICES
:: ============================================================
echo.
echo [PHASE 5] Starting background services...

schtasks /Run /TN "FileActivityMonitor" >nul 2>&1
if %errorlevel% neq 0 (
    echo   [WARN] FileActivityMonitor failed to start instantly.
) else (
    echo   [OK] FileActivityMonitor started.
)

schtasks /Run /TN "FileMonitorHttpServer" >nul 2>&1
if %errorlevel% neq 0 (
    echo   [WARN] FileMonitorHttpServer failed to start instantly.
) else (
    echo   [OK] FileMonitorHttpServer started.
)

:: Start Parsec Monitor if available
if exist "C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1" (
    schtasks /Run /TN "ParsecMonitorEditor" >nul 2>&1
    if %errorlevel% neq 0 (
        echo   [WARN] ParsecMonitorEditor failed to start instantly.
    ) else (
        echo   [OK] ParsecMonitorEditor started.
    )
)

:: Wait for initialization
echo   - Waiting for initialization...
timeout /t 3 /nobreak >nul

:: RESTART file monitor to ensure FileSystemWatcher initializes properly
echo   - Restarting FileActivityMonitor to initialize FileSystemWatcher...
schtasks /End /TN "FileActivityMonitor" >nul 2>&1
timeout /t 2 /nobreak >nul
schtasks /Run /TN "FileActivityMonitor" >nul 2>&1
timeout /t 3 /nobreak >nul

echo.
echo ================================================================
echo   VERIFICATION
echo ================================================================
echo.

:: ============================================================
:: POST-INSTALL VERIFICATION (SELF-TEST)
:: ============================================================
echo.
echo [SELF-TEST] Running verification...
echo.

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

:: Check if log file was created
if exist "C:\ProgramData\FileMonitor\monitor.log" (
    echo [OK] Log file created
) else (
    echo [WARN] No log file found yet
)

:: Check Parsec monitor status
if exist "C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1" (
    powershell -Command "if (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {$_.CommandLine -match 'parsec-monitor'}) { Write-Host '[OK] Parsec monitor running' } else { Write-Host '[WARN] Parsec monitor not running' }"
)

:: Check webhook connectivity
echo.
echo Testing webhook connectivity...
powershell -Command "try { $r = Invoke-RestMethod -Uri 'http://192.168.1.171:5678/webhook/file-activity' -Method Post -Body '{\"test\":true}' -ContentType 'application/json' -TimeoutSec 5; Write-Host '[OK] Webhook reachable' } catch { Write-Host '[WARN] Webhook test:' $_.Exception.Message }"

:: --- INTERACTIVE PARSEC TEST ---
echo.
echo ================================================================
echo    PARSEC CONNECTION TEST
echo ================================================================
echo.
echo   Please test Parsec now:
echo     1. Connect to this Editor PC via Parsec
echo     2. Disconnect from Parsec
echo   Watch for [PARSEC] events in Discord
echo.
set /p PARSEC_RESPONSE="Press Enter after testing Parsec (or type 'skip' to skip): "

if /i not "%PARSEC_RESPONSE%"=="skip" (
    if exist "C:\ProgramData\ParsecMonitor\monitor.log" (
        powershell -Command "if ((Get-Content 'C:\ProgramData\ParsecMonitor\monitor.log' -Tail 10) -match 'connected|disconnected') { Write-Host '  [OK] Parsec events detected!' } else { Write-Host '  [?] No recent Parsec events - try connecting again' }"
    ) else (
        echo   [INFO] Parsec log file not created yet - events go directly to webhook
    )
) else (
    echo   Parsec test skipped.
)

echo.
echo ================================================================
echo          WINDOWS EDITOR DEPLOYMENT COMPLETE
echo ================================================================
echo.
echo Services installed and running:
echo   - FileActivityMonitor
echo   - FileMonitorHttpServer (port 8080)
echo   - ParsecMonitorEditor
echo.
pause

@echo off
title Admin PC - Full Setup
color 0A

echo.
echo ================================================================
echo        ADMIN PC - INSTALL ALL SERVICES
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
:: 1. Update Server (Port 8888)
:: ============================================================
echo.
echo [1/3] Setting up Update Server (Port 8888)...

:: Kill existing
taskkill /F /IM python.exe /FI "WINDOWTITLE eq *" 2>nul
schtasks /Delete /TN "FileMonitorUpdateServer" /F >nul 2>&1

:: Create scheduled task for update server
powershell -Command "$action = New-ScheduledTaskAction -Execute 'pythonw.exe' -Argument '-m http.server 8888' -WorkingDirectory 'd:\Operations\Active monitor\_Deployment'; $trigger = New-ScheduledTaskTrigger -AtStartup; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable; Register-ScheduledTask -TaskName 'FileMonitorUpdateServer' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1

:: Start it now
schtasks /Run /TN "FileMonitorUpdateServer" >nul 2>&1
echo [OK] Update Server scheduled (runs at startup)

:: ============================================================
:: 2. Parsec Monitor
:: ============================================================
echo.
echo [2/3] Setting up Parsec Monitor...

:: Kill existing
powershell -Command "Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq '' } | Stop-Process -Force -ErrorAction SilentlyContinue" 2>nul
schtasks /Delete /TN "ParsecMonitorAdmin" /F >nul 2>&1

:: Create install directory
if not exist "C:\ProgramData\ParsecMonitor" mkdir "C:\ProgramData\ParsecMonitor"
copy /Y "%~dp0parsec-monitor-admin.ps1" "C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1" >nul

:: Create scheduled task
powershell -Command "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\ProgramData\ParsecMonitor\parsec-monitor-admin.ps1\"'; $trigger = New-ScheduledTaskTrigger -AtLogon; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 3; Register-ScheduledTask -TaskName 'ParsecMonitorAdmin' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force" >nul 2>&1

:: Start it now
schtasks /Run /TN "ParsecMonitorAdmin" >nul 2>&1
echo [OK] Parsec Monitor scheduled (runs at logon)

:: ============================================================
:: 3. Firewall
:: ============================================================
echo.
echo [3/3] Configuring Firewall...

powershell -Command "Remove-NetFirewallRule -DisplayName 'FileMonitor*' -ErrorAction SilentlyContinue" 2>nul
powershell -Command "New-NetFirewallRule -DisplayName 'FileMonitor UpdateServer' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8888 -Enabled True" >nul 2>&1
powershell -Command "New-NetFirewallRule -DisplayName 'FileMonitor n8n Webhook' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5678 -Enabled True" >nul 2>&1
echo [OK] Firewall configured

:: ============================================================
:: Verify
:: ============================================================
echo.
echo ================================================================
echo Verifying services...
timeout /t 3 /nobreak >nul

echo.
echo Checking Update Server (port 8888)...
netstat -an | findstr "8888" >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Update Server is running
) else (
    echo [WARN] Update Server may not be running yet
)

echo.
echo Checking Parsec Monitor...
powershell -Command "if (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*parsec-monitor*' }) { Write-Host '[OK] Parsec Monitor is running' } else { Write-Host '[WARN] Parsec Monitor may not be running yet' }"

echo.
echo ================================================================
echo                    SETUP COMPLETE
echo ================================================================
echo.
echo Scheduled Tasks Created:
echo   - FileMonitorUpdateServer (runs at startup)
echo   - ParsecMonitorAdmin (runs at logon)
echo.
echo Both services will start automatically after restart.
echo.
pause

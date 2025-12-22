@echo off
:: Deploy HTTP Log Server as standalone scheduled task
:: Run as Administrator

echo === Deploying HTTP Log Server ===

:: Clean up existing instances
echo Cleaning existing instances...
schtasks /End /TN "FileMonitorHttpServer" >nul 2>&1
schtasks /Delete /TN "FileMonitorHttpServer" /F >nul 2>&1
powershell -Command "Get-Process -Name powershell | Where-Object { $_.MainWindowTitle -like '*http-log-server*' } | Stop-Process -Force -ErrorAction SilentlyContinue"
powershell -Command "Stop-ScheduledTask -TaskName 'FileActivityMonitor' -ErrorAction SilentlyContinue"
timeout /t 2 >nul

:: Kill any process using port 8080
echo Freeing port 8080...
for /f "tokens=5" %%a in ('netstat -ano ^| findstr :8080 ^| findstr LISTENING') do (
    taskkill /F /PID %%a >nul 2>&1
)

:: Download script
set SCRIPT_URL=http://192.168.1.171:8888/http-log-server.ps1
set SCRIPT_DIR=%ProgramData%\FileMonitor
set SCRIPT_PATH=%SCRIPT_DIR%\http-log-server.ps1

if not exist "%SCRIPT_DIR%" mkdir "%SCRIPT_DIR%"

echo Downloading HTTP server script...
powershell -Command "Invoke-WebRequest -Uri '%SCRIPT_URL%' -OutFile '%SCRIPT_PATH%'"

:: Remove old task if exists
schtasks /Delete /TN "FileMonitorHttpServer" /F >nul 2>&1

:: Create scheduled task
echo Creating scheduled task...
schtasks /Create /TN "FileMonitorHttpServer" ^
    /TR "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%SCRIPT_PATH%\"" ^
    /SC ONLOGON ^
    /RL HIGHEST ^
    /F

:: Configure task for auto-restart on failure
powershell -Command "$task = Get-ScheduledTask -TaskName 'FileMonitorHttpServer'; $settings = $task.Settings; $settings.RestartCount = 999; $settings.RestartInterval = 'PT1M'; $settings.ExecutionTimeLimit = 'PT0S'; $settings.DisallowStartIfOnBatteries = $false; $settings.StopIfGoingOnBatteries = $false; Set-ScheduledTask -TaskName 'FileMonitorHttpServer' -Settings $settings"

:: Start the task now
echo Starting HTTP server...
schtasks /Run /TN "FileMonitorHttpServer"

:: Wait and verify
timeout /t 5 >nul
powershell -Command "try { $r = Invoke-WebRequest -Uri 'http://localhost:8080/health' -UseBasicParsing; if ($r.StatusCode -eq 200) { Write-Host 'SUCCESS: HTTP Server is running!' -ForegroundColor Green } } catch { Write-Host 'WARNING: Server may still be starting...' -ForegroundColor Yellow }"

echo.
echo Deployment complete!
echo HTTP Server: http://localhost:8080/logs
echo Health Check: http://localhost:8080/health
echo.
pause

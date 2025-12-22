@echo off
:: Bulletproof Update Server using Python
:: No admin required

set SCRIPT_DIR=d:\Operations\Active monitor\_Deployment
set LOG_FILE=%ProgramData%\FileMonitor\update-server.log

:: Kill any existing python servers on port 8888
for /f "tokens=5" %%a in ('netstat -ano ^| findstr :8888 ^| findstr LISTENING') do (
    taskkill /F /PID %%a >nul 2>&1
)

cd /d "%SCRIPT_DIR%"

echo [%date% %time%] Starting Update Server on port 8888 >> "%LOG_FILE%"
echo Serving from: %SCRIPT_DIR% >> "%LOG_FILE%"

:: Start Python HTTP server (runs indefinitely)
python -m http.server 8888 --bind 0.0.0.0 2>&1 >> "%LOG_FILE%"

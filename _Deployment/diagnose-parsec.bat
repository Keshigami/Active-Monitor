@echo off
title Parsec Diagnostics - Windows Editor PC
color 0E

echo.
echo ================================================================
echo        PARSEC DIAGNOSTICS
echo ================================================================
echo.
echo This will help diagnose why Parsec events aren't being detected.
echo.

:: Check if Parsec is installed
echo [1/5] Checking if Parsec is installed...
if exist "%PROGRAMFILES%\Parsec\parsecd.exe" (
    echo   [OK] Parsec found in Program Files
) else (
    echo   [WARN] Parsec not found in Program Files
)

:: Check log location
echo.
echo [2/5] Checking Parsec log locations...
set LOG_FOUND=0

if exist "%APPDATA%\Parsec\log.txt" (
    echo   [OK] Log found: %APPDATA%\Parsec\log.txt
    set PARSEC_LOG=%APPDATA%\Parsec\log.txt
    set LOG_FOUND=1
) else (
    echo   [WARN] No log at: %APPDATA%\Parsec\log.txt
)

if exist "%USERPROFILE%\.parsec\log.txt" (
    echo   [OK] Log found: %USERPROFILE%\.parsec\log.txt
    if %LOG_FOUND%==0 set PARSEC_LOG=%USERPROFILE%\.parsec\log.txt
    set LOG_FOUND=1
) else (
    echo   [WARN] No log at: %USERPROFILE%\.parsec\log.txt
)

if %LOG_FOUND%==0 (
    echo.
    echo   [ERROR] No Parsec log file found!
    echo   Please check if Parsec is installed and has been run at least once.
    pause
    exit /b 1
)

:: Show log file info
echo.
echo [3/5] Log file information...
echo   Path: %PARSEC_LOG%
for %%A in ("%PARSEC_LOG%") do (
    echo   Size: %%~zA bytes
    echo   Modified: %%~tA
)

:: Show last 20 lines
echo.
echo [4/5] Last 20 lines of Parsec log:
echo ---
powershell -Command "Get-Content '%PARSEC_LOG%' -Tail 20"
echo ---

:: Test connection detection
echo.
echo [5/5] Testing connection pattern matching...
echo Searching for connection/disconnection patterns...
powershell -Command "$lines = Get-Content '%PARSEC_LOG%' -Tail 50; $found = $false; foreach ($line in $lines) { if ($line -match '\[I .*?\] (.*?) (connected|disconnected)\.') { Write-Host '  [FOUND] ' -NoNewline -ForegroundColor Green; Write-Host $line; $found = $true } }; if (-not $found) { Write-Host '  [NOT FOUND] No connection events in last 50 lines' -ForegroundColor Red }"

echo.
echo ================================================================
echo                    DIAGNOSTICS COMPLETE
echo ================================================================
echo.
echo Next steps:
echo   1. If no connection patterns found, try connecting via Parsec
echo   2. Check if monitor is watching the correct log path
echo   3. Review monitor.log: C:\ProgramData\FileMonitor\monitor.log
echo.
pause

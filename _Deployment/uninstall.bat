@echo off
title File Activity Monitor - Uninstaller
color 0C

echo.
echo ============================================================
echo         FILE ACTIVITY MONITOR - UNINSTALLER
echo ============================================================
echo.
echo This will completely remove the File Activity Monitor.
echo.

:: Check for Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] This script must be run as Administrator!
    echo.
    echo Please right-click this file and select "Run as administrator"
    echo.
    pause
    exit /b 1
)

echo [1/3] Stopping and removing Scheduled Task...
schtasks /End /TN "FileActivityMonitor" >nul 2>&1
schtasks /Delete /TN "FileActivityMonitor" /F >nul 2>&1
echo [OK] Scheduled Task removed.

echo.
echo [2/3] Removing Firewall Rule...
powershell -Command "Remove-NetFirewallRule -DisplayName 'FileMonitor Outbound' -ErrorAction SilentlyContinue" 2>nul
echo [OK] Firewall rule removed.

echo.
echo [3/3] Deleting installed files...
set "INSTALL_DIR=%ProgramData%\FileMonitor"
if exist "%INSTALL_DIR%" (
    rmdir /S /Q "%INSTALL_DIR%"
    echo [OK] Files deleted from %INSTALL_DIR%
) else (
    echo [OK] No files to delete.
)

echo.
echo ============================================================
echo                   UNINSTALL COMPLETE
echo ============================================================
echo.
echo The File Activity Monitor has been completely removed.
echo.
pause

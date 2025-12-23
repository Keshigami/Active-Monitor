# 🔧 Active Monitor Maintenance Guide

This guide explains how to keep the Active Monitor system running smoothly and how to solve common "problems" if they reoccur.

## 1. How to Add Exclusions (Stop Log Bloat)
If `events.json` grows too large (e.g., >10MB) or n8n times out, a new "spammy" file type has likely appeared (e.g., a new Adobe temp file).

**Steps to Fix:**
1.  Open `d:\Operations\Active monitor\_Deployment\` on the **Admin PC**.
2.  Edit **Both Scripts**:
    *   `file-monitor-admin.ps1` (Line ~309: `$ignorePatterns`)
    *   `file-monitor.ps1` (Line ~309: `$ignorePatterns`)
    *   `file-monitor-mac.sh` (Line ~196: `IGNORE_PATTERNS`)
3.  Add the new extension (e.g., `'.nef'`) to the list.
4.  **Save**.
5.  **Redeploy** to the affected machines (see below).

## 2. Safe Redeployment (Fix "It Stopped Working")
If a monitor stops working or you updated the script, simply run the **Safe Deploy** command.
*It is designed to be run repeatedly without breaking anything.*

**Windows (Editor):**
```powershell
Invoke-WebRequest "http://192.168.1.171:8888/deploy-windows.bat" -OutFile "$env:TEMP\deploy.bat"; Start-Process cmd.exe "/c $env:TEMP\deploy.bat" -Verb RunAs
```

**Mac (Editor):**
```bash
curl -s http://192.168.1.171:8888/file-monitor-mac.sh | bash
```

**Admin PC:**
Restart the task manually or run:
```powershell
Stop-ScheduledTask "FileActivityMonitor"; Start-ScheduledTask "FileActivityMonitor"
```

## 3. Verify It's Working
Check the "Pulse" of the system by visiting:
*   **Windows Editor Logs:** `http://192.168.1.172:8080/logs`
*   **Mac Editor Logs:** `http://192.168.1.170:8080/logs`

If these links load, the system is healthy.

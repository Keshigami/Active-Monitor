# Active Monitor System v2.0 - Deployment Walkthrough

This document outlines the final configuration and deployment steps for the Active Monitor System (v2.0).

## System Architecture

The system consists of three components working in unison:

1. **Admin PC (Central Hub)** `192.168.1.171`
    * **Services**:
        * Update Server (Port 8888) - Serves scripts to other PCs.
        * n8n Webhook (Port 5678) - Receives events from all PCs.
        * Parsec Monitor - Tracks Parsec connections on Admin PC.
    * **Persistence**: Auto-Start at Boot (Update Server) & Logon (Monitor).

2. **Windows Editor PC**
    * **Monitor**: `file-monitor.ps1` (v2.0.0)
    * **Function**: Tracks File Changes, Active App, Parsec Connections.
    * **Persistence**: Hidden Scheduled Task (Auto-Start at Logon).

3. **Mac Editor PC**
    * **Monitor**: `file-monitor-mac.sh` (v2.0)
    * **Function**: Tracks File Changes, Active App, Parsec Connections.
    * **Persistence**: LaunchAgent (Auto-Start at Login).

---

## Deployment Instructions

All deployment is managed via the **Deployment Website** hosted on the Admin PC.

**Deployment URL:** `http://192.168.1.171:8888`

### 1. Admin PC Setup (This Machine)

Run this once to set up the Update Server and local monitor services.

```powershell
Invoke-WebRequest "http://192.168.1.171:8888/setup-admin-pc.bat" -OutFile "$env:TEMP\setup.bat"; Start-Process cmd.exe "/c $env:TEMP\setup.bat" -Verb RunAs
```

### 2. Windows Editor PC

Run this in PowerShell on the Editor PC. It performs a clean install and starts the background service immediately.

```powershell
Invoke-WebRequest "http://192.168.1.171:8888/deploy-windows.bat" -OutFile "$env:TEMP\deploy.bat"; Start-Process cmd.exe "/c $env:TEMP\deploy.bat" -Verb RunAs
```

### 3. Mac Editor PC

Run this in Terminal on the Mac Editor.

```bash
curl -s http://192.168.1.171:8888/file-monitor-mac.sh | bash
```

---

## Maintenance & Logs

* **View Logs**: navigate to `http://<PC-IP>:8080/logs` (e.g., `http://192.168.1.172:8080/logs`)
* **Discord**: Check the `#active-monitor` channel (or configured channel) for notifications.
* **Source Folder**: `d:\Operations\Active monitor\_Deployment` (on Admin PC)

## Version History

* **v2.0** (Current): Unified release. Background services for all platforms. Auto-update capable.
* **v1.x**: Initial development versions.

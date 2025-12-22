# Active Monitor System v2.1 - Documentation

## System Overview

Cross-platform monitoring system for Editor PCs tracking file activity, active applications, and Parsec remote connections.

## Network Architecture

| Machine | IP | Role | Services |
|---------|-----|------|----------|
| Admin PC | 192.168.1.171 | Central Hub | Update Server :8888, n8n Webhook :5678, Parsec Monitor |
| Windows Editor | 192.168.1.172 | Editor PC | File Monitor, Parsec Monitor, HTTP Logs :8080 |
| Mac Editor | 192.168.1.170 | Editor PC | File Monitor, Parsec Monitor, HTTP Logs :8080 |

---

## Deployment Commands

### Windows Editor PC
```powershell
cd $env:TEMP
curl -o deploy.bat http://192.168.1.171:8888/deploy-windows.bat
.\deploy.bat

# Parsec Monitor (separate task)
curl -o deploy-parsec.bat http://192.168.1.171:8888/deploy-parsec-editor.bat
.\deploy-parsec.bat

# HTTP Listener Permission (run once as Admin)
netsh http add urlacl url=http://+:8080/ user=Everyone
```

### Mac Editor PC
```bash
curl -s http://192.168.1.171:8888/file-monitor-mac.sh | bash
```

### Admin PC
```powershell
Invoke-WebRequest "http://192.168.1.171:8888/setup-admin-pc.bat" -OutFile "$env:TEMP\setup.bat"
Start-Process cmd.exe "/c $env:TEMP\setup.bat" -Verb RunAs
```

---

## Scheduled Tasks / Services

### Windows Editor PC
| Task Name | Script | Trigger | Auto-Restart |
|-----------|--------|---------|--------------|
| FileActivityMonitor | file-monitor.ps1 | At Logon | 999 attempts |
| ParsecMonitorEditor | parsec-monitor-admin.ps1 | At Logon | 999 attempts |

### Mac Editor PC
| Service | Script | Trigger | Auto-Restart |
|---------|--------|---------|--------------|
| com.filemonitor LaunchAgent | ~/.file-monitor.py | At Login | KeepAlive: true |

### Admin PC
| Task Name | Script | Trigger | Auto-Restart |
|-----------|--------|---------|--------------|
| FileMonitorUpdateServer | start-update-server.bat | At Boot | 999 attempts |
| ParsecMonitorAdmin | parsec-monitor-admin.ps1 | At Logon | 999 attempts |

---

## HTTP Logs Endpoints

Access from any machine on network:
- **Mac Editor**: `http://192.168.1.170:8080/logs`
- **Windows Editor**: `http://192.168.1.172:8080/logs`

Returns JSON with daily events:
```json
{
  "date": "2025-12-19",
  "events": [...],
  "machine": "DESKTOP-GKMTJ5H"
}
```

---

## n8n Workflows

### 1. Editor Monitor (Real-time)
- **Webhook**: `http://192.168.1.171:5678/webhook/file-activity`
- **Purpose**: Real-time Discord notifications
- **Triggers**:
  - Parsec connect/disconnect → Discord
  - File deleted → Discord
  - Other events → Logged only

### 2. Daily Report (Scheduled)
- **Schedule**: 9 PM daily
- **Data Sources**:
  - `http://192.168.1.170:8080/logs` (Mac)
  - `http://192.168.1.172:8080/logs` (Windows)
- **Output**: AI-generated summary to Discord

---

## AI Prompt for Daily Report

### System Message
```
You are the Daily Activity Analyst for Banner Mountain Media.

OUTPUT FORMAT:

📊 **Daily Editor Activity - [DATE]**

[2-3 sentence summary. Mention active projects and total remote work hours.]

---

**🖥️ Mac Editor (Jacobs-Mac-mini)**
`Status: Active/Quiet` | `Hours: [First] - [Last]`

📂 **Projects Worked On:**
• [Project Name] - X files

🗑️ **Deleted Files:**
• `[full path]`

📈 **Stats:** Created: X | Modified: X | Deleted: X

---

**🖥️ Windows Editor (DESKTOP-GKMTJ5H)**
`Status: Active/Quiet` | `Hours: [First] - [Last]`

📂 **Projects Worked On:**
• [Project Name] - X files

🗑️ **Deleted Files:**
• `[full path]`

📈 **Stats:** Created: X | Modified: X | Deleted: X

---

**🔌 Remote Sessions:**
• 👤 [User] - [Start] → [End] (**Xh Xm**)
**Total Remote: X hours**

---

**📊 Daily Totals:** Created: X | Modified: X | Deleted: X

GUIDELINES:
- ALWAYS show both machines, even if no activity
- Calculate Parsec session durations from timestamps
- List ALL deleted files with full paths
- Group files by project when possible
- Prioritize video files (.prproj, .aep, .mp4)
```

---

## Diagnostic Commands

### Windows Editor PC
```powershell
# Check tasks
Get-ScheduledTask -TaskName "FileActivityMonitor" | Select-Object State
Get-ScheduledTask -TaskName "ParsecMonitorEditor" | Select-Object State

# Check logs
Get-Content "C:\ProgramData\FileMonitor\monitor.log" -Tail 20
Get-Content "C:\ProgramData\ParsecMonitor\monitor.log" -Tail 10

# Check HTTP endpoint
curl http://localhost:8080/logs

# Restart monitors
Start-ScheduledTask -TaskName "FileActivityMonitor"
Start-ScheduledTask -TaskName "ParsecMonitorEditor"
```

### Mac Editor PC
```bash
# Check process
pgrep -fl "file-monitor"

# Check logs
tail -20 /tmp/file-monitor.log

# Check HTTP endpoint
curl http://localhost:8080/logs

# Restart
launchctl unload ~/Library/LaunchAgents/com.filemonitor.plist
launchctl load ~/Library/LaunchAgents/com.filemonitor.plist
```

---

## Key Files

| File | Location | Purpose |
|------|----------|---------|
| file-monitor.ps1 | `C:\ProgramData\FileMonitor\` | Windows file monitoring |
| parsec-monitor-admin.ps1 | `C:\ProgramData\ParsecMonitor\` | Windows Parsec monitoring |
| events.json | `C:\ProgramData\FileMonitor\` | Daily events storage |
| monitor.log | `C:\ProgramData\FileMonitor\` | Windows monitor log |
| .file-monitor.py | `~/.file-monitor.py` | Mac file + Parsec monitoring |
| .file-events.json | `~/.file-events.json` | Mac events storage |

---

## Version History

- **v2.1** (Dec 2025): Separated Parsec monitor, HTTP logs endpoint, URL ACL fix, improved n8n prompts
- **v2.0**: Unified release with background services
- **v1.x**: Initial development

*Maintained by Keshigami*

============================================================
      ACTIVE MONITOR SYSTEM v2.0 - DEPLOYMENT PACKAGE
============================================================

This folder contains the complete monitoring solution for:
1. Windows Editor PCs (File Monitor + Parsec)
2. Mac Editor PCs (File Monitor + Parsec)
3. Admin PC (Central Server + Parsec)

============================================================
                    QUICK DEPLOYMENT
============================================================

The easiest way to install/update is via the internal website:

    >>  http://192.168.1.171:8888  <<

Visit this URL from any computer to get the one-line install command.

============================================================
                   FILES IN THIS FOLDER
============================================================

[DEPLOYMENT SERVER]
  start-update-server.bat     - (Redundant) Starts the Python update server manually
  index.html                  - The Deployment Website shown at port 8888
  setup-admin-pc.bat          - Installs the Update Server & Admin Monitor as SYSTEM services

[WINDOWS MONITOR]
  file-monitor.ps1            - The core monitoring script (v2.0)
  deploy-windows.bat          - Installer script (fetches file-monitor.ps1 + sets up Task)
  uninstall.bat               - Removes the monitor completely

[MAC MONITOR]
  file-monitor-mac.sh         - Installs Python monitor + LaunchAgent service

[ADMIN MONITOR]
  parsec-monitor-admin.ps1    - Admin-specific Parsec monitor script

[N8N WORKFLOWS]
  unified-monitor.json        - Main workflow (Webhook -> Discord)
  daily-report-all-pcs.json   - Daily summary report workflow

============================================================
                 SYSTEM ARCHITECTURE (v2.0)
============================================================

1. Admin PC (192.168.1.171)
   - Hosting: Update Server (Port 8888, Auto-Start)
   - Hosting: n8n Webhook (Port 5678)
   - Monitor: Parsec Connections (Port 8080 logs)

2. Windows Editor PC
   - Monitor: File Activity + Active App + Parsec
   - Service: Hidden Scheduled Task (Auto-Start at Logon)
   - Logs: http://<IP>:8080/logs

3. Mac Editor PC
   - Monitor: File Activity + Active App + Parsec
   - Service: LaunchAgent (Auto-Start at Login)
   - Logs: http://<IP>:8080/logs

============================================================
                    MANUAL INSTALLATION
============================================================

If the website is down:

[Windows]
1. Copy 'file-monitor.ps1' to C:\ProgramData\FileMonitor\
2. Create Scheduled Task to run it hidden at logon.

[Mac]
1. Copy 'file-monitor-mac.sh' to user home.
2. Run: bash file-monitor-mac.sh

[Admin]
1. Run 'setup-admin-pc.bat' as Administrator.

# Remote Deployment Setup Guide

## Overview
Enable remote deployment from Admin PC (192.168.1.171) to:
- Windows Editor PC (192.168.1.172)
- Mac Editor PC (192.168.1.170)

---

## Part 1: Windows Editor Setup

### Step 1: Run on Windows Editor PC (ONE-TIME)
Open PowerShell as Administrator and run:
```powershell
# Enable WinRM
Enable-PSRemoting -Force

# Allow connections from Admin PC
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.171" -Force

# Configure firewall
netsh advfirewall firewall add rule name="WinRM-HTTP" protocol=TCP dir=in localport=5985 action=allow

# Verify
Get-Service WinRM
```

### Step 2: Run on Admin PC (ONE-TIME)
```powershell
# Add Windows Editor to trusted hosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.172" -Force

# Test connection
Test-WSMan -ComputerName 192.168.1.172
```

---

## Part 2: Mac Editor Setup

### Step 1: Enable SSH on Mac (ONE-TIME)
System Preferences > Sharing > Enable "Remote Login"

Or via Terminal:
```bash
sudo systemsetup -setremotelogin on
```

### Step 2: Set up SSH Key from Admin PC (ONE-TIME)
```powershell
# Generate SSH key if you don't have one
ssh-keygen -t rsa -b 4096 -f "$env:USERPROFILE\.ssh\id_rsa" -N ""

# Copy public key to Mac (replace 'username' with Mac username)
type "$env:USERPROFILE\.ssh\id_rsa.pub" | ssh username@192.168.1.170 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

---

## Part 3: Remote Deployment Commands

### Deploy to Windows Editor (from Admin PC)
```powershell
Invoke-Command -ComputerName 192.168.1.172 -ScriptBlock {
    # Stop existing monitors
    schtasks /End /TN "FileActivityMonitor" 2>$null
    schtasks /End /TN "FileMonitorHttpServer" 2>$null
    schtasks /End /TN "ParsecMonitorEditor" 2>$null
    
    # Download and run deployment script
    Invoke-WebRequest "http://192.168.1.171:8888/deploy-windows.bat" -OutFile "$env:TEMP\deploy.bat"
    Start-Process cmd.exe "/c $env:TEMP\deploy.bat" -Wait
}
```

### Deploy to Mac Editor (from Admin PC)
```powershell
ssh username@192.168.1.170 'curl -s "http://192.168.1.171:8888/file-monitor-mac.sh?$(date +%s)" | bash'
```

---

## Part 4: One-Click Deployment Script

Save this as `remote-deploy.ps1` in the Deployment folder:

```powershell
param(
    [switch]$Windows,
    [switch]$Mac,
    [switch]$All
)

$MacUser = "jacob"  # Change to actual Mac username
$MacIP = "192.168.1.170"
$WinEditorIP = "192.168.1.172"
$UpdateServer = "http://192.168.1.171:8888"

if ($All) { $Windows = $true; $Mac = $true }

if ($Windows) {
    Write-Host "Deploying to Windows Editor ($WinEditorIP)..." -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $WinEditorIP -ScriptBlock {
            schtasks /End /TN "FileActivityMonitor" 2>$null
            schtasks /End /TN "FileMonitorHttpServer" 2>$null
            Invoke-WebRequest "http://192.168.1.171:8888/deploy-windows.bat" -OutFile "$env:TEMP\deploy.bat"
            Start-Process cmd.exe "/c $env:TEMP\deploy.bat" -Wait
        }
        Write-Host "Windows Editor deployed!" -ForegroundColor Green
    }
    catch {
        Write-Host "Windows deployment failed: $_" -ForegroundColor Red
    }
}

if ($Mac) {
    Write-Host "Deploying to Mac Editor ($MacIP)..." -ForegroundColor Cyan
    try {
        ssh "$MacUser@$MacIP" "curl -s '$UpdateServer/file-monitor-mac.sh?$(Get-Date -UFormat %s)' | bash"
        Write-Host "Mac Editor deployed!" -ForegroundColor Green
    }
    catch {
        Write-Host "Mac deployment failed: $_" -ForegroundColor Red
    }
}

Write-Host "Deployment complete!" -ForegroundColor Green
```

### Usage:
```powershell
# Deploy to Windows only
.\remote-deploy.ps1 -Windows

# Deploy to Mac only
.\remote-deploy.ps1 -Mac

# Deploy to both
.\remote-deploy.ps1 -All
```

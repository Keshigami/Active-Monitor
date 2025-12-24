<#
.SYNOPSIS
    Remote Deployment Script for Active Monitor
.DESCRIPTION
    Deploys monitor scripts to Windows Editor and Mac Editor PCs from Admin PC.
.PARAMETER Windows
    Deploy to Windows Editor PC only
.PARAMETER Mac
    Deploy to Mac Editor PC only
.PARAMETER All
    Deploy to both Windows and Mac Editor PCs
#>

param(
    [switch]$Windows,
    [switch]$Mac,
    [switch]$All
)

# Configuration
$MacUser = "jacob"  # Mac username for SSH
$MacIP = "192.168.1.170"
$WinEditorIP = "192.168.1.172"
$UpdateServer = "http://192.168.1.171:8888"

if ($All) { $Windows = $true; $Mac = $true }

if (-not $Windows -and -not $Mac) {
    Write-Host "Usage: .\remote-deploy.ps1 -Windows | -Mac | -All" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  .\remote-deploy.ps1 -Windows   # Deploy to Windows Editor only"
    Write-Host "  .\remote-deploy.ps1 -Mac       # Deploy to Mac Editor only"
    Write-Host "  .\remote-deploy.ps1 -All       # Deploy to both"
    exit
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Active Monitor Remote Deployment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($Windows) {
    Write-Host "[WINDOWS] Deploying to Windows Editor ($WinEditorIP)..." -ForegroundColor Cyan
    try {
        $result = Invoke-Command -ComputerName $WinEditorIP -ScriptBlock {
            # Stop existing monitors
            schtasks /End /TN "FileActivityMonitor" 2>$null | Out-Null
            schtasks /End /TN "FileMonitorHttpServer" 2>$null | Out-Null
            schtasks /End /TN "ParsecMonitorEditor" 2>$null | Out-Null
            Start-Sleep 2
            
            # Download updated scripts
            $UpdateServer = "http://192.168.1.171:8888"
            $ScriptDir = "$env:ProgramData\FileMonitor"
            
            Invoke-WebRequest "$UpdateServer/file-monitor.ps1" -OutFile "$ScriptDir\file-monitor.ps1" -UseBasicParsing
            Invoke-WebRequest "$UpdateServer/http-log-server.ps1" -OutFile "$ScriptDir\http-log-server.ps1" -UseBasicParsing
            Invoke-WebRequest "$UpdateServer/parsec-monitor-admin.ps1" -OutFile "$ScriptDir\parsec-monitor.ps1" -UseBasicParsing
            
            # Restart monitors
            schtasks /Run /TN "FileActivityMonitor" | Out-Null
            schtasks /Run /TN "FileMonitorHttpServer" | Out-Null
            schtasks /Run /TN "ParsecMonitorEditor" | Out-Null
            
            return "SUCCESS: Scripts updated and monitors restarted"
        } -ErrorAction Stop
        
        Write-Host "[WINDOWS] $result" -ForegroundColor Green
    }
    catch {
        Write-Host "[WINDOWS] Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "If WinRM is not enabled, run this on Windows Editor PC:" -ForegroundColor Yellow
        Write-Host "  Enable-PSRemoting -Force" -ForegroundColor White
    }
    Write-Host ""
}

if ($Mac) {
    Write-Host "[MAC] Deploying to Mac Editor ($MacIP)..." -ForegroundColor Cyan
    try {
        # Test SSH connection first
        $sshTest = ssh -o ConnectTimeout=5 -o BatchMode=yes "$MacUser@$MacIP" "echo connected" 2>&1
        if ($sshTest -match "connected") {
            # Run deployment
            $timestamp = [int](Get-Date -UFormat %s)
            ssh "$MacUser@$MacIP" "curl -s '$UpdateServer/file-monitor-mac.sh?$timestamp' | bash"
            Write-Host "[MAC] Deployment script executed" -ForegroundColor Green
        }
        else {
            throw "SSH connection failed"
        }
    }
    catch {
        Write-Host "[MAC] Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "If SSH is not set up, ensure:" -ForegroundColor Yellow
        Write-Host "  1. Remote Login is enabled on Mac (System Preferences > Sharing)" -ForegroundColor White
        Write-Host "  2. SSH key is copied: ssh-copy-id $MacUser@$MacIP" -ForegroundColor White
    }
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Deployment Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

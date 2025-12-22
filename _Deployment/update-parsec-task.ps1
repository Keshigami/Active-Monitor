# Quick fix to update ParsecMonitorAdmin task settings
Write-Host "Updating ParsecMonitorAdmin task settings..." -ForegroundColor Cyan

# Export current task to XML
$xmlPath = "$env:TEMP\parsec-task.xml"
schtasks /query /TN "ParsecMonitorAdmin" /XML > $xmlPath

# Read and modify XML
[xml]$xml = Get-Content $xmlPath

# Update settings
$xml.Task.Settings.ExecutionTimeLimit = "PT0S"  # Infinite
$xml.Task.Settings.AllowStartOnDemand = "true"
$xml.Task.Settings.AllowHardTerminate = "false"
$xml.Task.Settings.RestartOnFailure.Interval = "PT1M"  # 1 minute
$xml.Task.Settings.RestartOnFailure.Count = "999"

# Save modified XML
$xml.Save($xmlPath)

# Re-register task
schtasks /Delete /TN "ParsecMonitorAdmin" /F | Out-Null
schtasks /Create /TN "ParsecMonitorAdmin" /XML $xmlPath /RU "SYSTEM" /F | Out-Null

# Start it
schtasks /Run /TN "ParsecMonitorAdmin" | Out-Null

Write-Host "Task updated successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "New settings:" -ForegroundColor Yellow
schtasks /query /TN "ParsecMonitorAdmin" /V /FO LIST | Select-String "ExecutionTimeLimit|RestartInterval|RestartCount"

Remove-Item $xmlPath -Force

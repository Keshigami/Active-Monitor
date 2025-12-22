param(
    [int]$Port = 8080
)

# HTTP Log Server - Runs as standalone service
# Bulletproof version with auto-recovery

$LogDir = "$env:ProgramData\FileMonitor"
$LogFile = Join-Path $LogDir "http-server.log"
$EventsFile = Join-Path $LogDir "events.json"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param($Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

# Single instance check
$mutexName = "Global\FileMonitorHttpServer"
$mutexCreated = $false
try {
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
}
catch {
    $mutex = $null
}

if (-not $mutexCreated) {
    Write-Log "Another HTTP server instance is already running. Exiting."
    exit
}

Write-Log "=== HTTP Log Server Starting ==="
Write-Log "Port: $Port"
Write-Log "Events File: $EventsFile"

# Create listener with retry logic
$maxRetries = 5
$retryDelay = 5
$listener = $null

for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://+:$Port/")
        $listener.Start()
        Write-Log "HTTP Server started successfully on port $Port"
        break
    }
    catch {
        Write-Log "Attempt $i failed: $($_.Exception.Message)"
        if ($i -lt $maxRetries) {
            Write-Log "Retrying in $retryDelay seconds..."
            Start-Sleep -Seconds $retryDelay
        }
        else {
            # Try localhost as fallback
            try {
                $listener = New-Object System.Net.HttpListener
                $listener.Prefixes.Add("http://localhost:$Port/")
                $listener.Start()
                Write-Log "HTTP Server started on localhost:$Port (external access may not work)"
            }
            catch {
                Write-Log "FATAL: Could not start HTTP server after $maxRetries attempts"
                exit 1
            }
        }
    }
}

# Main request loop with error recovery
$requestCount = 0
$errorCount = 0
$maxConsecutiveErrors = 10

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        
        $requestCount++
        $errorCount = 0  # Reset on successful request
        
        if ($request.Url.AbsolutePath -eq "/logs") {
            # Read events file
            $responseData = @{
                date    = (Get-Date -Format "yyyy-MM-dd")
                events  = @()
                machine = $env:COMPUTERNAME
            }
            
            if (Test-Path $EventsFile) {
                try {
                    $data = Get-Content $EventsFile -Raw -ErrorAction Stop | ConvertFrom-Json
                    $responseData = $data
                }
                catch {
                    Write-Log "Warning: Could not read events file: $($_.Exception.Message)"
                }
            }
            
            $json = $responseData | ConvertTo-Json -Depth 10 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($request.Url.AbsolutePath -eq "/health") {
            # Health check endpoint
            $health = @{
                status = "ok"
                uptime = $requestCount
                timestamp = (Get-Date).ToString("o")
            } | ConvertTo-Json
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($health)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($request.Url.AbsolutePath -eq "/logs/clear" -and $request.HttpMethod -eq "POST") {
            @{ date = (Get-Date -Format "yyyy-MM-dd"); events = @(); machine = $env:COMPUTERNAME } | 
            ConvertTo-Json | Out-File $EventsFile -Encoding UTF8 -Force
            $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"status":"cleared"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        else {
            $response.StatusCode = 404
            $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Not found"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        
        $response.Close()
    }
    catch {
        $errorCount++
        Write-Log "Request error ($errorCount): $($_.Exception.Message)"
        
        if ($errorCount -ge $maxConsecutiveErrors) {
            Write-Log "Too many consecutive errors. Restarting listener..."
            try { $listener.Stop() } catch {}
            Start-Sleep -Seconds 2
            
            try {
                $listener = New-Object System.Net.HttpListener
                $listener.Prefixes.Add("http://+:$Port/")
                $listener.Start()
                Write-Log "Listener restarted successfully"
                $errorCount = 0
            }
            catch {
                Write-Log "FATAL: Could not restart listener. Exiting."
                exit 1
            }
        }
    }
}

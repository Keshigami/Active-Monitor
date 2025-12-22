param(
    [int]$Port = 8888,
    [string]$Directory = "d:\Operations\Active monitor\_Deployment"
)

# Bulletproof Update Server with auto-recovery
# Serves deployment scripts to Editor PCs

$LogFile = "$env:ProgramData\FileMonitor\update-server.log"
$LogDir = Split-Path $LogFile -Parent
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param($Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# Single instance check
$mutexName = "Global\FileMonitorUpdateServer"
$mutexCreated = $false
try {
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
}
catch {
    $mutex = $null
}

if (-not $mutexCreated) {
    Write-Log "Another update server instance is already running. Exiting."
    exit
}

Write-Log "=== Update Server Starting ==="
Write-Log "Port: $Port"
Write-Log "Directory: $Directory"

# Change to deployment directory
Set-Location $Directory

# Create listener with retry logic
$maxRetries = 10
$retryDelay = 5
$listener = $null

for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://+:$Port/")
        $listener.Start()
        Write-Log "Update Server started successfully on port $Port"
        break
    }
    catch {
        Write-Log "Attempt $i failed: $($_.Exception.Message)"
        if ($i -lt $maxRetries) {
            Write-Log "Retrying in $retryDelay seconds..."
            Start-Sleep -Seconds $retryDelay
        }
        else {
            Write-Log "FATAL: Could not start Update Server after $maxRetries attempts"
            exit 1
        }
    }
}

# MIME types
$mimeTypes = @{
    ".html" = "text/html"
    ".css" = "text/css"
    ".js" = "application/javascript"
    ".json" = "application/json"
    ".ps1" = "text/plain"
    ".bat" = "text/plain"
    ".sh" = "text/plain"
    ".txt" = "text/plain"
    ".py" = "text/plain"
    ".md" = "text/plain"
}

# Main request loop with error recovery
$requestCount = 0
$errorCount = 0
$maxConsecutiveErrors = 10

Write-Log "Update Server running - serving files from $Directory"

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        
        $requestCount++
        $errorCount = 0  # Reset on successful request
        
        $requestPath = $request.Url.LocalPath.TrimStart('/')
        
        # Default to index.html
        if ([string]::IsNullOrEmpty($requestPath)) {
            $requestPath = "index.html"
        }
        
        $filePath = Join-Path $Directory $requestPath
        
        if (Test-Path $filePath -PathType Leaf) {
            # Serve the file
            $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
            $contentType = $mimeTypes[$extension]
            if (-not $contentType) {
                $contentType = "application/octet-stream"
            }
            
            $content = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentType = $contentType
            $response.ContentLength64 = $content.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($content, 0, $content.Length)
            
            Write-Log "200 - $requestPath ($($content.Length) bytes)"
        }
        elseif ($requestPath -eq "health") {
            # Health check endpoint
            $health = @{
                status = "ok"
                requests = $requestCount
                directory = $Directory
                timestamp = (Get-Date).ToString("o")
            } | ConvertTo-Json
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($health)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        else {
            # File not found
            $response.StatusCode = 404
            $errorMsg = "File not found: $requestPath"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorMsg)
            $response.ContentType = "text/plain"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            
            Write-Log "404 - $requestPath"
        }
        
        $response.Close()
    }
    catch {
        $errorCount++
        Write-Log "Request error ($errorCount): $($_.Exception.Message)"
        
        try { $response.Close() } catch {}
        
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

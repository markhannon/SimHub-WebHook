########################################################
# SimHub Property Server Continuous Connection Daemon
# Maintains persistent socket and streams property updates
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Start', 'Stop', 'Status')]
    [string]$Command = 'Start',
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'data'  # Directory for daemon state, logs, and PID files
)

# Configuration
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$DataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }

# Ensure data directory exists
if (-not (Test-Path $DataPath)) {
    New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
}

$simhubConfigPath = Join-Path $ScriptDir 'Simhub.json'
$propsConfigPath = Join-Path $ScriptDir 'Properties.json'
$daemonStateFile = Join-Path $DataPath '_daemon_state.json'
$daemonLogFile = Join-Path $DataPath '_daemon.log'
$daemonControlFile = Join-Path $DataPath '_daemon_control.txt'
$daemonPidFile = Join-Path $DataPath '_daemon_pid.txt'

# ==================== Logging ====================
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    if ($PSCmdlet.MyInvocation.BoundParameters['Debug']) {
        Write-Debug $logMessage
    }
    
    # Append to log file
    Add-Content -Path $daemonLogFile -Value $logMessage -Force
}

# ==================== State Management ====================
function Initialize-DaemonState {
    $state = @{
        connected  = $false
        lastUpdate = Get-Date -Format 'o'
        properties = @{}
        processId  = $PID
        daemon     = @{
            startTime = Get-Date -Format 'o'
            uptime    = 0
        }
    }
    return $state
}

function Save-DaemonState {
    param([hashtable]$State)
    
    try {
        $State.lastUpdate = Get-Date -Format 'o'
        $State.daemon.uptime = ((Get-Date) - [datetime]$State.daemon.startTime).TotalSeconds
        $State | ConvertTo-Json -Depth 10 | Set-Content -Path $daemonStateFile -Force
    }
    catch {
        Write-Log "Failed to save daemon state: $_" 'Error'
    }
}

function Load-DaemonState {
    if (Test-Path $daemonStateFile) {
        try {
            return Get-Content -Path $daemonStateFile | ConvertFrom-Json | ForEach-Object {
                # Convert PSCustomObject to hashtable
                $hash = @{}
                $_.PSObject.Properties | ForEach-Object { $hash[$_.Name] = $_.Value }
                $hash
            }
        }
        catch {
            Write-Log "Failed to load daemon state: $_" 'Error'
            return $null
        }
    }
    return $null
}

# ==================== Control Commands ====================
function Test-DaemonRunning {
    if (-not (Test-Path $daemonPidFile)) {
        return $false
    }
    
    try {
        $pid = [int](Get-Content $daemonPidFile)
        $process = Get-Process -Id $pid -ErrorAction SilentlyContinue
        return $null -ne $process
    }
    catch {
        return $false
    }
}

function Send-StopSignal {
    Write-Log "Sending stop signal to daemon..."
    
    # Create control file to signal daemon to stop
    Set-Content -Path $daemonControlFile -Value 'STOP' -Force
    
    # Wait for daemon to exit (max 5 seconds)
    $timeout = 5
    $elapsed = 0
    while ((Test-DaemonRunning) -and ($elapsed -lt $timeout)) {
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }
    
    if (Test-DaemonRunning) {
        Write-Log "Daemon did not respond to stop signal within $timeout seconds" 'Warning'
        # Forcefully kill if necessary
        try {
            $pid = [int](Get-Content $daemonPidFile)
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            Write-Log "Forcefully terminated daemon process $pid"
        }
        catch {
            Write-Log "Failed to forcefully terminate daemon: $_" 'Error'
        }
    }
    else {
        Write-Log "Daemon stopped successfully"
    }
    
    # Cleanup
    Remove-Item $daemonPidFile -ErrorAction SilentlyContinue
    Remove-Item $daemonControlFile -ErrorAction SilentlyContinue
}

function Show-DaemonStatus {
    if (Test-DaemonRunning) {
        $state = Load-DaemonState
        if ($state) {
            Write-Host "✓ Daemon is running (PID: $(Get-Content $daemonPidFile))"
            Write-Host "  Connected: $($state.connected)"
            Write-Host "  Last Update: $($state.lastUpdate)"
            Write-Host "  Property Count: $(($state.properties | Measure-Object).Count)"
            Write-Host "  Uptime: $([math]::Round($state.daemon.uptime)) seconds"
        }
        else {
            Write-Host "⚠ Daemon running but unable to read state"
        }
    }
    else {
        Write-Host "✗ Daemon is not running"
    }
}

# ==================== Connection Logic ====================
function Connect-ToPropertyServer {
    param(
        [string]$HostName,
        [int]$Port
    )
    
    try {
        Write-Log "Connecting to SimHub Property Server at $HostName`:$Port..."
        $socket = New-Object System.Net.Sockets.TcpClient($HostName, $Port)
        
        if (-not $socket.Connected) {
            throw "Failed to establish connection"
        }
        
        $stream = $socket.GetStream()
        Write-Log "Successfully connected to SimHub Property Server"
        
        return @{
            socket = $socket
            stream = $stream
            reader = New-Object System.IO.StreamReader($stream)
            writer = New-Object System.IO.StreamWriter($stream)
        }
    }
    catch {
        Write-Log "Connection failed: $_" 'Error'
        return $null
    }
}

function Close-Connection {
    param($ConnectionObject)
    
    if ($ConnectionObject) {
        try {
            if ($ConnectionObject.writer) {
                $ConnectionObject.writer.WriteLine('disconnect')
                $ConnectionObject.writer.Flush()
            }
        }
        catch {
            Write-Log "Error sending disconnect: $_" 'Warning'
        }
        
        try {
            if ($ConnectionObject.reader) { $ConnectionObject.reader.Dispose() }
            if ($ConnectionObject.writer) { $ConnectionObject.writer.Dispose() }
            if ($ConnectionObject.stream) { $ConnectionObject.stream.Dispose() }
            if ($ConnectionObject.socket) { $ConnectionObject.socket.Close() }
            Write-Log "Connection closed"
        }
        catch {
            Write-Log "Error closing connection: $_" 'Warning'
        }
    }
}

function Subscribe-ToProperties {
    param(
        $ConnectionObject,
        [string[]]$Properties,
        [hashtable]$DaemonState
    )
    
    try {
        Write-Log "Subscribing to $($Properties.Count) properties..."
        
        foreach ($prop in $Properties) {
            $propName = $prop.Trim()
            if ([string]::IsNullOrWhiteSpace($propName)) { continue }
            
            Write-Debug "Subscribing to: $propName"
            $ConnectionObject.writer.WriteLine("subscribe $propName")
        }
        
        $ConnectionObject.writer.Flush()
        Write-Log "Property subscriptions sent"
        
        Start-Sleep -Milliseconds 1000
        $initialUpdates = Read-PropertyUpdates -ConnectionObject $ConnectionObject -MaxUpdates 100 -TimeoutMs 2000
        
        if ($initialUpdates.Count -gt 0) {
            foreach ($key in $initialUpdates.Keys) {
                $DaemonState.properties[$key] = $initialUpdates[$key]
            }
            Write-Log "Captured $($initialUpdates.Count) initial property values"
        }
        
        return $true
    }
    catch {
        Write-Log "Failed to subscribe to properties: $_" 'Error'
        return $false
    }
}

function Read-PropertyUpdates {
    param(
        $ConnectionObject,
        [int]$MaxUpdates = 1000,  # Read up to N updates before returning
        [int]$TimeoutMs = 5000     # Max time to spend reading in milliseconds
    )
    
    $updates = @{}
    $updateCount = 0
    $startTime = Get-Date
    
    try {
        # Set a read timeout to avoid blocking indefinitely on ReadLine()
        $ConnectionObject.stream.ReadTimeout = 100  # milliseconds
        
        while ($updateCount -lt $MaxUpdates -and $ConnectionObject.stream.CanRead) {
            # Check if we've exceeded timeout
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalMilliseconds -gt $TimeoutMs) {
                Write-Debug "Read-PropertyUpdates timeout after $([math]::Round($elapsed.TotalMilliseconds))ms"
                break
            }
            
            try {
                if ($ConnectionObject.stream.DataAvailable) {
                    $line = $ConnectionObject.reader.ReadLine()
                    
                    if ($null -eq $line) {
                        # Connection closed by server
                        Write-Log "Connection closed by server" 'Warning'
                        break
                    }
                    
                    # Parse property update
                    # Format: Property <name> <type> <value>
                    if ($line -match '^Property\s+(?<key>\S+)\s+\S+\s+(?<val>.*)$') {
                        $key = $matches.key
                        $val = $matches.val.Trim()
                        
                        # Handle null values
                        if ($val -eq '(null)' -or [string]::IsNullOrEmpty($val)) {
                            $val = $null
                        }
                        
                        $updates[$key] = $val
                        $updateCount++
                    }
                    elseif ($line -match '^SimHub') {
                        # Skip header lines
                        continue
                    }
                }
                else {
                    # No data available, small sleep to prevent CPU spinning
                    Start-Sleep -Milliseconds 50
                }
            }
            catch [System.IO.IOException] {
                # Timeout on ReadLine occurred, that's okay
                Write-Debug "ReadLine timeout occurred"
                break
            }
        }
    }
    catch {
        Write-Log "Error reading property updates: $_" 'Error'
    }
    
    return $updates
}

# ==================== Main Daemon Loop ====================
function Start-Daemon {
    try {
        # Ensure data directory exists FIRST
        if (-not (Test-Path $DataPath)) {
            New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
        }
        
        Write-Log "Daemon starting..."
        
        # Load configuration
        if (-not (Test-Path $simhubConfigPath)) {
            Write-Log "Configuration file not found: $simhubConfigPath" 'Error'
            exit 1
        }
        
        $simhubConfig = Get-Content -Raw -Path $simhubConfigPath | ConvertFrom-Json
        $simhubHost = $simhubConfig.simhubHost
        $simhubPort = $simhubConfig.simhubPort
        
        if (-not (Test-Path $propsConfigPath)) {
            Write-Log "Properties configuration file not found: $propsConfigPath" 'Error'
            exit 1
        }
        
        $propsConfig = Get-Content -Raw -Path $propsConfigPath | ConvertFrom-Json
        $properties = $propsConfig.properties
        
        Write-Log "Configuration loaded: Host=$simhubHost Port=$simhubPort Properties=$($properties.Count) items"
        
        # Initialize state
        $daemonState = Initialize-DaemonState
        $daemonState.properties = @{}
        Save-DaemonState $daemonState
        Write-Log "State file initialized"
        
        # Write PID file for tracking
        Set-Content -Path $daemonPidFile -Value $PID -Force
        Write-Log "PID file written: $PID"
    
        # Main loop
        $reconnectDelay = 5  # seconds
        $connectionAttempts = 0
        $maxReconnectAttempts = 0  # Unlimited reconnection
    
        Write-Log "Entering main daemon loop..."
    
        while ($true) {
            # Check for stop signal
            if (Test-Path $daemonControlFile) {
                $signal = Get-Content $daemonControlFile
                if ($signal -eq 'STOP') {
                    Write-Log "Stop signal received"
                    break
                }
            }
        
            # Attempt connection
            $connection = Connect-ToPropertyServer -HostName $simhubHost -Port $simhubPort
        
            if ($null -eq $connection) {
                $connectionAttempts++
                Write-Log "Connection attempt $connectionAttempts failed, retrying in $reconnectDelay seconds..." 'Warning'
            
                Start-Sleep -Seconds $reconnectDelay
                continue
            }
        
            $connectionAttempts = 0
            $daemonState.connected = $true
        
            # Subscribe to properties
            if (-not (Subscribe-ToProperties -ConnectionObject $connection -Properties $properties -DaemonState $daemonState)) {
                Close-Connection $connection
                $daemonState.connected = $false
                Save-DaemonState $daemonState
            
                Start-Sleep -Seconds $reconnectDelay
                continue
            }
        
            # Mark as listening (even if no updates yet)
            $daemonState.connected = $true
            Save-DaemonState $daemonState
        
            # Main read loop - continuously listen for property updates
            Write-Log "Listening for property updates..."
            $readErrorCount = 0
        
            while ($true) {
                # Check for stop signal
                if (Test-Path $daemonControlFile) {
                    $signal = Get-Content $daemonControlFile
                    if ($signal -eq 'STOP') {
                        Write-Log "Stop signal received during read loop"
                        Close-Connection $connection
                        $daemonState.connected = $false
                        Save-DaemonState $daemonState
                        return
                    }
                }
            
                try {
                    # Read updates (non-blocking with timeout)
                    $updates = Read-PropertyUpdates -ConnectionObject $connection -MaxUpdates 50 -TimeoutMs 1000
                
                    if ($updates.Count -gt 0) {
                        # Merge updates into state
                        foreach ($key in $updates.Keys) {
                            $daemonState.properties[$key] = $updates[$key]
                        }
                    
                        # Save state periodically
                        Save-DaemonState $daemonState
                    
                        $readErrorCount = 0
                    }
                
                    # Small sleep to prevent CPU spinning
                    Start-Sleep -Milliseconds 100
                }
                catch {
                    $readErrorCount++
                    Write-Log "Error in read loop (attempt $readErrorCount): $_" 'Warning'
                
                    if ($readErrorCount -gt 5) {
                        Write-Log "Too many read errors, reconnecting..." 'Error'
                        break
                    }
                }
            }
        
            # Reconnection logic
            Close-Connection $connection
            $daemonState.connected = $false
            Save-DaemonState $daemonState
        
            Write-Log "Reconnecting in $reconnectDelay seconds..." 'Warning'
            Start-Sleep -Seconds $reconnectDelay
        }
    
        # Cleanup before exit
        Clean-DaemonResources
        Write-Log "Daemon exiting gracefully"
    }
    catch {
        Write-Log "Fatal error in Start-Daemon: $_" 'Error'
        Clean-DaemonResources
        exit 1
    }
}

function Clean-DaemonResources {
    try {
        Remove-Item $daemonPidFile -ErrorAction SilentlyContinue
        Remove-Item $daemonControlFile -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Error during cleanup: $_" 'Warning'
    }
}

# ==================== Command Routing ====================
try {
    Write-Log "=== Daemon Command: $Command ===" 'Info'
    
    switch ($Command) {
        'Start' {
            if (Test-DaemonRunning) {
                Write-Host "✓ Daemon is already running"
                exit 0
            }
            Start-Daemon
        }
        'Stop' {
            Send-StopSignal
        }
        'Status' {
            Show-DaemonStatus
        }
        default {
            Write-Host "Unknown command: $Command"
            exit 1
        }
    }
}
catch {
    Write-Log "Fatal error: $_" 'Error'
    Clean-DaemonResources
    exit 1
}

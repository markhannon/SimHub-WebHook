########################################################
# SimHub Property Server Continuous Connection Daemon
# Maintains persistent socket and streams property updates
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Start,
    [Parameter(Mandatory = $false)]
    [switch]$Stop,
    [Parameter(Mandatory = $false)]
    [switch]$Status,
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
$script:DaemonMutexName = $null
$script:DaemonMutex = $null
$script:HasDaemonMutex = $false

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
        $json = $State | ConvertTo-Json -Depth 10
        $tmpFile = "$daemonStateFile.tmp"

        [System.IO.File]::WriteAllText($tmpFile, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmpFile -Destination $daemonStateFile -Force
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

function Get-DaemonMutexName {
    $normalizedPath = [System.IO.Path]::GetFullPath($DataPath).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
    return "Global\SimHubPropertyDaemon_$hash"
}

function Acquire-DaemonMutex {
    try {
        $script:DaemonMutexName = Get-DaemonMutexName
        $createdNew = $false
        $script:DaemonMutex = New-Object System.Threading.Mutex($false, $script:DaemonMutexName, [ref]$createdNew)

        if (-not $script:DaemonMutex.WaitOne(0)) {
            $script:DaemonMutex.Dispose()
            $script:DaemonMutex = $null
            $script:HasDaemonMutex = $false
            return $false
        }

        $script:HasDaemonMutex = $true
        return $true
    }
    catch {
        Write-Log "Failed to acquire daemon mutex: $_" 'Error'
        return $false
    }
}

function Release-DaemonMutex {
    if (-not $script:HasDaemonMutex -or $null -eq $script:DaemonMutex) {
        return
    }

    try {
        $script:DaemonMutex.ReleaseMutex()
    }
    catch {
        Write-Log "Failed to release daemon mutex: $_" 'Warning'
    }
    finally {
        try { $script:DaemonMutex.Dispose() } catch {}
        $script:DaemonMutex = $null
        $script:HasDaemonMutex = $false
    }
}

# ==================== Control Commands ====================
function Get-ExpectedDaemonIdentity {
    return @{ 
        scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
        dataPath   = [System.IO.Path]::GetFullPath($DataPath)
    }
}

function Test-DaemonProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { return $false }

        $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
        if ($null -eq $procInfo -or [string]::IsNullOrWhiteSpace($procInfo.CommandLine)) {
            return $false
        }

        $identity = Get-ExpectedDaemonIdentity
        $escapedScript = [regex]::Escape($identity.scriptPath)
        $escapedData = [regex]::Escape($identity.dataPath)

        if ($procInfo.CommandLine -notmatch $escapedScript) { return $false }
        if ($procInfo.CommandLine -notmatch $escapedData) { return $false }

        return $true
    }
    catch {
        return $false
    }
}

function Test-DaemonRunning {
    if (-not (Test-Path $daemonPidFile)) {
        return $false
    }
    
    try {
        $daemonPid = [int](Get-Content $daemonPidFile)
        return (Test-DaemonProcessIdentity -ProcessId $daemonPid)
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
            $daemonPid = [int](Get-Content $daemonPidFile)
            Stop-Process -Id $daemonPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500

            if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
                & taskkill /PID $daemonPid /T /F | Out-Null
                Start-Sleep -Milliseconds 500
            }

            if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
                Write-Log "Failed to terminate daemon process $daemonPid" 'Error'
            }
            else {
                Write-Log "Forcefully terminated daemon process $daemonPid"
            }
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
            Write-Host "Daemon is running (PID: $(Get-Content $daemonPidFile))"
            Write-Host "  Connected: $($state.connected)"
            Write-Host "  Last Update: $($state.lastUpdate)"
            Write-Host "  Property Count: $(($state.properties | Measure-Object).Count)"
            Write-Host "  Uptime: $([math]::Round($state.daemon.uptime)) seconds"
        }
        else {
            Write-Host "WARNING: Daemon running but unable to read state"
        }
    }
    else {
        Write-Host "Daemon is not running"
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
        $stopRequested = $false
    
        Write-Log "Entering main daemon loop..."
    
        while (-not $stopRequested) {
            # Check for stop signal
            if (Test-Path $daemonControlFile) {
                $signal = Get-Content $daemonControlFile
                if ($signal -eq 'STOP') {
                    Write-Log "Stop signal received"
                    $stopRequested = $true
                    continue
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
        
            $lastHeartbeatSave = Get-Date

            while (-not $stopRequested) {
                # Check for stop signal
                if (Test-Path $daemonControlFile) {
                    $signal = Get-Content $daemonControlFile
                    if ($signal -eq 'STOP') {
                        Write-Log "Stop signal received during read loop"
                        Close-Connection $connection
                        $daemonState.connected = $false
                        Save-DaemonState $daemonState
                        $stopRequested = $true
                        break
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
                        $lastHeartbeatSave = Get-Date
                    
                        $readErrorCount = 0
                    }
                    elseif (((Get-Date) - $lastHeartbeatSave).TotalSeconds -ge 2) {
                        # Persist a heartbeat so readers can distinguish idle vs stale daemon.
                        Save-DaemonState $daemonState
                        $lastHeartbeatSave = Get-Date
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
        
            if ($stopRequested) {
                break
            }

            # Reconnection logic
            Close-Connection $connection
            $daemonState.connected = $false
            Save-DaemonState $daemonState
        
            Write-Log "Reconnecting in $reconnectDelay seconds..." 'Warning'
            Start-Sleep -Seconds $reconnectDelay
        }
    
        Write-Log "Daemon exiting gracefully"
    }
    catch {
        Write-Log "Fatal error in Start-Daemon: $_" 'Error'
        exit 1
    }
    finally {
        Clean-DaemonResources
    }
}

function Clean-DaemonResources {
    try {
        Remove-Item $daemonPidFile -ErrorAction SilentlyContinue
        Remove-Item $daemonControlFile -ErrorAction SilentlyContinue
        Release-DaemonMutex
    }
    catch {
        Write-Log "Error during cleanup: $_" 'Warning'
    }
}

# ==================== Command Routing ====================
try {
    # Determine which command to execute
    if (-not $Start -and -not $Stop -and -not $Status) {
        $Start = $true  # Default to Start
    }

    if ($Start) {
        $commandName = 'Start'
    }
    elseif ($Stop) {
        $commandName = 'Stop'
    }
    elseif ($Status) {
        $commandName = 'Status'
    }

    Write-Log "=== Daemon Command: $commandName ===" 'Info'

    if ($commandName -eq 'Start') {
        if (-not (Acquire-DaemonMutex)) {
            $mutexMessage = "DAEMON_MUTEX_CONFLICT: Another daemon instance is already running for data directory '$DataPath'."
            Write-Log $mutexMessage 'Error'
            Write-Error $mutexMessage
            exit 12
        }

        if (Test-DaemonRunning) {
            Write-Host "Daemon is already running"
            Release-DaemonMutex
            exit 0
        }

        Start-Daemon
    }
    elseif ($commandName -eq 'Stop') {
        Send-StopSignal
    }
    elseif ($commandName -eq 'Status') {
        Show-DaemonStatus
    }
    else {
        Write-Host "Unknown command: $commandName"
        exit 1
    }
}
catch {
    Write-Log "Fatal error: $_" 'Error'
    Clean-DaemonResources
    exit 1
}

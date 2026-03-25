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
    [switch]$Capture,
    [Parameter(Mandatory = $false)]
    [switch]$Replay,
    [Parameter(Mandatory = $false)]
    [string]$CaptureFile,
    [Parameter(Mandatory = $false)]
    [string]$ReplayFile,
    [Parameter(Mandatory = $false)]
    [double]$ReplaySpeed = 1.0,
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
$capturePath = Join-Path $DataPath 'captures'
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
            mode      = 'live'
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
            if ($state.daemon -and $state.daemon.mode) {
                Write-Host "  Mode: $($state.daemon.mode)"
            }
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

function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = $InputObject[$key]
        }
        return $result
    }

    $hash = @{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        $hash[[string]$prop.Name] = $prop.Value
    }
    return $hash
}

function Get-CaptureDefaultFile {
    if (-not (Test-Path $capturePath)) {
        New-Item -Path $capturePath -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path $capturePath ("session-capture-$timestamp.json")
}

function Resolve-ReplayFilePath {
    param([string]$CandidatePath)

    if (-not [string]::IsNullOrWhiteSpace($CandidatePath)) {
        if ([System.IO.Path]::IsPathRooted($CandidatePath)) {
            return $CandidatePath
        }

        return Join-Path $ScriptDir $CandidatePath
    }

    if (-not (Test-Path $capturePath)) {
        return $null
    }

    $latest = Get-ChildItem -Path $capturePath -Filter 'session-capture-*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

    if ($latest) {
        return $latest.FullName
    }

    return $null
}

function Get-ComparableValue {
    param($Value)

    if ($null -eq $Value) {
        return '<null>'
    }

    return [string]$Value
}

function Get-PropertyDelta {
    param(
        [hashtable]$Current,
        [hashtable]$Previous
    )

    $delta = @{}

    foreach ($key in $Current.Keys) {
        $curVal = $Current[$key]
        if (-not $Previous.ContainsKey($key)) {
            $delta[$key] = $curVal
            continue
        }

        $prevVal = $Previous[$key]
        if ((Get-ComparableValue $curVal) -ne (Get-ComparableValue $prevVal)) {
            $delta[$key] = $curVal
        }
    }

    return $delta
}

function Build-StatusLabel {
    param([hashtable]$Properties)

    $game = [string]$Properties['dcp.gd.GameName']
    if ([string]::IsNullOrWhiteSpace($game)) { $game = [string]$Properties['dcp.GameData.NewData.GameName'] }
    if ([string]::IsNullOrWhiteSpace($game)) { $game = 'n/a' }

    $track = [string]$Properties['dcp.gd.TrackName']
    if ([string]::IsNullOrWhiteSpace($track)) { $track = [string]$Properties['dcp.GameData.NewData.TrackName'] }
    if ([string]::IsNullOrWhiteSpace($track)) { $track = 'n/a' }

    $car = [string]$Properties['dcp.gd.CarModel']
    if ([string]::IsNullOrWhiteSpace($car)) { $car = [string]$Properties['dcp.GameData.NewData.CarModel'] }
    if ([string]::IsNullOrWhiteSpace($car)) { $car = 'n/a' }

    $lap = [string]$Properties['dcp.gd.CurrentLap']
    if ([string]::IsNullOrWhiteSpace($lap)) { $lap = [string]$Properties['dcp.GameData.NewData.Lap'] }
    if ([string]::IsNullOrWhiteSpace($lap)) { $lap = 'n/a' }

    return "Game: $game | Track: $track | Car: $car | Lap: $lap"
}

function Write-DaemonControlFiles {
    Set-Content -Path $daemonPidFile -Value $PID -Force
    Remove-Item $daemonControlFile -ErrorAction SilentlyContinue
}

function Get-ReplayClockProperty {
    param([hashtable]$Properties)

    $gameName = [string]$Properties['dcp.GameName']
    if ([string]::IsNullOrWhiteSpace($gameName)) { $gameName = [string]$Properties['dcp.gd.GameName'] }
    if ([string]::IsNullOrWhiteSpace($gameName)) { $gameName = [string]$Properties['dcp.GameData.NewData.GameName'] }

    if (-not [string]::IsNullOrWhiteSpace($gameName) -and ($gameName -like '*iRacing*')) {
        return 'DataCorePlugin.GameRawData.Telemetry.SessionTimeOfDay'
    }

    return 'DataCorePlugin.GameRawData.Graphics.clock'
}

function Get-ReplayClockSeconds {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.TimeSpan]) {
        return [double]$Value.TotalSeconds
    }

    if ($Value -is [DateTime]) {
        return [double]$Value.TimeOfDay.TotalSeconds
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $timeSpanValue = [System.TimeSpan]::Zero
    if ([System.TimeSpan]::TryParse($text, [ref]$timeSpanValue)) {
        return [double]$timeSpanValue.TotalSeconds
    }

    $dateTimeValue = [DateTime]::MinValue
    if ([DateTime]::TryParse($text, [ref]$dateTimeValue)) {
        return [double]$dateTimeValue.TimeOfDay.TotalSeconds
    }

    $numericValue = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$numericValue)) {
        return [double]$numericValue
    }

    if ([double]::TryParse($text, [ref]$numericValue)) {
        return [double]$numericValue
    }

    return $null
}

function Get-NullableIntValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $intValue = 0
    if ([int]::TryParse($text.Trim(), [ref]$intValue)) {
        return [int]$intValue
    }

    return $null
}

function Start-CaptureMode {
    $connection = $null
    try {
        if (-not (Test-Path $simhubConfigPath)) {
            throw "Configuration file not found: $simhubConfigPath"
        }

        if (-not (Test-Path $propsConfigPath)) {
            throw "Properties configuration file not found: $propsConfigPath"
        }

        $simhubConfig = Get-Content -Raw -Path $simhubConfigPath | ConvertFrom-Json
        $propsConfig = Get-Content -Raw -Path $propsConfigPath | ConvertFrom-Json
        $properties = @($propsConfig.properties)

        $captureOutputFile = if ([string]::IsNullOrWhiteSpace($CaptureFile)) {
            Get-CaptureDefaultFile
        }
        elseif ([System.IO.Path]::IsPathRooted($CaptureFile)) {
            $CaptureFile
        }
        else {
            Join-Path $ScriptDir $CaptureFile
        }

        $captureOutputDir = Split-Path -Parent $captureOutputFile
        if (-not (Test-Path $captureOutputDir)) {
            New-Item -Path $captureOutputDir -ItemType Directory -Force | Out-Null
        }

        Write-Host "Capture mode started"
        Write-Host "Capture file: $captureOutputFile"

        Write-DaemonControlFiles

        $connection = Connect-ToPropertyServer -HostName $simhubConfig.simhubHost -Port ([int]$simhubConfig.simhubPort)
        if ($null -eq $connection) {
            throw 'Unable to connect to SimHub Property Server for capture'
        }

        $daemonState = Initialize-DaemonState
        $daemonState.daemon.mode = 'capture'
        $daemonState.connected = $true
        Save-DaemonState $daemonState

        if (-not (Subscribe-ToProperties -ConnectionObject $connection -Properties $properties -DaemonState $daemonState)) {
            Close-Connection $connection
            throw 'Failed to subscribe to properties for capture mode'
        }

        $currentProps = ConvertTo-Hashtable $daemonState.properties
        $initialStateProps = @{}
        foreach ($key in $currentProps.Keys) {
            $initialStateProps[$key] = $currentProps[$key]
        }

        $lastSampledProps = @{}
        foreach ($key in $currentProps.Keys) {
            $lastSampledProps[$key] = $currentProps[$key]
        }

        $samples = @()
        $captureStart = Get-Date
        $nextSampleAt = $captureStart.AddSeconds(1)
        $sampleIndex = 0
        $changedTickCount = 0
        $totalChangedProperties = 0
        $perPropertyChangeCount = @{}
        $fullSnapshotPropertyCount = $initialStateProps.Count
        $selectedReplayClockProperty = Get-ReplayClockProperty -Properties $currentProps
        $captureStartReplayClockSeconds = Get-ReplayClockSeconds -Value $currentProps[$selectedReplayClockProperty]
        $previousReplayClockSeconds = $captureStartReplayClockSeconds
        $captureStartLap = Get-NullableIntValue $currentProps['dcp.gd.CurrentLap']
        $loopDetected = $false
        $loopSampleIndex = -1
        $propsAtLoopPoint = $null
        $loopDetectedAtLocal = $null
        $clockParseMissCount = 0

        while ($true) {
            if (Test-Path $daemonControlFile) {
                $signal = (Get-Content $daemonControlFile -ErrorAction SilentlyContinue)
                if ([string]::Equals(([string]$signal).Trim(), 'STOP', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Host 'Capture stop signal received'
                    break
                }
            }

            $updates = Read-PropertyUpdates -ConnectionObject $connection -MaxUpdates 200 -TimeoutMs 200
            if ($updates.Count -gt 0) {
                foreach ($k in $updates.Keys) {
                    $currentProps[$k] = $updates[$k]
                    $daemonState.properties[$k] = $updates[$k]
                }
            }

            $now = Get-Date
            if ($now -ge $nextSampleAt) {
                $selectedReplayClockProperty = Get-ReplayClockProperty -Properties $currentProps
                $currentReplayClockSeconds = Get-ReplayClockSeconds -Value $currentProps[$selectedReplayClockProperty]
                $currentLap = Get-NullableIntValue $currentProps['dcp.gd.CurrentLap']

                if ($null -ne $currentReplayClockSeconds) {
                    if ($null -eq $captureStartReplayClockSeconds) {
                        $captureStartReplayClockSeconds = $currentReplayClockSeconds
                    }

                    $clockParseMissCount = 0
                }
                else {
                    $clockParseMissCount++
                }

                if ($null -eq $captureStartLap -and $null -ne $currentLap) {
                    $captureStartLap = $currentLap
                }

                if (-not $loopDetected) {
                    $clockLoopDetected = ($null -ne $previousReplayClockSeconds) -and ($null -ne $currentReplayClockSeconds) -and ($currentReplayClockSeconds -lt $previousReplayClockSeconds)
                    $lapLoopDetected = ($null -ne $captureStartLap) -and ($null -ne $currentLap) -and ($currentLap -lt $captureStartLap)

                    if ($clockLoopDetected -or (($clockParseMissCount -ge 3) -and $lapLoopDetected)) {
                        $loopDetected = $true
                        $loopSampleIndex = $sampleIndex
                        $loopDetectedAtLocal = $now
                        $propsAtLoopPoint = @{}
                        foreach ($key in $currentProps.Keys) {
                            $propsAtLoopPoint[$key] = $currentProps[$key]
                        }

                        if ($clockLoopDetected) {
                            Write-Host "Replay loop-around detected at sample $sampleIndex using $selectedReplayClockProperty ($previousReplayClockSeconds -> $currentReplayClockSeconds)"
                        }
                        else {
                            Write-Host "Replay loop-around detected at sample $sampleIndex using lap fallback (CurrentLap: $currentLap, CaptureStartLap: $captureStartLap)"
                        }
                    }
                }
                elseif ($sampleIndex -gt $loopSampleIndex) {
                    $hasClockBoundary = ($null -ne $captureStartReplayClockSeconds) -and ($null -ne $currentReplayClockSeconds)
                    $clockAtOrPastStart = $hasClockBoundary -and ($currentReplayClockSeconds -ge ($captureStartReplayClockSeconds - 0.5))
                    $lapAtOrPastStart = ($null -ne $captureStartLap) -and ($null -ne $currentLap) -and ($currentLap -ge $captureStartLap)

                    if (($hasClockBoundary -and $clockAtOrPastStart -and $lapAtOrPastStart) -or ((-not $hasClockBoundary) -and $lapAtOrPastStart)) {
                        Write-Host "Capture reached replay start boundary at sample $sampleIndex; finalizing reordered capture"
                        break
                    }
                }

                if ($null -ne $currentReplayClockSeconds) {
                    $previousReplayClockSeconds = $currentReplayClockSeconds
                }

                $delta = Get-PropertyDelta -Current $currentProps -Previous $lastSampledProps
                $changedCount = $delta.Count
                if ($changedCount -gt 0) {
                    $changedTickCount++
                    $totalChangedProperties += $changedCount

                    foreach ($changedKey in $delta.Keys) {
                        if (-not $perPropertyChangeCount.ContainsKey($changedKey)) {
                            $perPropertyChangeCount[$changedKey] = 0
                        }
                        $perPropertyChangeCount[$changedKey] = [int]$perPropertyChangeCount[$changedKey] + 1
                    }

                    $samples += [PSCustomObject]@{
                        sampleIndex    = $sampleIndex
                        timestamp      = $now.ToString('o')
                        elapsedSeconds = [math]::Round(($now - $captureStart).TotalSeconds, 3)
                        propertyDeltas = $delta
                    }
                }

                foreach ($k in $currentProps.Keys) {
                    $lastSampledProps[$k] = $currentProps[$k]
                }

                $statusLabel = Build-StatusLabel -Properties $currentProps
                Write-Host "$(Get-Date -Format 'HH:mm:ss') [CAPTURE] $statusLabel | Events: $changedCount/$totalChangedProperties | Samples: $sampleIndex"

                $sampleIndex++
                $nextSampleAt = $nextSampleAt.AddSeconds(1)
                $daemonState.connected = $true
                Save-DaemonState $daemonState
            }
        }

        $captureEnd = Get-Date
        $durationSeconds = [math]::Round(($captureEnd - $captureStart).TotalSeconds, 3)
        $topChangedProperties = @()
        foreach ($entry in ($perPropertyChangeCount.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) {
            $topChangedProperties += [PSCustomObject]@{
                property = [string]$entry.Key
                changes  = [int]$entry.Value
            }
        }

        $minimumSnapshotProps = if ($fullSnapshotPropertyCount -gt 0) { $fullSnapshotPropertyCount } else { 1 }
        $fullSnapshotEstimate = $sampleIndex * $minimumSnapshotProps
        $compressionRatio = if ($fullSnapshotEstimate -le 0) { 0 } else { [math]::Round(($totalChangedProperties / $fullSnapshotEstimate), 4) }

        $orderedSamples = @($samples)
        $reorderedFromLoop = $false

        if ($loopDetected -and $loopSampleIndex -ge 0 -and $orderedSamples.Count -gt 0) {
            $samplesBeforeLoop = @($orderedSamples | Where-Object { [int]$_.sampleIndex -lt $loopSampleIndex })
            $samplesAfterLoop = @($orderedSamples | Where-Object { [int]$_.sampleIndex -ge $loopSampleIndex })

            if ($samplesAfterLoop.Count -gt 0) {
                $orderedSamples = @($samplesAfterLoop + $samplesBeforeLoop)
                for ($i = 0; $i -lt $orderedSamples.Count; $i++) {
                    $orderedSamples[$i].sampleIndex = $i
                    $orderedSamples[$i].elapsedSeconds = $i
                }
                $reorderedFromLoop = $true
            }

            if ($propsAtLoopPoint -and $propsAtLoopPoint.Count -gt 0) {
                $initialStateProps = @{}
                foreach ($key in $propsAtLoopPoint.Keys) {
                    $initialStateProps[$key] = $propsAtLoopPoint[$key]
                }
            }
        }

        $initialStateTimestamp = if ($loopDetectedAtLocal) { $loopDetectedAtLocal.ToString('o') } else { $captureStart.ToString('o') }

        $captureDocument = [PSCustomObject]@{
            metadata     = [PSCustomObject]@{
                captureVersion         = '1.0'
                capturedAt             = $captureStart.ToString('o')
                completedAt            = $captureEnd.ToString('o')
                durationSeconds        = $durationSeconds
                collectionHzFrequency  = 1
                pollingIntervalSeconds = 1
                simhubHost             = [string]$simhubConfig.simhubHost
                simhubPort             = [int]$simhubConfig.simhubPort
                dataDir                = $DataPath
                replayClockProperty    = $selectedReplayClockProperty
                loopDetected           = $loopDetected
                loopSampleIndex        = $loopSampleIndex
                reorderedFromLoop      = $reorderedFromLoop
            }
            initialState = [PSCustomObject]@{
                timestamp  = $initialStateTimestamp
                properties = $initialStateProps
            }
            samples      = $orderedSamples
            summary      = [PSCustomObject]@{
                totalTicks             = $sampleIndex
                ticksWithChanges       = $changedTickCount
                totalChangedProperties = $totalChangedProperties
                fullSnapshotEstimate   = $fullSnapshotEstimate
                compressionRatio       = $compressionRatio
                topChangedProperties   = $topChangedProperties
            }
        }

        $captureJson = $captureDocument | ConvertTo-Json -Depth 20
        Set-Content -Path $captureOutputFile -Value $captureJson -Encoding UTF8

        Write-Host ''
        Write-Host 'Capture summary:' -ForegroundColor Cyan
        Write-Host "  File: $captureOutputFile"
        Write-Host "  Duration: $durationSeconds sec"
        Write-Host "  Total ticks: $sampleIndex"
        Write-Host "  Ticks with changes: $changedTickCount"
        Write-Host "  Changed properties: $totalChangedProperties"
        Write-Host "  Compression ratio (lower is better): $compressionRatio"

    }
    catch {
        Write-Error "Capture mode failed: $($_.Exception.Message)"
        Write-Log "Capture mode failed: $_" 'Error'
        throw
    }
    finally {
        if ($connection) {
            Close-Connection $connection
        }
        Remove-Item $daemonPidFile -ErrorAction SilentlyContinue
        Remove-Item $daemonControlFile -ErrorAction SilentlyContinue
        Release-DaemonMutex
    }
}

function Start-ReplayMode {
    try {
        if ($ReplaySpeed -le 0) {
            throw 'ReplaySpeed must be greater than zero.'
        }

        $resolvedReplayFile = Resolve-ReplayFilePath -CandidatePath $ReplayFile
        if ([string]::IsNullOrWhiteSpace($resolvedReplayFile) -or -not (Test-Path $resolvedReplayFile)) {
            throw 'Replay file not found. Provide -ReplayFile or create a capture first.'
        }

        $capture = Get-Content -Raw -Path $resolvedReplayFile | ConvertFrom-Json
        if (-not $capture -or -not $capture.initialState -or -not $capture.initialState.properties) {
            throw "Replay file '$resolvedReplayFile' is missing initialState.properties"
        }

        $samples = @($capture.samples)
        $currentProps = ConvertTo-Hashtable $capture.initialState.properties

        Write-Host "Replay mode started"
        Write-Host "Replay file: $resolvedReplayFile"
        Write-Host "Replay speed: $ReplaySpeed x"

        Write-DaemonControlFiles

        $daemonState = Initialize-DaemonState
        $daemonState.daemon.mode = 'replay'
        $daemonState.connected = $true
        $daemonState.properties = $currentProps
        Save-DaemonState $daemonState

        $totalSamples = $samples.Count
        $sleepMs = [int][math]::Round(1000.0 / $ReplaySpeed)
        if ($sleepMs -lt 1) { $sleepMs = 1 }
        $replayStart = Get-Date

        for ($i = 0; $i -lt $totalSamples; $i++) {
            if (Test-Path $daemonControlFile) {
                $signal = (Get-Content $daemonControlFile -ErrorAction SilentlyContinue)
                if ([string]::Equals(([string]$signal).Trim(), 'STOP', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Host 'Replay stop signal received'
                    break
                }
            }

            $sample = $samples[$i]
            $deltaHash = ConvertTo-Hashtable $sample.propertyDeltas
            foreach ($k in $deltaHash.Keys) {
                $currentProps[$k] = $deltaHash[$k]
            }

            $daemonState.connected = $true
            $daemonState.properties = $currentProps
            Save-DaemonState $daemonState

            $statusLabel = Build-StatusLabel -Properties $currentProps
            Write-Host "$(Get-Date -Format 'HH:mm:ss') [REPLAY] Sample $($i + 1)/$totalSamples | $statusLabel"

            Start-Sleep -Milliseconds $sleepMs
        }

        $replayDuration = [math]::Round(((Get-Date) - $replayStart).TotalSeconds, 3)
        Write-Host ''
        Write-Host 'Replay summary:' -ForegroundColor Cyan
        Write-Host "  Source: $resolvedReplayFile"
        Write-Host "  Samples emitted: $totalSamples"
        Write-Host "  Replay duration: $replayDuration sec"
        Write-Host "  Replay speed: $ReplaySpeed x"

        $daemonState.connected = $false
        Save-DaemonState $daemonState
    }
    catch {
        Write-Log "Replay mode failed: $_" 'Error'
        throw
    }
    finally {
        Remove-Item $daemonPidFile -ErrorAction SilentlyContinue
        Remove-Item $daemonControlFile -ErrorAction SilentlyContinue
        Release-DaemonMutex
    }
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
    $requestedCommands = @()
    if ($Start) { $requestedCommands += 'Start' }
    if ($Stop) { $requestedCommands += 'Stop' }
    if ($Status) { $requestedCommands += 'Status' }
    if ($Capture) { $requestedCommands += 'Capture' }
    if ($Replay) { $requestedCommands += 'Replay' }

    if ($requestedCommands.Count -eq 0) {
        $Start = $true  # Default to Start
        $requestedCommands = @('Start')
    }

    if ($requestedCommands.Count -gt 1) {
        throw "Only one command can be specified at a time. Received: $($requestedCommands -join ', ')"
    }

    if ($Capture -and -not [string]::IsNullOrWhiteSpace($ReplayFile)) {
        throw '-ReplayFile cannot be used with -Capture.'
    }

    if ($Replay -and -not [string]::IsNullOrWhiteSpace($CaptureFile)) {
        throw '-CaptureFile cannot be used with -Replay.'
    }

    if (-not $Replay -and $ReplaySpeed -ne 1.0) {
        throw '-ReplaySpeed can only be used with -Replay.'
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
    elseif ($Capture) {
        $commandName = 'Capture'
    }
    elseif ($Replay) {
        $commandName = 'Replay'
    }

    Write-Log "=== Daemon Command: $commandName ===" 'Info'

    if ($commandName -eq 'Start' -or $commandName -eq 'Capture' -or $commandName -eq 'Replay') {
        if (-not (Acquire-DaemonMutex)) {
            $mutexMessage = "DAEMON_MUTEX_CONFLICT: Another daemon instance is already running for data directory '$DataPath'."
            Write-Log $mutexMessage 'Error'
            Write-Error $mutexMessage
            exit 12
        }
    }

    if ($commandName -eq 'Start') {

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
    elseif ($commandName -eq 'Capture') {
        if (Test-DaemonRunning) {
            Write-Error "A daemon process is already running for data directory '$DataPath'. Stop it before capture mode."
            Release-DaemonMutex
            exit 1
        }
        Start-CaptureMode
    }
    elseif ($commandName -eq 'Replay') {
        if (Test-DaemonRunning) {
            Write-Error "A daemon process is already running for data directory '$DataPath'. Stop it before replay mode."
            Release-DaemonMutex
            exit 1
        }
        Start-ReplayMode
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

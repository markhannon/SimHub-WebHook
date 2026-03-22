########################################################
# Primary SimHub Data Collection Service
# 
# Continuously collects telemetry from SimHub via daemon
# - Starts/manages PropertyServer daemon automatically
# - Runs in long-running mode (continuous collection)
# - Triggers CSV updates on session/lap changes
# Supports -Start (initialize), -Stop (cleanup), and -Reset (force stop + wipe) flags
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Start,
    [Parameter(Mandatory = $false)]
    [switch]$Stop,
    [Parameter(Mandatory = $false)]
    [switch]$Reset,
    [Parameter(Mandatory = $false)]
    [int]$UpdateInterval = 1,  # Seconds between daemon state checks
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'data'  # Directory for CSV and daemon files
)

$ScriptDir = $PSScriptRoot
$DataPath = Join-Path $ScriptDir $DataDir

# Ensure data directory exists
if (-not (Test-Path $DataPath)) {
    New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
}

$daemonStateFile = Join-Path $DataPath '_daemon_state.json'
$daemonScriptFile = Join-Path $ScriptDir 'SimHub-PropertyServer-Daemon.ps1'
$SessionCsvPath = Join-Path $DataPath "session.csv"
$LapsCsvPath = Join-Path $DataPath "laps.csv"
$statePath = Join-Path $DataPath "_lapstate.json"
$script:DaemonStartedByCollector = $false
$script:CollectorMutex = $null
$script:HasCollectorMutex = $false

# ==================== Helper Functions ====================

function Parse-TimeSpanSafe($val) {
    try { [timespan]::Parse($val) } catch { $null }
}

function Get-OrDefault($value, $defaultValue) {
    if ($null -eq $value -or ([string]::IsNullOrWhiteSpace([string]$value))) {
        return $defaultValue
    }
    return $value
}

function Get-AvgTyreWear($cleaned) {
    $tyres = @('TyreWearFrontLeft', 'TyreWearFrontRight', 'TyreWearRearLeft', 'TyreWearRearRight')
    $vals = $tyres | ForEach-Object { [double](Get-OrDefault $cleaned[$_] 0) }
    if ($vals.Count -eq 0) { return 0 }
    [math]::Round(($vals | Measure-Object -Average).Average, 3)
}

# Helper function to convert PSObject to hashtable
function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }

    $hashtable = @{}
    $InputObject.PSObject.Properties | ForEach-Object {
        $hashtable[$_.Name] = $_.Value
    }
    return $hashtable
}

# ==================== Collector Single-Instance Mutex ====================

function Get-CollectorMutexName {
    $normalizedPath = [System.IO.Path]::GetFullPath($DataPath).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedPath)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hash = [System.Convert]::ToHexString($hashBytes)
    return "Global\SimHubCollector_$hash"
}

function Acquire-CollectorMutex {
    $mutexName = Get-CollectorMutexName
    $script:CollectorMutex = [System.Threading.Mutex]::new($false, $mutexName)
    $acquired = $script:CollectorMutex.WaitOne(0)
    if ($acquired) {
        $script:HasCollectorMutex = $true
        return $true
    }
    $script:CollectorMutex.Dispose()
    $script:CollectorMutex = $null
    return $false
}

function Release-CollectorMutex {
    if ($script:HasCollectorMutex -and $null -ne $script:CollectorMutex) {
        try { $script:CollectorMutex.ReleaseMutex() } catch {}
        $script:CollectorMutex.Dispose()
        $script:CollectorMutex = $null
        $script:HasCollectorMutex = $false
    }
}

# ==================== Exclusive File Locking ====================

function Write-CsvExclusive {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject,
        [string]$Path,
        [int]$RetryCount = 3,
        [int]$RetryDelayMs = 50
    )

    begin {
        $buffer = @()
    }

    process {
        if ($null -ne $InputObject) {
            $buffer += $InputObject
        }
    }

    end {
        if ($buffer.Count -eq 0) {
            return $true
        }

        $attempt = 0
        while ($attempt -lt $RetryCount) {
            try {
                $buffer | Export-Csv -Path $Path -NoTypeInformation -Force
                return $true
            }
            catch {
                $attempt++
                if ($attempt -lt $RetryCount) {
                    Start-Sleep -Milliseconds $RetryDelayMs
                }
            }
        }

        Write-Error "Failed to write CSV to $Path after $RetryCount attempts"
        return $false
    }
}

function Write-JsonExclusive {
    param(
        [string]$Json,
        [string]$Path,
        [int]$RetryCount = 3,
        [int]$RetryDelayMs = 50
    )

    $attempt = 0
    while ($attempt -lt $RetryCount) {
        try {
            [System.IO.File]::WriteAllText($Path, $Json, [System.Text.Encoding]::UTF8)
            return
        }
        catch {
            $attempt++
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Milliseconds $RetryDelayMs
            }
            else {
                Write-Warning "Failed to write JSON to $Path after $RetryCount attempts: $_"
            }
        }
    }
}

function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }

    $hashtable = @{}
    $InputObject.PSObject.Properties | ForEach-Object {
        $hashtable[$_.Name] = $_.Value
    }
    return $hashtable
}

# ==================== Daemon Management ====================

function Get-ExpectedDaemonIdentity {
    return @{ 
        scriptPath = [System.IO.Path]::GetFullPath($daemonScriptFile)
        dataPath = [System.IO.Path]::GetFullPath($DataPath)
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

function Get-DaemonStatus {
    if (-not (Test-Path $daemonStateFile)) {
        return @{ connected = $false; running = $false }
    }
    
    try {
        $state = Get-Content -Raw -Path $daemonStateFile | ConvertFrom-Json

        $isRunning = $false
        if ($state.processId) {
            $isRunning = Test-DaemonProcessIdentity -ProcessId ([int]$state.processId)
        }

        return @{ 
            connected = $state.connected
            running   = $isRunning
            processId = $state.processId
        }
    }
    catch {
        return @{ connected = $false; running = $false }
    }
}

function Start-PropertyDaemon {
    $status = Get-DaemonStatus
    
    if ($status.running) {
        $script:DaemonStartedByCollector = $false
        Write-Host "✓ Daemon already running (PID: $($status.processId))"
        if ($status.connected) {
            Write-Host "✓ Connected to PropertyServer"
        }
        else {
            Write-Host "⚠ Daemon running but waiting for PropertyServer connection..."
        }
        return $true
    }
    
    if (-not (Test-Path $daemonScriptFile)) {
        Write-Error "Daemon script not found: $daemonScriptFile"
        return $false
    }
    
    Write-Host "Starting PropertyServer daemon..."
    try {
        $absDaemonScript = (Resolve-Path $daemonScriptFile).Path
        $absDataPath = $DataPath
        $daemonStdOutFile = Join-Path $DataPath '_daemon_stdout.log'
        $daemonStdErrFile = Join-Path $DataPath '_daemon_stderr.log'
        $mutexErrorToken = 'DAEMON_MUTEX_CONFLICT'
        $daemonArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$absDaemonScript`" -Command Start -DataDir `"$absDataPath`""

        Remove-Item $daemonStdOutFile -ErrorAction SilentlyContinue
        Remove-Item $daemonStdErrFile -ErrorAction SilentlyContinue

        $process = Start-Process -FilePath 'pwsh' `
            -ArgumentList $daemonArgs `
            -WorkingDirectory $ScriptDir `
            -RedirectStandardOutput $daemonStdOutFile `
            -RedirectStandardError $daemonStdErrFile `
            -PassThru

        Write-Host "  Daemon process launched (PID: $($process.Id))"

        # Wait for daemon to write its state file
        $maxWaitForStart = 20
        $waited = 0
        $daemonRunning = $false

        while ($waited -lt $maxWaitForStart) {
            Start-Sleep -Seconds 1
            $waited++

            if ($process.HasExited) {
                $stderrText = ''
                if (Test-Path $daemonStdErrFile) {
                    $stderrText = Get-Content -Raw -Path $daemonStdErrFile -ErrorAction SilentlyContinue
                }

                if ($stderrText -match $mutexErrorToken) {
                    Write-Error "Daemon single-instance lock prevented startup for data directory '$absDataPath'."
                    Write-Error "Stop the existing daemon first or use a different -DataDir."
                    Write-Error "Daemon stderr:"; Get-Content $daemonStdErrFile | ForEach-Object { Write-Error "  $_" }
                }
                else {
                    Write-Error "Daemon process exited early (ExitCode: $($process.ExitCode))."
                    if ($stderrText) {
                        Write-Error "Daemon stderr:"; Get-Content $daemonStdErrFile | ForEach-Object { Write-Error "  $_" }
                    }
                }

                return $false
            }

            if (Test-Path $daemonStateFile) {
                $status = Get-DaemonStatus
                if ($status.running) {
                    $daemonRunning = $true
                    break
                }
            }

            if ($waited % 5 -eq 0) {
                Write-Host "  ... waiting for daemon initialization ($waited/$maxWaitForStart seconds)"
            }
        }

        if (-not $daemonRunning) {
            $stderrText = if (Test-Path $daemonStdErrFile) { Get-Content -Raw -Path $daemonStdErrFile -ErrorAction SilentlyContinue } else { '' }

            if ($stderrText -match $mutexErrorToken) {
                Write-Error "Daemon single-instance lock prevented startup for data directory '$absDataPath'."
                Write-Error "Stop the existing daemon first or use a different -DataDir."
            }

            Write-Error "Daemon failed to initialize within $maxWaitForStart seconds"
            $logPath = Join-Path $DataPath '_daemon.log'
            if (Test-Path $logPath) {
                Write-Error "Daemon log:"; Get-Content $logPath | ForEach-Object { Write-Error "  $_" }
            }
            if (Test-Path $daemonStdErrFile) {
                Write-Error "Daemon stderr:"; Get-Content $daemonStdErrFile | ForEach-Object { Write-Error "  $_" }
            }
            return $false
        }

        $actualStatus = Get-DaemonStatus
        Write-Host "✓ Daemon initialized (PID: $($actualStatus.processId))"
        $script:DaemonStartedByCollector = $true

        # Wait for PropertyServer connection
        Write-Host "Waiting for PropertyServer connection..."
        $maxWaitForConnection = 30
        $connectionWait = 0

        while ($connectionWait -lt $maxWaitForConnection) {
            Start-Sleep -Seconds 1
            $connectionWait++

            $status = Get-DaemonStatus
            if ($status.connected) {
                Write-Host "✓ Connected to PropertyServer"
                return $true
            }

            if ($connectionWait % 5 -eq 0) {
                Write-Host "  ... still waiting for PropertyServer ($connectionWait/$maxWaitForConnection seconds)"
            }
        }

        Write-Host "⚠ PropertyServer not responding (daemon will retry in background)"
        Write-Host "  Make sure SimHub is running and streaming on 127.0.0.1:18082"
        return $true
    }
    catch {
        Write-Error "Failed to start daemon: $_"
        return $false
    }
}

function Stop-CollectorDaemon {
    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    $targetPid = $null

    if (Test-Path $pidFile) {
        $pidText = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($pidText -and ($pidText -as [int])) {
            $candidatePid = [int]$pidText
            if (Test-DaemonProcessIdentity -ProcessId $candidatePid) {
                $targetPid = $candidatePid
            }
        }
    }

    if (-not $targetPid) {
        $status = Get-DaemonStatus
        if ($status.processId -and ($status.processId -as [int])) {
            $candidatePid = [int]$status.processId
            if (Test-DaemonProcessIdentity -ProcessId $candidatePid) {
                $targetPid = $candidatePid
            }
        }
    }

    if (-not $targetPid) {
        return $true
    }

    # Ask daemon to stop gracefully first.
    $daemonControlFile = Join-Path $DataPath '_daemon_control.txt'
    Set-Content -Path $daemonControlFile -Value 'STOP' -ErrorAction SilentlyContinue

    $waitedMs = 0
    while ($waitedMs -lt 5000) {
        Start-Sleep -Milliseconds 200
        $waitedMs += 200
        if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
            Remove-Item $pidFile -ErrorAction SilentlyContinue
            return $true
        }
    }

    Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
        & taskkill /PID $targetPid /T /F | Out-Null
        Start-Sleep -Milliseconds 500
    }

    $stillRunning = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $stillRunning) {
        Remove-Item $pidFile -ErrorAction SilentlyContinue
        return $true
    }

    return $false
}

# ==================== Session/Lap State Retrieval ====================

function Get-DaemonProperties {
    if (-not (Test-Path $daemonStateFile)) {
        return $null
    }

    try {
        $state = Get-Content -Raw -Path $daemonStateFile | ConvertFrom-Json

        # Ignore stale daemon state to avoid persisting duplicate rows when daemon is dead.
        if ($state.processId) {
            if (-not (Test-DaemonProcessIdentity -ProcessId ([int]$state.processId))) {
                return $null
            }
        }

        if ($state.lastUpdate) {
            $lastUpdate = [datetime]$state.lastUpdate
            if (((Get-Date) - $lastUpdate).TotalSeconds -gt 10) {
                return $null
            }
        }
        else {
            return $null
        }
        
        # Convert daemon properties to hashtable
        $propValues = @{}
        if ($state.properties) {
            $state.properties.PSObject.Properties | ForEach-Object {
                $propValues[$_.Name] = $_.Value
            }
        }

        return $propValues
    }
    catch {
        return $null
    }
}

function Test-SessionChanged {
    param(
        [hashtable]$CurrentProps,
        [string]$CsvPath
    )
    
    # If CSV doesn't exist yet, this is the first entry
    if (-not (Test-Path $CsvPath)) {
        return $true
    }
    
    # Get current session and lap
    $currentSession = Get-OrDefault $CurrentProps['dcp.gd.SessionTypeName'] $CurrentProps['SessionTypeName']
    $currentLapRaw = Get-OrDefault $CurrentProps['dcp.gd.CurrentLap'] $CurrentProps['CurrentLap']
    $currentLap = [int](Get-OrDefault $currentLapRaw 0)
    
    if ([string]::IsNullOrWhiteSpace([string]$currentSession)) {
        return $false
    }
    
    # Read last row from CSV
    try {
        $csv = Import-Csv $CsvPath -ErrorAction SilentlyContinue
        if ($null -eq $csv -or $csv.Count -eq 0) {
            return $true
        }
        
        # Get the last row
        $lastRow = if ($csv -is [array]) { $csv[-1] } else { $csv }
        
        # Compare session name and lap number
        $lastSession = $lastRow.SessionName
        $lastLap = [int](Get-OrDefault $lastRow.LapNumber 0)
        
        # Write entry if session changed or lap changed
        if ($currentSession -ne $lastSession -or $currentLap -ne $lastLap) {
            return $true
        }
        
        return $false
    }
    catch {
        # If we can't read CSV, assume it's a new entry
        return $true
    }
}

# ==================== CSV Persistence ====================

function Write-DataToCsv {
    param(
        [hashtable]$Properties,
        [hashtable]$PreviousState
    )
    
    # Clean property keys
    $cleaned = @{}
    foreach ($k in $Properties.Keys) {
        $newKey = $k -replace '^(dcp\.gd\.|dcp\.|DataCorePlugin\.Computed\.)', ''
        $cleaned[$newKey] = $Properties[$k]
    }

    # --- Session CSV ---
    $sessionObj = [PSCustomObject]@{
        Timestamp          = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        GameName           = $cleaned.GameName
        Driver             = $cleaned.PlayerName
        Car                = $cleaned.CarModel
        CarClass           = $cleaned.CarClass
        Track              = $cleaned.TrackName
        SessionType        = $cleaned.SessionTypeName
        Position           = $cleaned.Position
        CurrentLap         = $cleaned.CurrentLap
        CompletedLaps      = $cleaned.CompletedLaps
        TotalLaps          = $cleaned.TotalLaps
        SessionTimeLeft    = $cleaned.SessionTimeLeft
        SessionBestLapTime = $cleaned.BestLapTime
        LastLap            = $cleaned.LastLapTime
        CurrentFuel        = $cleaned.Fuel
        FuelUnit           = $cleaned.FuelUnit
        Fuel_LitersPerLap  = $cleaned.Fuel_LitersPerLap
        Fuel_RemainingLaps = $cleaned.Fuel_RemainingLaps
        Fuel_RemainingTime = $cleaned.Fuel_RemainingTime
    }

    # Append or create session CSV
    if (-not (Test-Path $SessionCsvPath)) {
        $sessionObj | Write-CsvExclusive -Path $SessionCsvPath | Out-Null
    }
    else {
        $existing = @(Import-Csv $SessionCsvPath)
        $existing += $sessionObj
        $existing | Write-CsvExclusive -Path $SessionCsvPath | Out-Null
    }

    # --- Lap CSV ---
    $lapNumber = [int](Get-OrDefault $cleaned.CurrentLap ($PreviousState.LapCount + 1))
    $position = $cleaned.Position
    $lastLapTime = $cleaned.LastLapTime
    $bestLapTime = $cleaned.BestLapTime
    $fuel = [double](Get-OrDefault $cleaned.Fuel 0)

    $tyreWear = Get-AvgTyreWear $cleaned
    $tyreWearFL = [double](Get-OrDefault $cleaned.TyreWearFrontLeft 0)
    $tyreWearFR = [double](Get-OrDefault $cleaned.TyreWearFrontRight 0)
    $tyreWearRL = [double](Get-OrDefault $cleaned.TyreWearRearLeft 0)
    $tyreWearRR = [double](Get-OrDefault $cleaned.TyreWearRearRight 0)

    # Calculate deltas
    $bestLapTS = Parse-TimeSpanSafe $bestLapTime
    $lastLapTS = Parse-TimeSpanSafe $lastLapTime
    $deltaToSessionBestLapTime = if ($bestLapTS -and $lastLapTS) { [math]::Round(($lastLapTS - $bestLapTS).TotalSeconds, 3) } else { 0 }
    $deltaFuelUsage = if ($PreviousState.PrevFuel) { [math]::Round([double]$PreviousState.PrevFuel - $fuel, 3) } else { 0 }

    $lapObj = [PSCustomObject]@{
        Timestamp                 = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        GameName                  = $cleaned.GameName
        Car                       = $cleaned.CarModel
        CarClass                  = $cleaned.CarClass
        Track                     = $cleaned.TrackName
        SessionName               = $cleaned.SessionTypeName
        LapNumber                 = $lapNumber
        Position                  = $position
        CompletedLaps             = $cleaned.CompletedLaps
        TotalLaps                 = $cleaned.TotalLaps
        SessionTimeLeft           = $cleaned.SessionTimeLeft
        LastLapTime               = $lastLapTime
        BestLapTime               = $bestLapTime
        Fuel                      = $fuel
        TyreWear                  = $tyreWear
        TyreWearFrontLeft         = $tyreWearFL
        TyreWearFrontRight        = $tyreWearFR
        TyreWearRearLeft          = $tyreWearRL
        TyreWearRearRight         = $tyreWearRR
        deltaToSessionBestLapTime = $deltaToSessionBestLapTime
        deltaFuelUsage            = $deltaFuelUsage
        Fuel_LitersPerLap         = $cleaned.Fuel_LitersPerLap
        Fuel_LastLapConsumption   = $cleaned.Fuel_LastLapConsumption
        Fuel_RemainingLaps        = $cleaned.Fuel_RemainingLaps
        Fuel_RemainingTime        = $cleaned.Fuel_RemainingTime
    }

    # Upsert lap CSV (update existing lap or add new)
    if (-not (Test-Path $LapsCsvPath)) {
        $lapObj | Write-CsvExclusive -Path $LapsCsvPath | Out-Null
        Write-Debug "Upsert: Created new CSV with $($cleaned.SessionTypeName) Lap $lapNumber"
    }
    else {
        $existing = @(Import-Csv $LapsCsvPath)
        $existingCount = $existing.Count
        
        # Normalize current session name for comparison
        $currentSession = if ([string]::IsNullOrWhiteSpace($cleaned.SessionTypeName)) { "" } else { $cleaned.SessionTypeName.Trim() }
        $currentLapNum = [int]$lapNumber
        
        Write-Debug "Upsert: Looking for match - $currentSession / Lap $currentLapNum in $existingCount existing rows"
        
        # Build new array, updating duplicate or appending new
        $foundMatch = $false
        $newExisting = @()
        
        foreach ($existingLap in $existing) {
            # Normalize existing session name (handle null, whitespace, type conversion)
            [string]$existingSession = if ([string]::IsNullOrWhiteSpace($existingLap.SessionName)) { "" } else { $existingLap.SessionName.Trim() }
            [int]$existingLapNum = 0
            
            # Try to parse lap number
            if (-not [string]::IsNullOrWhiteSpace($existingLap.LapNumber)) {
                [int]::TryParse($existingLap.LapNumber.Trim(), [ref]$existingLapNum) | Out-Null
            }
            
            # Check composite key: SessionName + LapNumber
            if ($existingSession -eq $currentSession -and $existingLapNum -eq $currentLapNum) {
                # This is a duplicate - replace with updated lap
                Write-Debug "Upsert: ✓ Found and updating: $existingSession / Lap $existingLapNum"
                $newExisting += $lapObj
                $foundMatch = $true
            }
            else {
                # Keep existing lap
                $newExisting += $existingLap
            }
        }
        
        # If lap wasn't found, append it
        if (-not $foundMatch) {
            Write-Debug "Upsert: ✗ No match found - appending: $currentSession / Lap $currentLapNum"
            $newExisting += $lapObj
        }
        
        # Export updated array
        $newExisting | Write-CsvExclusive -Path $LapsCsvPath | Out-Null
    }

    # Update state
    $PreviousState.BestLapTime = $bestLapTime
    $PreviousState.PrevTyreWear = $tyreWear
    $PreviousState.PrevFuel = $fuel
    $PreviousState.LapCount = $lapNumber
    $PreviousState.SessionName = $cleaned.SessionTypeName
    Write-JsonExclusive -Json ($PreviousState | ConvertTo-Json) -Path $statePath
}

# ==================== Session Start/Stop Handlers ====================

if ($Reset) {
    Write-Host "==================== SimHub Data Reset ===================="
    Write-Host "DataDir: $DataPath"

    if (-not (Test-Path $DataPath)) {
        Write-Host "⚠ DataDir does not exist — nothing to reset: $DataPath"
        exit 0
    }

    # Step 1: Graceful daemon stop via control file
    Write-Host "Sending stop signal to daemon..."
    $daemonControlFile = Join-Path $DataPath '_daemon_control.txt'
    Set-Content -Path $daemonControlFile -Value 'STOP' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Step 2: Force-kill daemon by PID file
    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    if (Test-Path $pidFile) {
        $storedPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($storedPid -and ($storedPid -as [int])) {
            $daemonProc = Get-Process -Id ([int]$storedPid) -ErrorAction SilentlyContinue
            if ($daemonProc) {
                Write-Host "Force-killing daemon (PID: $storedPid)..."
                Stop-Process -Id ([int]$storedPid) -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                Write-Host "✓ Daemon killed"
            }
        }
    }

    # Step 3: Kill any remaining processes with command lines referencing this DataDir or these scripts
    $absDataPath = (Resolve-Path $DataPath -ErrorAction SilentlyContinue)?.Path ?? $DataPath
    $scriptPatterns = @(
        [regex]::Escape($absDataPath),
        [regex]::Escape((Split-Path $daemonScriptFile -Leaf)),
        [regex]::Escape((Split-Path $PSCommandPath -Leaf))
    )
    $combinedPattern = $scriptPatterns -join '|'

    $relatedProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $combinedPattern -and $_.ProcessId -ne $PID }

    if ($relatedProcs) {
        foreach ($proc in $relatedProcs) {
            Write-Host "Force-killing related process (PID: $($proc.ProcessId) — $($proc.Name))..."
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        Write-Host "✓ Related processes killed"
    }
    else {
        Write-Host "✓ No related processes found"
    }

    # Step 4: Remove all data files
    Write-Host "Removing data files..."
    $filesToRemove = @(
        $SessionCsvPath,
        $LapsCsvPath,
        $statePath,
        (Join-Path $DataPath '_daemon_state.json'),
        (Join-Path $DataPath '_daemon_pid.txt'),
        (Join-Path $DataPath '_daemon.log'),
        (Join-Path $DataPath '_daemon_stdout.log'),
        (Join-Path $DataPath '_daemon_stderr.log'),
        (Join-Path $DataPath '_daemon_control.txt'),
        (Join-Path $DataPath 'summary.csv')
    )

    foreach ($file in $filesToRemove) {
        if (Test-Path $file) {
            Remove-Item $file -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed: $(Split-Path $file -Leaf)"
        }
    }

    Write-Host "✓ Reset complete — $DataPath is clean"
    exit 0
}

if ($Stop) {
    Write-Host "Stopping daemon and finalizing session..."
    
    # Stop the daemon process
    Write-Host "Stopping PropertyServer daemon..."
    $stopOk = $true
    try {
        & $daemonScriptFile -Command Stop -DataDir $DataPath | Out-Null
    }
    catch {
        $stopOk = $false
        Write-Warning "Daemon stop command failed: $_"
    }

    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    if (Test-Path $pidFile) {
        $daemonPidText = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($daemonPidText -and ($daemonPidText -as [int])) {
            $daemonPid = [int]$daemonPidText
            if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
                Write-Warning "Daemon still running after stop command (PID: $daemonPid). Forcing termination..."
                Stop-Process -Id $daemonPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
                    & taskkill /PID $daemonPid /T /F | Out-Null
                    Start-Sleep -Milliseconds 500
                }
            }
        }
    }

    $remainingDaemon = $false
    if (Test-Path $pidFile) {
        $daemonPidText = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($daemonPidText -and ($daemonPidText -as [int])) {
            $remainingDaemon = $null -ne (Get-Process -Id ([int]$daemonPidText) -ErrorAction SilentlyContinue)
        }
    }

    if ($remainingDaemon) {
        Write-Error "Failed to stop daemon process; it is still running."
        exit 1
    }

    if ($stopOk) {
        Write-Host "✓ Daemon stopped"
    }
    else {
        Write-Warning "Daemon stop completed via forced termination"
    }
    
    # Clean up state file
    Remove-Item $statePath -ErrorAction SilentlyContinue
    
    # Generate summary if data exists
    if ((Test-Path $SessionCsvPath) -and (Test-Path $LapsCsvPath)) {
        try {
            $summaryPath = Join-Path $DataPath "summary.csv"
            $session = Import-Csv $SessionCsvPath | Select-Object -Last 1
            $laps = Import-Csv $LapsCsvPath
            
            if ($null -ne $session -and $null -ne $laps) {
                $sessionName = $session.SessionType
                $lapsInSession = if ($laps -is [array]) { $laps.Count } else { 1 }
                $lapTimes = $laps | ForEach-Object { [double]($_.LastLapTime -replace '[^0-9\.]', '') } | Where-Object { $_ -gt 0 }
                $bestLap = if ($lapTimes.Count -gt 0) { ($lapTimes | Measure-Object -Minimum).Minimum } else { 'N/A' }
                $worstLap = if ($lapTimes.Count -gt 0) { ($lapTimes | Measure-Object -Maximum).Maximum } else { 'N/A' }
                $avgLap = if ($lapTimes.Count -gt 0) { [math]::Round(($lapTimes | Measure-Object -Average).Average, 3) } else { 'N/A' }
                $fuelConsumptions = $laps | ForEach-Object { [double]($_.Fuel_LastLapConsumption) } | Where-Object { $_ -gt 0 }
                $bestFuel = if ($fuelConsumptions.Count -gt 0) { ($fuelConsumptions | Measure-Object -Minimum).Minimum } else { 'N/A' }
                $worstFuel = if ($fuelConsumptions.Count -gt 0) { ($fuelConsumptions | Measure-Object -Maximum).Maximum } else { 'N/A' }
                $avgFuel = if ($fuelConsumptions.Count -gt 0) { [math]::Round(($fuelConsumptions | Measure-Object -Average).Average, 3) } else { 'N/A' }
                
                $summaryObj = [PSCustomObject]@{
                    Session                = $sessionName
                    LapsInSession          = $lapsInSession
                    BestLapTime            = $bestLap
                    WorstLapTime           = $worstLap
                    AverageLapTime         = $avgLap
                    BestFuelConsumption    = $bestFuel
                    WorstFuelConsumption   = $worstFuel
                    AverageFuelConsumption = $avgFuel
                }
                
                $summaryObj | Write-CsvExclusive -Path $summaryPath | Out-Null
                Write-Host "✓ Summary written to summary.csv"
            }
        }
        catch {
            Write-Warning "Failed to generate summary: $_"
        }
    }
    else {
        Write-Host "⚠ Session or lap CSV not found, skipping summary generation"
    }
    
    Write-Host "✓ Session finalized"
    exit 0
}

# ==================== Long-Running Collection Mode ====================

Write-Host "==================== SimHub Data Collection Service ===================="

# Acquire single-instance collector mutex for this DataDir before any startup cleanup.
if (-not (Acquire-CollectorMutex)) {
    Write-Error "Another collector instance is already running for data directory '$DataPath'."
    Write-Error "Stop the existing collector first or use a different -DataDir."
    exit 1
}

# Initialize new session if -Start flag is set
if ($Start) {
    Write-Host "Initializing new session..."
    
    # Kill any orphaned daemon processes
    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    if (Test-Path $pidFile) {
        $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($oldPid -and ($oldPid -as [int])) {
            try {
                [int]$oldPidInt = [int]$oldPid
                $oldProcess = if (Test-DaemonProcessIdentity -ProcessId $oldPidInt) {
                    Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue
                }
                else {
                    $null
                }
                if ($oldProcess) {
                    Write-Host "⚠ Killing orphaned daemon process (PID: $oldPidInt)"
                    Stop-Process -Id $oldPidInt -Force -ErrorAction SilentlyContinue

                    $killWaitMs = 0
                    while ($killWaitMs -lt 5000) {
                        Start-Sleep -Milliseconds 200
                        $killWaitMs += 200
                        $stillRunning = Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue
                        if (-not $stillRunning) {
                            break
                        }
                    }

                    if (Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue) {
                        Write-Warning "Stop-Process did not terminate PID $oldPidInt, forcing with taskkill..."
                        & taskkill /PID $oldPidInt /T /F | Out-Null
                        Start-Sleep -Milliseconds 500
                    }

                    if (Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue) {
                        Write-Error "Failed to terminate orphan daemon PID $oldPidInt. Resolve this process before starting collection."
                        exit 1
                    }

                    Write-Host "✓ Orphan daemon process terminated"
                }
            }
            catch {}
        }
    }

    # Clear stale daemon metadata so startup checks cannot be fooled by old state.
    Remove-Item (Join-Path $DataPath '_daemon_pid.txt') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $DataPath '_daemon_state.json') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $DataPath '_daemon_control.txt') -ErrorAction SilentlyContinue
    
    # Check if CSV files are locked (indicates running process)
    $csvFiles = @($LapsCsvPath, $SessionCsvPath)
    $lockedBy = $null
    
    foreach ($csvFile in $csvFiles) {
        if (-not (Test-Path $csvFile)) { continue }
        
        try {
            # Try non-blocking check: if file exists but can't be opened, it's likely locked
            [System.IO.File]::GetAttributes($csvFile) | Out-Null
            
            # File exists and is accessible, try a quick exclusive open check
            $fileStream = [System.IO.File]::Open($csvFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $fileStream.Close()
        }
        catch [System.IO.IOException] {
            # File is locked - try to identify which process has it
            if (Test-Path $pidFile) {
                $daemonPid = Get-Content $pidFile -ErrorAction SilentlyContinue
                if ($daemonPid -and ($daemonPid -as [int])) {
                    $runningProcess = Get-Process -Id $daemonPid -ErrorAction SilentlyContinue
                    if ($runningProcess) {
                        $lockedBy = "PID $daemonPid (ProcessName: $($runningProcess.ProcessName))"
                    }
                }
            }
            
            Write-Error "CSV file is locked by another process: $csvFile"
            if ($lockedBy) {
                Write-Error "Locked by: $lockedBy"
            }
            Write-Error "Stop the running daemon with: .\Get-SimHub-Data.ps1 -Stop -DataDir $DataPath"
            exit 1
        }
        catch {
            # Other error, ignore and continue
        }
    }
    
    Remove-Item $LapsCsvPath -ErrorAction SilentlyContinue
    Remove-Item $SessionCsvPath -ErrorAction SilentlyContinue
    Remove-Item $statePath -ErrorAction SilentlyContinue
    Write-Host "✓ CSV files cleared"
}

Write-Host "Starting continuous collection (Ctrl+C to stop)..."
Write-Host ""

# Ensure daemon is running
if (-not (Start-PropertyDaemon)) {
    Release-CollectorMutex
    Write-Error "Failed to start PropertyServer daemon"
    exit 1
}

# Load or initialize state
if (Test-Path $statePath) {
    $lapState = Get-Content $statePath | ConvertFrom-Json | ConvertTo-Hashtable
}
else {
    $lapState = @{ 
        BestLapTime          = $null
        PrevTyreWear         = $null
        PrevFuel             = $null
        LapCount             = 0
        SessionName          = $null
        InitialRecordCreated = $false
    }
}

# Wait for daemon to connect and get initial property values
Write-Host "Waiting for PropertyServer to connect..." -ForegroundColor Yellow
$initialConnectWaitTime = 0
$maxInitialConnectWait = 30000  # 30 seconds max wait
while ($initialConnectWaitTime -lt $maxInitialConnectWait) {
    $daemonStatus = Get-DaemonStatus
    $propValues = Get-DaemonProperties
    
    if ($daemonStatus.connected -and $propValues -and $propValues.Count -gt 0) {
        Write-Host "✓ PropertyServer connected with $(($propValues | Measure-Object).Count) properties" -ForegroundColor Green
        
        # Create initial session record from property baseline
        if (-not $lapState.InitialRecordCreated) {
            Write-Host "Recording initial session baseline..." -ForegroundColor Green
            
            # Create baseline session record
            $cleaned = @{}
            foreach ($k in $propValues.Keys) {
                $newKey = $k -replace '^(dcp\.gd\.|dcp\.|DataCorePlugin\.Computed\.)', ''
                $cleaned[$newKey] = $propValues[$k]
            }
            
            $initialSession = [PSCustomObject]@{
                Timestamp          = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                GameName           = $cleaned.GameName
                Driver             = $cleaned.PlayerName
                Car                = $cleaned.CarModel
                CarClass           = $cleaned.CarClass
                Track              = $cleaned.TrackName
                SessionType        = $cleaned.SessionTypeName
                Position           = $cleaned.Position
                CurrentLap         = $cleaned.CurrentLap
                CompletedLaps      = $cleaned.CompletedLaps
                TotalLaps          = $cleaned.TotalLaps
                SessionTimeLeft    = $cleaned.SessionTimeLeft
                SessionBestLapTime = $cleaned.BestLapTime
                LastLap            = $cleaned.LastLapTime
                CurrentFuel        = $cleaned.Fuel
                FuelUnit           = $cleaned.FuelUnit
                Fuel_LitersPerLap  = $cleaned.Fuel_LitersPerLap
                Fuel_RemainingLaps = $cleaned.Fuel_RemainingLaps
                Fuel_RemainingTime = $cleaned.Fuel_RemainingTime
            }
            
            $initialSession | Write-CsvExclusive -Path $SessionCsvPath | Out-Null
            Write-Host "  ✓ Initial session record created" -ForegroundColor Green
            Write-Host "    Game: $($initialSession.GameName) | Track: $($initialSession.Track) | Driver: $($initialSession.Driver)"
            
            $lapState.InitialRecordCreated = $true
            $lapState.SessionName = $cleaned.SessionTypeName
            $lapState.LapCount = [int](Get-OrDefault $cleaned.CurrentLap 0)
            
            # Persisting initial state so that subsequent lap changes can be detected
            Write-JsonExclusive -Json ($lapState | ConvertTo-Json) -Path $statePath
        }
        
        break
    }
    
    Start-Sleep -Milliseconds 500
    $initialConnectWaitTime += 500
}

if ($initialConnectWaitTime -ge $maxInitialConnectWait) {
    Write-Host "✗ PropertyServer did not connect within $($maxInitialConnectWait / 1000) seconds" -ForegroundColor Red
    Write-Host "  Continuing without initial baseline (will start recording on lap change)" -ForegroundColor Yellow
}

# Main collection loop
$collectionCount = 0
$lastStatusTime = Get-Date

try {
    while ($true) {
        # Get current properties from daemon
        $propValues = Get-DaemonProperties
        
        if ($null -eq $propValues -or $propValues.Count -eq 0) {
            # Print status every 10 seconds while waiting
            $now = Get-Date
            if (($now - $lastStatusTime).TotalSeconds -ge 10) {
                $daemonStatus = Get-DaemonStatus
                if (-not $daemonStatus.connected) {
                    Write-Host "$(Get-Date -Format 'HH:mm:ss') ⏳ Waiting for PropertyServer data... (Ctrl+C to stop)" -ForegroundColor Yellow
                }
                else {
                    Write-Host "$(Get-Date -Format 'HH:mm:ss') ⏳ Listening for session/lap changes... (Ctrl+C to stop)" -ForegroundColor Yellow
                }
                $lastStatusTime = $now
            }
            Start-Sleep -Seconds $UpdateInterval
            continue
        }

        # Check if session/lap changed
        if (Test-SessionChanged $propValues $LapsCsvPath) {
            $currentLap = [int](Get-OrDefault $propValues['dcp.gd.CurrentLap'] $propValues['CurrentLap'] 0)
            Write-Host "$(Get-Date -Format 'HH:mm:ss') [Lap $currentLap] Writing data..." -ForegroundColor Green
            
            Write-DataToCsv $propValues $lapState
            $collectionCount++
            Write-Host "  ✓ Data persisted (entry #$collectionCount)"
            $lastStatusTime = Get-Date  # Reset status timer after writing
        }
        
        Start-Sleep -Seconds $UpdateInterval
    }
}
catch {
    # Handle cancellation gracefully but let it propagate if it's a cancellation
    if ($_ -is [System.OperationCanceledException] -or $_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        Write-Host ""
        Write-Host "Collection stopped by user" -ForegroundColor Yellow
    }
    else {
        Write-Error "Collection error: $_"
    }
}
finally {
    Release-CollectorMutex
    if ($script:DaemonStartedByCollector) {
        try {
            Write-Host "Stopping daemon started by collector..." -ForegroundColor Yellow
            if (Stop-CollectorDaemon) {
                Write-Host "✓ Collector daemon stopped" -ForegroundColor Green
            }
            else {
                Write-Warning "Collector daemon could not be terminated cleanly"
            }
        }
        catch {
            Write-Warning "Failed to stop collector-started daemon: $_"
        }
        finally {
            $script:DaemonStartedByCollector = $false
        }
    }
}


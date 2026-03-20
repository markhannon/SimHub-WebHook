########################################################
# Primary SimHub Data Collection Service
# 
# Continuously collects telemetry from SimHub via daemon
# - Starts/manages PropertyServer daemon automatically
# - Runs in long-running mode (continuous collection)
# - Triggers CSV updates on session/lap changes
# - Supports -Start (initialize) and -Stop (cleanup) flags
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Start,
    [Parameter(Mandatory = $false)]
    [switch]$Stop,
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

# ==================== Exclusive File Locking ====================

function Write-CsvExclusive {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject,
        [string]$Path,
        [int]$RetryCount = 3,
        [int]$RetryDelayMs = 50
    )
    
    $attempt = 0
    while ($attempt -lt $RetryCount) {
        try {
            $InputObject | Export-Csv -Path $Path -NoTypeInformation -Force
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

function Get-DaemonStatus {
    if (-not (Test-Path $daemonStateFile)) {
        return @{ connected = $false; running = $false }
    }
    
    try {
        $state = Get-Content -Raw -Path $daemonStateFile | ConvertFrom-Json
        return @{ 
            connected = $state.connected
            running   = $state.daemon.startTime -ne $null
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

# ==================== Session/Lap State Retrieval ====================

function Get-DaemonProperties {
    if (-not (Test-Path $daemonStateFile)) {
        return $null
    }

    try {
        $state = Get-Content -Raw -Path $daemonStateFile | ConvertFrom-Json
        
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
        [hashtable]$PreviousState
    )
    
    # Check if session name changed
    $currentSession = $CurrentProps.SessionTypeName -replace '^(dcp\.|DataCorePlugin\.Computed\.)', ''
    $previousSession = $PreviousState.SessionName
    
    if ($currentSession -ne $previousSession) {
        return $true
    }
    
    # Check if lap count increased
    $currentLap = [int](Get-OrDefault $CurrentProps.CurrentLap 0)
    $previousLap = $PreviousState.LapCount
    
    if ($currentLap -gt $previousLap) {
        return $true
    }
    
    return $false
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
    $PreviousState | ConvertTo-Json | Set-Content $statePath
}

# ==================== Session Start/Stop Handlers ====================

if ($Stop) {
    Write-Host "Stopping daemon and finalizing session..."
    
    # Stop the daemon process
    Write-Host "Stopping PropertyServer daemon..."
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$daemonScriptFile`" -Command Stop -DataDir `"$DataDir`"" `
        -WindowStyle Hidden `
        -Wait | Out-Null
    
    Write-Host "✓ Daemon stopped"
    
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

# Initialize new session if -Start flag is set
if ($Start) {
    Write-Host "Initializing new session..."
    
    # Kill any orphaned daemon processes
    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    if (Test-Path $pidFile) {
        $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($oldPid -and ($oldPid -as [int])) {
            try {
                $oldProcess = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                if ($oldProcess) {
                    Write-Host "⚠ Killing orphaned daemon process (PID: $oldPid)"
                    Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                }
            }
            catch {}
        }
    }
    
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
        if (Test-SessionChanged $propValues $lapState) {
            Write-Debug "Change detected - writing to CSV (Session: $($lapState.SessionName), Lap: $($lapState.LapCount))"
            Write-Host "$(Get-Date -Format 'HH:mm:ss') [Lap $($lapState.LapCount)] Writing data..." -ForegroundColor Green
            
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
    if ($_ -is [System.OperationCanceledException]) {
        Write-Host ""
        Write-Host "Collection stopped by user" -ForegroundColor Yellow
    }
    else {
        Write-Error "Collection error: $_"
    }
}


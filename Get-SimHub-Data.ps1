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
    
    if ($status.running -and $status.connected) {
        Write-Host "✓ Daemon already running (PID: $($status.processId))"
        return $true
    }
    
    if (-not (Test-Path $daemonScriptFile)) {
        Write-Error "Daemon script not found: $daemonScriptFile"
        return $false
    }
    
    Write-Host "Starting PropertyServer daemon..."
    try {
        $process = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$daemonScriptFile`" -Command Start" `
            -WindowStyle Hidden `
            -PassThru
        
        # Wait for daemon to initialize and create state file
        $maxWait = 10
        $waited = 0
        while ($waited -lt $maxWait) {
            Start-Sleep -Seconds 1
            $waited++
            
            if (Test-Path $daemonStateFile) {
                $status = Get-DaemonStatus
                if ($status.connected) {
                    Write-Host "✓ Daemon started successfully (PID: $($process.Id))"
                    return $true
                }
            }
        }
        
        Write-Error "Daemon failed to initialize within $maxWait seconds"
        return $false
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
        $sessionObj | Export-Csv -Path $SessionCsvPath -NoTypeInformation -Force
    }
    else {
        $existing = @(Import-Csv $SessionCsvPath)
        $existing += $sessionObj
        $existing | Export-Csv -Path $SessionCsvPath -NoTypeInformation -Force
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
        SessionName               = $cleaned.SessionTypeName
        LapNumber                 = $lapNumber
        Position                  = $position
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
        GameName                  = $cleaned.GameName
        Car                       = $cleaned.CarModel
        CarClass                  = $cleaned.CarClass
        Track                     = $cleaned.TrackName
        CompletedLaps             = $cleaned.CompletedLaps
        TotalLaps                 = $cleaned.TotalLaps
        SessionTimeLeft           = $cleaned.SessionTimeLeft
    }

    # Append or create lap CSV
    if (-not (Test-Path $LapsCsvPath)) {
        $lapObj | Export-Csv -Path $LapsCsvPath -NoTypeInformation -Force
    }
    else {
        $existing = @(Import-Csv $LapsCsvPath)
        $existing += $lapObj
        $existing | Export-Csv -Path $LapsCsvPath -NoTypeInformation -Force
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

if ($Start) {
    Write-Host "Initializing new session..."
    Remove-Item $LapsCsvPath -ErrorAction SilentlyContinue
    Remove-Item $SessionCsvPath -ErrorAction SilentlyContinue
    Remove-Item $statePath -ErrorAction SilentlyContinue
    Write-Host "✓ CSV files cleared for new session"
    exit 0
}

if ($Stop) {
    Write-Host "Finalizing session..."
    Remove-Item $statePath -ErrorAction SilentlyContinue

    if ((Test-Path $SessionCsvPath) -and (Test-Path $LapsCsvPath)) {
        try {
            $summaryPath = Join-Path $ScriptDir "summary.csv"
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
                
                $summaryObj | Export-Csv -Path $summaryPath -NoTypeInformation -Force
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
        BestLapTime  = $null
        PrevTyreWear = $null
        PrevFuel     = $null
        LapCount     = 0
        SessionName  = $null
    }
}

# Main collection loop
$collectionCount = 0
try {
    while ($true) {
        # Get current properties from daemon
        $propValues = Get-DaemonProperties
        
        if ($null -eq $propValues -or $propValues.Count -eq 0) {
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
        }
        
        Start-Sleep -Seconds $UpdateInterval
    }
}
catch [System.OperationCanceledException] {
    Write-Host ""
    Write-Host "Collection stopped by user"
    exit 0
}
catch {
    Write-Error "Collection error: $_"
    exit 1
}


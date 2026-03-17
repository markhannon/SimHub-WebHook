########################################################
# Fetch SimHub status via SimHub Property Server plugin
########################################################
# support common parameters (e.g. -Debug) for conditional logging

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('--start', '--stop')]
    [string]$Mode
)

# read host/port configuration from external JSON
$configPath = Join-Path -Path $PSScriptRoot -ChildPath 'Simhub.json'
if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath"
}
$simhubConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$simhubHost = $simhubConfig.simhubHost
$simhubPort = $simhubConfig.simhubPort

# load list of properties to capture from external JSON file
$propsConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'Properties.json'
if (-not (Test-Path $propsConfigPath)) {
    throw "Properties configuration file not found: $propsConfigPath"
}
$propsConfig = Get-Content -Raw -Path $propsConfigPath | ConvertFrom-Json
$properties = $propsConfig.properties

# build subscribe commands dynamically
$commands = $properties | ForEach-Object { "subscribe $_" }
$commands += 'disconnect'

# Connect and initialize stream
$socket = New-Object System.Net.Sockets.TcpClient($simhubHost, $simhubPort)
$stream = $socket.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

# Function to read output
function Read-TelnetOutput {
    Start-Sleep -Milliseconds 500 # buffer time
    $output = ''
    while ($stream.DataAvailable) {
        $buffer = New-Object byte[] 1024
        $read = $stream.Read($buffer, 0, 1024)
        $output += [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    }
    return $output
}

# Collect property values
$propValues = @{}

foreach ($command in $commands) {
    Write-Debug "Sending: $command"
    $writer.WriteLine($command)
    $writer.Flush()

    $response = Read-TelnetOutput
    if ($response) {
        Write-Debug "Received response:`n$response"
        $response -split "`n" | ForEach-Object {
            $line = $_.Trim()
            # ignore header line
            if ($line -like 'SimHub*') { return }
            # parse lines like: Property dcp.GameName string IRacing
            if ($line -match '^Property\s+(?<key>\S+)\s+\S+\s+(?<val>.+)$') {
                $val = $matches.val
                if ($val -eq '(null)') { $val = $null }
                $propValues[$matches.key] = $val
            }
        }
    }
}



# Close connections
$writer.Close()
$socket.Close()

# If -Debug was passed, print all property values as JSON to the console
if ($PSBoundParameters['Debug']) {
    $propValues | ConvertTo-Json -Depth 5 | Write-Output
}




# --- Session/Lap CSV persistence and flag logic ---
$ScriptDir = $PSScriptRoot
$SessionCsvPath = Join-Path $ScriptDir "session.csv"
$LapsCsvPath = Join-Path $ScriptDir "laps.csv"

# Helper: parse timespan safely
function Parse-TimeSpanSafe($val) {
    try { [timespan]::Parse($val) } catch { $null }
}

# Helper: get average tyre wear
function Get-AvgTyreWear($cleaned) {
    $tyres = @('TyreWearFrontLeft', 'TyreWearFrontRight', 'TyreWearRearLeft', 'TyreWearRearRight')
    $vals = $tyres | ForEach-Object { [double]($cleaned[$_] ?? 0) }
    if ($vals.Count -eq 0) { return 0 }
    [math]::Round(($vals | Measure-Object -Average).Average, 3)
}

# State for deltas
$statePath = Join-Path $ScriptDir "_lapstate.json"
if (Test-Path $statePath) {
    $lapState = Get-Content $statePath | ConvertFrom-Json
}
else {
    $lapState = @{ BestLapTime = $null; PrevTyreWear = $null; PrevFuel = $null; LapCount = 0 }
}

# Handle flags
switch ($Mode) {
    '--start' {
        Remove-Item $LapsCsvPath -ErrorAction SilentlyContinue
        Remove-Item $SessionCsvPath -ErrorAction SilentlyContinue
        Remove-Item $statePath -ErrorAction SilentlyContinue
        Write-Host "Session started. CSV files cleared."
        exit 0
    }
    '--stop' {
        Write-Host "Session stopped. Data persisted to session.csv and laps.csv."
        Remove-Item $statePath -ErrorAction SilentlyContinue
        exit 0
    }
}

# --- Normal mode: fetch, calculate, persist ---
if ($propValues.Count -eq 0) {
    Write-Warning "No property values were captured. Check that SimHub Property Server is running and properties are subscribed."
    exit 1
}

# Clean property keys
$cleaned = @{}
foreach ($k in $propValues.Keys) {
    $newKey = $k -replace '^(dcp\.gd\.|dcp\.|DataCorePlugin\.Computed\.)', ''
    $cleaned[$newKey] = $propValues[$k]
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
if (-not (Test-Path $SessionCsvPath)) {
    $sessionObj | Export-Csv -Path $SessionCsvPath -NoTypeInformation -Force
}
else {
    $existing = Import-Csv $SessionCsvPath
    if ($null -eq $existing) {
        $existing = @()
    }
    elseif ($existing -isnot [System.Collections.IEnumerable] -or $existing -is [string]) {
        $existing = @($existing)
    }
    $existing += $sessionObj
    $existing | Export-Csv -Path $SessionCsvPath -NoTypeInformation -Force
}

# --- Lap CSV ---
$lapNumber = [int]($cleaned.CurrentLap ?? ($lapState.LapCount + 1))
$position = $cleaned.Position
$lastLapTime = $cleaned.LastLapTime
$bestLapTime = $cleaned.BestLapTime
$fuel = [double]($cleaned.Fuel ?? 0)

$tyreWear = Get-AvgTyreWear $cleaned
$tyreWearFL = [double]($cleaned.TyreWearFrontLeft ?? 0)
$tyreWearFR = [double]($cleaned.TyreWearFrontRight ?? 0)
$tyreWearRL = [double]($cleaned.TyreWearRearLeft ?? 0)
$tyreWearRR = [double]($cleaned.TyreWearRearRight ?? 0)

# Calculate deltas
$bestLapTS = Parse-TimeSpanSafe $bestLapTime
$lastLapTS = Parse-TimeSpanSafe $lastLapTime
$deltaToSessionBestLapTime = if ($bestLapTS -and $lastLapTS) { [math]::Round(($lastLapTS - $bestLapTS).TotalSeconds, 3) } else { 0 }
$deltaTyreWear = if ($lapState.PrevTyreWear) { [math]::Round($tyreWear - [double]$lapState.PrevTyreWear, 3) } else { 0 }
$deltaFuelUsage = if ($lapState.PrevFuel) { [math]::Round([double]$lapState.PrevFuel - $fuel, 3) } else { 0 }

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
    deltaTyreWear             = $deltaTyreWear
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
if (-not (Test-Path $LapsCsvPath)) {
    $lapObj | Export-Csv -Path $LapsCsvPath -NoTypeInformation -Force
}
else {
    $existing = Import-Csv $LapsCsvPath
    if ($null -eq $existing) {
        $existing = @()
    }
    elseif ($existing -isnot [System.Collections.IEnumerable] -or $existing -is [string]) {
        $existing = @($existing)
    }
    $existing += $lapObj
    $existing | Export-Csv -Path $LapsCsvPath -NoTypeInformation -Force
}

# Update state
$lapState.BestLapTime = $bestLapTime
$lapState.PrevTyreWear = $tyreWear
$lapState.PrevFuel = $fuel
$lapState.LapCount = $lapNumber
$lapState | ConvertTo-Json | Set-Content $statePath

# Output nothing to pipeline (CSV only)


#
# .SYNOPSIS
# Formats SimHub CSV data as Discord-friendly markdown text.
#

param(
    [Parameter(Mandatory = $false)]
    [string]$Extra,
    [Parameter(Mandatory = $false)]
    [switch]$IncludeLaps
)

$ScriptDir = $PSScriptRoot
$SessionCsvPath = Join-Path $ScriptDir "session.csv"
$LapsCsvPath = Join-Path $ScriptDir "laps.csv"

if (!(Test-Path $SessionCsvPath) -or !(Test-Path $LapsCsvPath)) {
    throw "session.csv or laps.csv not found. Run Get-SimHub-Data.ps1 first."
}

# Get latest session and lap data
$session = Import-Csv $SessionCsvPath | Select-Object -Last 1
$lap = Import-Csv $LapsCsvPath | Select-Object -Last 1

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$playerName = $session.Driver
$trackName = $session.Track
$carName = $session.Vehicle
$sessionType = $session.SessionType
$bestLap = $session.SessionBestLapTime
$totalLaps = $session.TotalLaps

$lapNumber = $lap.LapNumber
$position = $lap.Position
$lastLap = $lap.LastLapTime
$fuel = $lap.Fuel
$tyreWear = $lap.TyreWear
$tyreWearFL = $lap.TyreWearFrontLeft
$tyreWearFR = $lap.TyreWearFrontRight
$tyreWearRL = $lap.TyreWearRearLeft
$tyreWearRR = $lap.TyreWearRearRight
$deltaLap = $lap.deltaToSessionBestLapTime
$deltaTyre = $lap.deltaTyreWear
$deltaFuel = $lap.deltaFuelUsage

$extraText = ''
if (-not [string]::IsNullOrWhiteSpace($Extra)) {
    $extraText = " ($Extra)"
}

# Collect all output lines
$outputLines = @()
$outputLines += "${timestamp}: SimHub $playerName$extraText"
$outputLines += "Track:       $trackName"
$outputLines += "Car:         $carName"
$outputLines += "Session:     $sessionType"
$outputLines += "Best Lap:    $bestLap"
$outputLines += "Total Laps:  $totalLaps"
$outputLines += "Lap:         $lapNumber"
$outputLines += "Position:    $position"
$outputLines += "Last Lap:    $lastLap (Δ $deltaLap s)"
$outputLines += "Fuel:        $fuel (Δ $deltaFuel)"
$outputLines += "Tyre Wear:   $tyreWear (Δ $deltaTyre)"
$outputLines += "  FL: $tyreWearFL  FR: $tyreWearFR  RL: $tyreWearRL  RR: $tyreWearRR"

# Optionally include lap summary table
if ($IncludeLaps) {
    $laps = Import-Csv $LapsCsvPath
    if ($laps.Count -gt 0) {
        $sortedLaps = $laps | Sort-Object SessionName, { [int]$_.LapNumber }
        # Calculate max widths for each column
        $sessionWidth = 16
        $lapWidth = ($sortedLaps | ForEach-Object { ($_.LapNumber).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $lapWidth -or $lapWidth -lt 3) { $lapWidth = 3 }
        $lastLapWidth = ($sortedLaps | ForEach-Object { ($_.LastLapTime).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $lastLapWidth -or $lastLapWidth -lt 11) { $lastLapWidth = 11 }
        $deltaWidth = ($sortedLaps | ForEach-Object { ($_.deltaToSessionBestLapTime).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $deltaWidth -or $deltaWidth -lt 11) { $deltaWidth = 11 }
        $fuelWidth = ($sortedLaps | ForEach-Object { ($_.deltaFuelUsage).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $fuelWidth -or $fuelWidth -lt 5) { $fuelWidth = 5 }

        $outputLines += ""
        $outputLines += "Lap Summary:"
        $header = "{0} {1} {2} {3} {4}" -f 
        'Session'.PadRight($sessionWidth),
        'Lap'.PadRight($lapWidth),
        'LastLapTime'.PadRight($lastLapWidth),
        'ΔToBest(s)'.PadRight($deltaWidth),
        'ΔFuel'.PadRight($fuelWidth)
        $divider = "{0} {1} {2} {3} {4}" -f 
        ('-' * $sessionWidth),
        ('-' * $lapWidth),
        ('-' * $lastLapWidth),
        ('-' * $deltaWidth),
        ('-' * $fuelWidth)
        $outputLines += $header
        $outputLines += $divider
        foreach ($l in $sortedLaps) {
            # Force each column to be exactly its width
            $sessionCell = $l.SessionName
            if ($null -eq $sessionCell) { $sessionCell = '' }
            if ($sessionCell.Length -gt $sessionWidth) {
                $sessionCell = $sessionCell.Substring(0, $sessionWidth)
            }
            else {
                $sessionCell = $sessionCell.PadRight($sessionWidth, ' ')
            }
            $lapCell = ($l.LapNumber).ToString()
            if ($lapCell.Length -gt $lapWidth) {
                $lapCell = $lapCell.Substring(0, $lapWidth)
            }
            else {
                $lapCell = $lapCell.PadRight($lapWidth, ' ')
            }
            $lastLapCell = ($l.LastLapTime)
            if ($null -eq $lastLapCell) { $lastLapCell = '' }
            if ($lastLapCell.Length -gt $lastLapWidth) {
                $lastLapCell = $lastLapCell.Substring(0, $lastLapWidth)
            }
            else {
                $lastLapCell = $lastLapCell.PadRight($lastLapWidth, ' ')
            }
            $deltaCell = ($l.deltaToSessionBestLapTime)
            if ($null -eq $deltaCell) { $deltaCell = '' }
            if ($deltaCell.Length -gt $deltaWidth) {
                $deltaCell = $deltaCell.Substring(0, $deltaWidth)
            }
            else {
                $deltaCell = $deltaCell.PadRight($deltaWidth, ' ')
            }
            $fuelCell = ($l.deltaFuelUsage)
            if ($null -eq $fuelCell) { $fuelCell = '' }
            if ($fuelCell.Length -gt $fuelWidth) {
                $fuelCell = $fuelCell.Substring(0, $fuelWidth)
            }
            else {
                $fuelCell = $fuelCell.PadRight($fuelWidth, ' ')
            }
            $row = "$sessionCell $lapCell $lastLapCell $deltaCell $fuelCell"
            $outputLines += $row
        }
    }
}

# Output everything in a single code block
Write-Output '```'
Write-Output ($outputLines -join "`n")
Write-Output '```'

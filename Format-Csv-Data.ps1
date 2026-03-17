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

Write-Output "${timestamp}: SimHub $playerName$extraText"
Write-Output '```'

# Optionally include lap summary table
if ($IncludeLaps) {
    $laps = Import-Csv $LapsCsvPath
    if ($laps.Count -gt 0) {
        $sortedLaps = $laps | Sort-Object SessionName, { [int]$_.LapNumber }
        $table = @()
        $table += "Session | Lap | LastLapTime | ΔToBest (s) | ΔFuel"
        $table += "------- | --- | ----------- | ----------- | -----"
        foreach ($l in $sortedLaps) {
            $row = "{0} | {1} | {2} | {3} | {4}" -f $l.SessionName, $l.LapNumber, $l.LastLapTime, $l.deltaToSessionBestLapTime, $l.deltaFuelUsage
            $table += $row
        }
        $tableString = ($table -join "`n")
        Write-Output "Lap Summary:"
        Write-Output '```'
        Write-Output $tableString
        Write-Output '```'
    }
}
Write-Output ("Track:       $trackName")
Write-Output ("Car:         $carName")
Write-Output ("Session:     $sessionType")
Write-Output ("Best Lap:    $bestLap")
Write-Output ("Total Laps:  $totalLaps")
Write-Output ("Lap:         $lapNumber")
Write-Output ("Position:    $position")
Write-Output ("Last Lap:    $lastLap (Δ $deltaLap s)")
Write-Output ("Fuel:        $fuel (Δ $deltaFuel)")
Write-Output ("Tyre Wear:   $tyreWear (Δ $deltaTyre)")
Write-Output ("  FL: $tyreWearFL  FR: $tyreWearFR  RL: $tyreWearRL  RR: $tyreWearRR")
Write-Output '```'

<#
.SYNOPSIS
Formats SimHub JSON data as Discord-friendly markdown text.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Extra
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
$deltaLap = $lap.deltaToSessionBestLapTime
$deltaTyre = $lap.deltaTyreWear
$deltaFuel = $lap.deltaFuelUsage

$extraText = ''
if (-not [string]::IsNullOrWhiteSpace($Extra)) {
    $extraText = " ($Extra)"
}

Write-Output "${timestamp}: SimHub $playerName$extraText"
Write-Output '```'
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
Write-Output '```'

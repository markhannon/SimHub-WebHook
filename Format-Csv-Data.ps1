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
    $extraText = $Extra
}

# Collect all output lines
$outputLines = @()

# Info message formatting: first line, centered, capitalized, with > and < padding, timestamp on second line
if ($extraText -ne '') {
    # Calculate width to match lap summary (done later, so default to 80 if not available yet)
    $lapSummaryWidth = 80
    if ($IncludeLaps) {
        $laps = Import-Csv $LapsCsvPath
        if ($laps.Count -gt 0) {
            $sortedLaps = $laps | Sort-Object SessionName, { [int]$_.LapNumber }
            $sessionWidth = 16
            $lapWidth = ($sortedLaps | ForEach-Object { ($_.LapNumber).ToString().Length } | Measure-Object -Maximum).Maximum
            if (-not $lapWidth -or $lapWidth -lt 3) { $lapWidth = 3 }
            $lastLapWidth = ($sortedLaps | ForEach-Object { ($_.LastLapTime).ToString().Length } | Measure-Object -Maximum).Maximum
            if (-not $lastLapWidth -or $lastLapWidth -lt 11) { $lastLapWidth = 11 }
            $deltaWidth = ($sortedLaps | ForEach-Object { ($_.deltaToSessionBestLapTime).ToString().Length } | Measure-Object -Maximum).Maximum
            if (-not $deltaWidth -or $deltaWidth -lt 11) { $deltaWidth = 11 }
            $fuelWidth = ($sortedLaps | ForEach-Object { ($_.deltaFuelUsage).ToString().Length } | Measure-Object -Maximum).Maximum
            if (-not $fuelWidth -or $fuelWidth -lt 5) { $fuelWidth = 5 }
            $positionWidth = ($sortedLaps | ForEach-Object { ($_.Position).ToString().Length } | Measure-Object -Maximum).Maximum
            if (-not $positionWidth -or $positionWidth -lt 3) { $positionWidth = 3 }
            $tyreWidth = 3
            $lapSummaryWidth = $sessionWidth + $lapWidth + $positionWidth + $lastLapWidth + $deltaWidth + $fuelWidth + ($tyreWidth * 4) + 9 # 9 spaces between columns
        }
    }
    # Compose info message (capitalized, centered, with > and < padding, 2 spaces each side)
    $infoText = ($extraText.ToUpper())
    $infoLen = $infoText.Length
    $totalWidth = $lapSummaryWidth
    $sideSpace = 2
    $padChar = '>'
    $padCharR = '<'
    $padLen = [Math]::Max(0, [int](($totalWidth - $infoLen - ($sideSpace * 2)) / 2))
    $leftPad = $padChar * $padLen
    $rightPad = $padCharR * $padLen
    $centeredInfo = $leftPad + (' ' * $sideSpace) + $infoText + (' ' * $sideSpace) + $rightPad
    # If odd width, add one more < to right
    if ($centeredInfo.Length -lt $totalWidth) {
        $centeredInfo += $padCharR
    }
    $outputLines += $centeredInfo
    $outputLines += ("Timestamp:   $timestamp")
}
else {
    $outputLines += ("Timestamp:   $timestamp")
}

# Try to get all requested fields, fallback to N/A if missing
$gameName = $session.GameName
if (-not $gameName) { $gameName = "N/A" }
$car = $session.Car
if (-not $car) { $car = "N/A" }
$carClass = $session.CarClass
if (-not $carClass) { $carClass = "N/A" }
$track = $session.Track
if (-not $track) { $track = "N/A" }
$sessionName = $session.SessionType
if (-not $sessionName) { $sessionName = "N/A" }
$position = $lap.Position
if (-not $position) { $position = "N/A" }
$currentLap = $lap.LapNumber
if (-not $currentLap) { $currentLap = "N/A" }
$completedLaps = $session.CompletedLaps
if (-not $completedLaps) { $completedLaps = "N/A" }
$totalLaps = $session.TotalLaps
if (-not $totalLaps) { $totalLaps = "N/A" }
$sessionTimeLeft = $session.SessionTimeLeft
if (-not $sessionTimeLeft) { $sessionTimeLeft = "N/A" }
$bestLap = $session.SessionBestLapTime
if (-not $bestLap) { $bestLap = "N/A" }
else {
    # Format to max 3 decimal places for seconds
    if ($bestLap -match '^(\d{2}:\d{2}:\d{2})\.(\d{1,7})$') {
        $main = $matches[1]
        $frac = $matches[2].Substring(0, [Math]::Min(3, $matches[2].Length))
        $bestLap = "$main.$frac"
    }
}
$lastLap = $lap.LastLapTime
if (-not $lastLap) { $lastLap = "N/A" }
else {
    if ($lastLap -match '^(\d{2}:\d{2}:\d{2})\.(\d{1,7})$') {
        $main = $matches[1]
        $frac = $matches[2].Substring(0, [Math]::Min(3, $matches[2].Length))
        $lastLap = "$main.$frac"
    }
}

# Format fuel to three decimal places if numeric and append FuelUnit
$fuel = $lap.Fuel
$fuelUnit = $session.FuelUnit
if ($fuel -and $fuel -as [double]) {
    $fuel = [math]::Round([double]$fuel, 3)
    $fuel = "{0:F3}" -f $fuel
}
elseif (-not $fuel) {
    $fuel = "N/A"
}
if ($fuelUnit) {
    $fuel = "$fuel $fuelUnit"
}

$outputLines += "Driver:      $playerName"
$outputLines += "Game:        $gameName"
$outputLines += "Car:         $car"
$outputLines += "Car Class:   $carClass"
$outputLines += "Track:       $track"
$outputLines += "Session:     $sessionName"
$outputLines += "Position:    $position"
$outputLines += "Lap:         $currentLap"
$outputLines += "Laps Total:  $totalLaps"
$outputLines += "Time Left:   $sessionTimeLeft"
$outputLines += "Best Lap:    $bestLap"
$outputLines += "Last Lap:    $lastLap"

# Add Fuel_LitersPerLap, Fuel_RemainingLaps, Fuel_RemainingTime with labels
$fuelLitersPerLap = $session.Fuel_LitersPerLap
if ($fuelLitersPerLap -and $fuelLitersPerLap -as [double]) {
    $fuelLitersPerLap = [math]::Round([double]$fuelLitersPerLap, 3)
    $fuelLitersPerLap = "{0:F3}" -f $fuelLitersPerLap
}
elseif (-not $fuelLitersPerLap) {
    $fuelLitersPerLap = "N/A"
}
$fuelRemainingLaps = $session.Fuel_RemainingLaps
if ($fuelRemainingLaps -and $fuelRemainingLaps -as [double]) {
    $fuelRemainingLaps = [math]::Round([double]$fuelRemainingLaps, 1)
    $fuelRemainingLaps = "{0:F1}" -f $fuelRemainingLaps
}
elseif (-not $fuelRemainingLaps) {
    $fuelRemainingLaps = "N/A"
}
$fuelRemainingTime = $session.Fuel_RemainingTime
if (-not $fuelRemainingTime) { $fuelRemainingTime = "N/A" }

$outputLines += "Fuel:        $fuel"
$outputLines += "Litres/Lap (AVG): $fuelLitersPerLap"
$outputLines += "Est.Laps:    $fuelRemainingLaps"
$outputLines += "Est.Time:    $fuelRemainingTime"



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
        $fuelWidth = ($sortedLaps | ForEach-Object { ($_.Fuel_LastLapConsumption).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $fuelWidth -or $fuelWidth -lt 5) { $fuelWidth = 5 }

        $outputLines += ""
        $outputLines += "Lap Summary:"
        $positionWidth = ($sortedLaps | ForEach-Object { ($_.Position).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $positionWidth -or $positionWidth -lt 3) { $positionWidth = 3 }
        $tyreWidth = 3
        $header = "{0} {1} {2} {3} {4} {5} {6} {7} {8} {9}" -f 
        'Session'.PadRight($sessionWidth),
        'Lap'.PadRight($lapWidth),
        'Pos'.PadRight($positionWidth),
        'LastLapTime'.PadRight($lastLapWidth),
        'ΔToBest(s)'.PadRight($deltaWidth),
        'LastLapCons'.PadRight($fuelWidth),
        'FL'.PadRight($tyreWidth),
        'FR'.PadRight($tyreWidth),
        'RL'.PadRight($tyreWidth),
        'RR'.PadRight($tyreWidth)
        $divider = "{0} {1} {2} {3} {4} {5} {6} {7} {8} {9}" -f 
        ('-' * $sessionWidth),
        ('-' * $lapWidth),
        ('-' * $positionWidth),
        ('-' * $lastLapWidth),
        ('-' * $deltaWidth),
        ('-' * $fuelWidth),
        ('-' * $tyreWidth),
        ('-' * $tyreWidth),
        ('-' * $tyreWidth),
        ('-' * $tyreWidth)
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
            $positionCell = ($l.Position).ToString()
            if ($null -eq $positionCell) { $positionCell = '' }
            if ($positionCell.Length -gt $positionWidth) {
                $positionCell = $positionCell.Substring(0, $positionWidth)
            }
            else {
                $positionCell = $positionCell.PadRight($positionWidth, ' ')
            }
            $lastLapCell = ($l.LastLapTime)
            if ($null -eq $lastLapCell) { $lastLapCell = '' }
            else {
                if ($lastLapCell -match '^(\d{2}:\d{2}:\d{2})\.(\d{1,7})$') {
                    $main = $matches[1]
                    $frac = $matches[2].Substring(0, [Math]::Min(3, $matches[2].Length))
                    $lastLapCell = "$main.$frac"
                }
            }
            if ($lastLapCell.Length -gt $lastLapWidth) {
                $lastLapCell = $lastLapCell.Substring(0, $lastLapWidth)
            }
            else {
                $lastLapCell = $lastLapCell.PadRight($lastLapWidth, ' ')
            }
            $deltaCell = ($l.deltaToSessionBestLapTime)
            if ($null -eq $deltaCell) { $deltaCell = '' }
            else {
                # Add sign and format to 3 decimal places if numeric
                if ($deltaCell -as [double] -or $deltaCell -as [float]) {
                    $num = [double]$deltaCell
                    $sign = if ($num -ge 0) { '+' } else { '-' }
                    $deltaCell = $sign + [math]::Abs([math]::Round($num, 3)).ToString('0.###')
                }
            }
            if ($deltaCell.Length -gt $deltaWidth) {
                $deltaCell = $deltaCell.Substring(0, $deltaWidth)
            }
            else {
                $deltaCell = $deltaCell.PadRight($deltaWidth, ' ')
            }
            $fuelCell = ($l.Fuel_LastLapConsumption)
            if ($null -eq $fuelCell) { $fuelCell = '' }
            if ($fuelCell -and $fuelCell -as [double]) {
                $fuelCell = [math]::Round([double]$fuelCell, 3)
                $fuelCell = "{0:F3}" -f $fuelCell
            }
            if ($fuelCell.Length -gt $fuelWidth) {
                $fuelCell = $fuelCell.Substring(0, $fuelWidth)
            }
            else {
                $fuelCell = $fuelCell.PadRight($fuelWidth, ' ')
            }
            $flCell = [int]([double]($l.TyreWearFrontLeft) 2> $null)
            $frCell = [int]([double]($l.TyreWearFrontRight) 2> $null)
            $rlCell = [int]([double]($l.TyreWearRearLeft) 2> $null)
            $rrCell = [int]([double]($l.TyreWearRearRight) 2> $null)
            $flCell = $flCell.ToString().PadRight($tyreWidth)
            $frCell = $frCell.ToString().PadRight($tyreWidth)
            $rlCell = $rlCell.ToString().PadRight($tyreWidth)
            $rrCell = $rrCell.ToString().PadRight($tyreWidth)
            $row = "$sessionCell $lapCell $positionCell $lastLapCell $deltaCell $fuelCell $flCell $frCell $rlCell $rrCell"
            $outputLines += $row
        }
    }
}

# Output everything in a single code block, with a leading blank line
Write-Output ''
Write-Output '```'
Write-Output ($outputLines -join "`n")
Write-Output '```'

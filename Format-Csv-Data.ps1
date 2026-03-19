#
# .SYNOPSIS
# Formats SimHub CSV data as Discord-friendly markdown text.
#

param(
    [Parameter(Mandatory = $false)]
    [string]$Extra,
    [Parameter(Mandatory = $false)]
    [switch]$IncludeLaps,
    [Parameter(Mandatory = $false)]
    [switch]$NoFuelAndLaps,
    [Parameter(Mandatory = $false)]
    [switch]$IncludeSummary,
    [Parameter(Mandatory = $false)]
    [string]$DataDir
)


$ScriptDir = $PSScriptRoot
$CsvDir = if ($DataDir) { $DataDir } else { $ScriptDir }
$SessionCsvPath = Join-Path $CsvDir "session.csv"
$LapsCsvPath = Join-Path $CsvDir "laps.csv"

if (!(Test-Path $SessionCsvPath) -or !(Test-Path $LapsCsvPath)) {
    Write-Host "[DEBUG] session.csv or laps.csv not found. Skipping formatted output."
    return
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



$extraText = ''
if (-not [string]::IsNullOrWhiteSpace($Extra)) {
    $extraText = $Extra
}

# Collect all output lines
$outputLines = @()

# Optionally include summary.csv output
if ($IncludeSummary) {
    $summaryPath = Join-Path $CsvDir "summary.csv"
    if (Test-Path $summaryPath) {
        $summary = Import-Csv $summaryPath | Select-Object -Last 1
        $outputLines += "Session Summary:"
        $outputLines += "Session:           $($summary.Session)"
        $outputLines += "Laps In Session:    $($summary.LapsInSession)"
        $outputLines += "Best Lap Time:      $($summary.BestLapTime)"
        $outputLines += "Worst Lap Time:     $($summary.WorstLapTime)"
        $outputLines += "Average Lap Time:   $($summary.AverageLapTime)"
        $outputLines += "Best Fuel Cons.:    $($summary.BestFuelConsumption)"
        $outputLines += "Worst Fuel Cons.:   $($summary.WorstFuelConsumption)"
        $outputLines += "Average Fuel Cons.: $($summary.AverageFuelConsumption)"
        $outputLines += ""
    }
    else {
        $outputLines += "Session summary not available. Run -Stop to generate summary.csv."
        $outputLines += ""
    }
}

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
            $outputLines += ""
            if ($laps.Count -gt 0) {
                $sortedLaps = $laps | Sort-Object SessionName, { [int]$_.LapNumber }
                # Calculate max widths for each column
                $sessionWidth = 16
                $lapWidth = ($sortedLaps | ForEach-Object { ($_.LapNumber).ToString().Length } | Measure-Object -Maximum).Maximum
                if (-not $lapWidth -or $lapWidth -lt 3) { $lapWidth = 3 }
                $lastLapWidth = ($sortedLaps | ForEach-Object { ($_.LastLapTime).ToString().Length } | Measure-Object -Maximum).Maximum
                if (-not $lastLapWidth -or $lastLapWidth -lt 11) { $lastLapWidth = 11 }
                $fuelWidth = 10
                $fuelAvgWidth = 10

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
                'Fuel(LAST)'.PadRight($fuelWidth),
                'Fuel(AVG)'.PadRight($fuelAvgWidth),
                'FL'.PadRight($tyreWidth),
                'FR'.PadRight($tyreWidth),
                'RL'.PadRight($tyreWidth),
                'RR'.PadRight($tyreWidth)
                $divider = "{0} {1} {2} {3} {4} {5} {6} {7} {8} {9}" -f
                ('-' * $sessionWidth),
                ('-' * $lapWidth),
                ('-' * $positionWidth),
                ('-' * $lastLapWidth),
                ('-' * $fuelWidth),
                ('-' * $fuelAvgWidth),
                ('-' * $tyreWidth),
                ('-' * $tyreWidth),
                ('-' * $tyreWidth),
                ('-' * $tyreWidth)
                $outputLines += $header
                $outputLines += $divider
                foreach ($l in $sortedLaps) {
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
                        if ($lastLapCell -match '^(
?
                $lastLapCell = $lastLapCell.Substring(0, $lastLapWidth)
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
                    $fuelAvgCell = ($l.Fuel_LitersPerLap)
                    if ($null -eq $fuelAvgCell) { $fuelAvgCell = '' }
                    if ($fuelAvgCell -and $fuelAvgCell -as [double]) {
                        $fuelAvgCell = [math]::Round([double]$fuelAvgCell, 3)
                        $fuelAvgCell = "{0:F3}" -f $fuelAvgCell
                    }
                    if ($fuelAvgCell.Length -gt $fuelAvgWidth) {
                        $fuelAvgCell = $fuelAvgCell.Substring(0, $fuelAvgWidth)
                    }
                    else {
                        $fuelAvgCell = $fuelAvgCell.PadRight($fuelAvgWidth, ' ')
                    }
                    $flCell = [int]([double]($l.TyreWearFrontLeft) 2> $null)
                    $frCell = [int]([double]($l.TyreWearFrontRight) 2> $null)
                    $rlCell = [int]([double]($l.TyreWearRearLeft) 2> $null)
                    $rrCell = [int]([double]($l.TyreWearRearRight) 2> $null)
                    $flCell = $flCell.ToString().PadRight($tyreWidth)
                    $frCell = $frCell.ToString().PadRight($tyreWidth)
                    $rlCell = $rlCell.ToString().PadRight($tyreWidth)
                    $rrCell = $rrCell.ToString().PadRight($tyreWidth)
                    $row = "$sessionCell $lapCell $positionCell $lastLapCell $fuelCell $fuelAvgCell $flCell $frCell $rlCell $rrCell"
                    $outputLines += $row
                }
            }
            }
            else {
                $lastLapCell = $lastLapCell.PadRight($lastLapWidth, ' ')
            }

            # Calculate best lap time so far (in seconds)
            $lapTimeSec = $null
            if ($l.LastLapTime -and $l.LastLapTime -match '^(\d { 2 }):(\d { 2 }):(\d { 2 })\.(\d+)$') {
                $h = [int]$matches[1]; $m = [int]$matches[2]; $s = [int]$matches[3]; $ms = [int]$matches[4]
                $lapTimeSec = ($h * 3600) + ($m * 60) + $s + ($ms / [math]::Pow(10, $matches[4].Length))
            }
            if ($lapTimeSec -ne $null) {
                if ($bestLapTimeSoFar -eq $null -or $lapTimeSec -lt $bestLapTimeSoFar) {
                    $bestLapTimeSoFar = $lapTimeSec
                }
            }

            # Calculate delta to best lap time so far
            $deltaCell = ''
            if ($lapTimeSec -ne $null -and $bestLapTimeSoFar -ne $null) {
                $deltaVal = $lapTimeSec - $bestLapTimeSoFar
                $sign = if ($deltaVal -ge 0) { '+' } else { '-' }
                $deltaCell = $sign + [math]::Abs([math]::Round($deltaVal, 3)).ToString('0.###')
            }
            $deltaCell = $deltaCell.PadRight($deltaWidth, ' ')

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
            $fuelAvgCell = ($l.Fuel_LitersPerLap)
            if ($null -eq $fuelAvgCell) { $fuelAvgCell = '' }
            if ($fuelAvgCell -and $fuelAvgCell -as [double]) {
                $fuelAvgCell = [math]::Round([double]$fuelAvgCell, 3)
                $fuelAvgCell = "{0:F3}" -f $fuelAvgCell
            }
            if ($fuelAvgCell.Length -gt $fuelAvgWidth) {
                $fuelAvgCell = $fuelAvgCell.Substring(0, $fuelAvgWidth)
            }
            else {
                $fuelAvgCell = $fuelAvgCell.PadRight($fuelAvgWidth, ' ')
            }
            $flCell = [int]([double]($l.TyreWearFrontLeft) 2> $null)
            $frCell = [int]([double]($l.TyreWearFrontRight) 2> $null)
            $rlCell = [int]([double]($l.TyreWearRearLeft) 2> $null)
            $rrCell = [int]([double]($l.TyreWearRearRight) 2> $null)
            $flCell = $flCell.ToString().PadRight($tyreWidth)
            $frCell = $frCell.ToString().PadRight($tyreWidth)
            $rlCell = $rlCell.ToString().PadRight($tyreWidth)
            $rrCell = $rrCell.ToString().PadRight($tyreWidth)
            $row = "$sessionCell $lapCell $positionCell $lastLapCell $deltaCell $fuelCell $fuelAvgCell $flCell $frCell $rlCell $rrCell"
            $outputLines += $row
        }
    }
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
                if ($lastLapCell -match '^(\d { 2 }:\d { 2 }:\d { 2 })\.(\d { 1, 7 })$') {
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
            $fuelAvgCell = ($l.Fuel_LitersPerLap)
            if ($null -eq $fuelAvgCell) { $fuelAvgCell = '' }
            if ($fuelAvgCell -and $fuelAvgCell -as [double]) {
                $fuelAvgCell = [math]::Round([double]$fuelAvgCell, 3)
                $fuelAvgCell = "{0:F3}" -f $fuelAvgCell
            }
            if ($fuelAvgCell.Length -gt $fuelAvgWidth) {
                $fuelAvgCell = $fuelAvgCell.Substring(0, $fuelAvgWidth)
            }
            else {
                $fuelAvgCell = $fuelAvgCell.PadRight($fuelAvgWidth, ' ')
            }
            $flCell = [int]([double]($l.TyreWearFrontLeft) 2> $null)
            $frCell = [int]([double]($l.TyreWearFrontRight) 2> $null)
            $rlCell = [int]([double]($l.TyreWearRearLeft) 2> $null)
            $rrCell = [int]([double]($l.TyreWearRearRight) 2> $null)
            $flCell = $flCell.ToString().PadRight($tyreWidth)
            $frCell = $frCell.ToString().PadRight($tyreWidth)
            $rlCell = $rlCell.ToString().PadRight($tyreWidth)
            $rrCell = $rrCell.ToString().PadRight($tyreWidth)
            $row = "$sessionCell $lapCell $positionCell $lastLapCell $deltaCell $fuelCell $fuelAvgCell $flCell $frCell $rlCell $rrCell"
            $outputLines += $row
        }
    }
}

# Output everything in a single code block, with a leading blank line
Write-Output ''
Write-Output '```'
                            Write-Output ($outputLines -join "`n")
                            Write-Output '```'

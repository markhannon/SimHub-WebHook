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
    [switch]$Minimal,
    [Parameter(Mandatory = $false)]
    [string]$LapSessionName,
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'data'
)

$ScriptDir = $PSScriptRoot
$DataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }
$SessionCsvPath = Join-Path $DataPath "session.csv"
$LapsCsvPath = Join-Path $DataPath "laps.csv"

if (!(Test-Path $SessionCsvPath) -or !(Test-Path $LapsCsvPath)) {
    Write-Host "[DEBUG] session.csv or laps.csv not found. Skipping formatted output."
    return
}

function Convert-LapTimeToSeconds {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $LapTime
    )

    if ($null -eq $LapTime) {
        return $null
    }

    $text = [string]$LapTime
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $trimmed = $text.Trim()
    if ($trimmed -match '^(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})(?:\.(?<f>\d{1,7}))?$') {
        $hours = [int]$matches['h']
        $minutes = [int]$matches['m']
        $seconds = [int]$matches['s']
        $fraction = 0.0
        if ($matches['f']) {
            $fractionText = $matches['f'].PadRight(7, '0').Substring(0, 7)
            $fraction = [double]("0.$fractionText")
        }
        $totalSeconds = ($hours * 3600) + ($minutes * 60) + $seconds + $fraction
        if ($totalSeconds -le 0) {
            return $null
        }
        return $totalSeconds
    }

    if ($trimmed -as [double]) {
        $asNumber = [double]$trimmed
        if ($asNumber -gt 0) {
            return $asNumber
        }
    }

    return $null
}

function ConvertTo-BoolSafe {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    switch -Regex ($text.Trim().ToLowerInvariant()) {
        '^(1|true|yes|on)$' { return $true }
        '^(0|false|no|off)$' { return $false }
        default { return $null }
    }
}

function ConvertTo-NullableDouble {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return [double]$text.Trim()
    }
    catch {
        return $null
    }
}

function ConvertTo-NullableInt {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return [int]$text.Trim()
    }
    catch {
        return $null
    }
}

function Convert-DurationToSeconds {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $trimmed = $text.Trim()
    if ($trimmed -match '^(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})(?:\.(?<f>\d{1,7}))?$') {
        try {
            return [timespan]::Parse($trimmed).TotalSeconds
        }
        catch {
            return $null
        }
    }

    try {
        return [double]$trimmed
    }
    catch {
        return $null
    }
}

function Format-SecondsText {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    $seconds = Convert-DurationToSeconds $Value
    if ($null -eq $seconds) {
        return '-'
    }

    $roundedSeconds = [math]::Round([double]$seconds, 1)
    if ([math]::Abs($roundedSeconds - [math]::Round($roundedSeconds, 0)) -lt 0.0001) {
        return ([math]::Round($roundedSeconds, 0)).ToString()
    }

    return ('{0:F1}' -f $roundedSeconds)
}

function Test-IsZeroOrMissingMetric {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value,
        [Parameter(Mandatory = $false)]
        [switch]$TreatAsDuration
    )

    if ($null -eq $Value) {
        return $true
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $true
    }

    $trimmed = $text.Trim()
    if ([string]::Equals($trimmed, 'N/A', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if ($TreatAsDuration) {
        $durationSeconds = Convert-DurationToSeconds $trimmed
        if ($null -ne $durationSeconds) {
            return ([double]$durationSeconds -le 0)
        }
    }

    try {
        $numericValue = [double]$trimmed
        return ([math]::Abs($numericValue) -lt 0.0000001)
    }
    catch {
        return ($trimmed -match '^0+(?:\.0+)?$')
    }
}

function Get-CurrentSessionLaps {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [array]$Laps,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$CurrentSession
    )

    if ($null -eq $Laps -or $Laps.Count -eq 0) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($CurrentSession)) {
        return @()
    }

    $sessionKey = $CurrentSession.Trim()
    return @(
        $Laps | Where-Object {
            $lapSession = [string]$_.SessionName
            -not [string]::IsNullOrWhiteSpace($lapSession) -and
            [string]::Equals($lapSession.Trim(), $sessionKey, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
}

# Get latest session and lap data
$session = Import-Csv $SessionCsvPath | Select-Object -Last 1
$lap = Import-Csv $LapsCsvPath | Select-Object -Last 1
$currentSessionName = [string]$session.SessionType
$effectiveLapSessionName = if (-not [string]::IsNullOrWhiteSpace($LapSessionName)) { $LapSessionName } else { $currentSessionName }

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$playerName = $session.Driver
$bestLap = $session.SessionBestLapTime
$totalLaps = $session.TotalLaps

$position = $lap.Position
$lastLap = $lap.LastLapTime
$fuel = $lap.Fuel

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
    $laps = Import-Csv $LapsCsvPath
    $laps = Get-CurrentSessionLaps -Laps $laps -CurrentSession $effectiveLapSessionName
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
        $fuelWidth = 10
        $fuelAvgWidth = 10
        $lapSummaryWidth = $sessionWidth + $lapWidth + $positionWidth + $lastLapWidth + $deltaWidth + $fuelWidth + $fuelAvgWidth + ($tyreWidth * 4) + 10 # 10 spaces between columns
    }
    $totalWidth = $lapSummaryWidth
    $outputLines += $extraText
    $timestampLine = "Timestamp:   $timestamp"
    if ($timestampLine.Length -lt $totalWidth) {
        $timestampLine += (' ' * ($totalWidth - $timestampLine.Length))
    }
    $outputLines += $timestampLine
}
else {
    $timestampLine = "Timestamp:   $timestamp"
    if ($timestampLine.Length -lt 80) {
        $timestampLine += (' ' * (80 - $timestampLine.Length))
    }
    $outputLines += $timestampLine
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
if ($sessionTimeLeft -and $sessionTimeLeft -match '^\-') {
    $sessionTimeLeft = 'N/A'
}
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
$currentFuelValue = ConvertTo-NullableDouble $lap.Fuel
$maxFuelValue = ConvertTo-NullableDouble $lap.MaxFuel
$fuelUnit = $session.FuelUnit
$fuelUnitDisplay = $null
if (-not [string]::IsNullOrWhiteSpace([string]$fuelUnit)) {
    $fuelUnitDisplay = ([string]$fuelUnit) -replace '(?i)\bliters\b', 'litres'
}
$fuel = "N/A"
if ($null -ne $currentFuelValue) {
    $fuel = "{0:F3}" -f ([math]::Round($currentFuelValue, 3))
    if ($null -ne $maxFuelValue) {
        $fuelMax = "{0:F3}" -f ([math]::Round($maxFuelValue, 3))
        $fuel = "$fuel/$fuelMax"
    }
}
if ($fuel -ne "N/A" -and $fuelUnitDisplay) {
    $fuel = "$fuel $fuelUnitDisplay"
}

$outputLines += "Driver:      $playerName"
$outputLines += "Game:        $gameName"
$outputLines += "Car:         $car"
$outputLines += "Car Class:   $carClass"
$outputLines += "Track:       $track"
$outputLines += "Session:     $sessionName"
$outputLines += "Time Left:   $sessionTimeLeft"
$outputLines += "Position:    $position"
$outputLines += "Lap:         $currentLap"
$outputLines += "Laps Total:  $totalLaps"

if (-not $Minimal) {
    if (-not (Test-IsZeroOrMissingMetric -Value $bestLap -TreatAsDuration)) {
        $outputLines += "Best Lap:    $bestLap"
    }
    if (-not (Test-IsZeroOrMissingMetric -Value $lastLap -TreatAsDuration)) {
        $outputLines += "Last Lap:    $lastLap"
    }

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
    if (-not $fuelRemainingTime) {
        $fuelRemainingTime = "N/A"
    }
    elseif ($fuelRemainingTime -match '\.') {
        $fuelRemainingTime = $fuelRemainingTime -replace '\..*$', ''
    }

    $outputLines += "Fuel:        $fuel"
    $fuelLitersPerLapLabel = "Fuel (AVG):".PadRight(13)
    $fuelLitersPerLapValue = $fuelLitersPerLap
    if ($fuelLitersPerLap -ne "N/A" -and $fuelUnitDisplay) {
        $fuelLitersPerLapValue = "$fuelLitersPerLap $fuelUnitDisplay/Lap"
    }

    if (-not (Test-IsZeroOrMissingMetric -Value $fuelLitersPerLap)) {
        $outputLines += "$fuelLitersPerLapLabel$fuelLitersPerLapValue"
    }
    if (-not (Test-IsZeroOrMissingMetric -Value $fuelRemainingLaps)) {
        $outputLines += "Fuel (LAPS): $fuelRemainingLaps"
    }
    if (-not (Test-IsZeroOrMissingMetric -Value $fuelRemainingTime -TreatAsDuration)) {
        $outputLines += "Fuel (TIME): $fuelRemainingTime"
    }

    $lapsSinceLastPit = ConvertTo-NullableInt $lap.LapsSinceLastPit
    if ($null -ne $lapsSinceLastPit) {
        $stintDetails = @()

        $lastPitStopSeconds = Convert-DurationToSeconds $lap.LastPitStopDuration
        if ($null -ne $lastPitStopSeconds -and [double]$lastPitStopSeconds -gt 0) {
            $lastPitStopDuration = Format-SecondsText $lap.LastPitStopDuration
            $stintDetails += "${lastPitStopDuration}s in-pit"
        }

        $lastPitLaneSeconds = Convert-DurationToSeconds $lap.LastPitLaneDuration
        if ($null -ne $lastPitLaneSeconds -and [double]$lastPitLaneSeconds -gt 0) {
            $lastPitLaneDuration = Format-SecondsText $lap.LastPitLaneDuration
            $stintDetails += "${lastPitLaneDuration}s in-pitlane"
        }

        if ($stintDetails.Count -gt 0) {
            $outputLines += "Stint:       ${lapsSinceLastPit}L ($($stintDetails -join ' '))"
        }
        else {
            $outputLines += "Stint:       ${lapsSinceLastPit}L"
        }
    }
}



# Optionally include lap summary table
if ($IncludeLaps) {
    $laps = Import-Csv $LapsCsvPath
    $laps = Get-CurrentSessionLaps -Laps $laps -CurrentSession $effectiveLapSessionName
    if ($laps.Count -gt 0) {
        $sortedLaps = $laps | Sort-Object SessionName, { [int]$_.LapNumber }

        $lapSecondsByIndex = @{}
        for ($i = 0; $i -lt $sortedLaps.Count; $i++) {
            $lapSecondsByIndex[$i] = Convert-LapTimeToSeconds -LapTime $sortedLaps[$i].LastLapTime
        }

        $bestBySession = @{}
        $groupRows = for ($i = 0; $i -lt $sortedLaps.Count; $i++) {
            [PSCustomObject]@{
                Index       = $i
                SessionName = [string]$sortedLaps[$i].SessionName
                LapSeconds  = $lapSecondsByIndex[$i]
            }
        }

        foreach ($group in ($groupRows | Group-Object SessionName)) {
            $validRows = @($group.Group | Where-Object { $null -ne $_.LapSeconds })
            if ($validRows.Count -eq 0) {
                continue
            }

            $bestSeconds = ($validRows | Measure-Object -Property LapSeconds -Minimum).Minimum
            $bestCandidates = @($validRows | Where-Object { [math]::Abs([double]$_.LapSeconds - [double]$bestSeconds) -lt 0.0000001 })
            $bestIndex = ($bestCandidates | Sort-Object Index | Select-Object -First 1).Index
            $bestBySession[[string]$group.Name] = [PSCustomObject]@{
                BestSeconds = [double]$bestSeconds
                BestIndex   = [int]$bestIndex
            }
        }

        $computedDeltaByIndex = @{}
        for ($i = 0; $i -lt $sortedLaps.Count; $i++) {
            $sessionKey = [string]$sortedLaps[$i].SessionName
            $lapSeconds = $lapSecondsByIndex[$i]
            $bestMeta = $bestBySession[$sessionKey]

            if ($null -eq $lapSeconds -or $null -eq $bestMeta) {
                $rawDelta = $sortedLaps[$i].deltaToSessionBestLapTime
                if ($rawDelta -as [double] -or $rawDelta -as [float]) {
                    $rawNum = [double]$rawDelta
                    $rawSign = if ($rawNum -ge 0) { '+' } else { '-' }
                    $computedDeltaByIndex[$i] = $rawSign + [math]::Abs([math]::Round($rawNum, 3)).ToString('0.###')
                }
                else {
                    $computedDeltaByIndex[$i] = ''
                }
                continue
            }

            $deltaSeconds = [double]$lapSeconds - [double]$bestMeta.BestSeconds
            $isBestRow = ($i -eq $bestMeta.BestIndex) -and ([math]::Abs($deltaSeconds) -lt 0.0005)
            $isTiedNonBest = ($i -ne $bestMeta.BestIndex) -and ([math]::Abs($deltaSeconds) -lt 0.0005)

            if ($isBestRow) {
                $computedDeltaByIndex[$i] = '0'
            }
            elseif ($isTiedNonBest) {
                $computedDeltaByIndex[$i] = '+0.001'
            }
            else {
                $roundedDelta = [math]::Round($deltaSeconds, 3)
                $deltaSign = if ($roundedDelta -ge 0) { '+' } else { '-' }
                $computedDeltaByIndex[$i] = $deltaSign + [math]::Abs($roundedDelta).ToString('0.###')
            }
        }

        # Calculate max widths for each column
        $sessionWidth = 16
        $lapWidth = ($sortedLaps | ForEach-Object { ($_.LapNumber).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $lapWidth -or $lapWidth -lt 3) { $lapWidth = 3 }
        $lastLapWidth = ($sortedLaps | ForEach-Object { ($_.LastLapTime).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $lastLapWidth -or $lastLapWidth -lt 11) { $lastLapWidth = 11 }
        $deltaWidth = ($computedDeltaByIndex.Values | ForEach-Object { $_.ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $deltaWidth -or $deltaWidth -lt 11) { $deltaWidth = 11 }
        $fuelWidth = 10
        $fuelAvgWidth = 10

        $outputLines += ""
        $outputLines += "Lap Summary:"
        $positionWidth = ($sortedLaps | ForEach-Object { ($_.Position).ToString().Length } | Measure-Object -Maximum).Maximum
        if (-not $positionWidth -or $positionWidth -lt 3) { $positionWidth = 3 }
        $tyreWidth = 3
        $header = "{0} {1} {2} {3} {4} {5} {6} {7} {8} {9} {10}" -f
        'Session'.PadRight($sessionWidth),
        'Lap'.PadRight($lapWidth),
        'Pos'.PadRight($positionWidth),
        'LastLapTime'.PadRight($lastLapWidth),
        'Delta'.PadRight($deltaWidth),
        'Fuel(LAST)'.PadRight($fuelWidth),
        'Fuel(AVG)'.PadRight($fuelAvgWidth),
        'FL'.PadRight($tyreWidth),
        'FR'.PadRight($tyreWidth),
        'RL'.PadRight($tyreWidth),
        'RR'.PadRight($tyreWidth)
        $divider = "{0} {1} {2} {3} {4} {5} {6} {7} {8} {9} {10}" -f
        ('-' * $sessionWidth),
        ('-' * $lapWidth),
        ('-' * $positionWidth),
        ('-' * $lastLapWidth),
        ('-' * $deltaWidth),
        ('-' * $fuelWidth),
        ('-' * $fuelAvgWidth),
        ('-' * $tyreWidth),
        ('-' * $tyreWidth),
        ('-' * $tyreWidth),
        ('-' * $tyreWidth)
        $outputLines += $header
        $outputLines += $divider
        for ($i = 0; $i -lt $sortedLaps.Count; $i++) {
            $l = $sortedLaps[$i]
            # Force each column to be exactly its width
            $sessionCell = [string]$l.SessionName
            if ($null -eq $sessionCell) { $sessionCell = '' }

            $pitFlag = [string]$l.Pit
            $showPit = [string]::Equals($pitFlag.Trim(), 'Yes', [System.StringComparison]::OrdinalIgnoreCase)
            if ($showPit) {
                $pitSuffix = '(Pit)'
                $baseMaxLength = [Math]::Max(0, $sessionWidth - $pitSuffix.Length)
                if ($sessionCell.Length -gt $baseMaxLength) {
                    $sessionCell = $sessionCell.Substring(0, $baseMaxLength)
                }
                $sessionCell = "$sessionCell $pitSuffix"
            }

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
            $deltaCell = $computedDeltaByIndex[$i]
            if ($null -eq $deltaCell) { $deltaCell = '' }
            if ($deltaCell.Length -gt $deltaWidth) {
                $deltaCell = $deltaCell.Substring(0, $deltaWidth)
            }
            else {
                $deltaCell = $deltaCell.PadRight($deltaWidth, ' ')
            }
            $isFuelTrackingValid = ConvertTo-BoolSafe $l.CurrentLapIsValidForTracking
            if ($false -eq $isFuelTrackingValid) {
                $fuelCell = '-'
            }
            else {
                $fuelCell = ($l.Fuel_LastLapConsumption)
                if ($null -eq $fuelCell) { $fuelCell = '' }
                if ($fuelCell -and $fuelCell -as [double]) {
                    $fuelCell = [math]::Round([double]$fuelCell, 3)
                    $fuelCell = "{0:F3}" -f $fuelCell
                }
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

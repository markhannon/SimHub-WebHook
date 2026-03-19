####################################################

####################################################
# Send SimHub CSV data to Discord via webhook with event options
# Usage:
#   ./Send-Discord-Data.ps1 -SessionStart
#   ./Send-Discord-Data.ps1 -SessionEnd
#   ./Send-Discord-Data.ps1 -PitIn
#   ./Send-Discord-Data.ps1 -PitOut
#   ./Send-Discord-Data.ps1 -Status
####################################################

param(
    [Parameter(Mandatory = $false)]
    [switch]$SessionStart,
    [Parameter(Mandatory = $false)]
    [switch]$SessionEnd,
    [Parameter(Mandatory = $false)]
    [switch]$PitIn,
    [Parameter(Mandatory = $false)]
    [switch]$PitOut,
    [Parameter(Mandatory = $false)]
    [switch]$Status,
    [Parameter(Mandatory = $false)]
    [string]$DataDir,
    [Parameter(Mandatory = $false)]
    [switch]$TestOutput
)

$ScriptDir = $PSScriptRoot
$CsvDir = if ($DataDir) { $DataDir } else { $ScriptDir }
$SessionCsvPath = Join-Path $CsvDir "session.csv"
$LapsCsvPath = Join-Path $CsvDir "laps.csv"
$formatCommand = Join-Path $ScriptDir "Format-Csv-Data.ps1"
$configPath = Join-Path $ScriptDir 'Discord.json'
if (-not (Test-Path $configPath)) { throw "Configuration file not found: $configPath" }
$discordConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$hookUrl = $discordConfig.hookUrl

if (-not (Test-Path $SessionCsvPath) -or -not (Test-Path $LapsCsvPath)) {
    Write-Host "[DEBUG] session.csv or laps.csv not found. Skipping Discord output."
    exit 0
}

# Determine event type and extra text
$extra = ""
if ($SessionStart) { $extra = "Session Start" }
elseif ($SessionEnd) { $extra = "Session End" }
elseif ($PitIn) { $extra = "Entering Pits" }
elseif ($PitOut) { $extra = "Exiting Pits" }
elseif ($Status) { $extra = "Status" }



# Compose Discord output with lap summary and delta calculation
$laps = Import-Csv $LapsCsvPath
$session = Import-Csv $SessionCsvPath | Select-Object -Last 1

'Pos'.PadRight($positionWidth),
'LastLapTime'.PadRight($lastLapWidth),

# Compose lap summary with delta calculation
$sessionWidth = 16
$lapWidth = 3
$positionWidth = 3
$lastLapWidth = 11
$deltaWidth = 11
$fuelWidth = 10
$fuelAvgWidth = 10
$tyreWidth = 3

$header = "{0} {1} {2} {3} {4} {5} {6} {7} {8} {9} {10}" -f @(
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
)
$divider = "{0} {1} {2} {3} {4} {5} {6} {7} {8} {9} {10}" -f @(
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
)
$outputLines = @()
$outputLines += "Lap Summary:"
$outputLines += $header
$outputLines += $divider

$bestLapTimeSoFar = $null
foreach ($l in ($laps | Sort-Object SessionName, { [int]$_.LapNumber })) {
    $sessionCell = $l.SessionName
    if ($null -eq $sessionCell) { $sessionCell = '' }
    if ($sessionCell.Length -gt $sessionWidth) {
        $sessionCell = $sessionCell.Substring(0, $sessionWidth)
    }
    else {
        $sessionCell = $sessionCell.PadRight($sessionWidth, ' ')
    }
    $lapCell = ($l.LapNumber).ToString().PadRight($lapWidth, ' ')
    $positionCell = ($l.Position).ToString().PadRight($positionWidth, ' ')
    $lastLapCell = ($l.LastLapTime)
    if ($null -eq $lastLapCell) { $lastLapCell = '' }
    else {
        if ($lastLapCell -match '^(
?
?\d{2}:\d{2}:\d{2})\.(\d{1,7})$') {
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
    # Calculate best lap time so far (in seconds)
    $lapTimeSec = $null
    if ($l.LastLapTime -and $l.LastLapTime -match '^(\d{2}):(\d{2}):(\d{2})\.(\d+)$') {
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
        $fuelCell = "{0:F3}" -f [double]$fuelCell
    }
    $fuelCell = "$fuelCell".PadRight($fuelWidth, ' ')
    
    $fuelAvgCell = ($l.Fuel_LitersPerLap)
    if ($null -eq $fuelAvgCell) { $fuelAvgCell = '' }
    if ($fuelAvgCell -and $fuelAvgCell -as [double]) {
        $fuelAvgCell = "{0:F3}" -f [double]$fuelAvgCell
    }
    $fuelAvgCell = "$fuelAvgCell".PadRight($fuelAvgWidth, ' ')
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
$content = @"
```
$($outputLines -join "`n")
```
"@

if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Host '[DEBUG] No formatted content generated. Skipping Discord output.'
    exit 0
}

# If -TestOutput is set, write to console and skip Discord
if ($TestOutput) {
    Write-Host $content
    Write-Host '[DEBUG] TestOutput: Content written to console, not sent to Discord.'
    exit 0
}

# Build payload
$payload = [PSCustomObject]@{ content = $content }

# Send to Discord webhook
try {
    Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 6) -ContentType 'application/json'
    Write-Host ('Discord message sent: ' + $extra)
}
catch {
    Write-Error ('Failed to send Discord message: ' + $_)
}

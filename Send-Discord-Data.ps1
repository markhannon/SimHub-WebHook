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
    [switch]$Status
)

$ScriptDir = $PSScriptRoot
$SessionCsvPath = Join-Path $ScriptDir "session.csv"
$LapsCsvPath = Join-Path $ScriptDir "laps.csv"
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


# Format the CSV data for Discord
if ($Status) {
    if ([string]::IsNullOrWhiteSpace($extra)) {
        $formatted = & $formatCommand -IncludeLaps
    }
    else {
        $formatted = & $formatCommand -Extra $extra -IncludeLaps
    }
}
else {
    if ($PitIn) {
        if ([string]::IsNullOrWhiteSpace($extra)) {
            $formatted = & $formatCommand -IncludeLaps
        }
        else {
            $formatted = & $formatCommand -Extra $extra -IncludeLaps
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($extra)) {
            $formatted = & $formatCommand -NoFuelAndLaps
        }
        else {
            $formatted = & $formatCommand -Extra $extra -NoFuelAndLaps
        }
    }
}
if ($formatted -is [System.Array]) {
    $content = $formatted -join "`n"
}
else {
    $content = $formatted
}

if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Host "[DEBUG] No formatted content generated. Skipping Discord output."
    exit 0
}

# Build payload
$payload = [PSCustomObject]@{ content = $content }


# Send to Discord webhook
try {
    Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 6) -ContentType 'application/json'
    Write-Host "Discord message sent: $extra"
}
catch {
    Write-Error "Failed to send Discord message: $_"
}

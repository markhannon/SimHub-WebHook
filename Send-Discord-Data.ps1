####################################################

####################################################
# Send SimHub CSV data to Discord via webhook with event options
# Usage:
#   ./Send-Discord-Data.ps1 -SessionStart
#   ./Send-Discord-Data.ps1 -SessionEnd
#   ./Send-Discord-Data.ps1 -PitIn
#   ./Send-Discord-Data.ps1 -PitOut
#   ./Send-Discord-Data.ps1 -Status
#   ./Send-Discord-Data.ps1
#   ./Send-Discord-Data.ps1 -EventName "Fastest Lap" -EventScope "Personal"
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
    [string]$EventName,
    [Parameter(Mandatory = $false)]
    [string]$EventScope,
    [Parameter(Mandatory = $false)]
    [string]$EventDetails,
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'data'
)

$ScriptDir = $PSScriptRoot
$DataPath = Join-Path $ScriptDir $DataDir
$SessionCsvPath = Join-Path $DataPath "session.csv"
$LapsCsvPath = Join-Path $DataPath "laps.csv"
$EventsCsvPath = Join-Path $DataPath "events.csv"
$formatCommand = Join-Path $ScriptDir "Format-Csv-Data.ps1"
$configPath = Join-Path $ScriptDir 'Discord.json'
if (-not (Test-Path $configPath)) { throw "Configuration file not found: $configPath" }
$discordConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$hookUrl = $discordConfig.hookUrl

if ([string]::IsNullOrWhiteSpace([string]$hookUrl)) {
    Write-Host "[DEBUG] Discord webhook URL is not configured. Skipping output."
    exit 0
}

if (-not (Test-Path $SessionCsvPath) -or -not (Test-Path $LapsCsvPath)) {
    Write-Host "[DEBUG] session.csv or laps.csv not found. Skipping Discord output."
    exit 0
}

# Default to Status Update when no explicit mode is provided.
if (-not $SessionStart -and -not $SessionEnd -and -not $PitIn -and -not $PitOut -and -not $Status -and [string]::IsNullOrWhiteSpace($EventName)) {
    $Status = $true
}

# Determine event type and extra text
$extra = ""
$includeLaps = $true
$eventLookupName = $null

if ($SessionStart) {
    $extra = "Session Start"
    $eventLookupName = "Session Started"
    $includeLaps = $false
}
elseif ($SessionEnd) {
    $extra = "Session End"
    $eventLookupName = "Session Stopped"
    $includeLaps = $true
}
elseif ($PitIn) {
    $extra = "Entering Pits"
    $eventLookupName = "Entering Pits"
    $includeLaps = $true
}
elseif ($PitOut) {
    $extra = "Exiting Pits"
    $eventLookupName = "Exiting Pits"
    $includeLaps = $false
}
elseif ($Status) {
    $extra = "Status Update"
    $includeLaps = $true
}
elseif (-not [string]::IsNullOrWhiteSpace($EventName)) {
    $extra = $EventName
    $eventLookupName = $EventName
    $compactEventNames = @('Session Started', 'Exiting Pits')
    $includeLaps = -not ($compactEventNames -contains $EventName)
}

$latestEvent = $null
if (-not [string]::IsNullOrWhiteSpace($eventLookupName) -and (Test-Path $EventsCsvPath)) {
    try {
        $events = @(Import-Csv $EventsCsvPath)
        for ($idx = $events.Count - 1; $idx -ge 0; $idx--) {
            $candidate = $events[$idx]
            if ($candidate.EventName -ne $eventLookupName) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($EventScope) -and $candidate.Scope -ne $EventScope) {
                continue
            }
            $latestEvent = $candidate
            break
        }
    }
    catch {
        Write-Host "[DEBUG] Failed reading events.csv: $_"
    }
}

if ($latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.Scope)) {
    $extra = "$extra [$($latestEvent.Scope)]"
}


# Format the CSV data for Discord
if ($includeLaps) {
    if ([string]::IsNullOrWhiteSpace($extra)) {
        $formatted = & $formatCommand -IncludeLaps -DataDir $DataDir
    }
    else {
        $formatted = & $formatCommand -Extra $extra -IncludeLaps -DataDir $DataDir
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($extra)) {
        $formatted = & $formatCommand -NoFuelAndLaps -DataDir $DataDir
    }
    else {
        $formatted = & $formatCommand -Extra $extra -NoFuelAndLaps -DataDir $DataDir
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

# For Session Stopped output, display the stopped (previous) session name from events.csv.
if ($eventLookupName -eq 'Session Stopped' -and $latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.SessionName)) {
    $content = [regex]::Replace(
        $content,
        '(?m)^Session:\s+.*$',
        "Session:     $($latestEvent.SessionName)",
        1
    )
}

$eventDetailsLine = $null
if (-not [string]::IsNullOrWhiteSpace($EventDetails)) {
    $eventDetailsLine = $EventDetails
}
elseif ($latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.Details)) {
    $eventDetailsLine = $latestEvent.Details
}

if ($latestEvent -or $eventDetailsLine) {
    $summaryEventLines = @()
    if ($latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.RuleMatched)) {
        $summaryEventLines += "Rule Match:  $($latestEvent.RuleMatched)"
    }
    if ($eventDetailsLine) {
        $summaryEventLines += "Details:     $eventDetailsLine"
    }

    if ($summaryEventLines.Count -gt 0) {
        $contentLines = @($content -split "`r?`n")
        $timestampIndex = -1
        for ($i = 0; $i -lt $contentLines.Count; $i++) {
            if ($contentLines[$i] -match '^Timestamp:') {
                $timestampIndex = $i
                break
            }
        }

        if ($timestampIndex -ge 0) {
            $before = @()
            if ($timestampIndex -gt 0) {
                $before = $contentLines[0..$timestampIndex]
            }
            else {
                $before = @($contentLines[0])
            }

            $after = @()
            if ($timestampIndex -lt ($contentLines.Count - 1)) {
                $after = $contentLines[($timestampIndex + 1)..($contentLines.Count - 1)]
            }

            $content = (@($before) + $summaryEventLines + @($after)) -join "`n"
        }
    }
}

$maxDiscordLength = 2000
if ($content.Length -gt $maxDiscordLength) {
    $suffix = "`n`n[truncated to fit Discord message limit]"
    $keepLength = $maxDiscordLength - $suffix.Length
    if ($keepLength -lt 1) {
        $keepLength = $maxDiscordLength
        $suffix = ""
    }
    $content = $content.Substring(0, $keepLength) + $suffix
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

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
    [switch]$UseTextMode,
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

function Convert-ToDisplayValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value,
        [Parameter(Mandatory = $false)]
        [string]$Default = 'N/A'
    )

    if ($null -eq $Value) { return $Default }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    return $text
}

function Convert-ToLapTimeDisplay {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value,
        [Parameter(Mandatory = $false)]
        [string]$Default = 'N/A'
    )

    $text = Convert-ToDisplayValue -Value $Value -Default $Default
    if ($text -eq $Default) { return $text }

    if ($text -match '^(\d{2}:\d{2}:\d{2})\.(\d{1,7})$') {
        $main = $matches[1]
        $frac = $matches[2].Substring(0, [Math]::Min(3, $matches[2].Length))
        return "$main.$frac"
    }

    return $text
}

function Limit-DiscordText {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value,
        [Parameter(Mandatory = $true)]
        [int]$MaxLength
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($text.Length -le $MaxLength) {
        return $text
    }

    $suffix = '...'
    $keepLength = $MaxLength - $suffix.Length
    if ($keepLength -lt 0) { $keepLength = 0 }
    if ($keepLength -eq 0) { return $suffix.Substring(0, $MaxLength) }
    return $text.Substring(0, $keepLength) + $suffix
}

function New-EmbedField {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $false)]
        [switch]$Inline
    )

    return [PSCustomObject]@{
        name   = Limit-DiscordText -Value $Name -MaxLength 256
        value  = Limit-DiscordText -Value $Value -MaxLength 1024
        inline = [bool]$Inline
    }
}

$eventDetailsLine = $null
if (-not [string]::IsNullOrWhiteSpace($EventDetails)) {
    $eventDetailsLine = $EventDetails
}
elseif ($latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.Details)) {
    $eventDetailsLine = $latestEvent.Details
}

$sessionRows = @(Import-Csv $SessionCsvPath)
$lapRows = @(Import-Csv $LapsCsvPath)
$latestSessionRow = if ($sessionRows.Count -gt 0) { $sessionRows[$sessionRows.Count - 1] } else { $null }
$latestLapRow = if ($lapRows.Count -gt 0) { $lapRows[$lapRows.Count - 1] } else { $null }

if (-not $latestSessionRow -or -not $latestLapRow) {
    Write-Host "[DEBUG] session.csv or laps.csv has no rows. Skipping Discord output."
    exit 0
}

# For Session Stopped output, display the stopped (previous) session name from events.csv.
$sessionNameForDisplay = Convert-ToDisplayValue -Value $latestSessionRow.SessionType
if ($eventLookupName -eq 'Session Stopped' -and $latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.SessionName)) {
    $sessionNameForDisplay = $latestEvent.SessionName
}

$useEmbedMode = -not $UseTextMode
$payload = $null

if (-not $useEmbedMode) {
    # Legacy text mode path.
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

    if ($eventLookupName -eq 'Session Stopped' -and $latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.SessionName)) {
        $content = [regex]::Replace(
            $content,
            '(?m)^Session:\s+.*$',
            "Session:     $($latestEvent.SessionName)",
            1
        )
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

    $payload = [PSCustomObject]@{ content = $content }
}
else {
    $timestampValue = Convert-ToDisplayValue -Value $latestSessionRow.Timestamp -Default (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $driverValue = Convert-ToDisplayValue -Value $latestSessionRow.Driver
    $gameValue = Convert-ToDisplayValue -Value $latestSessionRow.GameName
    $carValue = Convert-ToDisplayValue -Value $latestSessionRow.Car
    $carClassValue = Convert-ToDisplayValue -Value $latestSessionRow.CarClass
    $trackValue = Convert-ToDisplayValue -Value $latestSessionRow.Track
    $positionValue = Convert-ToDisplayValue -Value $latestLapRow.Position
    $lapValue = Convert-ToDisplayValue -Value $latestLapRow.LapNumber
    $lapsTotalValue = Convert-ToDisplayValue -Value $latestSessionRow.TotalLaps
    $timeLeftValue = Convert-ToDisplayValue -Value $latestSessionRow.SessionTimeLeft
    if ($timeLeftValue -match '^\-') { $timeLeftValue = 'N/A' }

    $bestLapValue = Convert-ToLapTimeDisplay -Value $latestSessionRow.SessionBestLapTime
    $lastLapValue = Convert-ToLapTimeDisplay -Value $latestLapRow.LastLapTime

    $fuelValue = Convert-ToDisplayValue -Value $latestLapRow.Fuel
    if ($fuelValue -ne 'N/A' -and ($fuelValue -as [double])) {
        $fuelValue = '{0:F3}' -f ([math]::Round([double]$fuelValue, 3))
    }
    $fuelUnitValue = Convert-ToDisplayValue -Value $latestSessionRow.FuelUnit -Default ''
    if ($fuelUnitValue) {
        $fuelValue = "$fuelValue $fuelUnitValue"
    }

    $fuelAvgValue = Convert-ToDisplayValue -Value $latestSessionRow.Fuel_LitersPerLap
    if ($fuelAvgValue -ne 'N/A' -and ($fuelAvgValue -as [double])) {
        $fuelAvgValue = '{0:F3}' -f ([math]::Round([double]$fuelAvgValue, 3))
    }
    if ($fuelAvgValue -ne 'N/A' -and $fuelUnitValue) {
        $fuelAvgValue = "$fuelAvgValue $fuelUnitValue/Lap"
    }

    $fuelRemainingLapsValue = Convert-ToDisplayValue -Value $latestSessionRow.Fuel_RemainingLaps
    if ($fuelRemainingLapsValue -ne 'N/A' -and ($fuelRemainingLapsValue -as [double])) {
        $fuelRemainingLapsValue = '{0:F1}' -f ([math]::Round([double]$fuelRemainingLapsValue, 1))
    }

    $fuelRemainingTimeValue = Convert-ToDisplayValue -Value $latestSessionRow.Fuel_RemainingTime
    if ($fuelRemainingTimeValue -ne 'N/A' -and $fuelRemainingTimeValue -match '\.') {
        $fuelRemainingTimeValue = $fuelRemainingTimeValue -replace '\..*$', ''
    }

    $embedFields = New-Object System.Collections.Generic.List[object]
    $embedFields.Add((New-EmbedField -Name 'Timestamp' -Value $timestampValue))
    if ($latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.RuleMatched)) {
        $embedFields.Add((New-EmbedField -Name 'Rule Match' -Value $latestEvent.RuleMatched))
    }
    if ($eventDetailsLine) {
        $embedFields.Add((New-EmbedField -Name 'Details' -Value $eventDetailsLine))
    }

    $embedFields.Add((New-EmbedField -Name 'Driver' -Value $driverValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Game' -Value $gameValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Session' -Value $sessionNameForDisplay -Inline))
    $embedFields.Add((New-EmbedField -Name 'Car' -Value $carValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Car Class' -Value $carClassValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Track' -Value $trackValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Position' -Value $positionValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Lap' -Value $lapValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Laps Total' -Value $lapsTotalValue -Inline))
    $embedFields.Add((New-EmbedField -Name 'Time Left' -Value $timeLeftValue -Inline))

    if ($includeLaps) {
        $embedFields.Add((New-EmbedField -Name 'Best Lap' -Value $bestLapValue -Inline))
        $embedFields.Add((New-EmbedField -Name 'Last Lap' -Value $lastLapValue -Inline))
        $embedFields.Add((New-EmbedField -Name 'Fuel' -Value $fuelValue -Inline))
        $embedFields.Add((New-EmbedField -Name 'Fuel (AVG)' -Value $fuelAvgValue -Inline))
        $embedFields.Add((New-EmbedField -Name 'Fuel (LAPS)' -Value $fuelRemainingLapsValue -Inline))
        $embedFields.Add((New-EmbedField -Name 'Fuel (TIME)' -Value $fuelRemainingTimeValue -Inline))

        $lapRowsForSession = $lapRows
        if (-not [string]::IsNullOrWhiteSpace($sessionNameForDisplay) -and $sessionNameForDisplay -ne 'N/A') {
            $lapRowsForSession = @($lapRows | Where-Object { $_.SessionName -eq $sessionNameForDisplay })
            if ($lapRowsForSession.Count -eq 0) {
                $lapRowsForSession = $lapRows
            }
        }

        $sortedLapRows = @($lapRowsForSession | Sort-Object SessionName, @{ Expression = { [int]$_.LapNumber }; Ascending = $true })
        if ($sortedLapRows.Count -gt 0 -and $embedFields.Count -lt 25) {
            $embedFields.Add((New-EmbedField -Name 'Lap Details' -Value 'Recent laps shown below'))

            $maxLapFields = 8
            $availableLapFields = 25 - $embedFields.Count
            if ($availableLapFields -lt 1) {
                $availableLapFields = 0
            }

            $maxLapRows = [Math]::Min($maxLapFields, $availableLapFields)
            if ($maxLapRows -gt 0) {
                $start = [Math]::Max(0, $sortedLapRows.Count - $maxLapRows)
                $recentLapRows = @($sortedLapRows[$start..($sortedLapRows.Count - 1)])

                foreach ($lapRow in $recentLapRows) {
                    if ($embedFields.Count -ge 25) { break }
                    $lapNumberText = Convert-ToDisplayValue -Value $lapRow.LapNumber
                    $lapPosText = Convert-ToDisplayValue -Value $lapRow.Position
                    $lapLastText = Convert-ToLapTimeDisplay -Value $lapRow.LastLapTime
                    $lapDeltaRaw = Convert-ToDisplayValue -Value $lapRow.deltaToSessionBestLapTime
                    $lapDeltaText = $lapDeltaRaw
                    if ($lapDeltaRaw -ne 'N/A' -and ($lapDeltaRaw -as [double])) {
                        $lapDeltaValue = [double]$lapDeltaRaw
                        $lapDeltaSign = '+'
                        if ($lapDeltaValue -lt 0) {
                            $lapDeltaSign = '-'
                        }
                        $lapDeltaAbs = [math]::Abs($lapDeltaValue)
                        $lapDeltaText = '{0}{1:0.###}' -f $lapDeltaSign, $lapDeltaAbs
                    }

                    $lapFuelAvgText = Convert-ToDisplayValue -Value $lapRow.Fuel_LitersPerLap
                    if ($lapFuelAvgText -ne 'N/A' -and ($lapFuelAvgText -as [double])) {
                        $lapFuelAvgText = '{0:F3}' -f ([math]::Round([double]$lapFuelAvgText, 3))
                    }
                    if ($lapFuelAvgText -ne 'N/A' -and $fuelUnitValue) {
                        $lapFuelAvgText = "$lapFuelAvgText $fuelUnitValue/Lap"
                    }

                    $lapFieldName = "Lap $lapNumberText"
                    $lapFieldValue = "Pos: $lapPosText | Last: $lapLastText | Delta: $lapDeltaText | Fuel(AVG): $lapFuelAvgText"
                    $embedFields.Add((New-EmbedField -Name $lapFieldName -Value $lapFieldValue))
                }

                if ($sortedLapRows.Count -gt $recentLapRows.Count -and $embedFields.Count -lt 25) {
                    $shown = $recentLapRows.Count
                    $total = $sortedLapRows.Count
                    $embedFields.Add((New-EmbedField -Name 'Lap Details (truncated)' -Value "Showing $shown of $total laps"))
                }
            }
        }
    }

    $embedTitle = Convert-ToDisplayValue -Value $discordConfig.embedTitle -Default 'SimHub Status'
    if (-not [string]::IsNullOrWhiteSpace($extra)) {
        $embedTitle = $extra
    }

    $embedDescription = Convert-ToDisplayValue -Value $discordConfig.embedDescription -Default 'Latest telemetry snapshot'
    if ($latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.Rule)) {
        $embedDescription = "Rule: $($latestEvent.Rule)"
    }

    $embedColor = 16711680
    if ($discordConfig.PSObject.Properties.Name -contains 'embedColor' -and $discordConfig.embedColor -as [int]) {
        $embedColor = [int]$discordConfig.embedColor
    }

    $embedObject = @{
        title       = (Limit-DiscordText -Value $embedTitle -MaxLength 256)
        description = (Limit-DiscordText -Value $embedDescription -MaxLength 4096)
        color       = [int]$embedColor
        fields      = @($embedFields.ToArray())
        footer      = @{
            text = 'SimHub WebHook'
        }
    }

    $payload = @{
        embeds = @($embedObject)
    }
}

if ($null -eq $payload) {
    Write-Host '[DEBUG] No Discord payload generated. Skipping output.'
    exit 0
}


# Send to Discord webhook
try {
    Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 8) -ContentType 'application/json'
    Write-Host "Discord message sent: $extra"
}
catch {
    Write-Error "Failed to send Discord message: $_"
}

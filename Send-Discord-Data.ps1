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
$DataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }
$SessionCsvPath = Join-Path $DataPath 'session.csv'
$LapsCsvPath = Join-Path $DataPath 'laps.csv'
$EventsCsvPath = Join-Path $DataPath 'events.csv'
$formatCommand = Join-Path $ScriptDir 'Format-Csv-Data.ps1'
$configPath = Join-Path $ScriptDir 'Discord.json'

if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath"
}

$discordConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$hookUrl = $discordConfig.hookUrl

if ([string]::IsNullOrWhiteSpace([string]$hookUrl)) {
    Write-Host '[DEBUG] Discord webhook URL is not configured. Skipping output.'
    exit 0
}

if (-not (Test-Path $SessionCsvPath) -or -not (Test-Path $LapsCsvPath)) {
    Write-Host '[DEBUG] session.csv or laps.csv not found. Skipping Discord output.'
    exit 0
}

if (-not $SessionStart -and -not $SessionEnd -and -not $PitIn -and -not $PitOut -and -not $Status -and [string]::IsNullOrWhiteSpace($EventName)) {
    $Status = $true
}

$extra = ''
$includeLaps = $true
$eventLookupName = $null

if ($SessionStart) {
    $extra = 'Session Start'
    $eventLookupName = 'Session Started'
    $includeLaps = $false
}
elseif ($SessionEnd) {
    $extra = 'Session End'
    $eventLookupName = 'Session Stopped'
    $includeLaps = $true
}
elseif ($PitIn) {
    $extra = 'Entering Pits'
    $eventLookupName = 'Entering Pits'
    $includeLaps = $true
}
elseif ($PitOut) {
    $extra = 'Exiting Pits'
    $eventLookupName = 'Exiting Pits'
    $includeLaps = $false
}
elseif ($Status) {
    $extra = 'Status Update'
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
            if ($candidate.EventName -ne $eventLookupName) { continue }
            if (-not [string]::IsNullOrWhiteSpace($EventScope) -and $candidate.Scope -ne $EventScope) { continue }
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

function Get-BaseFormattedContent {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$IncludeLaps,
        [Parameter(Mandatory = $false)]
        [string]$Extra,
        [Parameter(Mandatory = $true)]
        [string]$FormatCommand,
        [Parameter(Mandatory = $true)]
        [string]$DataDir
    )

    if ($IncludeLaps) {
        if ([string]::IsNullOrWhiteSpace($Extra)) {
            $formatted = & $FormatCommand -IncludeLaps -DataDir $DataDir
        }
        else {
            $formatted = & $FormatCommand -Extra $Extra -IncludeLaps -DataDir $DataDir
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Extra)) {
            $formatted = & $FormatCommand -Minimal -DataDir $DataDir
        }
        else {
            $formatted = & $FormatCommand -Extra $Extra -Minimal -DataDir $DataDir
        }
    }

    if ($formatted -is [System.Array]) {
        return $formatted -join "`n"
    }

    return [string]$formatted
}

function Apply-SessionStoppedOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $false)]
        [string]$EventLookupName,
        [Parameter(Mandatory = $false)]
        $LatestEvent
    )

    if ($EventLookupName -eq 'Session Stopped' -and $LatestEvent -and -not [string]::IsNullOrWhiteSpace($LatestEvent.SessionName)) {
        # This replacement relies on Format-Csv-Data.ps1 emitting a line that starts with "Session:".
        if (-not ([regex]::IsMatch($Content, '(?m)^Session:\s+.*$'))) {
            Write-Host '[DEBUG] Session override requested, but no Session line was found in formatted content.'
            return $Content
        }

        return [regex]::Replace(
            $Content,
            '(?m)^Session:\s+.*$',
            "Session:     $($LatestEvent.SessionName)",
            1
        )
    }

    return $Content
}

function Insert-EventSummaryLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $false)]
        $LatestEvent,
        [Parameter(Mandatory = $false)]
        [string]$EventDetailsLine
    )

    if (-not $LatestEvent -and [string]::IsNullOrWhiteSpace($EventDetailsLine)) {
        return $Content
    }

    $summaryEventLines = @()
    if ($LatestEvent -and -not [string]::IsNullOrWhiteSpace($LatestEvent.RuleMatched)) {
        $summaryEventLines += "Rule Match:  $($LatestEvent.RuleMatched)"
    }
    if (-not [string]::IsNullOrWhiteSpace($EventDetailsLine)) {
        $summaryEventLines += "Details:     $EventDetailsLine"
    }

    if ($summaryEventLines.Count -eq 0) {
        return $Content
    }

    $contentLines = @($Content -split "`r?`n")
    $timestampIndex = -1
    # This insertion relies on Format-Csv-Data.ps1 emitting a line that starts with "Timestamp:".
    for ($i = 0; $i -lt $contentLines.Count; $i++) {
        if ($contentLines[$i] -match '^Timestamp:') {
            $timestampIndex = $i
            break
        }
    }

    if ($timestampIndex -lt 0) {
        Write-Host '[DEBUG] Timestamp line not found; appending event summary lines near the top of formatted content.'
        if ($contentLines.Count -le 0) {
            return ($summaryEventLines -join "`n")
        }
        if ($contentLines.Count -eq 1) {
            return (@($contentLines[0]) + $summaryEventLines) -join "`n"
        }

        return (@($contentLines[0]) + $summaryEventLines + @($contentLines[1..($contentLines.Count - 1)])) -join "`n"
    }

    $before = @()
    if ($timestampIndex -gt 0) { $before = $contentLines[0..$timestampIndex] } else { $before = @($contentLines[0]) }

    $after = @()
    if ($timestampIndex -lt ($contentLines.Count - 1)) {
        $after = $contentLines[($timestampIndex + 1)..($contentLines.Count - 1)]
    }

    return (@($before) + $summaryEventLines + @($after)) -join "`n"
}

function Remove-MarkdownCodeFenceWrapper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $lines = @($Text -split "`r?`n")

    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[0])) {
        if ($lines.Count -eq 1) { return '' }
        $lines = $lines[1..($lines.Count - 1)]
    }

    if ($lines.Count -gt 0 -and $lines[0].Trim() -eq '```') {
        if ($lines.Count -eq 1) { return '' }
        $lines = $lines[1..($lines.Count - 1)]
    }

    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
        if ($lines.Count -eq 1) { return '' }
        $lines = $lines[0..($lines.Count - 2)]
    }

    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -eq '```') {
        if ($lines.Count -eq 1) { return '' }
        $lines = $lines[0..($lines.Count - 2)]
    }

    return ($lines -join "`n")
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
    Write-Host '[DEBUG] session.csv or laps.csv has no rows. Skipping Discord output.'
    exit 0
}

$content = Get-BaseFormattedContent -IncludeLaps:$includeLaps -Extra $extra -FormatCommand $formatCommand -DataDir $DataDir
if ([string]::IsNullOrWhiteSpace($content)) {
    Write-Host '[DEBUG] No formatted content generated. Skipping Discord output.'
    exit 0
}

$content = Apply-SessionStoppedOverride -Content $content -EventLookupName $eventLookupName -LatestEvent $latestEvent
$content = Insert-EventSummaryLines -Content $content -LatestEvent $latestEvent -EventDetailsLine $eventDetailsLine

$txtAttachmentContent = Remove-MarkdownCodeFenceWrapper -Text $content
if ([string]::IsNullOrWhiteSpace($txtAttachmentContent)) {
    Write-Host '[DEBUG] TXT attachment content is empty. Skipping Discord output.'
    exit 0
}

$tempAttachmentDir = $null
$tempTextPath = $null

try {
    $tempAttachmentDir = Join-Path ([System.IO.Path]::GetTempPath()) ("simhub-discord-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $tempAttachmentDir -ItemType Directory -Force)

    $tempTextPath = Join-Path $tempAttachmentDir 'simhub-table.txt'
    Set-Content -Path $tempTextPath -Value $txtAttachmentContent -Encoding UTF8

    $txtPayload = @{
        content = "Formatted lap table TXT attached: $extra"
    }

    $payloadJson = $txtPayload | ConvertTo-Json -Depth 4 -Compress

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $txtForm = @{
            payload_json = $payloadJson
            'files[0]'   = Get-Item -Path $tempTextPath
        }

        Invoke-RestMethod -Uri $hookUrl -Method Post -Form $txtForm | Out-Null
    }
    else {
        $httpClientType = ('System.Net.Http.HttpClient' -as [type])
        if (-not $httpClientType) {
            try {
                Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
            }
            catch {
                try { [void][System.Reflection.Assembly]::Load('System.Net.Http') } catch {}
            }

            $httpClientType = ('System.Net.Http.HttpClient' -as [type])
        }

        if (-not $httpClientType) {
            Write-Warning 'System.Net.Http is unavailable in this PowerShell host. Sending JSON-only Discord payload without TXT attachment.'
            Invoke-RestMethod -Uri $hookUrl -Method Post -Body $payloadJson -ContentType 'application/json; charset=utf-8' | Out-Null
        }
        else {
            $httpClient = New-Object System.Net.Http.HttpClient
            $multipart = $null
            $response = $null

            try {
                $multipart = New-Object System.Net.Http.MultipartFormDataContent

                $payloadContent = New-Object System.Net.Http.StringContent($payloadJson, [System.Text.Encoding]::UTF8, 'application/json')
                [void]$multipart.Add($payloadContent, 'payload_json')

                $fileBytes = [System.IO.File]::ReadAllBytes($tempTextPath)
                $fileContent = New-Object System.Net.Http.ByteArrayContent (, $fileBytes)
                $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('text/plain; charset=utf-8')
                [void]$multipart.Add($fileContent, 'files[0]', 'simhub-table.txt')

                $response = $httpClient.PostAsync($hookUrl, $multipart).GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) {
                    $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    throw "Discord webhook failed: HTTP $([int]$response.StatusCode) $($response.ReasonPhrase) $responseBody"
                }
            }
            finally {
                if ($response) { $response.Dispose() }
                if ($multipart) { $multipart.Dispose() }
                $httpClient.Dispose()
            }
        }
    }

    Write-Host "Discord message sent: $extra"
}
catch {
    Write-Error "Failed to send Discord message: $_"
}
finally {
    if ($tempAttachmentDir -and (Test-Path $tempAttachmentDir)) {
        Remove-Item -Path $tempAttachmentDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

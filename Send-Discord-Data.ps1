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
    [string]$DriverName,
    [Parameter(Mandatory = $false)]
    [string]$DetailsFilePath,
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'data',
    [Parameter(Mandatory = $false)]
    [switch]$Disable,
    [Parameter(Mandatory = $false)]
    [switch]$Enable,
    [Parameter(Mandatory = $false)]
    [switch]$Debug
)

$ScriptDir = $PSScriptRoot
$DataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }
$SessionCsvPath = Join-Path $DataPath 'session.csv'
$LapsCsvPath = Join-Path $DataPath 'laps.csv'
$EventsCsvPath = Join-Path $DataPath 'events.csv'
$formatCommand = Join-Path $ScriptDir 'Format-Csv-Data.ps1'
$configPath = Join-Path $ScriptDir 'Discord.json'
$eventsConfigPath = Join-Path $ScriptDir 'Events.json'

if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath"
}


$discordConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$hookUrl = $discordConfig.hookUrl
$configDisable = $false
$configDebug = $false
if ($discordConfig.PSObject.Properties.Name -contains 'disable') { $configDisable = [bool]$discordConfig.disable }
if ($discordConfig.PSObject.Properties.Name -contains 'debug') { $configDebug = [bool]$discordConfig.debug }

# Resolve effective disable/debug flags
$effectiveDisable = $configDisable
if ($Enable) { $effectiveDisable = $false }
if ($Disable) { $effectiveDisable = $true }
$effectiveDebug = $configDebug
if ($Debug) { $effectiveDebug = $true }

if ([string]::IsNullOrWhiteSpace([string]$hookUrl)) {
    Write-Host '[DEBUG] Discord webhook URL is not configured. Skipping output.'
    exit 0
}

function Send-DiscordMultipart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InlineContent,
        [Parameter(Mandatory = $true)]
        [string]$AttachmentContent,
        [Parameter(Mandatory = $false)]
        [string]$Label = '',
        [Parameter(Mandatory = $false)]
        [bool]$Disable = $false,
        [Parameter(Mandatory = $false)]
        [bool]$Debug = $false
    )

    $tempAttachmentDir = $null
    $tempTextPath = $null

    $safeInline = $InlineContent.Trim()
    if ([string]::IsNullOrWhiteSpace($safeInline)) {
        $safeInline = 'Status Update'
    }
    $safeAttachment = $AttachmentContent
    if ([string]::IsNullOrWhiteSpace($safeAttachment)) {
        $safeAttachment = $safeInline
    }
    $txtPayload = @{
        content = '```text' + "`n" + $safeInline + "`n" + '```'
    }
    $payloadJson = $txtPayload | ConvertTo-Json -Depth 4 -Compress

    if ($Disable) {
        Write-Host "[DEBUG] Discord sending is DISABLED. Would have sent:"
        Write-Host "[DEBUG] Inline: $safeInline"
        Write-Host "[DEBUG] Attachment: $safeAttachment"
        if ($Debug) {
            Write-Host "[DEBUG] (Debug flag set)"
        }
        return
    }

    try {
        $tempAttachmentDir = Join-Path ([System.IO.Path]::GetTempPath()) ("simhub-discord-" + [guid]::NewGuid().ToString('N'))
        [void](New-Item -Path $tempAttachmentDir -ItemType Directory -Force)
        $tempTextPath = Join-Path $tempAttachmentDir 'details.txt'
        Set-Content -Path $tempTextPath -Value $safeAttachment -Encoding UTF8

        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
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
            [void]$multipart.Add($fileContent, 'files[0]', 'details.txt')
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
        if (-not [string]::IsNullOrWhiteSpace($Label)) {
            Write-Host "Discord message sent: $Label"
        }
        else {
            Write-Host 'Discord message sent.'
        }
        if ($Debug) {
            Write-Host "[DEBUG] Inline: $safeInline"
            Write-Host "[DEBUG] Attachment: $safeAttachment"
        }
    }
    finally {
        if ($tempAttachmentDir -and (Test-Path $tempAttachmentDir)) {
            Remove-Item -Path $tempAttachmentDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$transportEventMode = -not [string]::IsNullOrWhiteSpace($EventName) -and (
    -not [string]::IsNullOrWhiteSpace($DriverName) -or
    -not [string]::IsNullOrWhiteSpace($EventDetails) -or
    -not [string]::IsNullOrWhiteSpace($DetailsFilePath)
)

if ($transportEventMode) {
    $inlinePrefix = if ([string]::IsNullOrWhiteSpace($DriverName)) { '' } else { "$($DriverName): " }
    $inlineDetails = if ([string]::IsNullOrWhiteSpace($EventDetails)) { '' } else { " $($EventDetails.Trim())" }
    $inlineContent = ("$inlinePrefix$($EventName.Trim())$inlineDetails").Trim()

    $hasAttachmentFile = -not [string]::IsNullOrWhiteSpace($DetailsFilePath) -and (Test-Path $DetailsFilePath)
    if ($hasAttachmentFile) {
        $attachmentContent = Get-Content -Raw -Path $DetailsFilePath
        if ([string]::IsNullOrWhiteSpace($attachmentContent)) {
            $attachmentContent = if ([string]::IsNullOrWhiteSpace($EventDetails)) { $inlineContent } else { $EventDetails }
        }
        Send-DiscordMultipart -InlineContent $inlineContent -AttachmentContent $attachmentContent -Label $EventName -Disable:$effectiveDisable -Debug:$effectiveDebug
        exit 0
    }

    $txtPayload = @{
        content = '```text' + "`n" + $inlineContent + "`n" + '```'
    }
    $payloadJson = $txtPayload | ConvertTo-Json -Depth 4 -Compress
    if ($effectiveDisable) {
        Write-Host "[DEBUG] Discord sending is DISABLED. Would have sent:"
        Write-Host "[DEBUG] Inline: $inlineContent"
        if ($effectiveDebug) {
            Write-Host "[DEBUG] (Debug flag set)"
        }
        exit 0
    }
    Invoke-RestMethod -Uri $hookUrl -Method Post -Body $payloadJson -ContentType 'application/json; charset=utf-8' | Out-Null
    Write-Host "Discord message sent: $EventName"
    if ($effectiveDebug) {
        Write-Host "[DEBUG] Inline: $inlineContent"
    }
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
        [Parameter(Mandatory = $false)]
        [string]$LapSessionFilter,
        [Parameter(Mandatory = $true)]
        [string]$FormatCommand,
        [Parameter(Mandatory = $true)]
        [string]$DataDir
    )

    if ($IncludeLaps) {
        if ([string]::IsNullOrWhiteSpace($Extra)) {
            $formatted = & $FormatCommand -IncludeLaps -LapSessionName $LapSessionFilter -DataDir $DataDir
        }
        else {
            $formatted = & $FormatCommand -Extra $Extra -IncludeLaps -LapSessionName $LapSessionFilter -DataDir $DataDir
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

function Get-QualificationSessionNames {
    param(
        [Parameter(Mandatory = $false)]
        [string]$EventsConfigPath
    )

    $defaultNames = @('Qualify', 'Qualification', 'Lone Qualify')
    if (-not (Test-Path $EventsConfigPath)) {
        return $defaultNames
    }

    try {
        $configJson = Get-Content -Raw -Path $EventsConfigPath | ConvertFrom-Json
        if (-not $configJson -or -not $configJson.Events) {
            return $defaultNames
        }

        $qualEvent = $configJson.Events | Where-Object { $_.EventName -eq 'Qualification Complete' } | Select-Object -First 1
        if ($qualEvent -and $qualEvent.RuleSettings -and $qualEvent.RuleSettings.QualificationSessionNames) {
            $names = @($qualEvent.RuleSettings.QualificationSessionNames | ForEach-Object { [string]$_ })
            if ($names.Count -gt 0) {
                return $names
            }
        }
    }
    catch {
        Write-Host "[DEBUG] Failed reading qualification session names from Events.json: $_"
    }

    return $defaultNames
}

function Test-SessionNameInList {
    param(
        [Parameter(Mandatory = $false)]
        [string]$SessionName,
        [Parameter(Mandatory = $false)]
        [array]$AllowedSessionNames
    )

    if ([string]::IsNullOrWhiteSpace($SessionName) -or $null -eq $AllowedSessionNames -or $AllowedSessionNames.Count -eq 0) {
        return $false
    }

    $candidate = $SessionName.Trim()
    foreach ($allowed in $AllowedSessionNames) {
        $allowedText = [string]$allowed
        if ([string]::IsNullOrWhiteSpace($allowedText)) {
            continue
        }

        if ([string]::Equals($candidate, $allowedText.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
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
    
    # Combine Rule Match and Details into single line
    $ruleMatch = if ($LatestEvent -and -not [string]::IsNullOrWhiteSpace($LatestEvent.RuleMatched)) { $LatestEvent.RuleMatched } else { "" }
    $details = if (-not [string]::IsNullOrWhiteSpace($EventDetailsLine)) { $EventDetailsLine } else { "" }
    
    if (-not [string]::IsNullOrWhiteSpace($ruleMatch) -or -not [string]::IsNullOrWhiteSpace($details)) {
        if (-not [string]::IsNullOrWhiteSpace($ruleMatch) -and -not [string]::IsNullOrWhiteSpace($details)) {
            $summaryEventLines += "Details:     $ruleMatch ($details)"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ruleMatch)) {
            $summaryEventLines += "Details:     $ruleMatch"
        }
        else {
            $summaryEventLines += "Details:     $details"
        }
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

# Build structured header line from live CSV data
$hDriver = [string]$latestSessionRow.Driver
$hGame = [string]$latestSessionRow.GameName
$hCar = [string]$latestSessionRow.Car
$hTrack = [string]$latestSessionRow.Track
$hSession = [string]$latestLapRow.SessionName
$hSessionUpper = $hSession.ToUpper()
$hSessionDisplay = if ($hSessionUpper -like '*QUAL*') { 'QUAL' } elseif ($hSessionUpper -like '*PRAC*' -or $hSessionUpper -like '*PRACTICE*') { 'PRAC' } else { $hSession }
$hLap = [string]$latestLapRow.LapNumber
$hPosition = [string]$latestLapRow.Position
$hStint = [string]$latestLapRow.LapsSinceLastPit

# Reusable parenthesized position block
$hPosBlock = "($hSessionDisplay L$hLap P$hPosition)"

$formattedHeader = if ($PitOut) {
    "$($hDriver): EXITING PITS $hPosBlock [$hGame, $hCar, $hTrack]"
}
elseif ($PitIn) {
    "$($hDriver): ENTERING PITS $hPosBlock [$hGame, $hCar, $hTrack]"
}
elseif ($SessionStart) {
    "$($hDriver): SESSION STARTING $hPosBlock [$hGame, $hCar, $hTrack]"
}
elseif ($SessionEnd) {
    "$($hDriver): SESSION COMPLETED $hPosBlock [$hGame, $hCar, $hTrack]"
}
else {
    $hEventNameRaw = if (-not [string]::IsNullOrWhiteSpace($EventName)) { $EventName } else { 'Status Update' }
    $hEventName = $hEventNameRaw.ToUpper()
    # Abbreviate QUALIFICATION -> QUAL in the event name
    $hEventNameShort = $hEventName -replace 'QUALIFICATION', 'QUAL'

    if ([string]::Equals($hEventNameShort, 'FUEL WARNING', [System.StringComparison]::OrdinalIgnoreCase)) {
        $fuelShortDetails = if (-not [string]::IsNullOrWhiteSpace($eventDetailsLine)) { $eventDetailsLine } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($fuelShortDetails)) {
            $fuelShortDetails = [regex]::Replace($fuelShortDetails, '([0-9]+(?:\.[0-9]+)?)\s+laps?', '$1L', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $fuelShortDetails = [regex]::Replace($fuelShortDetails, '\band\b', ' ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $fuelShortDetails = [regex]::Replace($fuelShortDetails, '([0-9]+)\s+seconds?', '$1s', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $fuelShortDetails = [regex]::Replace($fuelShortDetails, 'fuel\s+remaining', 'remaining', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $fuelShortDetails = [regex]::Replace($fuelShortDetails, '\s+', ' ')
            $fuelShortDetails = $fuelShortDetails.Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($fuelShortDetails)) {
            "$($hDriver): FUEL WARNING $fuelShortDetails $hPosBlock [$hGame, $hCar, $hTrack]"
        }
        else {
            "$($hDriver): FUEL WARNING $hPosBlock [$hGame, $hCar, $hTrack]"
        }
    }
    elseif ($hEventNameShort -like '*QUAL*' -or $hEventNameShort -like '*RACE*') {
        # QUAL/RACE events: no session/lap/position in header
        "$($hDriver): $hEventNameShort [$hGame, $hCar, $hTrack]"
    }
    else {
        $hDetails = if (-not [string]::IsNullOrWhiteSpace($eventDetailsLine)) { $eventDetailsLine } else { '' }
        if ([string]::IsNullOrWhiteSpace($hDetails)) {
            "$($hDriver): $hEventNameShort $hPosBlock [$hGame, $hCar, $hTrack]"
        }
        else {
            "$($hDriver): $hEventNameShort $hDetails $hPosBlock [$hGame, $hCar, $hTrack]"
        }
    }
}

$lapSessionFilter = $null
if ($eventLookupName -eq 'Race Complete') {
    $lapSessionFilter = 'RACE'
}
elseif ($eventLookupName -eq 'Qualification Complete') {
    $qualificationSessionNames = Get-QualificationSessionNames -EventsConfigPath $eventsConfigPath

    if ($latestEvent -and (Test-SessionNameInList -SessionName $latestEvent.SessionName -AllowedSessionNames $qualificationSessionNames)) {
        $lapSessionFilter = [string]$latestEvent.SessionName
    }
    else {
        for ($idx = $lapRows.Count - 1; $idx -ge 0; $idx--) {
            $candidateSession = [string]$lapRows[$idx].SessionName
            if (Test-SessionNameInList -SessionName $candidateSession -AllowedSessionNames $qualificationSessionNames) {
                $lapSessionFilter = $candidateSession
                break
            }
        }
    }
}

$content = Get-BaseFormattedContent -IncludeLaps:$includeLaps -Extra $formattedHeader -LapSessionFilter $lapSessionFilter -FormatCommand $formatCommand -DataDir $DataDir
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
    # Extract header line for payload, use rest for attachment
    $contentLines = @($txtAttachmentContent -split "`r?`n", 2)
    $headerLine = if ($contentLines.Count -gt 0) { $contentLines[0] } else { "" }
    $attachmentBody = if ($contentLines.Count -gt 1) { $contentLines[1] } else { "" }
    $inlineContent = $headerLine.Trim()
    if ([string]::IsNullOrWhiteSpace($inlineContent)) {
        $inlineContent = $txtAttachmentContent.TrimEnd()
    }

    $txtPayload = @{
        content = '```text' + "`n" + $inlineContent + "`n" + '```'
    }

    $payloadJson = $txtPayload | ConvertTo-Json -Depth 4 -Compress

    if ($effectiveDisable) {
        Write-Host "[DEBUG] Discord sending is DISABLED. Would have sent:"
        Write-Host "[DEBUG] Inline: $inlineContent"
        Write-Host "[DEBUG] Attachment: $attachmentContent"
        if ($effectiveDebug) {
            Write-Host "[DEBUG] (Debug flag set)"
        }
        return
    }

    $tempAttachmentDir = Join-Path ([System.IO.Path]::GetTempPath()) ("simhub-discord-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $tempAttachmentDir -ItemType Directory -Force)

    $tempTextPath = Join-Path $tempAttachmentDir 'details.txt'
    $attachmentContent = if ([string]::IsNullOrWhiteSpace($attachmentBody)) { $txtAttachmentContent } else { $attachmentBody }
    Set-Content -Path $tempTextPath -Value $attachmentContent -Encoding UTF8

    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
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
        [void]$multipart.Add($fileContent, 'files[0]', 'details.txt')

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
    Write-Host "Discord message sent: $extra"
    if ($effectiveDebug) {
        Write-Host "[DEBUG] Inline: $inlineContent"
        Write-Host "[DEBUG] Attachment: $attachmentContent"
    }
}
catch {
    Write-Error "Failed to send Discord message: $_"
}
finally {
    if ($tempAttachmentDir -and (Test-Path $tempAttachmentDir)) {
        Remove-Item -Path $tempAttachmentDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

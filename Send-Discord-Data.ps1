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
#   ./Send-Discord-Data.ps1 -IncludeCsvAttachment
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
    [switch]$IncludeCsvAttachment,
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
            $formatted = & $FormatCommand -NoFuelAndLaps -DataDir $DataDir
        }
        else {
            $formatted = & $FormatCommand -Extra $Extra -NoFuelAndLaps -DataDir $DataDir
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
    for ($i = 0; $i -lt $contentLines.Count; $i++) {
        if ($contentLines[$i] -match '^Timestamp:') {
            $timestampIndex = $i
            break
        }
    }

    if ($timestampIndex -lt 0) {
        return $Content
    }

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

    return (@($before) + $summaryEventLines + @($after)) -join "`n"
}

function Truncate-DiscordContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $false)]
        [int]$MaxLength = 2000
    )

    if ($Content.Length -le $MaxLength) {
        return $Content
    }

    $suffix = "`n`n[truncated to fit Discord message limit]"
    $keepLength = $MaxLength - $suffix.Length
    if ($keepLength -lt 1) {
        $keepLength = $MaxLength
        $suffix = ""
    }

    return $Content.Substring(0, $keepLength) + $suffix
}

function Convert-TextToPng {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $false)]
        [int]$MaxLines = 250
    )

    try {
        Add-Type -AssemblyName System.Drawing
    }
    catch {
        Write-Host "[DEBUG] Failed to load System.Drawing: $_"
        return $false
    }

    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt $MaxLines) {
        $lines = @($lines[0..($MaxLines - 2)] + '[truncated to fit image height]')
    }

    $font = $null
    $measureBitmap = $null
    $measureGraphics = $null
    $bitmap = $null
    $graphics = $null
    $brush = $null

    try {
        $font = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $measureBitmap = New-Object System.Drawing.Bitmap(1, 1)
        $measureGraphics = [System.Drawing.Graphics]::FromImage($measureBitmap)

        $maxWidth = 0.0
        foreach ($line in $lines) {
            $size = $measureGraphics.MeasureString([string]$line, $font)
            if ($size.Width -gt $maxWidth) {
                $maxWidth = $size.Width
            }
        }

        $lineHeight = [Math]::Ceiling($measureGraphics.MeasureString('Ag', $font).Height) + 2
        $padding = 12

        $width = [Math]::Max(320, [int][Math]::Ceiling($maxWidth) + ($padding * 2))
        $height = [Math]::Max(120, ($lineHeight * $lines.Count) + ($padding * 2))
        if ($width -gt 4000) { $width = 4000 }
        if ($height -gt 4000) { $height = 4000 }

        $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $graphics.Clear([System.Drawing.Color]::White)

        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
        $y = $padding
        foreach ($line in $lines) {
            $graphics.DrawString([string]$line, $font, $brush, $padding, $y)
            $y += $lineHeight
            if ($y -ge ($height - $padding)) {
                break
            }
        }

        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
        return $true
    }
    catch {
        Write-Host "[DEBUG] Failed to render PNG table: $_"
        return $false
    }
    finally {
        if ($brush) { $brush.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($measureGraphics) { $measureGraphics.Dispose() }
        if ($measureBitmap) { $measureBitmap.Dispose() }
        if ($font) { $font.Dispose() }
    }
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
    Write-Host "[DEBUG] session.csv or laps.csv has no rows. Skipping Discord output."
    exit 0
}

# For Session Stopped output, display the stopped (previous) session name from events.csv.
$sessionNameForDisplay = Convert-ToDisplayValue -Value $latestSessionRow.SessionType
if ($eventLookupName -eq 'Session Stopped' -and $latestEvent -and -not [string]::IsNullOrWhiteSpace($latestEvent.SessionName)) {
    $sessionNameForDisplay = $latestEvent.SessionName
}

$fullFormattedContent = Get-BaseFormattedContent -IncludeLaps:$includeLaps -Extra $extra -FormatCommand $formatCommand -DataDir $DataDir
if ([string]::IsNullOrWhiteSpace($fullFormattedContent)) {
    Write-Host "[DEBUG] No formatted content generated. Skipping Discord output."
    exit 0
}

$fullFormattedContent = Apply-SessionStoppedOverride -Content $fullFormattedContent -EventLookupName $eventLookupName -LatestEvent $latestEvent
$fullFormattedContent = Insert-EventSummaryLines -Content $fullFormattedContent -LatestEvent $latestEvent -EventDetailsLine $eventDetailsLine

$useEmbedMode = -not $UseTextMode
$payload = $null

if (-not $useEmbedMode) {
    # Legacy text mode path.
    $content = Truncate-DiscordContent -Content $fullFormattedContent -MaxLength 2000

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
        $embedFields.Add((New-EmbedField -Name 'Fuel (LAPS)' -Value $fuelRemainingLapsValue -Inline))
        $embedFields.Add((New-EmbedField -Name 'Fuel (TIME)' -Value $fuelRemainingTimeValue -Inline))
        $embedFields.Add((New-EmbedField -Name 'Fuel (AVG)' -Value $fuelAvgValue -Inline))
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


$tempAttachmentDir = $null
$tempTextPath = $null
$tempCsvPath = $null
$tempPngPath = $null

# Send to Discord webhook
try {
    if (-not $useEmbedMode) {
        Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 8) -ContentType 'application/json'
    }
    else {
        $tempAttachmentDir = Join-Path ([System.IO.Path]::GetTempPath()) ("simhub-discord-" + [guid]::NewGuid().ToString('N'))
        [void](New-Item -Path $tempAttachmentDir -ItemType Directory -Force)

        $tempTextPath = Join-Path $tempAttachmentDir 'simhub-table.txt'
        $tempCsvPath = Join-Path $tempAttachmentDir 'simhub-laps.csv'
        $tempPngPath = Join-Path $tempAttachmentDir 'simhub-table.png'

        $txtAttachmentContent = Remove-MarkdownCodeFenceWrapper -Text $fullFormattedContent
        Set-Content -Path $tempTextPath -Value $txtAttachmentContent -Encoding UTF8
        Copy-Item -Path $LapsCsvPath -Destination $tempCsvPath -Force

        $pngRendered = Convert-TextToPng -Text $txtAttachmentContent -OutputPath $tempPngPath
        if (-not $pngRendered -or -not (Test-Path $tempPngPath)) {
            try {
                Add-Type -AssemblyName System.Drawing
                $fallbackLines = @($txtAttachmentContent -split "`r?`n")
                if ($fallbackLines.Count -gt 180) {
                    $fallbackLines = @($fallbackLines[0..178] + '[truncated to fit image height]')
                }

                $fallbackBitmap = New-Object System.Drawing.Bitmap(1800, 2200, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $fallbackGraphics = [System.Drawing.Graphics]::FromImage($fallbackBitmap)
                $fallbackGraphics.Clear([System.Drawing.Color]::White)
                $fallbackFont = New-Object System.Drawing.Font('Consolas', 10)
                $fallbackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
                $y = 10
                $lineHeight = 12
                foreach ($line in $fallbackLines) {
                    $fallbackGraphics.DrawString([string]$line, $fallbackFont, $fallbackBrush, 10, $y)
                    $y += $lineHeight
                    if ($y -gt 2180) {
                        break
                    }
                }
                $fallbackBitmap.Save($tempPngPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $fallbackBrush.Dispose()
                $fallbackFont.Dispose()
                $fallbackGraphics.Dispose()
                $fallbackBitmap.Dispose()
                $pngRendered = (Test-Path $tempPngPath)
            }
            catch {
                Write-Host "[DEBUG] PNG fallback render failed: $_"
                $pngRendered = $false
            }
        }

        if (-not $pngRendered -or -not (Test-Path $tempPngPath)) {
            try {
                Add-Type -AssemblyName System.Drawing
                $finalBitmap = New-Object System.Drawing.Bitmap(800, 600, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $finalGraphics = [System.Drawing.Graphics]::FromImage($finalBitmap)
                $finalGraphics.Clear([System.Drawing.Color]::White)
                $finalFont = New-Object System.Drawing.Font('Consolas', 10)
                $finalBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
                $finalLines = @($txtAttachmentContent -split "`r?`n")
                if ($finalLines.Count -gt 45) {
                    $finalLines = @($finalLines[0..43] + '[truncated to fit fallback image]')
                }
                $finalY = 10
                foreach ($line in $finalLines) {
                    $finalGraphics.DrawString([string]$line, $finalFont, $finalBrush, 10, $finalY)
                    $finalY += 12
                    if ($finalY -gt 580) {
                        break
                    }
                }
                $finalBitmap.Save($tempPngPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $finalBrush.Dispose()
                $finalFont.Dispose()
                $finalGraphics.Dispose()
                $finalBitmap.Dispose()
                $pngRendered = (Test-Path $tempPngPath)
            }
            catch {
                Write-Host "[DEBUG] Final PNG render failed: $_"
                $pngRendered = $false
            }
        }

        if ($pngRendered -and (Test-Path $tempPngPath) -and $payload.ContainsKey('embeds') -and $payload.embeds.Count -gt 0) {
            $payload.embeds[0].image = @{ url = 'attachment://simhub-table.png' }
        }

        $embedForm = @{
            payload_json = ($payload | ConvertTo-Json -Depth 8)
        }

        if ($pngRendered -and (Test-Path $tempPngPath)) {
            $embedForm['files[0]'] = Get-Item -Path $tempPngPath
        }

        Invoke-RestMethod -Uri $hookUrl -Method Post -Form $embedForm

        if ($IncludeCsvAttachment) {
            # CSV attachment is optional and disabled by default.
            $csvPayload = @{
                content = "Raw lap data CSV attached: $extra"
            }
            $csvForm = @{
                payload_json = ($csvPayload | ConvertTo-Json -Depth 4)
                'files[0]'   = Get-Item -Path $tempCsvPath
            }
            Invoke-RestMethod -Uri $hookUrl -Method Post -Form $csvForm
        }

        $txtPayload = @{
            content = "Formatted lap table TXT attached: $extra"
        }
        $txtForm = @{
            payload_json = ($txtPayload | ConvertTo-Json -Depth 4)
            'files[0]'   = Get-Item -Path $tempTextPath
        }
        Invoke-RestMethod -Uri $hookUrl -Method Post -Form $txtForm
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

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
    if ([string]::IsNullOrWhiteSpace($extra)) {
        $formatted = & $formatCommand
    }
    else {
        $formatted = & $formatCommand -Extra $extra
    }
}
if ($formatted -is [System.Array]) {
    $content = $formatted -join "`n"
}
else {
    $content = $formatted
}

# Build payload
$payload = [PSCustomObject]@{ content = $content }
$useEmbed = $false
if ($discordConfig.PSObject.Properties.Name -contains 'useEmbeds') {
    $useEmbed = [bool]$discordConfig.useEmbeds
}

if ($useEmbed) {
    $embed = [PSCustomObject]@{
        title       = ($discordConfig.embedTitle -or 'SimHub status')
        description = ($discordConfig.embedDescription -or $content)
        color       = [int]($discordConfig.embedColor -or 16711680)
        fields      = @([PSCustomObject]@{ name = $extra; value = $content; inline = $false })
    }
    $payload = [PSCustomObject]@{ embeds = @($embed) }
}

# Send to Discord webhook
try {
    Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 6) -ContentType 'application/json'
    Write-Host "Discord message sent: $extra"
}
catch {
    Write-Error "Failed to send Discord message: $_"
}

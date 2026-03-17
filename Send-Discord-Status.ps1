####################################################
# Send SimHub status message to Discord via webhook
####################################################

param(
    [Parameter(Mandatory = $false)]
    [string]$Extra
)

# obtain current properties using helper script
# this script returns JSON text
$json = & "$PSScriptRoot\Get-SimHub-Data.ps1"

# format the SimHub CSV into markdown text for Discord
$formatCommand = "$PSScriptRoot\Format-Csv-Data.ps1"
if ([string]::IsNullOrWhiteSpace($Extra)) {
    $formatted = & $formatCommand
}
else {
    $formatted = & $formatCommand -Extra $Extra
}
if ($formatted -is [System.Array]) {
    $content = $formatted -join "`n"
}
else {
    $content = $formatted
}

# read webhook configuration from external JSON file in the same directory
$configPath = Join-Path -Path $PSScriptRoot -ChildPath 'Discord.json'
if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath"
}
$discordConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$hookUrl = $discordConfig.hookUrl

# Build payload with fallback to embeds if configured
$payload = [PSCustomObject]@{
    content = $content
}

$useEmbed = $false
if ($discordConfig.PSObject.Properties.Name -contains 'useEmbeds') {
    $useEmbed = [bool]$discordConfig.useEmbeds
}

if ($useEmbed) {
    # Build a nicely formatted embed message from SimHub JSON
    try {
        $data = $json | ConvertFrom-Json -ErrorAction Stop
        $fields = @()
        foreach ($prop in $data.PSObject.Properties) {
            $value = $prop.Value
            if ($null -eq $value) { continue }
            if ($value -is [System.Management.Automation.PSCustomObject] -or $value -is [System.Collections.IDictionary]) {
                foreach ($child in $value.PSObject.Properties) {
                    $fields += [PSCustomObject]@{ name = "$($prop.Name).$($child.Name)"; value = "$($child.Value)"; inline = $true }
                }
            }
            else {
                $fields += [PSCustomObject]@{ name = $prop.Name; value = "$value"; inline = $true }
            }
        }

        $embed = [PSCustomObject]@{
            title       = ($discordConfig.embedTitle -or 'SimHub status')
            description = ($discordConfig.embedDescription -or $content)
            color       = [int]($discordConfig.embedColor -or 16711680)
            fields      = $fields
        }

        $payload = [PSCustomObject]@{
            embeds = @($embed)
        }
    }
    catch {
        # If embed build fails, fallback to plain content
        Write-Warning "Could not build embed fallback: $_. Sending plain content instead."
    }
}

# Convert the payload to JSON and send the POST request
Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 5) -ContentType 'application/json'


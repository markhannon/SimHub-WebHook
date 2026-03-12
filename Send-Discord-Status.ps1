####################################################
# Send SimHub status message to Discord via webhook
####################################################

# obtain current properties using helper script
# this script returns a JSON object representing the values
$json = & "$PSScriptRoot\Get-SimHub-Data.ps1"

# use the JSON text as the message content (wrap in code block for readability)
$content = @"
```
$json
```
"@


# read webhook configuration from external JSON file in the same directory
$configPath = Join-Path -Path $PSScriptRoot -ChildPath 'Discord.json'
if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath"
}
$discordConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$hookUrl = $discordConfig.hookUrl

# (content variable set earlier from Get-SimHub-Data output)
# Create the payload as a PowerShell custom object
$payload = [PSCustomObject]@{
    content = $content
}

# Convert the payload to JSON and send the POST request
Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json) -ContentType 'application/json'


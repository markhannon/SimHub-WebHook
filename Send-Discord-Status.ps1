####################################################
# Send SimHub status message to Discord via webhook
####################################################

# obtain current properties using helper script
# this script returns a JSON object representing the values
$json = & "$PSScriptRoot\Get-SimHub-Data.ps1"

# use the JSON text as the message content (wrap in code block for readability)
$content = @"
```json
$json
```
"@


# Store your Discord webhook URL in a variable
$hookUrl = "https://discord.com/api/webhooks/1481496818838933615/OtnHTZ3Sji5U8UWRST6jT0TirIe-8FFBpKbYE96KgX54cAIkMqf9VdrW_pWajLuUrGeR"

# (content variable set earlier from Get-SimHub-Data output)
# Create the payload as a PowerShell custom object
$payload = [PSCustomObject]@{
    content = $content
}

# Convert the payload to JSON and send the POST request
Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json) -ContentType 'application/json'


# Store your Discord webhook URL in a variable
$hookUrl = "https://discord.com/api/webhooks/1481496818838933615/OtnHTZ3Sji5U8UWRST6jT0TirIe-8FFBpKbYE96KgX54cAIkMqf9VdrW_pWajLuUrGeR"

# Define the message content in a here-string
$content = @"
Hello from PowerShell!
This message has multiple lines.
"@

# Create the payload as a PowerShell custom object
$payload = [PSCustomObject]@{
    content = $content
}

# Convert the payload to JSON and send the POST request
Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json) -ContentType 'application/json'


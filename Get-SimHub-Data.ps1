########################################################
# Fetch SimHub status via SimHub Property Server plugin
########################################################
$simhubHost = "127.0.0.1"
$simhubPort = 18082

# properties to capture
$properties = @(
    'dcp.GameName',
    'dcp.gd.TrackName',
    'dcp.gd.CarModel',
    'dcp.gd.PlayerName',
    'dcp.gd.SessionTypeName',
    'dcp.gd.SessionTimeLeft',
    'dcp.gd.SessionTimeElapsed'
)

# build subscribe commands dynamically
$commands = $properties | ForEach-Object { "subscribe $_" }
$commands += 'disconnect'

# Connect and initialize stream
$socket = New-Object System.Net.Sockets.TcpClient($simhubHost, $simhubPort)
$stream = $socket.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

# Function to read output
function Read-TelnetOutput {
    Start-Sleep -Milliseconds 500 # buffer time
    $output = ''
    while ($stream.DataAvailable) {
        $buffer = New-Object byte[] 1024
        $read = $stream.Read($buffer, 0, 1024)
        $output += [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    }
    return $output
}

# Collect property values
$propValues = @{}

foreach ($command in $commands) {
    Write-Host "Sending: $command" -ForegroundColor Cyan
    $writer.WriteLine($command)
    $writer.Flush()

    $response = Read-TelnetOutput
    if ($response) {
        Write-Host "Received response:`n$response" -ForegroundColor Yellow
        $response -split "`n" | ForEach-Object {
            $line = $_.Trim()
            # ignore header line
            if ($line -like 'SimHub*') { return }
            # parse lines like: Property dcp.GameName string IRacing
            if ($line -match '^Property\s+(?<key>\S+)\s+\S+\s+(?<val>.+)$') {
                $val = $matches.val
                if ($val -eq '(null)') { $val = $null }
                $propValues[$matches.key] = $val
            }
        }
    }
}

# Close connections
$writer.Close()
$socket.Close()

# Output JSON suitable for ingestion
if ($propValues.Count -eq 0) {
    Write-Warning "No property values were captured. Check that SimHub Property Server is running and properties are subscribed."
}
$propValues | ConvertTo-Json | Write-Output


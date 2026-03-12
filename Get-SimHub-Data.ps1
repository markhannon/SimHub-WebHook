########################################################
# Fetch SimHub status via SimHub Property Server plugin
########################################################
# support common parameters (e.g. -Debug) for conditional logging
[CmdletBinding()]
param()

# read host/port configuration from external JSON
$configPath = Join-Path -Path $PSScriptRoot -ChildPath 'Simhub.json'
if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath"
}
$simhubConfig = Get-Content -Raw -Path $configPath | ConvertFrom-Json
$simhubHost = $simhubConfig.simhubHost
$simhubPort = $simhubConfig.simhubPort

# load list of properties to capture from external JSON file
$propsConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'Properties.json'
if (-not (Test-Path $propsConfigPath)) {
    throw "Properties configuration file not found: $propsConfigPath"
}
$propsConfig = Get-Content -Raw -Path $propsConfigPath | ConvertFrom-Json
$properties = $propsConfig.properties

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
    Write-Debug "Sending: $command"
    $writer.WriteLine($command)
    $writer.Flush()

    $response = Read-TelnetOutput
    if ($response) {
        Write-Debug "Received response:`n$response"
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

# Output JSON suitable for ingestion - remove SimHub prefixes from keys
if ($propValues.Count -eq 0) {
    Write-Warning "No property values were captured. Check that SimHub Property Server is running and properties are subscribed."
}

# strip leading "dcp." or "dcp.gd." from property names in the output
$cleaned = @{}
foreach ($k in $propValues.Keys) {
    $newKey = $k -replace '^(dcp\.gd\.|dcp\.)',''
    $cleaned[$newKey] = $propValues[$k]
}

$cleaned | ConvertTo-Json | Write-Output


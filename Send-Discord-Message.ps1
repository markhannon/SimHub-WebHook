####################################################
# Send a custom Discord message using latest daemon DriverName
#
# Wrapper over Send-Discord-Data.ps1 transport mode.
# - Reads DriverName from _daemon_state.json (daemon state only)
# - Prepends "DriverName: " to EventName
# - Forwards DataDir/EventName/EventDetails to sender
####################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'data',
    [Parameter(Mandatory = $true)]
    [string]$EventName,
    [Parameter(Mandatory = $false)]
    [string]$EventDetails
)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$DataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }
$daemonStatePath = Join-Path $DataPath '_daemon_state.json'
$sendDiscordDataScript = Join-Path $ScriptDir 'Send-Discord-Data.ps1'

if (-not (Test-Path $sendDiscordDataScript)) {
    throw "Send-Discord-Data.ps1 not found: $sendDiscordDataScript"
}

$driverName = ''
if (Test-Path $daemonStatePath) {
    try {
        $daemonState = Get-Content -Raw -Path $daemonStatePath | ConvertFrom-Json
        if ($daemonState -and $daemonState.properties) {
            $propertyMap = $daemonState.properties
            if ($propertyMap.PSObject.Properties['dcp.gd.PlayerName']) {
                $driverName = [string]$propertyMap.'dcp.gd.PlayerName'
            }
            elseif ($propertyMap.PSObject.Properties['dcp.PlayerName']) {
                $driverName = [string]$propertyMap.'dcp.PlayerName'
            }
            elseif ($propertyMap.PSObject.Properties['PlayerName']) {
                $driverName = [string]$propertyMap.'PlayerName'
            }
        }
    }
    catch {
        Write-Host "[DEBUG] Failed to read daemon state from ${daemonStatePath}: $_"
    }
}

$prefixedEventName = if ([string]::IsNullOrWhiteSpace($driverName)) {
    [string]$EventName
}
else {
    "$($driverName): $([string]$EventName)"
}

& $sendDiscordDataScript -DataDir $DataDir -EventName $prefixedEventName -EventDetails $EventDetails
exit $LASTEXITCODE

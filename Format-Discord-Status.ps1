<#
.SYNOPSIS
Formats SimHub JSON data as Discord-friendly markdown text.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline=$true)]
    [object]$InputObject,
    [Parameter(Mandatory=$false)]
    [string]$InputFile
)

begin {
    $lines = @()
}

process {
    if ($InputFile) { return }
    if ($null -eq $InputObject) { return }
    if ($InputObject -is [string]) {
        $lines += $InputObject
    } else {
        $lines += ($InputObject | ConvertTo-Json -Compress)
    }
}

end {
    if ($InputFile) {
        if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile" }
        $raw = Get-Content -Raw -Path $InputFile
    } elseif ($lines.Count -gt 0) {
        $raw = $lines -join "`n"
    } else {
        $raw = [Console]::In.ReadToEnd()
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No JSON input provided." }

    try {
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to parse JSON input. Ensure valid JSON. $_"
    }

    $playerName = $null
    if ($data.PSObject.Properties.Name -contains 'PlayerName') { $playerName = $data.PlayerName }
    if (-not $playerName -and $data.PSObject.Properties.Name -contains 'gd') {
        $gd = $data.gd
        if ($gd -and $gd.PSObject.Properties.Name -contains 'PlayerName') { $playerName = $gd.PlayerName }
    }
    if (-not $playerName) { $playerName = '<Unknown PlayerName>' }

    $gameName = $data.GameName
    if (-not $gameName) { $gameName = '<Unknown GameName>' }

    $sessionName = $data.SessionName
    if (-not $sessionName -and $data.PSObject.Properties.Name -contains 'SessionTypeName') { $sessionName = $data.SessionTypeName }
    if (-not $sessionName) { $sessionName = '<Unknown SessionName>' }

    $carName = $data.CarName
    if (-not $carName -and $data.PSObject.Properties.Name -contains 'CarModel') { $carName = $data.CarModel }
    if (-not $carName) { $carName = '<Unknown CarName>' }

    $trackName = $data.TrackName
    if (-not $trackName) { $trackName = '<Unknown TrackName>' }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "${timestamp}: SimHub $playerName"

    $entries = @{}
    foreach ($prop in $data.PSObject.Properties) {
        $entries[$prop.Name] = $prop.Value
    }

    $nested = @()
    foreach ($k in $entries.Keys) {
        $v = $entries[$k]
        if ($v -is [System.Collections.IDictionary] -or $v -is [System.Management.Automation.PSCustomObject]) {
            foreach ($child in $v.PSObject.Properties) {
                $entries["$k.$($child.Name)"] = $child.Value
            }
            $nested += $k
        }
    }
    foreach ($k in $nested) { $entries.Remove($k) | Out-Null }

    $priority = @('PlayerName','GameName','TrackName','CarModel','SessionTypeName')
    $rows = @()

    foreach ($p in $priority) {
        if ($entries.ContainsKey($p)) {
            $v = $entries[$p]
            if ($null -eq $v) { $v = '' }
            $rows += [PSCustomObject]@{ Key = $p; Value = $v.ToString() }
            $entries.Remove($p) | Out-Null
        }
    }

    foreach ($k in ($entries.Keys | Sort-Object)) {
        $v = $entries[$k]
        if ($null -eq $v) { $v = '' }
        $rows += [PSCustomObject]@{ Key = $k; Value = $v.ToString() }
    }

    $keyWidth = 3
    $valueWidth = 5
    if ($rows.Count -gt 0) {
        $keyWidth = ($rows | ForEach-Object { ($_.Key).Length } | Measure-Object -Maximum).Maximum
        if (-not $keyWidth -or $keyWidth -lt 3) { $keyWidth = 3 }
        $valueWidth = ($rows | ForEach-Object { ($_.Value).Length } | Measure-Object -Maximum).Maximum
        if (-not $valueWidth -or $valueWidth -lt 5) { $valueWidth = 5 }
    }

    Write-Output '```'
    Write-Output (('Key'.PadRight($keyWidth)) + ' | ' + ('Value'.PadRight($valueWidth)))
    Write-Output (('-' * $keyWidth) + '-+-' + ('-' * $valueWidth))
    foreach ($row in $rows) {
        Write-Output (($row.Key.PadRight($keyWidth)) + ' | ' + ($row.Value.PadRight($valueWidth)))
    }
    Write-Output '```'
}

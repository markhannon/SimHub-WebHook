########################################################
# Replay SimHub Selection Helper
#
# Enumerates available replay folders and returns the
# selected folder path to the caller on stdout.
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CaptureRoot = 'captures'
)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$captureRootPath = if ([System.IO.Path]::IsPathRooted($CaptureRoot)) { $CaptureRoot } else { Join-Path $ScriptDir $CaptureRoot }

if (-not (Test-Path -LiteralPath $captureRootPath)) {
    throw "Capture root does not exist: $captureRootPath"
}

$replayFolders = Get-ChildItem -LiteralPath $captureRootPath -Directory -ErrorAction Stop |
Where-Object {
    @(Get-ChildItem -LiteralPath $_.FullName -Filter 'session-capture-*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
} |
Sort-Object Name

if ($replayFolders.Count -eq 0) {
    throw "No replay folders containing session-capture-*.json were found under: $captureRootPath"
}

Write-Host '[OK] Available replay folders:'
for ($index = 0; $index -lt $replayFolders.Count; $index++) {
    $displayIndex = $index + 1
    Write-Host ("  [{0}] {1}" -f $displayIndex, $replayFolders[$index].Name)
}

while ($true) {
    $choice = Read-Host ("Select replay folder (1-{0}) or Q to cancel" -f $replayFolders.Count)

    if ([string]::IsNullOrWhiteSpace($choice)) {
        Write-Host '[WARN] A selection is required.'
        continue
    }

    if ($choice -match '^[Qq]$') {
        throw 'Replay selection cancelled.'
    }

    [int]$selectedIndex = 0
    if (-not [int]::TryParse($choice, [ref]$selectedIndex)) {
        Write-Host '[WARN] Enter a valid numeric selection.'
        continue
    }

    if ($selectedIndex -lt 1 -or $selectedIndex -gt $replayFolders.Count) {
        Write-Host ("[WARN] Selection must be between 1 and {0}." -f $replayFolders.Count)
        continue
    }

    Write-Output $replayFolders[$selectedIndex - 1].FullName
    return
}

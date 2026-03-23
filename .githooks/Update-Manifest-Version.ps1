param()

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'Manifest.json'

if (-not (Test-Path $manifestPath)) {
    throw "Manifest.json not found at $manifestPath"
}

$shortHash = '0000000'
try {
    $resolvedHash = (git rev-parse --short HEAD 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($resolvedHash)) {
        $shortHash = $resolvedHash.Trim()
    }
}
catch {
}

$versionValue = (Get-Date -Format 'yyyy.MM.dd') + '+' + $shortHash
$manifestText = Get-Content -Path $manifestPath -Raw

if ($manifestText -match '"version"\s*:\s*"[^"]*"') {
    $updatedManifestText = [regex]::Replace(
        $manifestText,
        '"version"\s*:\s*"[^"]*"',
        ('"version": "' + $versionValue + '"'),
        1
    )
}
else {
    $updatedManifestText = [regex]::Replace(
        $manifestText,
        '^\{\s*',
        ('{' + [Environment]::NewLine + '    "version": "' + $versionValue + '",' + [Environment]::NewLine),
        1
    )
}

if ($updatedManifestText -ne $manifestText) {
    [System.IO.File]::WriteAllText($manifestPath, $updatedManifestText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Updated Manifest.json version to $versionValue"
}
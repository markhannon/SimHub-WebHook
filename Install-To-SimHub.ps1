# 
# Install latests files to simhub
#

param (
    [switch]$dashboards = $false,
    [switch]$overlays = $false
)

$manifestPath = Join-Path $PSScriptRoot "Manifest.json"
if (-not (Test-Path $manifestPath)) {
    throw "Manifest file not found: $manifestPath"
}

$SettingsObject = Get-Content -Path $manifestPath | ConvertFrom-Json
$srcRoot = Resolve-Path (Join-Path $PSScriptRoot $SettingsObject.src)
$dstRoot = $SettingsObject.dst

if (-not (Test-Path $dstRoot)) {
    New-Item -Path $dstRoot -ItemType Directory -Force | Out-Null
}

Set-PSDebug -Trace 0

$sections = "json", "lnk", "powershell", "vbscript"
foreach ($section in $sections) {
    Write-Host "Installing $section files..."
    $collection = $SettingsObject.$section
    Write-Host "Found $($collection.Count) items in $section section."
    foreach ($item in $collection) {
        $fileName = $item.name
        $sourcePath = Join-Path $srcRoot $fileName
        $destinationPath = Join-Path $dstRoot $fileName

        if (-not (Test-Path $sourcePath)) {
            Write-Warning "Skipping missing file: $sourcePath"
            continue
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        Write-Host "Copied $fileName"
    }
}

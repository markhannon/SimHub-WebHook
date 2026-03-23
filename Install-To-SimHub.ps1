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
$shellMacrosRoot = $SettingsObject.dst
$simHubRoot = Split-Path -Path $shellMacrosRoot -Parent
$webhooksRoot = Join-Path $simHubRoot 'Webhooks'
$excludedPrefixes = @('.venv\', 'assets\')

if (-not (Test-Path $webhooksRoot)) {
    New-Item -Path $webhooksRoot -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $shellMacrosRoot)) {
    New-Item -Path $shellMacrosRoot -ItemType Directory -Force | Out-Null
}

$destinationBySection = @{
    json       = $webhooksRoot
    powershell = $webhooksRoot
    vbscript   = $shellMacrosRoot
    lnk        = $shellMacrosRoot
}

Set-PSDebug -Trace 0

$sections = "json", "lnk", "powershell", "vbscript"
foreach ($section in $sections) {
    Write-Host "Installing $section files..."
    $collection = @($SettingsObject.$section | Where-Object { $null -ne $_ })
    Write-Host "Found $($collection.Count) items in $section section."

    $destinationRoot = $destinationBySection[$section]
    if ([string]::IsNullOrWhiteSpace($destinationRoot)) {
        Write-Warning "No destination configured for section: $section"
        continue
    }

    foreach ($item in $collection) {
        $fileName = $item.name
        $normalizedFileName = $fileName.Replace('/', '\')

        if ($excludedPrefixes | Where-Object { $normalizedFileName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }) {
            Write-Host "Skipping excluded path: $fileName"
            continue
        }

        $sourcePath = Join-Path $srcRoot $fileName
        $destinationPath = Join-Path $destinationRoot $fileName
        $destinationDir = Split-Path -Path $destinationPath -Parent

        if (-not (Test-Path $sourcePath)) {
            Write-Warning "Skipping missing file: $sourcePath"
            continue
        }

        if (Test-Path $sourcePath -PathType Container) {
            Write-Host "Skipping directory entry: $fileName"
            continue
        }

        if (-not (Test-Path $destinationDir)) {
            New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        Write-Host "Copied $fileName -> $destinationRoot"
    }
}

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

$copiedCount = 0
$skippedMissingCount = 0
$skippedExcludedCount = 0
$skippedDirectoryCount = 0

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
            $skippedExcludedCount++
            continue
        }

        $sourcePath = Join-Path $srcRoot $fileName
        $destinationPath = Join-Path $destinationRoot $fileName
        $destinationDir = Split-Path -Path $destinationPath -Parent

        if (-not (Test-Path $sourcePath)) {
            Write-Warning "Skipping missing file: $sourcePath"
            $skippedMissingCount++
            continue
        }

        if (Test-Path $sourcePath -PathType Container) {
            Write-Host "Skipping directory entry: $fileName"
            $skippedDirectoryCount++
            continue
        }

        if (-not (Test-Path $destinationDir)) {
            New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        Write-Host "Copied $fileName -> $destinationRoot"
        $copiedCount++
    }
}

Write-Host ""
Write-Host "Install summary:"
Write-Host "  Copied files: $copiedCount"
Write-Host "  Skipped missing: $skippedMissingCount"
Write-Host "  Skipped excluded: $skippedExcludedCount"
Write-Host "  Skipped directories: $skippedDirectoryCount"

# Post-install verification for critical runtime fixes.
$verificationFailed = $false

$installedCollectorPath = Join-Path $webhooksRoot 'Get-SimHub-Data.ps1'
$installedStopWrapperPath = Join-Path $shellMacrosRoot 'Get-SimHub-Data-Stop.vbs'

if (Test-Path $installedCollectorPath) {
    $collectorText = Get-Content -Path $installedCollectorPath -Raw
    if ($collectorText -notmatch 'function Stop-RunningCollector') {
        Write-Warning "Verification failed: installed Get-SimHub-Data.ps1 is missing Stop-RunningCollector."
        $verificationFailed = $true
    }
}
else {
    Write-Warning "Verification failed: installed Get-SimHub-Data.ps1 not found at $installedCollectorPath"
    $verificationFailed = $true
}

if (Test-Path $installedStopWrapperPath) {
    $stopWrapperText = Get-Content -Path $installedStopWrapperPath -Raw
    if ($stopWrapperText -notmatch '-File') {
        Write-Warning "Verification failed: installed Get-SimHub-Data-Stop.vbs is not using direct -File stop invocation."
        $verificationFailed = $true
    }
    if ($stopWrapperText -match 'Out-File\s+-FilePath') {
        Write-Warning "Verification failed: installed Get-SimHub-Data-Stop.vbs still pipes stop output to _scripts.log."
        $verificationFailed = $true
    }
}
else {
    Write-Warning "Verification failed: installed Get-SimHub-Data-Stop.vbs not found at $installedStopWrapperPath"
    $verificationFailed = $true
}

if ($verificationFailed) {
    throw 'Install verification failed. See warnings above.'
}

Write-Host '[OK] Install verification passed'

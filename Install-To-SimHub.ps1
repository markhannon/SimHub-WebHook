<#
.SYNOPSIS
Installs SimHub webhook scripts to the SimHub installation directory.

.DESCRIPTION
Copies files defined in Manifest.json to their destinations in the SimHub installation.
Performs post-install verification to ensure critical fixes are in place.

.PARAMETER SkipVerification
Skip post-install integrity checks. Useful for offline or CI/CD scenarios.

.PARAMETER Force
Overwrite existing destination `.json` files. Existing `.json` files are preserved by default.

.EXAMPLE
.\Install-To-SimHub.ps1

Installs all files and verifies installation integrity.

.EXAMPLE
.\Install-To-SimHub.ps1 -SkipVerification

Installs files without running post-install verification.

.EXAMPLE
.\Install-To-SimHub.ps1 -Force

Installs files and overwrites existing destination `.json` files.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [switch]$SkipVerification,
    [switch]$Force
)

$manifestPath = Join-Path $PSScriptRoot "Manifest.json"
if (-not (Test-Path $manifestPath)) {
    throw "Manifest file not found: $manifestPath"
}

$manifest = Get-Content -Path $manifestPath | ConvertFrom-Json
$srcRoot = Resolve-Path (Join-Path $PSScriptRoot $manifest.src)
$shellMacrosRoot = $manifest.dst
$simHubRoot = Split-Path -Path $shellMacrosRoot -Parent
$webhooksRoot = Join-Path $simHubRoot 'Webhooks'

Write-Verbose "Source root: $srcRoot"
Write-Verbose "Webhooks root: $webhooksRoot"
Write-Verbose "Shell macros root: $shellMacrosRoot"

# Create target directories if they don't exist
@($webhooksRoot, $shellMacrosRoot) | ForEach-Object {
    if (-not (Test-Path $_)) {
        if ($PSCmdlet.ShouldProcess($_, "Create directory")) {
            New-Item -Path $_ -ItemType Directory -Force | Out-Null
            Write-Verbose "Created directory: $_"
        }
    }
}

$destinationBySection = @{
    json       = $webhooksRoot
    powershell = $webhooksRoot
    vbscript   = $shellMacrosRoot
    lnk        = $shellMacrosRoot
}

$excludedPrefixes = @('.venv\', 'assets\')

$destinationBySection = @{
    json       = $webhooksRoot
    powershell = $webhooksRoot
    vbscript   = $shellMacrosRoot
    lnk        = $shellMacrosRoot
}

$copiedCount = 0
$skippedCount = 0
$preservedJsonPaths = @{}

$sections = "json", "lnk", "powershell", "vbscript"
foreach ($section in $sections) {
    $items = @($manifest.$section | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        continue
    }

    Write-Verbose "Processing $section files ($($items.Count) items)..."
    $destinationRoot = $destinationBySection[$section]

    foreach ($item in $items) {
        $fileName = $item.name
        $normalizedFileName = $fileName.Replace('/', '\')

        # Check for excluded paths
        if ($excludedPrefixes | Where-Object { $normalizedFileName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }) {
            Write-Verbose "Skipped (excluded): $fileName"
            $skippedCount++
            continue
        }

        $sourcePath = Join-Path $srcRoot $fileName
        $destinationPath = Join-Path $destinationRoot $fileName
        $destinationDir = Split-Path -Path $destinationPath -Parent

        # Validate source
        if (-not (Test-Path $sourcePath)) {
            Write-Warning "Skipped (missing): $sourcePath"
            $skippedCount++
            continue
        }

        if (Test-Path $sourcePath -PathType Container) {
            Write-Verbose "Skipped (directory): $fileName"
            $skippedCount++
            continue
        }

        # Create destination directory if needed
        if (-not (Test-Path $destinationDir)) {
            if ($PSCmdlet.ShouldProcess($destinationDir, "Create directory")) {
                New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
            }
        }

        if ($section -eq 'json' -and -not $Force -and (Test-Path $destinationPath -PathType Leaf)) {
            Write-Verbose "Preserved existing JSON: $fileName"
            $preservedJsonPaths[$destinationPath] = $true
            $skippedCount++
            continue
        }

        # Copy file
        if ($PSCmdlet.ShouldProcess($destinationPath, "Copy from $sourcePath")) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            Write-Verbose "Installed: $fileName"
            $copiedCount++
        }
        else {
            $skippedCount++
        }
    }
}

Write-Host ""
Write-Host "Installation summary:"
Write-Host "  Installed: $copiedCount files"
Write-Host "  Skipped:   $skippedCount items"

if ($SkipVerification) {
    Write-Verbose "Verification skipped (as requested)"
    exit 0
}
# Post-install verification: check that all files were installed
Write-Host "Verifying installation..."

$verificationFailed = $false
$verifiedCount = 0

foreach ($section in @('json', 'powershell', 'vbscript')) {
    $items = @($manifest.$section | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        continue
    }

    $destinationRoot = $destinationBySection[$section]

    foreach ($item in $items) {
        $fileName = $item.name
        $installedPath = Join-Path $destinationRoot $fileName
        $sourcePath = Join-Path $srcRoot $fileName

        # Check destination
        if (-not (Test-Path $installedPath)) {
            Write-Warning "Verification failed: $fileName not found at destination ($installedPath)"
            $verificationFailed = $true
            continue
        }

        # Check source
        if (-not (Test-Path $sourcePath)) {
            Write-Warning "Verification failed: $fileName not found in source ($sourcePath)"
            $verificationFailed = $true
            continue
        }

        # Verify file integrity by comparing sizes
        $sourceSize = (Get-Item $sourcePath).Length
        $installedSize = (Get-Item $installedPath).Length

        if ($section -eq 'json' -and $preservedJsonPaths.ContainsKey($installedPath)) {
            Write-Verbose "Verified preserved JSON: $fileName ($installedSize bytes)"
            $verifiedCount++
            continue
        }

        if ($sourceSize -ne $installedSize) {
            Write-Warning "Verification failed: $fileName size mismatch (source: $sourceSize bytes, installed: $installedSize bytes)"
            $verificationFailed = $true
            continue
        }

        Write-Verbose "Verified: $fileName ($installedSize bytes)"
        $verifiedCount++
    }
}

if ($verificationFailed) {
    throw 'Installation verification failed. See warnings above.'
}

Write-Host "[OK] Installation verified: $verifiedCount files" -ForegroundColor Green

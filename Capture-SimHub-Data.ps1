########################################################
# Capture SimHub Data Wrapper
#
# Starts the PropertyServer daemon in -Capture mode.
# -DataDir controls daemon runtime/state directory.
# -CaptureDir controls where capture artifacts are written.
# Script exits when daemon capture exits.
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataDir,

    [Parameter(Mandatory = $true)]
    [string]$CaptureDir
)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$daemonScript = Join-Path $ScriptDir 'SimHub-PropertyServer-Daemon.ps1'

if (-not (Test-Path $daemonScript)) {
    throw "Daemon script not found: $daemonScript"
}

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    throw '-DataDir cannot be empty.'
}

if ([string]::IsNullOrWhiteSpace($CaptureDir)) {
    throw '-CaptureDir cannot be empty.'
}

$dataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }
$capturePath = if ([System.IO.Path]::IsPathRooted($CaptureDir)) { $CaptureDir } else { Join-Path $ScriptDir $CaptureDir }

if (-not (Test-Path $dataPath)) {
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
}

if (-not (Test-Path $capturePath)) {
    New-Item -ItemType Directory -Path $capturePath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$captureFile = Join-Path $capturePath ("session-capture-$timestamp.json")

Write-Host '[OK] Starting daemon capture'
Write-Host "  DataDir: $dataPath"
Write-Host "  CaptureDir: $capturePath"
Write-Host "  CaptureFile: $captureFile"

& $daemonScript -Capture -DataDir $dataPath -CaptureFile $captureFile
$captureSuccess = $?
$captureExitCode = $LASTEXITCODE

if (-not $captureSuccess -or (($null -ne $captureExitCode) -and ($captureExitCode -ne 0))) {
    $exitText = if ($null -ne $captureExitCode) { "$captureExitCode" } else { 'unknown' }
    throw "Capture daemon exited with failure (exit code: $exitText)."
}

Write-Host '[OK] Capture daemon exited cleanly.'
Write-Host "[OK] Capture artifact: $captureFile"

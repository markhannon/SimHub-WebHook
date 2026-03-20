param(
    [string]$DataDir = 'data'
)

# Ensure directory exists
$DataPath = Join-Path (Get-Location).Path $DataDir
if (-not (Test-Path $DataPath)) {
    New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
}

$daemonScript = Join-Path (Get-Location).Path 'SimHub-PropertyServer-Daemon.ps1'

Write-Host "Starting daemon..."
Write-Host "  DataDir: $DataPath"
Write-Host "  Script: $daemonScript"
Write-Host "  Time: $(Get-Date)"

& $daemonScript -Command Start -DataDir $DataPath

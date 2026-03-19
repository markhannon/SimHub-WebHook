# Test-Discord-Output.ps1
# Runs Send-Discord-Data.ps1 -TestOutput for each subdirectory in the tests folder, setting -DataDir to that subdirectory.

$ScriptDir = $PSScriptRoot
$TestsDir = Join-Path $ScriptDir 'tests/output'
$SendDiscordScript = Join-Path $ScriptDir 'Send-Discord-Data.ps1'

if (-not (Test-Path $TestsDir)) {
    Write-Host "[ERROR] tests directory not found: $TestsDir"
    exit 1
}

$subdirs = Get-ChildItem -Path $TestsDir -Directory
if ($subdirs.Count -eq 0) {
    Write-Host "[ERROR] No subdirectories found in tests directory."
    exit 1
}

foreach ($dir in $subdirs) {
    Write-Host "\n=== Running test for: $($dir.Name) ==="
    $dataDir = $dir.FullName
    powershell -ExecutionPolicy Bypass -NoProfile -File $SendDiscordScript -DataDir $dataDir -TestOutput
}

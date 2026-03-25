########################################################
# Replay SimHub Data Wrapper
#
# Starts the collector in replay mode using a prior capture.
# -DataDir    controls daemon runtime/state and CSV output directory.
# -CaptureDir controls where capture artifacts are read from.
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DataDir,

    [Parameter(Mandatory = $true)]
    [string]$CaptureDir
)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$collectorScript = Join-Path $ScriptDir 'Get-SimHub-Data.ps1'
$daemonScript = Join-Path $ScriptDir 'SimHub-PropertyServer-Daemon.ps1'

if (-not (Test-Path $collectorScript)) {
    throw "Collector script not found: $collectorScript"
}

if (-not (Test-Path $daemonScript)) {
    throw "Daemon script not found: $daemonScript"
}

$dataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir }    else { Join-Path $ScriptDir $DataDir }
$capturePath = if ([System.IO.Path]::IsPathRooted($CaptureDir)) { $CaptureDir } else { Join-Path $ScriptDir $CaptureDir }

if (-not (Test-Path $capturePath)) {
    throw "CaptureDir does not exist: $capturePath"
}

Write-Host '[OK] Starting replay collector'
Write-Host "  DataDir:    $dataPath"
Write-Host "  CaptureDir: $capturePath"

# Best-effort pre-stop to prevent stale collector/daemon lock conflicts.
Write-Host '[INFO] Ensuring previous collector/daemon is stopped for target DataDir...'
try {
    & $collectorScript -Stop -DataDir $dataPath | Out-Null
}
catch {
    Write-Host "[WARN] Pre-stop reported an issue: $($_.Exception.Message)"
}

$daemonPidFile = Join-Path $dataPath '_daemon_pid.txt'
$statusSettled = $false
for ($i = 0; $i -lt 15; $i++) {
    if (-not (Test-Path $daemonPidFile)) {
        $statusSettled = $true
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $statusSettled) {
    throw "Daemon did not reach a clean stopped state for DataDir '$dataPath' before replay start."
}

& $collectorScript -Start -DataDir $dataPath -CaptureDir $capturePath
$replaySuccess = $?
$replayExitCode = $LASTEXITCODE

if (-not $replaySuccess -or (($null -ne $replayExitCode) -and ($replayExitCode -ne 0))) {
    $exitText = if ($null -ne $replayExitCode) { "$replayExitCode" } else { 'unknown' }
    throw "Replay collector exited with failure (exit code: $exitText)."
}

Write-Host '[OK] Replay completed.'

########################################################
# Replay SimHub Task Wrapper
#
# Runs interactive replay folder selection and then
# invokes replay using the selected capture directory.
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'samples',

    [Parameter(Mandatory = $false)]
    [string]$CaptureRoot = 'captures'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$selectorScript = Join-Path $ScriptDir 'Replay-SimHub-Selection.ps1'
$replayScript = Join-Path $ScriptDir 'Replay-SimHub-Data.ps1'

if (-not (Test-Path -LiteralPath $selectorScript)) {
    throw "Replay selector script not found: $selectorScript"
}

if (-not (Test-Path -LiteralPath $replayScript)) {
    throw "Replay script not found: $replayScript"
}

$selectedCaptureDir = & $selectorScript -CaptureRoot $CaptureRoot
if ([string]::IsNullOrWhiteSpace($selectedCaptureDir)) {
    throw 'Replay selection did not return a capture directory.'
}

& $replayScript -DataDir $DataDir -CaptureDir $selectedCaptureDir

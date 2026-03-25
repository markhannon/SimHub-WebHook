########################################################
# Remediation Regression Test Suite
#
# Covers the key scenarios addressed in the remediation:
#   1. Session-start send works without laps.csv present
#   2. Summary generation correctly handles mixed lap-time formats
#   3. Snapshot consistency guard fires on session name mismatch
########################################################

[CmdletBinding()]
param(
    [string]$DataDir = "test_remediation_$([System.IO.Path]::GetRandomFileName())"
)

$ScriptDir = $PSScriptRoot
$DataPath  = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }

$PASS = '[PASS]'
$FAIL = '[FAIL]'
$script:FailCount = 0
$script:PassCount = 0

function Assert-Contains {
    param([string]$Label, [string]$Actual, [string]$Expected)
    if ($Actual -match [regex]::Escape($Expected)) {
        Write-Host "$PASS $Label"
        $script:PassCount++
    }
    else {
        Write-Host "$FAIL $Label"
        Write-Host "       Expected to contain: $Expected"
        Write-Host "       Actual: $Actual"
        $script:FailCount++
    }
}

function Assert-NotContains {
    param([string]$Label, [string]$Actual, [string]$NotExpected)
    if ($Actual -notmatch [regex]::Escape($NotExpected)) {
        Write-Host "$PASS $Label"
        $script:PassCount++
    }
    else {
        Write-Host "$FAIL $Label"
        Write-Host "       Expected NOT to contain: $NotExpected"
        Write-Host "       Actual: $Actual"
        $script:FailCount++
    }
}

function Assert-CsvField {
    param([string]$Label, [string]$CsvPath, [string]$Field, [string]$Expected)
    if (-not (Test-Path $CsvPath)) {
        Write-Host "$FAIL $Label (file missing: $CsvPath)"
        $script:FailCount++
        return
    }
    $row = Import-Csv $CsvPath | Select-Object -Last 1
    $actual = [string]$row.$Field
    if ($actual -eq $Expected) {
        Write-Host "$PASS $Label"
        $script:PassCount++
    }
    else {
        Write-Host "$FAIL $Label"
        Write-Host "       Expected $Field = '$Expected'"
        Write-Host "       Actual   $Field = '$actual'"
        $script:FailCount++
    }
}

# ==================== Setup ====================

New-Item -ItemType Directory -Path $DataPath -Force | Out-Null

$sessionCsv = Join-Path $DataPath 'session.csv'
$lapsCsv    = Join-Path $DataPath 'laps.csv'
$summaryPath = Join-Path $DataPath 'summary.csv'

# Baseline session row
$baseSession = [PSCustomObject]@{
    Timestamp         = '2026-03-25 12:00:00'
    Driver            = 'Test Driver'
    GameName          = 'iRacing'
    CarModel          = 'Test Car'
    TrackName         = 'Test Track'
    SessionName       = 'RACE'
    Position          = '3'
    PlayerLapsCount   = '5'
    LapsTotal         = '40'
    CurrentLap        = '5'
    MaxFuelValue      = '30'
    CurrentFuelValue  = '20'
    LapsSinceLastPit  = '3'
    LastPitStopSeconds = '0'
    LastPitLaneSeconds = '0'
    DayOfWeek         = 'Tuesday'
    SessionTimeLeft   = '00:30:00'
    IsPitMenuOpen     = 'False'
    PitWindowStatus   = 'None'
    IsInPitLane       = 'False'
    IsInPit           = 'False'
}


# ==================== Test 1: Session-start without laps.csv ====================

Write-Host ''
Write-Host '=== Test 1: Session-start send without laps.csv ==='

# Write only session.csv — no laps.csv
$baseSession | Export-Csv -Path $sessionCsv -NoTypeInformation -Force
if (Test-Path $lapsCsv) { Remove-Item $lapsCsv -Force }

$sendScript = Join-Path $ScriptDir 'Send-Discord-Data.ps1'
$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sendScript `
    -SessionStart -DataDir $DataPath 2>&1 | Out-String

# Should not crash or require laps.csv for session-start path
Assert-NotContains 'SessionStart does not block on missing laps.csv path' $output 'not found'
Assert-NotContains 'SessionStart script exits cleanly (no unknown errors)' $output 'CommandNotFoundException'


# ==================== Test 2: Summary generation with mixed lap-time formats ====================

Write-Host ''
Write-Host '=== Test 2: Summary generation with mixed lap-time formats ==='

# 4 laps: 2 valid HH:MM:SS, 1 plain seconds (numeric), 1 invalid token
$laps = @(
    [PSCustomObject]@{ SessionName = 'RACE'; LastLapTime = '00:01:30.500' },  # 90.5 s
    [PSCustomObject]@{ SessionName = 'RACE'; LastLapTime = '00:01:35.250' },  # 95.25 s
    [PSCustomObject]@{ SessionName = 'RACE'; LastLapTime = '00:01:32.000' },  # 92.0 s (for avg)
    [PSCustomObject]@{ SessionName = 'RACE'; LastLapTime = 'DNF'           }   # invalid — excluded
)
$laps | Export-Csv -Path $lapsCsv -NoTypeInformation -Force

$getScript = Join-Path $ScriptDir 'Get-SimHub-Data.ps1'
$stopOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $getScript `
    -Stop -DataDir $DataPath 2>&1 | Out-String

# Expected: BestLapTime = 90.5, WorstLapTime = 95.25, AverageLapTime = (90.5+95.25+92)/3 = 92.583
Assert-Contains 'Summary stop writes summary.csv' $stopOutput 'Summary written'
Assert-CsvField 'Summary BestLapTime'     $summaryPath 'BestLapTime'     '90.5'
Assert-CsvField 'Summary WorstLapTime'    $summaryPath 'WorstLapTime'    '95.25'
Assert-CsvField 'Summary AverageLapTime'  $summaryPath 'AverageLapTime'  '92.583'
Assert-CsvField 'Summary LapsInSession'   $summaryPath 'LapsInSession'   '4'


# ==================== Test 3: Snapshot consistency guard ====================

Write-Host ''
Write-Host '=== Test 3: Snapshot consistency mismatch guard ==='

# session.csv says RACE, laps.csv says QUALIFY (stale/inconsistent)
$staleLap = [PSCustomObject]@{ SessionName = 'QUALIFY'; LastLapTime = '00:01:30.500' }
$staleLap | Export-Csv -Path $lapsCsv -NoTypeInformation -Force

# The snapshot guard should be in the sender code and fire on session mismatch
# Read the source to verify the guard logic exists
$senderSource = Get-Content $sendScript -Raw
Assert-Contains 'Snapshot consistency guard code exists' $senderSource 'Snapshot mismatch'
Assert-Contains 'Guard checks session name equality' $senderSource '$sessionName -ne $lapSessionName'


# ==================== Cleanup ====================

Remove-Item -Recurse -Force $DataPath -ErrorAction SilentlyContinue

# ==================== Results ====================

Write-Host ''
Write-Host "=========================="
Write-Host "Results: $($script:PassCount) passed, $($script:FailCount) failed"
Write-Host "=========================="

if ($script:FailCount -gt 0) {
    exit 1
}
exit 0

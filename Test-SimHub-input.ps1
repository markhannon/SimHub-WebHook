# Test-SimHub-input.ps1
# Capture SimHub data to tests/input using Get-SimHub-Data.ps1

$ScriptDir = $PSScriptRoot
$InputDir = Join-Path $ScriptDir 'tests/input'
$GetSimHubScript = Join-Path $ScriptDir 'Get-SimHub-Data.ps1'

# Ensure input directory exists
if (-not (Test-Path $InputDir)) {
    New-Item -ItemType Directory -Path $InputDir | Out-Null
}

# Start new session
Write-Host "[INFO] Starting new SimHub data capture session..."
powershell -ExecutionPolicy Bypass -NoProfile -File $GetSimHubScript -Start -DataDir $InputDir

# Loop: poll every 30 seconds, check session name
$raceSeen = $false
$sessionName = $null
$firstDataLogged = $false

while ($true) {
    powershell -ExecutionPolicy Bypass -NoProfile -File $GetSimHubScript -DataDir $InputDir
    # Read latest session name
    $sessionCsv = Join-Path $InputDir 'session.csv'
    if (Test-Path $sessionCsv) {
        $session = Import-Csv $sessionCsv | Select-Object -Last 1
        $sessionName = $session.SessionType
        $lapNumber = $null
        # Try to get lap number from laps.csv if available
        $lapsCsv = Join-Path $InputDir 'laps.csv'
        if (Test-Path $lapsCsv) {
            $lastLap = Import-Csv $lapsCsv | Where-Object { $_.SessionName -eq $sessionName } | Select-Object -Last 1
            if ($lastLap) { $lapNumber = $lastLap.LapNumber }
            if (-not $firstDataLogged) {
                $firstLap = Import-Csv $lapsCsv | Select-Object -First 1
                if ($firstLap) {
                    Write-Host ("[DEBUG] Session Data: Game={0}, Track={1}, Car={2}" -f $firstLap.GameName, $firstLap.Track, $firstLap.Car)
                    $firstDataLogged = $true
                }
            }
        }
        Write-Host ("[DEBUG] Lap Data: Session={0}, Lap={1}" -f $sessionName, ($lapNumber ?? 'N/A'))
        if (-not $raceSeen) {
            if ($sessionName -and ($sessionName -ieq 'race')) {
                $raceSeen = $true
                Write-Host "[INFO] 'Race' session detected. Monitoring for session change..."
            }
            else {
                Write-Host "[INFO] Waiting for 'Race' session, current: $sessionName"
            }
        }
        else {
            if ($sessionName -and ($sessionName -ine 'race')) {
                Write-Host "[INFO] Session type changed from Race. Stopping capture."
                break
            }
        }
    }
    else {
        Write-Host "[WARN] session.csv not found, continuing..."
    }
    Start-Sleep -Seconds 2
}

# Stop session
powershell -ExecutionPolicy Bypass -NoProfile -File $GetSimHubScript -Stop -DataDir $InputDir
Write-Host "[INFO] Data capture complete."

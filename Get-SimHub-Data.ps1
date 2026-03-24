########################################################
# Primary SimHub Data Collection Service
# 
# Continuously collects telemetry from SimHub via daemon
# - Starts/manages PropertyServer daemon automatically
# - Runs in long-running mode (continuous collection)
# - Triggers CSV updates on session/lap changes
# Supports -Start (initialize), -Stop (cleanup), and -Reset (force stop + wipe) flags
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Start,
    [Parameter(Mandatory = $false)]
    [switch]$Stop,
    [Parameter(Mandatory = $false)]
    [switch]$Reset,
    [Parameter(Mandatory = $false)]
    [int]$UpdateInterval = 1,  # Seconds between daemon state checks
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'data'  # Directory for CSV and daemon files
)

$ScriptDir = $PSScriptRoot
$DataPath = if ([System.IO.Path]::IsPathRooted($DataDir)) { $DataDir } else { Join-Path $ScriptDir $DataDir }

# Ensure data directory exists
if (-not (Test-Path $DataPath)) {
    New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
}

$daemonStateFile = Join-Path $DataPath '_daemon_state.json'
$daemonScriptFile = Join-Path $ScriptDir 'SimHub-PropertyServer-Daemon.ps1'
$sendDiscordScriptFile = Join-Path $ScriptDir 'Send-Discord-Data.ps1'
$SessionCsvPath = Join-Path $DataPath "session.csv"
$LapsCsvPath = Join-Path $DataPath "laps.csv"
$EventsCsvPath = Join-Path $DataPath "events.csv"
$statePath = Join-Path $DataPath "_lapstate.json"
$eventStatePath = Join-Path $DataPath "_eventstate.json"
$collectorPidFile = Join-Path $DataPath '_collector_pid.txt'
$collectorControlFile = Join-Path $DataPath '_collector_control.txt'
$eventConfigPath = Join-Path $ScriptDir 'Events.json'
$script:DaemonStartedByCollector = $false
$script:CollectorMutex = $null
$script:HasCollectorMutex = $false

# ==================== Helper Functions ====================

function Parse-TimeSpanSafe($val) {
    try { [timespan]::Parse($val) } catch { $null }
}

function ConvertTo-BoolSafe {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $normalized = $text.Trim().ToLowerInvariant()
    switch ($normalized) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'off' { return $false }
    }

    $parsed = $false
    if ([bool]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function ConvertTo-NullableInt {
    param($Value)

    if ($null -eq $Value) { return $null }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = 0
    if ([int]::TryParse($text.Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Get-TimeSpanSafe {
    param($Value)

    if ($null -eq $Value) { return $null }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $ts = Parse-TimeSpanSafe $text
    if ($ts) { return $ts }

    $seconds = 0.0
    if ([double]::TryParse($text.Trim(), [ref]$seconds)) {
        return [timespan]::FromSeconds($seconds)
    }

    return $null
}

function Get-OrDefault($value, $defaultValue) {
    if ($null -eq $value -or ([string]::IsNullOrWhiteSpace([string]$value))) {
        return $defaultValue
    }
    return $value
}

function ConvertTo-CleanedProperties {
    param([hashtable]$Properties)

    $cleaned = @{}
    if ($null -eq $Properties) {
        return $cleaned
    }

    foreach ($k in $Properties.Keys) {
        $newKey = $k -replace '^(dcp\.gd\.|dcp\.|DataCorePlugin\.Computed\.)', ''
        $cleaned[$newKey] = $Properties[$k]
    }

    return $cleaned
}

function Get-AvgTyreWear($cleaned) {
    $tyres = @('TyreWearFrontLeft', 'TyreWearFrontRight', 'TyreWearRearLeft', 'TyreWearRearRight')
    $vals = $tyres | ForEach-Object { [double](Get-OrDefault $cleaned[$_] 0) }
    if ($vals.Count -eq 0) { return 0 }
    [math]::Round(($vals | Measure-Object -Average).Average, 3)
}

# Helper function to convert PSObject to hashtable
function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }

    $hashtable = @{}
    $InputObject.PSObject.Properties | ForEach-Object {
        $hashtable[$_.Name] = $_.Value
    }
    return $hashtable
}

# ==================== Collector Single-Instance Mutex ====================

function Get-CollectorMutexName {
    $normalizedPath = [System.IO.Path]::GetFullPath($DataPath).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
    return "Global\SimHubCollector_$hash"
}

function Acquire-CollectorMutex {
    $mutexName = Get-CollectorMutexName
    $script:CollectorMutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $script:CollectorMutex.WaitOne(0)
    if ($acquired) {
        $script:HasCollectorMutex = $true
        return $true
    }
    $script:CollectorMutex.Dispose()
    $script:CollectorMutex = $null
    return $false
}

function Release-CollectorMutex {
    if ($script:HasCollectorMutex -and $null -ne $script:CollectorMutex) {
        try { $script:CollectorMutex.ReleaseMutex() } catch {}
        $script:CollectorMutex.Dispose()
        $script:CollectorMutex = $null
        $script:HasCollectorMutex = $false
    }
}

function Get-ExpectedCollectorIdentity {
    return @{
        scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
        dataPath   = [System.IO.Path]::GetFullPath($DataPath)
    }
}

function Test-CollectorProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { return $false }

        $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
        if ($null -eq $procInfo -or [string]::IsNullOrWhiteSpace($procInfo.CommandLine)) {
            return $false
        }

        $identity = Get-ExpectedCollectorIdentity
        $escapedScript = [regex]::Escape($identity.scriptPath)
        $escapedData = [regex]::Escape($identity.dataPath)

        if ($procInfo.CommandLine -notmatch $escapedScript) { return $false }
        if ($procInfo.CommandLine -notmatch $escapedData) { return $false }

        return $true
    }
    catch {
        return $false
    }
}

function Get-CollectorProcessIds {
    $processIds = @()

    if (Test-Path $collectorPidFile) {
        $pidText = Get-Content $collectorPidFile -ErrorAction SilentlyContinue
        if ($pidText -and ($pidText -as [int])) {
            $candidatePid = [int]$pidText
            if ($candidatePid -ne $PID -and (Test-CollectorProcessIdentity -ProcessId $candidatePid)) {
                $processIds += $candidatePid
            }
        }
    }

    $identity = Get-ExpectedCollectorIdentity
    $escapedScript = [regex]::Escape($identity.scriptPath)
    $escapedData = [regex]::Escape($identity.dataPath)

    $matchingProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine -match $escapedScript -and
        $_.CommandLine -match $escapedData
    }

    foreach ($proc in $matchingProcs) {
        $processIds += [int]$proc.ProcessId
    }

    return @($processIds | Sort-Object -Unique)
}

function Stop-RunningCollector {
    $targetPids = @(Get-CollectorProcessIds)
    if ($targetPids.Count -eq 0) {
        Remove-Item $collectorPidFile -ErrorAction SilentlyContinue
        Remove-Item $collectorControlFile -ErrorAction SilentlyContinue
        return $true
    }

    Set-Content -Path $collectorControlFile -Value 'STOP' -ErrorAction SilentlyContinue

    $waitMs = 0
    while ($waitMs -lt 5000) {
        $stillRunning = @()
        foreach ($pidValue in $targetPids) {
            if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) {
                $stillRunning += $pidValue
            }
        }

        if ($stillRunning.Count -eq 0) {
            Remove-Item $collectorPidFile -ErrorAction SilentlyContinue
            Remove-Item $collectorControlFile -ErrorAction SilentlyContinue
            return $true
        }

        Start-Sleep -Milliseconds 200
        $waitMs += 200
    }

    foreach ($pidValue in $targetPids) {
        if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) {
            Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) {
                & taskkill /PID $pidValue /T /F | Out-Null
                Start-Sleep -Milliseconds 300
            }
        }
    }

    foreach ($pidValue in $targetPids) {
        if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) {
            return $false
        }
    }

    Remove-Item $collectorPidFile -ErrorAction SilentlyContinue
    Remove-Item $collectorControlFile -ErrorAction SilentlyContinue
    return $true
}

# ==================== Exclusive File Locking ====================

function Write-CsvExclusive {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject,
        [string]$Path,
        [int]$RetryCount = 3,
        [int]$RetryDelayMs = 50
    )

    begin {
        $buffer = @()
    }

    process {
        if ($null -ne $InputObject) {
            $buffer += $InputObject
        }
    }

    end {
        if ($buffer.Count -eq 0) {
            return $true
        }

        $attempt = 0
        while ($attempt -lt $RetryCount) {
            try {
                $buffer | Export-Csv -Path $Path -NoTypeInformation -Force
                return $true
            }
            catch {
                $attempt++
                if ($attempt -lt $RetryCount) {
                    Start-Sleep -Milliseconds $RetryDelayMs
                }
            }
        }

        Write-Error "Failed to write CSV to $Path after $RetryCount attempts"
        return $false
    }
}

function Write-JsonExclusive {
    param(
        [string]$Json,
        [string]$Path,
        [int]$RetryCount = 3,
        [int]$RetryDelayMs = 50
    )

    $attempt = 0
    while ($attempt -lt $RetryCount) {
        try {
            [System.IO.File]::WriteAllText($Path, $Json, [System.Text.Encoding]::UTF8)
            return
        }
        catch {
            $attempt++
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Milliseconds $RetryDelayMs
            }
            else {
                Write-Warning "Failed to write JSON to $Path after $RetryCount attempts: $_"
            }
        }
    }
}

function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }

    $hashtable = @{}
    $InputObject.PSObject.Properties | ForEach-Object {
        $hashtable[$_.Name] = $_.Value
    }
    return $hashtable
}

function Get-DefaultEventConfig {
    return @{
        Events = @(
            @{
                EventName    = 'Session Started'
                Enabled      = $true
                Rule         = 'SessionNameChangedToActive'
                RuleSettings = @{}
            },
            @{
                EventName    = 'Session Stopped'
                Enabled      = $true
                Rule         = 'SessionNameChangedPreviousSessionEnded'
                RuleSettings = @{}
            },
            @{
                EventName    = 'Position Changed'
                Enabled      = $true
                Rule         = 'CurrentPositionDifferentFromPreviousSample'
                RuleSettings = @{}
            },
            @{
                EventName    = 'Fastest Lap'
                Enabled      = $true
                Rule         = 'PersonalBestOrGlobalBestImprovedOnLapChange'
                RuleSettings = @{
                    PersonalBestEnabled           = $true
                    GlobalBestEnabled             = $true
                    GlobalBestLapTimePropertyKeys = @(
                        'GlobalFastestLapTime',
                        'OverallBestLapTime',
                        'SessionFastestLapTime',
                        'FastestLapTime'
                    )
                }
            },
            @{
                EventName    = 'Entering Pits'
                Enabled      = $true
                Rule         = 'InPitFlagTransitionFalseToTrue'
                RuleSettings = @{
                    PitPropertyKeys = @('InPitLane', 'InPit')
                }
            },
            @{
                EventName    = 'Exiting Pits'
                Enabled      = $true
                Rule         = 'InPitFlagTransitionTrueToFalse'
                RuleSettings = @{
                    PitPropertyKeys = @('InPitLane', 'InPit')
                }
            },
            @{
                EventName    = 'Bad lap'
                Enabled      = $true
                Rule         = 'LapDeltaThresholdOrIncidentProxyOnLapChange'
                RuleSettings = @{
                    DeltaThresholdSeconds    = 2.0
                    IncidentFlagPropertyKeys = @(
                        'Incident',
                        'HasIncident',
                        'IncidentDetected',
                        'IsOffTrack',
                        'OffTrack'
                    )
                }
            }
        )
    }
}

function Merge-EventDefinition {
    param(
        [hashtable]$DefaultEvent,
        [hashtable]$OverrideEvent
    )

    $merged = @{
        EventName    = $DefaultEvent.EventName
        Enabled      = [bool](Get-OrDefault $DefaultEvent.Enabled $true)
        Rule         = Get-OrDefault $DefaultEvent.Rule ''
        RuleSettings = @{}
    }

    if ($DefaultEvent.RuleSettings) {
        foreach ($key in $DefaultEvent.RuleSettings.Keys) {
            $merged.RuleSettings[$key] = $DefaultEvent.RuleSettings[$key]
        }
    }

    if ($OverrideEvent) {
        if ($OverrideEvent.ContainsKey('Enabled')) {
            $overrideEnabled = ConvertTo-BoolSafe $OverrideEvent.Enabled
            if ($null -ne $overrideEnabled) {
                $merged.Enabled = $overrideEnabled
            }
        }

        if ($OverrideEvent.ContainsKey('Rule') -and -not [string]::IsNullOrWhiteSpace([string]$OverrideEvent.Rule)) {
            $merged.Rule = [string]$OverrideEvent.Rule
        }

        if ($OverrideEvent.ContainsKey('RuleSettings') -and $OverrideEvent.RuleSettings) {
            $overrideRuleSettings = ConvertTo-Hashtable $OverrideEvent.RuleSettings
            foreach ($key in $overrideRuleSettings.Keys) {
                $merged.RuleSettings[$key] = $overrideRuleSettings[$key]
            }
        }
    }

    return $merged
}

function Get-EventConfig {
    param(
        [string]$ConfigPath
    )

    $defaultConfig = Get-DefaultEventConfig
    $defaultEvents = @{}
    foreach ($item in $defaultConfig.Events) {
        $defaultEvents[$item.EventName] = ConvertTo-Hashtable $item
    }

    if (-not (Test-Path $ConfigPath)) {
        return $defaultEvents
    }

    try {
        $fileConfig = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
        $configHash = ConvertTo-Hashtable $fileConfig
        $configuredEvents = @{}

        if ($configHash.ContainsKey('Events') -and $null -ne $configHash.Events) {
            foreach ($eventItem in $configHash.Events) {
                $eventHash = ConvertTo-Hashtable $eventItem
                if ($null -eq $eventHash) { continue }
                $eventName = [string](Get-OrDefault $eventHash.EventName '')
                if ([string]::IsNullOrWhiteSpace($eventName)) { continue }
                $configuredEvents[$eventName] = $eventHash
            }
        }

        $mergedEvents = @{}
        foreach ($eventName in $defaultEvents.Keys) {
            $mergedEvents[$eventName] = Merge-EventDefinition -DefaultEvent $defaultEvents[$eventName] -OverrideEvent $configuredEvents[$eventName]
        }

        foreach ($eventName in $configuredEvents.Keys) {
            if ($mergedEvents.ContainsKey($eventName)) { continue }
            $customEvent = ConvertTo-Hashtable $configuredEvents[$eventName]
            if ($null -eq $customEvent) { continue }

            $mergedEvents[$eventName] = @{
                EventName    = $eventName
                Enabled      = [bool](Get-OrDefault (ConvertTo-BoolSafe $customEvent.Enabled) $true)
                Rule         = [string](Get-OrDefault $customEvent.Rule 'CustomRule')
                RuleSettings = if ($customEvent.RuleSettings) { ConvertTo-Hashtable $customEvent.RuleSettings } else { @{} }
            }
        }

        return $mergedEvents
    }
    catch {
        Write-Warning "Failed to parse event configuration at $ConfigPath. Using defaults. Error: $_"
        return $defaultEvents
    }
}

function New-EventState {
    return @{
        PreviousSessionName       = $null
        PreviousPosition          = $null
        PreviousInPit             = $null
        PreviousLapNumber         = $null
        PreviousBestLapTime       = $null
        PreviousGlobalBestLapTime = $null
    }
}

function Get-EventState {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return New-EventState
    }

    try {
        $existing = Get-Content -Raw -Path $Path | ConvertFrom-Json | ConvertTo-Hashtable
        $eventState = New-EventState
        foreach ($key in $eventState.Keys) {
            if ($existing.ContainsKey($key)) {
                $eventState[$key] = $existing[$key]
            }
        }
        return $eventState
    }
    catch {
        Write-Warning "Failed to load event state from $Path. Starting with empty event state. Error: $_"
        return New-EventState
    }
}

function Save-EventState {
    param(
        [hashtable]$EventState,
        [string]$Path
    )

    Write-JsonExclusive -Json ($EventState | ConvertTo-Json) -Path $Path
}

function New-EventRecord {
    param(
        [string]$EventName,
        [string]$Rule,
        [string]$SessionName,
        [int]$LapNumber,
        [int]$Position,
        [string]$Scope,
        [string]$Details,
        [string]$RuleMatched
    )

    return [PSCustomObject]@{
        Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        EventName   = $EventName
        Rule        = $Rule
        SessionName = $SessionName
        LapNumber   = $LapNumber
        Position    = $Position
        Scope       = $Scope
        RuleMatched = $RuleMatched
        Details     = $Details
    }
}

function Write-EventsToCsv {
    param(
        [array]$Events,
        [string]$Path
    )

    if ($null -eq $Events -or $Events.Count -eq 0) {
        return
    }

    if (-not (Test-Path $Path)) {
        $Events | Write-CsvExclusive -Path $Path | Out-Null
        return
    }

    $existing = @(Import-Csv $Path)
    $existing += $Events
    $existing | Write-CsvExclusive -Path $Path | Out-Null
}

function Get-FirstPropertyValue {
    param(
        [hashtable]$CleanedProps,
        [hashtable]$RawProps,
        [array]$PropertyKeys
    )

    if ($null -eq $PropertyKeys) {
        return $null
    }

    foreach ($propertyName in $PropertyKeys) {
        if ([string]::IsNullOrWhiteSpace([string]$propertyName)) {
            continue
        }

        if ($CleanedProps.ContainsKey($propertyName)) {
            return $CleanedProps[$propertyName]
        }

        if ($RawProps.ContainsKey($propertyName)) {
            return $RawProps[$propertyName]
        }

        $candidateWithPrefix = "dcp.gd.$propertyName"
        if ($RawProps.ContainsKey($candidateWithPrefix)) {
            return $RawProps[$candidateWithPrefix]
        }
    }

    return $null
}

function Evaluate-ConfiguredEvents {
    param(
        [hashtable]$RawProperties,
        [hashtable]$CleanedProperties,
        [hashtable]$EventConfig,
        [hashtable]$EventState
    )

    $events = @()

    $currentSession = [string](Get-OrDefault $CleanedProperties.SessionTypeName '')
    if (-not [string]::IsNullOrWhiteSpace($currentSession)) {
        $currentSession = $currentSession.Trim()
    }

    $currentLap = [int](Get-OrDefault $CleanedProperties.CurrentLap 0)
    $currentPosition = ConvertTo-NullableInt $CleanedProperties.Position
    $currentBestLapText = [string](Get-OrDefault $CleanedProperties.BestLapTime '')
    $currentLastLapText = [string](Get-OrDefault $CleanedProperties.LastLapTime '')
    $currentBestLapTs = Get-TimeSpanSafe $currentBestLapText
    $currentLastLapTs = Get-TimeSpanSafe $currentLastLapText

    $previousSession = [string](Get-OrDefault $EventState.PreviousSessionName '')
    $previousPosition = ConvertTo-NullableInt $EventState.PreviousPosition
    $previousLap = ConvertTo-NullableInt $EventState.PreviousLapNumber
    $previousBestLapTs = Get-TimeSpanSafe $EventState.PreviousBestLapTime
    $previousGlobalBestLapTs = Get-TimeSpanSafe $EventState.PreviousGlobalBestLapTime

    $lapChanged = $false
    if ($null -ne $previousLap) {
        $lapChanged = $currentLap -ne $previousLap
    }

    $enteringConfig = if ($EventConfig.ContainsKey('Entering Pits')) { $EventConfig['Entering Pits'] } else { $null }
    $exitingConfig = if ($EventConfig.ContainsKey('Exiting Pits')) { $EventConfig['Exiting Pits'] } else { $null }
    $pitKeys = @('InPitLane', 'InPit')

    if ($enteringConfig -and $enteringConfig.RuleSettings.ContainsKey('PitPropertyKeys')) {
        $pitKeys = @($enteringConfig.RuleSettings.PitPropertyKeys)
    }
    elseif ($exitingConfig -and $exitingConfig.RuleSettings.ContainsKey('PitPropertyKeys')) {
        $pitKeys = @($exitingConfig.RuleSettings.PitPropertyKeys)
    }

    $currentInPitValue = Get-FirstPropertyValue -CleanedProps $CleanedProperties -RawProps $RawProperties -PropertyKeys $pitKeys
    $currentInPit = ConvertTo-BoolSafe $currentInPitValue
    $previousInPit = ConvertTo-BoolSafe $EventState.PreviousInPit

    if ($EventConfig.ContainsKey('Session Stopped')) {
        $sessionStoppedConfig = $EventConfig['Session Stopped']
        if ($sessionStoppedConfig.Enabled -and -not [string]::IsNullOrWhiteSpace($previousSession) -and -not [string]::IsNullOrWhiteSpace($currentSession) -and $previousSession -ne $currentSession) {
            $events += New-EventRecord -EventName 'Session Stopped' -Rule $sessionStoppedConfig.Rule -SessionName $previousSession -LapNumber (Get-OrDefault $previousLap 0) -Position (Get-OrDefault $previousPosition 0) -Scope 'Session' -Details "Session changed from '$previousSession' to '$currentSession'" -RuleMatched 'SessionNameChange'
        }
    }

    if ($EventConfig.ContainsKey('Session Started')) {
        $sessionStartedConfig = $EventConfig['Session Started']
        if ($sessionStartedConfig.Enabled -and -not [string]::IsNullOrWhiteSpace($currentSession) -and $previousSession -ne $currentSession) {
            $events += New-EventRecord -EventName 'Session Started' -Rule $sessionStartedConfig.Rule -SessionName $currentSession -LapNumber $currentLap -Position (Get-OrDefault $currentPosition 0) -Scope 'Session' -Details "Session '$currentSession' became active" -RuleMatched 'SessionNameChange'
        }
    }

    if ($EventConfig.ContainsKey('Position Changed')) {
        $positionConfig = $EventConfig['Position Changed']
        if ($positionConfig.Enabled -and $null -ne $currentPosition -and $null -ne $previousPosition -and $currentPosition -ne $previousPosition) {
            $events += New-EventRecord -EventName 'Position Changed' -Rule $positionConfig.Rule -SessionName $currentSession -LapNumber $currentLap -Position $currentPosition -Scope 'Position' -Details "Position changed from $previousPosition to $currentPosition" -RuleMatched 'PositionValueChanged'
        }
    }

    if ($EventConfig.ContainsKey('Entering Pits')) {
        $eventDef = $EventConfig['Entering Pits']
        if ($eventDef.Enabled -and $null -ne $previousInPit -and $null -ne $currentInPit -and (-not $previousInPit) -and $currentInPit) {
            $events += New-EventRecord -EventName 'Entering Pits' -Rule $eventDef.Rule -SessionName $currentSession -LapNumber $currentLap -Position (Get-OrDefault $currentPosition 0) -Scope 'Pit' -Details 'Pit state changed from out to in' -RuleMatched 'PitTransitionFalseToTrue'
        }
    }

    if ($EventConfig.ContainsKey('Exiting Pits')) {
        $eventDef = $EventConfig['Exiting Pits']
        if ($eventDef.Enabled -and $null -ne $previousInPit -and $null -ne $currentInPit -and $previousInPit -and (-not $currentInPit)) {
            $events += New-EventRecord -EventName 'Exiting Pits' -Rule $eventDef.Rule -SessionName $currentSession -LapNumber $currentLap -Position (Get-OrDefault $currentPosition 0) -Scope 'Pit' -Details 'Pit state changed from in to out' -RuleMatched 'PitTransitionTrueToFalse'
        }
    }

    $globalBestLapTs = $null
    $globalBestLapText = $null
    if ($EventConfig.ContainsKey('Fastest Lap')) {
        $fastestConfig = $EventConfig['Fastest Lap']
        if ($fastestConfig.Enabled -and $fastestConfig.RuleSettings.ContainsKey('GlobalBestLapTimePropertyKeys')) {
            $globalKeys = @($fastestConfig.RuleSettings.GlobalBestLapTimePropertyKeys)
            $globalBestLapValue = Get-FirstPropertyValue -CleanedProps $CleanedProperties -RawProps $RawProperties -PropertyKeys $globalKeys
            $globalBestLapTs = Get-TimeSpanSafe $globalBestLapValue
            $globalBestLapText = [string](Get-OrDefault $globalBestLapValue '')
        }

        if ($fastestConfig.Enabled -and $lapChanged) {
            $personalEnabled = [bool](Get-OrDefault (ConvertTo-BoolSafe $fastestConfig.RuleSettings.PersonalBestEnabled) $true)
            $globalEnabled = [bool](Get-OrDefault (ConvertTo-BoolSafe $fastestConfig.RuleSettings.GlobalBestEnabled) $true)

            if ($personalEnabled -and $currentBestLapTs -and (($null -eq $previousBestLapTs) -or ($currentBestLapTs -lt $previousBestLapTs))) {
                $events += New-EventRecord -EventName 'Fastest Lap' -Rule $fastestConfig.Rule -SessionName $currentSession -LapNumber $currentLap -Position (Get-OrDefault $currentPosition 0) -Scope 'Personal' -Details "Personal best improved to $currentBestLapText" -RuleMatched 'PersonalBestImproved'
            }

            if ($globalEnabled -and $globalBestLapTs -and (($null -eq $previousGlobalBestLapTs) -or ($globalBestLapTs -lt $previousGlobalBestLapTs))) {
                $events += New-EventRecord -EventName 'Fastest Lap' -Rule $fastestConfig.Rule -SessionName $currentSession -LapNumber $currentLap -Position (Get-OrDefault $currentPosition 0) -Scope 'Global' -Details "Global best improved to $globalBestLapText" -RuleMatched 'GlobalBestImproved'
            }
        }
    }

    if ($EventConfig.ContainsKey('Bad lap')) {
        $badLapConfig = $EventConfig['Bad lap']
        if ($badLapConfig.Enabled -and $lapChanged -and $currentLastLapTs) {
            $deltaThreshold = 2.0
            if ($badLapConfig.RuleSettings.ContainsKey('DeltaThresholdSeconds')) {
                $thresholdText = [string]$badLapConfig.RuleSettings.DeltaThresholdSeconds
                $parsedThreshold = 0.0
                if ([double]::TryParse($thresholdText, [ref]$parsedThreshold)) {
                    $deltaThreshold = $parsedThreshold
                }
            }

            $deltaHit = $false
            $deltaSeconds = 0.0
            if ($currentBestLapTs) {
                $deltaSeconds = ($currentLastLapTs - $currentBestLapTs).TotalSeconds
                $deltaHit = $deltaSeconds -ge $deltaThreshold
            }

            $incidentHit = $false
            if ($badLapConfig.RuleSettings.ContainsKey('IncidentFlagPropertyKeys')) {
                $incidentKeys = @($badLapConfig.RuleSettings.IncidentFlagPropertyKeys)
                foreach ($incidentKey in $incidentKeys) {
                    $candidateIncident = Get-FirstPropertyValue -CleanedProps $CleanedProperties -RawProps $RawProperties -PropertyKeys @($incidentKey)
                    $incidentBool = ConvertTo-BoolSafe $candidateIncident
                    if ($incidentBool -eq $true) {
                        $incidentHit = $true
                        break
                    }
                }
            }

            if ($deltaHit -or $incidentHit) {
                $reason = if ($deltaHit -and $incidentHit) { 'DeltaThreshold+IncidentFlag' } elseif ($deltaHit) { 'DeltaThreshold' } else { 'IncidentFlag' }
                $detail = if ($deltaHit) {
                    "Last lap $currentLastLapText exceeded best $currentBestLapText by $([math]::Round($deltaSeconds, 3))s"
                }
                else {
                    "Incident/off-track proxy flag set on lap $currentLap"
                }

                $events += New-EventRecord -EventName 'Bad lap' -Rule $badLapConfig.Rule -SessionName $currentSession -LapNumber $currentLap -Position (Get-OrDefault $currentPosition 0) -Scope 'LapQuality' -Details $detail -RuleMatched $reason
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($currentSession)) {
        $EventState.PreviousSessionName = $currentSession
    }
    if ($null -ne $currentPosition) {
        $EventState.PreviousPosition = $currentPosition
    }
    if ($null -ne $currentInPit) {
        $EventState.PreviousInPit = $currentInPit
    }
    $EventState.PreviousLapNumber = $currentLap
    if ($currentBestLapTs) {
        $EventState.PreviousBestLapTime = $currentBestLapText
    }
    if ($globalBestLapTs) {
        $EventState.PreviousGlobalBestLapTime = $globalBestLapText
    }

    return $events
}

function Invoke-DiscordNotificationsForEvents {
    param(
        [array]$Events,
        [string]$DataDirectory
    )

    if ($null -eq $Events -or $Events.Count -eq 0) {
        return
    }

    if (-not (Test-Path $sendDiscordScriptFile)) {
        Write-Warning "Discord sender script not found at $sendDiscordScriptFile"
        return
    }

    foreach ($eventRecord in $Events) {
        try {
            & $sendDiscordScriptFile `
                -EventName $eventRecord.EventName `
                -EventScope $eventRecord.Scope `
                -EventDetails $eventRecord.Details `
                -DataDir $DataDirectory | Out-Null
        }
        catch {
            Write-Warning "Failed to send Discord notification for event '$($eventRecord.EventName)': $_"
        }
    }
}

# ==================== Daemon Management ====================

function Get-ExpectedDaemonIdentity {
    return @{ 
        scriptPath = [System.IO.Path]::GetFullPath($daemonScriptFile)
        dataPath   = [System.IO.Path]::GetFullPath($DataPath)
    }
}

function Test-DaemonProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { return $false }

        $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
        if ($null -eq $procInfo -or [string]::IsNullOrWhiteSpace($procInfo.CommandLine)) {
            return $false
        }

        $identity = Get-ExpectedDaemonIdentity
        $escapedScript = [regex]::Escape($identity.scriptPath)
        $escapedData = [regex]::Escape($identity.dataPath)

        if ($procInfo.CommandLine -notmatch $escapedScript) { return $false }
        if ($procInfo.CommandLine -notmatch $escapedData) { return $false }

        return $true
    }
    catch {
        return $false
    }
}

function Get-DaemonStatus {
    if (-not (Test-Path $daemonStateFile)) {
        return @{ connected = $false; running = $false }
    }
    
    try {
        $state = Get-Content -Raw -Path $daemonStateFile | ConvertFrom-Json

        $isRunning = $false
        if ($state.processId) {
            $isRunning = Test-DaemonProcessIdentity -ProcessId ([int]$state.processId)
        }

        return @{ 
            connected = $state.connected
            running   = $isRunning
            processId = $state.processId
        }
    }
    catch {
        return @{ connected = $false; running = $false }
    }
}

function Start-PropertyDaemon {
    $status = Get-DaemonStatus
    
    if ($status.running) {
        $script:DaemonStartedByCollector = $false
        Write-Host "[OK] Daemon already running (PID: $($status.processId))"
        if ($status.connected) {
            Write-Host "[OK] Connected to PropertyServer"
        }
        else {
            Write-Host "[WARN] Daemon running but waiting for PropertyServer connection..."
        }
        return $true
    }
    
    if (-not (Test-Path $daemonScriptFile)) {
        Write-Error "Daemon script not found: $daemonScriptFile"
        return $false
    }
    
    Write-Host "Starting PropertyServer daemon..."
    try {
        $absDaemonScript = (Resolve-Path $daemonScriptFile).Path
        $absDataPath = $DataPath
        $daemonStdOutFile = Join-Path $DataPath '_daemon_stdout.log'
        $daemonStdErrFile = Join-Path $DataPath '_daemon_stderr.log'
        $mutexErrorToken = 'DAEMON_MUTEX_CONFLICT'
        $daemonArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$absDaemonScript`" -Start -DataDir `"$absDataPath`""

        Remove-Item $daemonStdOutFile -ErrorAction SilentlyContinue
        Remove-Item $daemonStdErrFile -ErrorAction SilentlyContinue

        $process = Start-Process -FilePath 'pwsh' `
            -ArgumentList $daemonArgs `
            -WorkingDirectory $ScriptDir `
            -RedirectStandardOutput $daemonStdOutFile `
            -RedirectStandardError $daemonStdErrFile `
            -PassThru

        Write-Host "  Daemon process launched (PID: $($process.Id))"

        # Wait for daemon to write its state file
        $maxWaitForStart = 20
        $waited = 0
        $daemonRunning = $false

        while ($waited -lt $maxWaitForStart) {
            Start-Sleep -Seconds 1
            $waited++

            if ($process.HasExited) {
                $stderrText = ''
                if (Test-Path $daemonStdErrFile) {
                    $stderrText = Get-Content -Raw -Path $daemonStdErrFile -ErrorAction SilentlyContinue
                }

                if ($stderrText -match $mutexErrorToken) {
                    Write-Error "Daemon single-instance lock prevented startup for data directory '$absDataPath'."
                    Write-Error "Stop the existing daemon first or use a different -DataDir."
                    Write-Error "Daemon stderr:"; Get-Content $daemonStdErrFile | ForEach-Object { Write-Error "  $_" }
                }
                else {
                    Write-Error "Daemon process exited early (ExitCode: $($process.ExitCode))."
                    if ($stderrText) {
                        Write-Error "Daemon stderr:"; Get-Content $daemonStdErrFile | ForEach-Object { Write-Error "  $_" }
                    }
                }

                return $false
            }

            if (Test-Path $daemonStateFile) {
                $status = Get-DaemonStatus
                if ($status.running) {
                    $daemonRunning = $true
                    break
                }
            }

            if ($waited % 5 -eq 0) {
                Write-Host "  ... waiting for daemon initialization ($waited/$maxWaitForStart seconds)"
            }
        }

        if (-not $daemonRunning) {
            $stderrText = if (Test-Path $daemonStdErrFile) { Get-Content -Raw -Path $daemonStdErrFile -ErrorAction SilentlyContinue } else { '' }

            if ($stderrText -match $mutexErrorToken) {
                Write-Error "Daemon single-instance lock prevented startup for data directory '$absDataPath'."
                Write-Error "Stop the existing daemon first or use a different -DataDir."
            }

            Write-Error "Daemon failed to initialize within $maxWaitForStart seconds"
            $logPath = Join-Path $DataPath '_daemon.log'
            if (Test-Path $logPath) {
                Write-Error "Daemon log:"; Get-Content $logPath | ForEach-Object { Write-Error "  $_" }
            }
            if (Test-Path $daemonStdErrFile) {
                Write-Error "Daemon stderr:"; Get-Content $daemonStdErrFile | ForEach-Object { Write-Error "  $_" }
            }
            return $false
        }

        $actualStatus = Get-DaemonStatus
        Write-Host "[OK] Daemon initialized (PID: $($actualStatus.processId))"
        $script:DaemonStartedByCollector = $true

        # Wait for PropertyServer connection
        Write-Host "Waiting for PropertyServer connection..."
        $maxWaitForConnection = 30
        $connectionWait = 0

        while ($connectionWait -lt $maxWaitForConnection) {
            Start-Sleep -Seconds 1
            $connectionWait++

            $status = Get-DaemonStatus
            if ($status.connected) {
                Write-Host "[OK] Connected to PropertyServer"
                return $true
            }

            if ($connectionWait % 5 -eq 0) {
                Write-Host "  ... still waiting for PropertyServer ($connectionWait/$maxWaitForConnection seconds)"
            }
        }

        Write-Host "[WARN] PropertyServer not responding (daemon will retry in background)"
        Write-Host "  Make sure SimHub is running and streaming on 127.0.0.1:18082"
        return $true
    }
    catch {
        Write-Error "Failed to start daemon: $_"
        return $false
    }
}

function Stop-CollectorDaemon {
    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    $targetPid = $null

    if (Test-Path $pidFile) {
        $pidText = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($pidText -and ($pidText -as [int])) {
            $candidatePid = [int]$pidText
            if (Test-DaemonProcessIdentity -ProcessId $candidatePid) {
                $targetPid = $candidatePid
            }
        }
    }

    if (-not $targetPid) {
        $status = Get-DaemonStatus
        if ($status.processId -and ($status.processId -as [int])) {
            $candidatePid = [int]$status.processId
            if (Test-DaemonProcessIdentity -ProcessId $candidatePid) {
                $targetPid = $candidatePid
            }
        }
    }

    if (-not $targetPid) {
        return $true
    }

    # Ask daemon to stop gracefully first.
    $daemonControlFile = Join-Path $DataPath '_daemon_control.txt'
    Set-Content -Path $daemonControlFile -Value 'STOP' -ErrorAction SilentlyContinue

    $waitedMs = 0
    while ($waitedMs -lt 5000) {
        Start-Sleep -Milliseconds 200
        $waitedMs += 200
        if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
            Remove-Item $pidFile -ErrorAction SilentlyContinue
            return $true
        }
    }

    Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
        & taskkill /PID $targetPid /T /F | Out-Null
        Start-Sleep -Milliseconds 500
    }

    $stillRunning = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $stillRunning) {
        Remove-Item $pidFile -ErrorAction SilentlyContinue
        return $true
    }

    return $false
}

# ==================== Session/Lap State Retrieval ====================

function Get-DaemonProperties {
    if (-not (Test-Path $daemonStateFile)) {
        return $null
    }

    try {
        $state = Get-Content -Raw -Path $daemonStateFile | ConvertFrom-Json

        # Ignore stale daemon state to avoid persisting duplicate rows when daemon is dead.
        if ($state.processId) {
            if (-not (Test-DaemonProcessIdentity -ProcessId ([int]$state.processId))) {
                return $null
            }
        }

        if ($state.lastUpdate) {
            $lastUpdate = [datetime]$state.lastUpdate
            if (((Get-Date) - $lastUpdate).TotalSeconds -gt 10) {
                return $null
            }
        }
        else {
            return $null
        }
        
        # Convert daemon properties to hashtable
        $propValues = @{}
        if ($state.properties) {
            $state.properties.PSObject.Properties | ForEach-Object {
                $propValues[$_.Name] = $_.Value
            }
        }

        return $propValues
    }
    catch {
        return $null
    }
}

function Test-SessionChanged {
    param(
        [hashtable]$CurrentProps,
        [string]$CsvPath
    )
    
    # If CSV doesn't exist yet, this is the first entry
    if (-not (Test-Path $CsvPath)) {
        return $true
    }
    
    # Get current session and lap
    $currentSession = Get-OrDefault $CurrentProps['dcp.gd.SessionTypeName'] $CurrentProps['SessionTypeName']
    $currentLapRaw = Get-OrDefault $CurrentProps['dcp.gd.CurrentLap'] $CurrentProps['CurrentLap']
    $currentLap = [int](Get-OrDefault $currentLapRaw 0)
    
    if ([string]::IsNullOrWhiteSpace([string]$currentSession)) {
        return $false
    }
    
    # Read last row from CSV
    try {
        $csv = Import-Csv $CsvPath -ErrorAction SilentlyContinue
        if ($null -eq $csv -or $csv.Count -eq 0) {
            return $true
        }
        
        # Get the last row
        $lastRow = if ($csv -is [array]) { $csv[-1] } else { $csv }
        
        # Compare session name and lap number
        $lastSession = $lastRow.SessionName
        $lastLap = [int](Get-OrDefault $lastRow.LapNumber 0)
        
        # Write entry if session changed or lap changed
        if ($currentSession -ne $lastSession -or $currentLap -ne $lastLap) {
            return $true
        }
        
        return $false
    }
    catch {
        # If we can't read CSV, assume it's a new entry
        return $true
    }
}

# ==================== CSV Persistence ====================

function Write-DataToCsv {
    param(
        [hashtable]$Properties,
        [hashtable]$PreviousState
    )
    
    # Clean property keys
    $cleaned = @{}
    foreach ($k in $Properties.Keys) {
        $newKey = $k -replace '^(dcp\.gd\.|dcp\.|DataCorePlugin\.Computed\.)', ''
        $cleaned[$newKey] = $Properties[$k]
    }

    # --- Session CSV ---
    $sessionObj = [PSCustomObject]@{
        Timestamp          = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        GameName           = $cleaned.GameName
        Driver             = $cleaned.PlayerName
        Car                = $cleaned.CarModel
        CarClass           = $cleaned.CarClass
        Track              = $cleaned.TrackName
        SessionType        = $cleaned.SessionTypeName
        Position           = $cleaned.Position
        CurrentLap         = $cleaned.CurrentLap
        CompletedLaps      = $cleaned.CompletedLaps
        TotalLaps          = $cleaned.TotalLaps
        SessionTimeLeft    = $cleaned.SessionTimeLeft
        SessionBestLapTime = $cleaned.BestLapTime
        LastLap            = $cleaned.LastLapTime
        CurrentFuel        = $cleaned.Fuel
        FuelUnit           = $cleaned.FuelUnit
        Fuel_LitersPerLap  = $cleaned.Fuel_LitersPerLap
        Fuel_RemainingLaps = $cleaned.Fuel_RemainingLaps
        Fuel_RemainingTime = $cleaned.Fuel_RemainingTime
    }

    # Append or create session CSV
    if (-not (Test-Path $SessionCsvPath)) {
        $sessionObj | Write-CsvExclusive -Path $SessionCsvPath | Out-Null
    }
    else {
        $existing = @(Import-Csv $SessionCsvPath)
        $existing += $sessionObj
        $existing | Write-CsvExclusive -Path $SessionCsvPath | Out-Null
    }

    # --- Lap CSV ---
    $lapNumber = [int](Get-OrDefault $cleaned.CurrentLap ($PreviousState.LapCount + 1))
    $position = $cleaned.Position
    $lastLapTime = $cleaned.LastLapTime
    $bestLapTime = $cleaned.BestLapTime
    $fuel = [double](Get-OrDefault $cleaned.Fuel 0)

    $tyreWear = Get-AvgTyreWear $cleaned
    $tyreWearFL = [double](Get-OrDefault $cleaned.TyreWearFrontLeft 0)
    $tyreWearFR = [double](Get-OrDefault $cleaned.TyreWearFrontRight 0)
    $tyreWearRL = [double](Get-OrDefault $cleaned.TyreWearRearLeft 0)
    $tyreWearRR = [double](Get-OrDefault $cleaned.TyreWearRearRight 0)

    # Calculate deltas
    $bestLapTS = Parse-TimeSpanSafe $bestLapTime
    $lastLapTS = Parse-TimeSpanSafe $lastLapTime
    $deltaToSessionBestLapTime = if ($bestLapTS -and $lastLapTS) { [math]::Round(($lastLapTS - $bestLapTS).TotalSeconds, 3) } else { 0 }
    $deltaFuelUsage = if ($PreviousState.PrevFuel) { [math]::Round([double]$PreviousState.PrevFuel - $fuel, 3) } else { 0 }

    $currentLapIsValidForTracking = ConvertTo-BoolSafe $Properties['DataCorePlugin.Computed.Fuel_CurrentLapIsValidForTracking']

    $maxFuel = $null
    $maxFuelText = [string]$Properties['DataCorePlugin.GameData.CarSettings_MaxFUEL']
    if (-not [string]::IsNullOrWhiteSpace($maxFuelText)) {
        try {
            $maxFuel = [double]$maxFuelText
        }
        catch {
            $maxFuel = $null
        }
    }

    $lapsSinceLastPit = ConvertTo-NullableInt $Properties['IRacingExtraProperties.iRacing_Player_LapsSinceLastPit']
    $lastPitLaneDuration = Get-TimeSpanSafe $Properties['IRacingExtraProperties.iRacing_Player_LastPitLaneDuration']
    $lastPitStopDuration = Get-TimeSpanSafe $Properties['IRacingExtraProperties.iRacing_Player_LastPitStopDuration']
    if ($null -eq $lastPitStopDuration) {
        $lastPitStopDuration = Get-TimeSpanSafe $cleaned.LastPitStopDuration
    }
    if ($null -eq $lastPitStopDuration) {
        $lastPitStopDuration = Get-TimeSpanSafe $Properties['DataCorePlugin.GameData.LastPitStopDuration']
    }

    $lapObj = [PSCustomObject]@{
        Timestamp                    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        GameName                     = $cleaned.GameName
        Car                          = $cleaned.CarModel
        CarClass                     = $cleaned.CarClass
        Track                        = $cleaned.TrackName
        SessionName                  = $cleaned.SessionTypeName
        LapNumber                    = $lapNumber
        Position                     = $position
        CompletedLaps                = $cleaned.CompletedLaps
        TotalLaps                    = $cleaned.TotalLaps
        SessionTimeLeft              = $cleaned.SessionTimeLeft
        LastLapTime                  = $lastLapTime
        BestLapTime                  = $bestLapTime
        Fuel                         = $fuel
        TyreWear                     = $tyreWear
        TyreWearFrontLeft            = $tyreWearFL
        TyreWearFrontRight           = $tyreWearFR
        TyreWearRearLeft             = $tyreWearRL
        TyreWearRearRight            = $tyreWearRR
        deltaToSessionBestLapTime    = $deltaToSessionBestLapTime
        deltaFuelUsage               = $deltaFuelUsage
        Fuel_LitersPerLap            = $cleaned.Fuel_LitersPerLap
        Fuel_LastLapConsumption      = $cleaned.Fuel_LastLapConsumption
        Fuel_RemainingLaps           = $cleaned.Fuel_RemainingLaps
        Fuel_RemainingTime           = $cleaned.Fuel_RemainingTime
        CurrentLapIsValidForTracking = $currentLapIsValidForTracking
        MaxFuel                      = $maxFuel
        LapsSinceLastPit             = $lapsSinceLastPit
        LastPitLaneDuration          = $lastPitLaneDuration
        LastPitStopDuration          = $lastPitStopDuration
    }

    # Upsert lap CSV (update existing lap or add new)
    if (-not (Test-Path $LapsCsvPath)) {
        $lapObj | Write-CsvExclusive -Path $LapsCsvPath | Out-Null
        Write-Debug "Upsert: Created new CSV with $($cleaned.SessionTypeName) Lap $lapNumber"
    }
    else {
        $existing = @(Import-Csv $LapsCsvPath)
        $existingCount = $existing.Count
        
        # Normalize current session name for comparison
        $currentSession = if ([string]::IsNullOrWhiteSpace($cleaned.SessionTypeName)) { "" } else { $cleaned.SessionTypeName.Trim() }
        $currentLapNum = [int]$lapNumber
        
        Write-Debug "Upsert: Looking for match - $currentSession / Lap $currentLapNum in $existingCount existing rows"
        
        # Build new array, updating duplicate or appending new
        $foundMatch = $false
        $newExisting = @()
        
        foreach ($existingLap in $existing) {
            # Normalize existing session name (handle null, whitespace, type conversion)
            [string]$existingSession = if ([string]::IsNullOrWhiteSpace($existingLap.SessionName)) { "" } else { $existingLap.SessionName.Trim() }
            [int]$existingLapNum = 0
            
            # Try to parse lap number
            if (-not [string]::IsNullOrWhiteSpace($existingLap.LapNumber)) {
                [int]::TryParse($existingLap.LapNumber.Trim(), [ref]$existingLapNum) | Out-Null
            }
            
            # Check composite key: SessionName + LapNumber
            if ($existingSession -eq $currentSession -and $existingLapNum -eq $currentLapNum) {
                # This is a duplicate - replace with updated lap
                Write-Debug "Upsert: [OK] Found and updating: $existingSession / Lap $existingLapNum"
                $newExisting += $lapObj
                $foundMatch = $true
            }
            else {
                # Keep existing lap
                $newExisting += $existingLap
            }
        }
        
        # If lap wasn't found, append it
        if (-not $foundMatch) {
            Write-Debug "Upsert: [NEW] No match found - appending: $currentSession / Lap $currentLapNum"
            $newExisting += $lapObj
        }
        
        # Export updated array
        $newExisting | Write-CsvExclusive -Path $LapsCsvPath | Out-Null
    }

    # Update state
    $PreviousState.BestLapTime = $bestLapTime
    $PreviousState.PrevTyreWear = $tyreWear
    $PreviousState.PrevFuel = $fuel
    $PreviousState.LapCount = $lapNumber
    $PreviousState.SessionName = $cleaned.SessionTypeName
    Write-JsonExclusive -Json ($PreviousState | ConvertTo-Json) -Path $statePath
}

# ==================== Session Start/Stop Handlers ====================

if ($Reset) {
    Write-Host "==================== SimHub Data Reset ===================="
    Write-Host "DataDir: $DataPath"

    if (-not (Test-Path $DataPath)) {
        Write-Host "[WARN] DataDir does not exist - nothing to reset: $DataPath"
        exit 0
    }

    # Step 1: Graceful daemon stop via control file
    Write-Host "Sending stop signal to daemon..."
    $daemonControlFile = Join-Path $DataPath '_daemon_control.txt'
    Set-Content -Path $daemonControlFile -Value 'STOP' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Step 2: Force-kill daemon by PID file
    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    if (Test-Path $pidFile) {
        $storedPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($storedPid -and ($storedPid -as [int])) {
            $daemonProc = Get-Process -Id ([int]$storedPid) -ErrorAction SilentlyContinue
            if ($daemonProc) {
                Write-Host "Force-killing daemon (PID: $storedPid)..."
                Stop-Process -Id ([int]$storedPid) -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                Write-Host "[OK] Daemon killed"
            }
        }
    }

    # Step 3: Kill any remaining processes with command lines referencing this DataDir or these scripts
    $resolvedDataPath = Resolve-Path $DataPath -ErrorAction SilentlyContinue
    if ($resolvedDataPath) {
        $absDataPath = $resolvedDataPath.Path
    }
    else {
        $absDataPath = $DataPath
    }
    $scriptPatterns = @(
        [regex]::Escape($absDataPath),
        [regex]::Escape((Split-Path $daemonScriptFile -Leaf)),
        [regex]::Escape((Split-Path $PSCommandPath -Leaf))
    )
    $combinedPattern = $scriptPatterns -join '|'

    $relatedProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $combinedPattern -and $_.ProcessId -ne $PID }

    if ($relatedProcs) {
        foreach ($proc in $relatedProcs) {
            Write-Host "Force-killing related process (PID: $($proc.ProcessId) - $($proc.Name))..."
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        Write-Host "[OK] Related processes killed"
    }
    else {
        Write-Host "[OK] No related processes found"
    }

    # Step 4: Remove all data files
    Write-Host "Removing data files..."
    $filesToRemove = @(
        $SessionCsvPath,
        $LapsCsvPath,
        $EventsCsvPath,
        $statePath,
        $eventStatePath,
        $collectorPidFile,
        $collectorControlFile,
        (Join-Path $DataPath '_daemon_state.json'),
        (Join-Path $DataPath '_daemon_pid.txt'),
        (Join-Path $DataPath '_daemon.log'),
        (Join-Path $DataPath '_daemon_stdout.log'),
        (Join-Path $DataPath '_daemon_stderr.log'),
        (Join-Path $DataPath '_daemon_control.txt'),
        (Join-Path $DataPath 'summary.csv')
    )

    foreach ($file in $filesToRemove) {
        if (Test-Path $file) {
            Remove-Item $file -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed: $(Split-Path $file -Leaf)"
        }
    }

    Write-Host "[OK] Reset complete - $DataPath is clean"
    exit 0
}

if ($Stop) {
    Write-Host "Stopping daemon and finalizing session..."

    Write-Host "Stopping collector process..."
    $collectorStopOk = Stop-RunningCollector
    if ($collectorStopOk) {
        Write-Host "[OK] Collector stopped"
    }
    else {
        Write-Warning "Collector could not be terminated cleanly"
    }
    
    # Stop the daemon process
    Write-Host "Stopping PropertyServer daemon..."
    $stopOk = $true
    try {
        & $daemonScriptFile -Stop -DataDir $DataPath | Out-Null
    }
    catch {
        $stopOk = $false
        Write-Warning "Daemon stop command failed: $_"
    }

    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    if (Test-Path $pidFile) {
        $daemonPidText = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($daemonPidText -and ($daemonPidText -as [int])) {
            $daemonPid = [int]$daemonPidText
            if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
                Write-Warning "Daemon still running after stop command (PID: $daemonPid). Forcing termination..."
                Stop-Process -Id $daemonPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
                    & taskkill /PID $daemonPid /T /F | Out-Null
                    Start-Sleep -Milliseconds 500
                }
            }
        }
    }

    $remainingDaemon = $false
    if (Test-Path $pidFile) {
        $daemonPidText = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($daemonPidText -and ($daemonPidText -as [int])) {
            $remainingDaemon = $null -ne (Get-Process -Id ([int]$daemonPidText) -ErrorAction SilentlyContinue)
        }
    }

    if ($remainingDaemon) {
        Write-Error "Failed to stop daemon process; it is still running."
        exit 1
    }

    if ($stopOk) {
        Write-Host "[OK] Daemon stopped"
    }
    else {
        Write-Warning "Daemon stop completed via forced termination"
    }
    
    # Clean up state file
    Remove-Item $statePath -ErrorAction SilentlyContinue
    Remove-Item $eventStatePath -ErrorAction SilentlyContinue
    
    # Generate summary if data exists
    if ((Test-Path $SessionCsvPath) -and (Test-Path $LapsCsvPath)) {
        try {
            $summaryPath = Join-Path $DataPath "summary.csv"
            $session = Import-Csv $SessionCsvPath | Select-Object -Last 1
            $laps = Import-Csv $LapsCsvPath
            
            if ($null -ne $session -and $null -ne $laps) {
                $sessionName = $session.SessionType
                $lapsInSession = if ($laps -is [array]) { $laps.Count } else { 1 }
                $lapTimes = $laps | ForEach-Object { [double]($_.LastLapTime -replace '[^0-9\.]', '') } | Where-Object { $_ -gt 0 }
                $bestLap = if ($lapTimes.Count -gt 0) { ($lapTimes | Measure-Object -Minimum).Minimum } else { 'N/A' }
                $worstLap = if ($lapTimes.Count -gt 0) { ($lapTimes | Measure-Object -Maximum).Maximum } else { 'N/A' }
                $avgLap = if ($lapTimes.Count -gt 0) { [math]::Round(($lapTimes | Measure-Object -Average).Average, 3) } else { 'N/A' }
                $fuelConsumptions = $laps | ForEach-Object { [double]($_.Fuel_LastLapConsumption) } | Where-Object { $_ -gt 0 }
                $bestFuel = if ($fuelConsumptions.Count -gt 0) { ($fuelConsumptions | Measure-Object -Minimum).Minimum } else { 'N/A' }
                $worstFuel = if ($fuelConsumptions.Count -gt 0) { ($fuelConsumptions | Measure-Object -Maximum).Maximum } else { 'N/A' }
                $avgFuel = if ($fuelConsumptions.Count -gt 0) { [math]::Round(($fuelConsumptions | Measure-Object -Average).Average, 3) } else { 'N/A' }
                
                $summaryObj = [PSCustomObject]@{
                    Session                = $sessionName
                    LapsInSession          = $lapsInSession
                    BestLapTime            = $bestLap
                    WorstLapTime           = $worstLap
                    AverageLapTime         = $avgLap
                    BestFuelConsumption    = $bestFuel
                    WorstFuelConsumption   = $worstFuel
                    AverageFuelConsumption = $avgFuel
                }
                
                $summaryObj | Write-CsvExclusive -Path $summaryPath | Out-Null
                Write-Host "[OK] Summary written to summary.csv"
            }
        }
        catch {
            Write-Warning "Failed to generate summary: $_"
        }
    }
    else {
        Write-Host "[WARN] Session or lap CSV not found, skipping summary generation"
    }
    
    Write-Host "[OK] Session finalized"
    exit 0
}

# ==================== Long-Running Collection Mode ====================

Write-Host "==================== SimHub Data Collection Service ===================="

# Register this process as the collector owner candidate for this DataDir.
Set-Content -Path $collectorPidFile -Value $PID -ErrorAction SilentlyContinue
Remove-Item $collectorControlFile -ErrorAction SilentlyContinue

# Acquire single-instance collector mutex for this DataDir before any startup cleanup.
if (-not (Acquire-CollectorMutex)) {
    Remove-Item $collectorPidFile -ErrorAction SilentlyContinue
    Write-Error "Another collector instance is already running for data directory '$DataPath'."
    Write-Error "Stop the existing collector first or use a different -DataDir."
    exit 1
}

# Initialize new session if -Start flag is set
if ($Start) {
    Write-Host "Initializing new session..."
    
    # Kill any orphaned daemon processes
    $pidFile = Join-Path $DataPath '_daemon_pid.txt'
    if (Test-Path $pidFile) {
        $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($oldPid -and ($oldPid -as [int])) {
            try {
                [int]$oldPidInt = [int]$oldPid
                $oldProcess = if (Test-DaemonProcessIdentity -ProcessId $oldPidInt) {
                    Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue
                }
                else {
                    $null
                }
                if ($oldProcess) {
                    Write-Host "[WARN] Killing orphaned daemon process (PID: $oldPidInt)"
                    Stop-Process -Id $oldPidInt -Force -ErrorAction SilentlyContinue

                    $killWaitMs = 0
                    while ($killWaitMs -lt 5000) {
                        Start-Sleep -Milliseconds 200
                        $killWaitMs += 200
                        $stillRunning = Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue
                        if (-not $stillRunning) {
                            break
                        }
                    }

                    if (Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue) {
                        Write-Warning "Stop-Process did not terminate PID $oldPidInt, forcing with taskkill..."
                        & taskkill /PID $oldPidInt /T /F | Out-Null
                        Start-Sleep -Milliseconds 500
                    }

                    if (Get-Process -Id $oldPidInt -ErrorAction SilentlyContinue) {
                        Write-Error "Failed to terminate orphan daemon PID $oldPidInt. Resolve this process before starting collection."
                        exit 1
                    }

                    Write-Host "[OK] Orphan daemon process terminated"
                }
            }
            catch {}
        }
    }

    # Clear stale daemon metadata so startup checks cannot be fooled by old state.
    Remove-Item (Join-Path $DataPath '_daemon_pid.txt') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $DataPath '_daemon_state.json') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $DataPath '_daemon_control.txt') -ErrorAction SilentlyContinue
    
    # Check if CSV files are locked (indicates running process)
    $csvFiles = @($LapsCsvPath, $SessionCsvPath)
    $lockedBy = $null
    
    foreach ($csvFile in $csvFiles) {
        if (-not (Test-Path $csvFile)) { continue }
        
        try {
            # Try non-blocking check: if file exists but can't be opened, it's likely locked
            [System.IO.File]::GetAttributes($csvFile) | Out-Null
            
            # File exists and is accessible, try a quick exclusive open check
            $fileStream = [System.IO.File]::Open($csvFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $fileStream.Close()
        }
        catch [System.IO.IOException] {
            # File is locked - try to identify which process has it
            if (Test-Path $pidFile) {
                $daemonPid = Get-Content $pidFile -ErrorAction SilentlyContinue
                if ($daemonPid -and ($daemonPid -as [int])) {
                    $runningProcess = Get-Process -Id $daemonPid -ErrorAction SilentlyContinue
                    if ($runningProcess) {
                        $lockedBy = "PID $daemonPid (ProcessName: $($runningProcess.ProcessName))"
                    }
                }
            }
            
            Write-Error "CSV file is locked by another process: $csvFile"
            if ($lockedBy) {
                Write-Error "Locked by: $lockedBy"
            }
            Write-Error "Stop the running daemon with: .\Get-SimHub-Data.ps1 -Stop -DataDir $DataPath"
            exit 1
        }
        catch {
            # Other error, ignore and continue
        }
    }
    
    Remove-Item $LapsCsvPath -ErrorAction SilentlyContinue
    Remove-Item $SessionCsvPath -ErrorAction SilentlyContinue
    Remove-Item $EventsCsvPath -ErrorAction SilentlyContinue
    Remove-Item $statePath -ErrorAction SilentlyContinue
    Remove-Item $eventStatePath -ErrorAction SilentlyContinue
    Write-Host "[OK] CSV files cleared"
}

Write-Host "Starting continuous collection (Ctrl+C to stop)..."
Write-Host ""

# Ensure daemon is running
if (-not (Start-PropertyDaemon)) {
    Release-CollectorMutex
    Write-Error "Failed to start PropertyServer daemon"
    exit 1
}

$eventConfig = Get-EventConfig -ConfigPath $eventConfigPath
$enabledEvents = @($eventConfig.Values | Where-Object { $_.Enabled } | ForEach-Object { $_.EventName } | Sort-Object)
if ($enabledEvents.Count -gt 0) {
    Write-Host "Enabled event triggers: $($enabledEvents -join ', ')" -ForegroundColor Cyan
}
else {
    Write-Host "No event triggers are enabled." -ForegroundColor Yellow
}

# Load or initialize state
if (Test-Path $statePath) {
    $lapState = Get-Content $statePath | ConvertFrom-Json | ConvertTo-Hashtable
}
else {
    $lapState = @{ 
        BestLapTime          = $null
        PrevTyreWear         = $null
        PrevFuel             = $null
        LapCount             = 0
        SessionName          = $null
        InitialRecordCreated = $false
    }
}

$eventState = Get-EventState -Path $eventStatePath

# Wait for daemon to connect and get initial property values
Write-Host "Waiting for PropertyServer to connect..." -ForegroundColor Yellow
$initialConnectWaitTime = 0
$maxInitialConnectWait = 30000  # 30 seconds max wait
while ($initialConnectWaitTime -lt $maxInitialConnectWait) {
    $daemonStatus = Get-DaemonStatus
    $propValues = Get-DaemonProperties
    
    if ($daemonStatus.connected -and $propValues -and $propValues.Count -gt 0) {
        Write-Host "[OK] PropertyServer connected with $(($propValues | Measure-Object).Count) properties" -ForegroundColor Green
        
        # Create initial session record from property baseline
        if (-not $lapState.InitialRecordCreated) {
            Write-Host "Recording initial session baseline..." -ForegroundColor Green
            
            # Create baseline session record
            $cleaned = @{}
            foreach ($k in $propValues.Keys) {
                $newKey = $k -replace '^(dcp\.gd\.|dcp\.|DataCorePlugin\.Computed\.)', ''
                $cleaned[$newKey] = $propValues[$k]
            }
            
            $initialSession = [PSCustomObject]@{
                Timestamp          = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                GameName           = $cleaned.GameName
                Driver             = $cleaned.PlayerName
                Car                = $cleaned.CarModel
                CarClass           = $cleaned.CarClass
                Track              = $cleaned.TrackName
                SessionType        = $cleaned.SessionTypeName
                Position           = $cleaned.Position
                CurrentLap         = $cleaned.CurrentLap
                CompletedLaps      = $cleaned.CompletedLaps
                TotalLaps          = $cleaned.TotalLaps
                SessionTimeLeft    = $cleaned.SessionTimeLeft
                SessionBestLapTime = $cleaned.BestLapTime
                LastLap            = $cleaned.LastLapTime
                CurrentFuel        = $cleaned.Fuel
                FuelUnit           = $cleaned.FuelUnit
                Fuel_LitersPerLap  = $cleaned.Fuel_LitersPerLap
                Fuel_RemainingLaps = $cleaned.Fuel_RemainingLaps
                Fuel_RemainingTime = $cleaned.Fuel_RemainingTime
            }
            
            $initialSession | Write-CsvExclusive -Path $SessionCsvPath | Out-Null
            Write-Host "  [OK] Initial session record created" -ForegroundColor Green
            Write-Host "    Game: $($initialSession.GameName) | Track: $($initialSession.Track) | Driver: $($initialSession.Driver)"
            
            $lapState.InitialRecordCreated = $true
            $lapState.SessionName = $cleaned.SessionTypeName
            $lapState.LapCount = [int](Get-OrDefault $cleaned.CurrentLap 0)
            
            # Persisting initial state so that subsequent lap changes can be detected
            Write-JsonExclusive -Json ($lapState | ConvertTo-Json) -Path $statePath
        }
        
        break
    }
    
    Start-Sleep -Milliseconds 500
    $initialConnectWaitTime += 500
}

if ($initialConnectWaitTime -ge $maxInitialConnectWait) {
    Write-Host "[FAIL] PropertyServer did not connect within $($maxInitialConnectWait / 1000) seconds" -ForegroundColor Red
    Write-Host "  Continuing without initial baseline (will start recording on lap change)" -ForegroundColor Yellow
}

# Main collection loop
$collectionCount = 0
$lastStatusTime = Get-Date

try {
    while ($true) {
        if (Test-Path $collectorControlFile) {
            $controlValue = Get-Content $collectorControlFile -ErrorAction SilentlyContinue
            if ([string]::Equals(([string]$controlValue).Trim(), 'STOP', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "Collector stop requested" -ForegroundColor Yellow
                break
            }
        }

        # Get current properties from daemon
        $propValues = Get-DaemonProperties
        
        if ($null -eq $propValues -or $propValues.Count -eq 0) {
            # Print status every 10 seconds while waiting
            $now = Get-Date
            if (($now - $lastStatusTime).TotalSeconds -ge 10) {
                $daemonStatus = Get-DaemonStatus
                if (-not $daemonStatus.connected) {
                    Write-Host "$(Get-Date -Format 'HH:mm:ss') [WAIT] Waiting for PropertyServer data... (Ctrl+C to stop)" -ForegroundColor Yellow
                }
                else {
                    Write-Host "$(Get-Date -Format 'HH:mm:ss') [WAIT] Listening for session/lap changes... (Ctrl+C to stop)" -ForegroundColor Yellow
                }
                $lastStatusTime = $now
            }
            Start-Sleep -Seconds $UpdateInterval
            continue
        }

        # Check if session/lap changed
        if (Test-SessionChanged $propValues $LapsCsvPath) {
            $currentLap = [int](Get-OrDefault $propValues['dcp.gd.CurrentLap'] $propValues['CurrentLap'] 0)
            Write-Host "$(Get-Date -Format 'HH:mm:ss') [Lap $currentLap] Writing data..." -ForegroundColor Green
            
            Write-DataToCsv $propValues $lapState
            $collectionCount++
            Write-Host "  [OK] Data persisted (entry #$collectionCount)"
            $lastStatusTime = Get-Date  # Reset status timer after writing
        }

        $cleanedProperties = ConvertTo-CleanedProperties -Properties $propValues
        $triggeredEvents = Evaluate-ConfiguredEvents -RawProperties $propValues -CleanedProperties $cleanedProperties -EventConfig $eventConfig -EventState $eventState

        if ($triggeredEvents.Count -gt 0) {
            Write-EventsToCsv -Events $triggeredEvents -Path $EventsCsvPath
            $eventNames = @($triggeredEvents | ForEach-Object { $_.EventName })
            Write-Host "$(Get-Date -Format 'HH:mm:ss') Event(s): $($eventNames -join ', ')" -ForegroundColor Magenta
            Invoke-DiscordNotificationsForEvents -Events $triggeredEvents -DataDirectory $DataDir
        }

        Save-EventState -EventState $eventState -Path $eventStatePath
        
        Start-Sleep -Seconds $UpdateInterval
    }
}
catch {
    # Handle cancellation gracefully but let it propagate if it's a cancellation
    if ($_ -is [System.OperationCanceledException] -or $_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        Write-Host ""
        Write-Host "Collection stopped by user" -ForegroundColor Yellow
    }
    else {
        Write-Error "Collection error: $_"
    }
}
finally {
    Remove-Item $collectorPidFile -ErrorAction SilentlyContinue
    Remove-Item $collectorControlFile -ErrorAction SilentlyContinue
    Release-CollectorMutex
    if ($script:DaemonStartedByCollector) {
        try {
            Write-Host "Stopping daemon started by collector..." -ForegroundColor Yellow
            if (Stop-CollectorDaemon) {
                Write-Host "[OK] Collector daemon stopped" -ForegroundColor Green
            }
            else {
                Write-Warning "Collector daemon could not be terminated cleanly"
            }
        }
        catch {
            Write-Warning "Failed to stop collector-started daemon: $_"
        }
        finally {
            $script:DaemonStartedByCollector = $false
        }
    }
}


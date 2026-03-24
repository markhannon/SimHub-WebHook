########################################################
# Sample Data Collection Test Script
# 
# Starts continuous data collection with -DataDir 'samples'
# Runs until manually stopped with Ctrl+C
# Then cleanly shuts down with -Stop
########################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DataDir = 'samples'
)

$ScriptDir = $PSScriptRoot
$dataCollectionScript = Join-Path $ScriptDir 'Get-SimHub-Data.ps1'
$dataDir = $DataDir

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Sample SimHub Data Collection Test" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Script: Get-SimHub-Data.ps1"
Write-Host "  Data Directory: $dataDir"
Write-Host "  CSV Location: .\$dataDir\*.csv"
Write-Host ""
Write-Host "Instructions:" -ForegroundColor Yellow
Write-Host "  * Press Ctrl+C to stop collection and finalize session"
Write-Host "  * Summary will be generated in .\$dataDir\summary.csv"
Write-Host ""
Write-Host "Starting collection..." -ForegroundColor Green
Write-Host ""

$collectionFailure = $false
$finalizationFailure = $false
$userInterrupted = $false
$startExitCode = $null
$stopExitCode = $null

try {
    # Start each sample capture from a clean state to avoid stale event/lap state carry-over.
    & $dataCollectionScript -Reset -DataDir $dataDir | Out-Null

    # Start collection with -Start in continuous mode
    & $dataCollectionScript -Start -DataDir $dataDir
    $startSuccess = $?
    $startExitCode = $LASTEXITCODE

    if (-not $startSuccess -or (($null -ne $startExitCode) -and ($startExitCode -ne 0))) {
        $collectionFailure = $true
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    # User interruption is not a failure by itself.
    $userInterrupted = $true
    Write-Host ""
    Write-Host "Collection stopped by user" -ForegroundColor Yellow
}
catch [System.OperationCanceledException] {
    # User interruption is not a failure by itself.
    $userInterrupted = $true
    Write-Host ""
    Write-Host "Collection stopped by user" -ForegroundColor Yellow
}
catch {
    # If any error occurs
    Write-Host ""
    Write-Host "Collection error: $_" -ForegroundColor Red
    $collectionFailure = $true
}
finally {
    # Always stop gracefully, even if script terminates unexpectedly
    Write-Host ""
    Write-Host "Finalizing session..." -ForegroundColor Yellow
    
    try {
        & $dataCollectionScript -Stop -DataDir $dataDir
        $stopSuccess = $?
        $stopExitCode = $LASTEXITCODE

        if (-not $stopSuccess -or (($null -ne $stopExitCode) -and ($stopExitCode -ne 0))) {
            $finalizationFailure = $true
        }
    }
    catch {
        Write-Warning "Error during finalization: $_"
        $finalizationFailure = $true
    }

    $sessionFailed = $collectionFailure -or $finalizationFailure
    
    Write-Host ""
    if ($sessionFailed) {
        Write-Host "================================================================" -ForegroundColor Red
        Write-Host "Session Failed" -ForegroundColor Red
        Write-Host "================================================================" -ForegroundColor Red
    }
    else {
        Write-Host "================================================================" -ForegroundColor Green
        Write-Host "Session Complete" -ForegroundColor Green
        Write-Host "================================================================" -ForegroundColor Green
    }

    if ($userInterrupted -and -not $sessionFailed) {
        Write-Host "Collection stopped by user and finalized successfully." -ForegroundColor Yellow
    }

    if ($collectionFailure) {
        Write-Host "Collection phase failed." -ForegroundColor Red
        if ($null -ne $startExitCode) {
            Write-Host "Collection exit code: $startExitCode" -ForegroundColor Red
        }
    }

    if ($finalizationFailure) {
        Write-Host "Finalization phase failed." -ForegroundColor Red
        if ($null -ne $stopExitCode) {
            Write-Host "Finalization exit code: $stopExitCode" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "Data Summary:" -ForegroundColor Cyan
    
    # Display summary if it was created
    $summaryPath = Join-Path (Join-Path $ScriptDir $dataDir) 'summary.csv'
    if (Test-Path $summaryPath) {
        Write-Host "[OK] Summary created: $summaryPath"
        Write-Host ""
        Import-Csv $summaryPath | Format-Table -AutoSize
    }
    
    # List all generated files
    $dataPath = Join-Path $ScriptDir $dataDir
    if (Test-Path $dataPath) {
        Write-Host ""
        Write-Host "Generated Files:" -ForegroundColor Cyan
        Get-ChildItem $dataPath -File | ForEach-Object {
            $size = "{0:N0}" -f $_.Length
            Write-Host "  * $($_.Name) ($size bytes)"
        }
    }
    
    Write-Host ""

    if ($sessionFailed) {
        exit 1
    }

    exit 0
}

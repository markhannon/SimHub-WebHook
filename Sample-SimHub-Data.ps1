########################################################
# Sample Data Collection Test Script
# 
# Starts continuous data collection with -DataDir 'samples'
# Runs until manually stopped with Ctrl+C
# Then cleanly shuts down with -Stop
########################################################

[CmdletBinding()]
param()

$ScriptDir = $PSScriptRoot
$dataCollectionScript = Join-Path $ScriptDir 'Get-SimHub-Data.ps1'
$dataDir = 'samples'

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Sample SimHub Data Collection Test                            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Script: Get-SimHub-Data.ps1"
Write-Host "  Data Directory: $dataDir"
Write-Host "  CSV Location: .\$dataDir\*.csv"
Write-Host ""
Write-Host "Instructions:" -ForegroundColor Yellow
Write-Host "  • Press Ctrl+C to stop collection and finalize session"
Write-Host "  • Summary will be generated in .\$dataDir\summary.csv"
Write-Host ""
Write-Host "Starting collection..." -ForegroundColor Green
Write-Host ""

$interruptedByUser = $false

# Set up trap for Ctrl+C (SIGINT)
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $interruptedByUser = $true
} -ErrorAction SilentlyContinue

try {
    # Start collection with -Start in continuous mode
    # Even though it's a blocking call, Ctrl+C will hit the trap
    & $dataCollectionScript -Start -DataDir $dataDir
}
catch {
    # If any error occurs
    Write-Host ""
    Write-Host "Collection error: $_" -ForegroundColor Red
    $interruptedByUser = $true
}
finally {
    # Always stop gracefully, even if script terminates unexpectedly
    Write-Host ""
    Write-Host "Finalizing session..." -ForegroundColor Yellow
    
    try {
        & $dataCollectionScript -Stop -DataDir $dataDir
    }
    catch {
        Write-Warning "Error during finalization: $_"
    }
    
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  Session Complete                                             ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Data Summary:" -ForegroundColor Cyan
    
    # Display summary if it was created
    $summaryPath = Join-Path $ScriptDir $dataDir 'summary.csv'
    if (Test-Path $summaryPath) {
        Write-Host "✓ Summary created: $summaryPath"
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
            Write-Host "  • $($_.Name) ($size bytes)"
        }
    }
    
    Write-Host ""
}

<#
.SYNOPSIS
    Cleanup PropertyServer daemon process
.DESCRIPTION
    Checks the status of the PropertyServer daemon, displays its status,
    and optionally kills it if it's still running.
.PARAMETER DataDir
    Data directory where the daemon PID file is stored (default: ./data)
.PARAMETER Force
    Force kill the daemon without confirmation
.EXAMPLE
    .\Cleanup-PropertyServer-Daemon.ps1
    .\Cleanup-PropertyServer-Daemon.ps1 -DataDir ./samples -Force
#>

param(
    [string]$DataDir = './data',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  PropertyServer Daemon Cleanup Utility                        ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Ensure data directory exists
if (-not (Test-Path $DataDir)) {
    Write-Host "✗ Data directory not found: $DataDir" -ForegroundColor Red
    exit 1
}

# Check for daemon PID file
$pidFile = Join-Path $DataDir '_daemon_pid.txt'

if (-not (Test-Path $pidFile)) {
    Write-Host "Status: No daemon PID file found ($pidFile)" -ForegroundColor Yellow
    Write-Host "        Daemon is not running or was never started" -ForegroundColor Yellow
    exit 0
}

# Read the PID
$daemonPid = Get-Content $pidFile -ErrorAction SilentlyContinue

if (-not $daemonPid -or -not ($daemonPid -as [int])) {
    Write-Host "Status: Invalid PID in PID file: '$daemonPid'" -ForegroundColor Yellow
    Write-Host "        Cleaning up invalid PID file..." -ForegroundColor Gray
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

Write-Host "Daemon PID: $daemonPid" -ForegroundColor Cyan

# Check if process is running
$process = Get-Process -Id $daemonPid -ErrorAction SilentlyContinue

if (-not $process) {
    Write-Host "Status: NOT RUNNING" -ForegroundColor Green
    Write-Host "        Cleaning up stale PID file..." -ForegroundColor Gray
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host "✓ PID file removed" -ForegroundColor Green
    exit 0
}

# Process is running - show status
Write-Host "Status: RUNNING" -ForegroundColor Yellow
Write-Host "  ProcessName: $($process.ProcessName)" -ForegroundColor Gray
Write-Host "  Parent PID:  $($process.Parent.Id)" -ForegroundColor Gray
Write-Host "  Memory:      $([Math]::Round($process.WorkingSet / 1MB, 2)) MB" -ForegroundColor Gray
Write-Host "  Threads:     $($process.Threads.Count)" -ForegroundColor Gray
Write-Host ""

# Prompt to kill if not forced
if (-not $Force) {
    $response = Read-Host "Kill this daemon? (y/n)"
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Host "✓ Daemon left running" -ForegroundColor Green
        exit 0
    }
}

# Kill the daemon
Write-Host "Stopping daemon..."  -ForegroundColor Gray
try {
    Stop-Process -Id $daemonPid -Force
    Start-Sleep -Milliseconds 500
    
    # Verify it's dead
    $stillRunning = Get-Process -Id $daemonPid -ErrorAction SilentlyContinue
    if ($stillRunning) {
        Write-Host "✗ Failed to kill process $daemonPid" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "✓ Daemon stopped successfully" -ForegroundColor Green
}
catch {
    Write-Host "✗ Error stopping daemon: $_" -ForegroundColor Red
    exit 1
}

# Clean up PID file
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Write-Host "✓ PID file cleaned up" -ForegroundColor Green

Write-Host ""
Write-Host "✓ Cleanup complete" -ForegroundColor Green
exit 0

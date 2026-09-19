#!/usr/bin/env pwsh
# scripts/demo-down.ps1 -- OracleGuard demo teardown (Windows)
# Stops the anvil process that was started by demo-up.ps1
# Usage: scripts\demo-down.ps1

$env:FOUNDRY_DISABLE_NIGHTLY_WARNING = "1"
$ErrorActionPreference = "Continue"   # non-fatal if process already gone

$PID_FILE = Join-Path $PSScriptRoot ".anvil.pid"

function Write-Step { param([string]$m) Write-Host "[demo-down] $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "   OK  $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  WARN $m" -ForegroundColor Yellow }

Write-Step "Stopping OracleGuard demo environment..."

if (Test-Path $PID_FILE) {
    $savedPid = (Get-Content $PID_FILE -Raw).Trim()
    if ($savedPid -match "^\d+$") {
        try {
            Stop-Process -Id ([int]$savedPid) -Force -ErrorAction Stop
            Write-OK "Killed anvil process (PID $savedPid)"
        } catch {
            Write-Warn "PID $savedPid not found -- anvil may have already exited."
        }
    }
    Remove-Item $PID_FILE -Force
} else {
    Write-Warn ".anvil.pid not found -- attempting to kill any process on port 8545..."
}

# Belt-and-suspenders: kill anything still holding port 8545
$pids = netstat -ano 2>$null |
    Select-String ":8545 " |
    ForEach-Object { ($_ -split "\s+")[-1] } |
    Select-Object -Unique |
    Where-Object { $_ -match "^\d+$" }

foreach ($p in $pids) {
    try {
        Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue
        Write-OK "Killed lingering process on :8545 (PID $p)"
    } catch {}
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " Demo stopped. Run scripts\demo-up.ps1 to restart." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green

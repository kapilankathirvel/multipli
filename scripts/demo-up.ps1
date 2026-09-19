#!/usr/bin/env pwsh
# scripts/demo-up.ps1 -- OracleGuard one-command demo environment (Windows)
#
# What this does (in order):
#   1. Starts anvil as a forked Mainnet sandbox in the background
#   2. Deploys OracleGuard contracts via forge script Deploy.s.sol
#   3. Funds the Admin Safe and runs the governance Spell (impersonated)
#   4. Takes an EVM snapshot, writes snapshotId into deployments/fork.json
#
# Usage:
#   cd multipli
#   $env:ETH_RPC_URL = "https://mainnet.gateway.tenderly.co"
#   scripts\demo-up.ps1
#
# Stop with: scripts\demo-down.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:FOUNDRY_DISABLE_NIGHTLY_WARNING = "1"   # suppress nightly build warnings from cast/forge/anvil

# -- Configuration (matches deployments/fork.example.json frozen schema) ----
$ANVIL_URL     = "http://127.0.0.1:8545"
$FORK_BLOCK    = 26011000
$CHAIN_ID      = 31337
$ADMIN_SAFE    = "0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99"
$ADMIN_BAL     = "0x56BC75E2D63100000"   # 100 ETH in hex wei
$ANVIL_KEY0    = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
$ANVIL_ADDR0   = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
$VAT           = "0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C"

$SCRIPTS_DIR   = $PSScriptRoot
$ROOT          = Split-Path $SCRIPTS_DIR -Parent
$CONTRACTS_DIR = Join-Path $ROOT "contracts"
$DEPLOY_DIR    = Join-Path $ROOT "deployments"
$FORK_JSON     = Join-Path $DEPLOY_DIR "fork.json"
$FORK_EXAMPLE  = Join-Path $DEPLOY_DIR "fork.example.json"
$PID_FILE      = Join-Path $SCRIPTS_DIR ".anvil.pid"

# -- Helpers -----------------------------------------------------------------
function Write-Step { param([string]$m) Write-Host "[demo-up] $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "   OK  $m" -ForegroundColor Green }
function Write-Skip { param([string]$m) Write-Host "   SKIP $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  ERR  $m" -ForegroundColor Red; exit 1 }

# -- Resolve ETH_RPC_URL (env > contracts/.env > default) --------------------
function Get-RpcUrl {
    if ($env:ETH_RPC_URL) { return $env:ETH_RPC_URL }
    $dotenv = Join-Path $CONTRACTS_DIR ".env"
    if (Test-Path $dotenv) {
        $line = Select-String -Path $dotenv -Pattern "^ETH_RPC_URL=" | Select-Object -First 1
        if ($line) { return ($line.Line -replace "^ETH_RPC_URL=", "").Trim() }
    }
    return "https://mainnet.gateway.tenderly.co"
}

# -- Check required tools ----------------------------------------------------
Write-Step "Checking required tools (anvil, forge, cast)..."
foreach ($tool in @("anvil", "forge", "cast")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fail "$tool not found in PATH. Add ~/.foundry/bin to PATH and retry."
    }
}
Write-OK "anvil, forge, cast found"

# ============================================================
# STEP 1: Start anvil forked mainnet in the background
# ============================================================
Write-Step "STEP 1: Starting anvil (fork-block $FORK_BLOCK)..."

$rpcUrl = Get-RpcUrl
Write-Host "         RPC source: $rpcUrl" -ForegroundColor Gray

# Kill any stale process on port 8545
$stale = netstat -ano 2>$null |
    Select-String ":8545 " |
    ForEach-Object { ($_ -split "\s+")[-1] } |
    Select-Object -Unique |
    Where-Object { $_ -match "^\d+$" }
foreach ($p in $stale) {
    try { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue } catch {}
}

$anvil = Start-Process `
    -FilePath "anvil" `
    -ArgumentList @(
        "--fork-url", $rpcUrl,
        "--fork-block-number", $FORK_BLOCK,
        "--auto-impersonate",
        "--chain-id", $CHAIN_ID,
        "--silent"
    ) `
    -PassThru -NoNewWindow

$anvil.Id | Out-File $PID_FILE -Encoding ASCII
Write-Host "         anvil PID $($anvil.Id) saved to $PID_FILE" -ForegroundColor Gray

# Poll until RPC is ready (up to 30 s)
Write-Host "         Waiting for RPC to be ready..." -ForegroundColor Gray
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-RestMethod `
            -Uri $ANVIL_URL -Method POST -ContentType "application/json" `
            -Body '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' `
            -ErrorAction SilentlyContinue
        if ($r.result) { $ready = $true; break }
    } catch {}
}
if (-not $ready) { Write-Fail "anvil did not answer within 30 s. Check ETH_RPC_URL." }
Write-OK "anvil ready at $ANVIL_URL (chain $CHAIN_ID)"

# ============================================================
# STEP 2: Deploy OracleGuard contracts
# ============================================================
Write-Step "STEP 2: Deploying OracleGuard contracts..."

$deployScript = Join-Path (Join-Path $CONTRACTS_DIR "script") "Deploy.s.sol"
if (-not (Test-Path $deployScript)) {
    Write-Skip "script/Deploy.s.sol not found -- skipping deploy (Kapilan's script not yet merged)"
} else {
    Push-Location $CONTRACTS_DIR
    try {
        & forge script script/Deploy.s.sol `
            --rpc-url $ANVIL_URL `
            --broadcast `
            --private-key $ANVIL_KEY0 `
            --silent
        if ($LASTEXITCODE -ne 0) { Write-Fail "Deploy.s.sol failed (exit $LASTEXITCODE)" }
        Write-OK "Contracts deployed. deployments/fork.json written."
    } finally { Pop-Location }
}

# ============================================================
# STEP 3: Fund Admin Safe + run Spell (impersonated)
# ============================================================
Write-Step "STEP 3: Funding Admin Safe and running governance Spell..."

# Fund with 100 ETH so the Safe can pay gas
& cast rpc anvil_setBalance $ADMIN_SAFE $ADMIN_BAL --rpc-url $ANVIL_URL 2>$null | Out-Null
Write-OK "Admin Safe $ADMIN_SAFE funded (100 ETH)"

# Self-test: impersonated read -- wards(AdminSafe) on the Vat
$wards = & cast call $VAT "wards(address)(uint256)" $ADMIN_SAFE --rpc-url $ANVIL_URL 2>$null
Write-Host "         Vat.wards(AdminSafe) = $wards  (1 = authorised)" -ForegroundColor Gray

$spellScript = Join-Path (Join-Path $CONTRACTS_DIR "script") "Spell.s.sol"
if (-not (Test-Path $spellScript)) {
    Write-Skip "script/Spell.s.sol not found -- skipping spell (Kapilan's script not yet merged)"
} else {
    Push-Location $CONTRACTS_DIR
    try {
        & forge script script/Spell.s.sol `
            --rpc-url $ANVIL_URL `
            --broadcast `
            --unlocked `
            --sender $ADMIN_SAFE `
            --silent
        if ($LASTEXITCODE -ne 0) { Write-Fail "Spell.s.sol failed (exit $LASTEXITCODE)" }
        Write-OK "Governance spell executed. SmartOSM is now the active pip."
    } finally { Pop-Location }
}

# ============================================================
# STEP 4: EVM snapshot -- write snapshotId into fork.json
# ============================================================
Write-Step "STEP 4: Taking EVM snapshot..."

$snapBody = '{"jsonrpc":"2.0","method":"evm_snapshot","params":[],"id":1}'
$snapResp  = Invoke-RestMethod `
    -Uri $ANVIL_URL -Method POST -ContentType "application/json" -Body $snapBody
$snapshotId = $snapResp.result

if (-not $snapshotId) { Write-Fail "evm_snapshot returned no result." }
Write-OK "Snapshot id = $snapshotId"

# Ensure fork.json exists (may have been skipped in step 2)
if (-not (Test-Path $FORK_JSON)) {
    if (Test-Path $FORK_EXAMPLE) {
        Copy-Item $FORK_EXAMPLE $FORK_JSON
        Write-Host "         Initialised fork.json from fork.example.json" -ForegroundColor Gray
    } else {
        $stub = '{"rpc":"http://127.0.0.1:8545","chainId":31337,"forkBlock":26011000,"snapshotId":"0x0","ilk":"paxg","oracleguard":{},"maker":{},"adminSafe":"0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99"}'
        $stub | Out-File $FORK_JSON -Encoding UTF8
    }
}

# Patch snapshotId in-place
$jsonObj = Get-Content $FORK_JSON -Raw | ConvertFrom-Json
$jsonObj.snapshotId = $snapshotId
$jsonObj | ConvertTo-Json -Depth 10 | Out-File $FORK_JSON -Encoding UTF8
Write-OK "snapshotId '$snapshotId' written to deployments/fork.json"

# ============================================================
# Done
# ============================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " OracleGuard demo environment is RUNNING" -ForegroundColor Green
Write-Host "  RPC:      $ANVIL_URL  (chain $CHAIN_ID)" -ForegroundColor Green
Write-Host "  Deployer: $ANVIL_ADDR0" -ForegroundColor Green
Write-Host "  Snapshot: $snapshotId" -ForegroundColor Green
Write-Host "  Stop:     scripts\demo-down.ps1" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green

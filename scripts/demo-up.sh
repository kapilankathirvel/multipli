#!/usr/bin/env bash
# ==============================================================================
# scripts/demo-up.sh — OracleGuard one-command demo environment (Mac/Linux)
# ==============================================================================
#
# What this does (in order):
#   1. Starts anvil as a forked Mainnet sandbox in the background
#   2. Deploys OracleGuard contracts via forge script Deploy.s.sol
#   3. Funds the Admin Safe and runs the governance Spell (impersonated)
#   4. Takes an EVM snapshot → writes snapshotId into deployments/fork.json
#
# Usage:
#   cd multipli
#   export ETH_RPC_URL="https://mainnet.gateway.tenderly.co"   # (or set in contracts/.env)
#   bash scripts/demo-up.sh
#
# Then open the dashboard and connect to http://127.0.0.1:8545 (chain 31337).
# To stop everything: bash scripts/demo-down.sh
# ==============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (frozen constants matching deployments/fork.example.json)
# ---------------------------------------------------------------------------
ANVIL_URL="http://127.0.0.1:8545"
FORK_BLOCK=26011000
CHAIN_ID=31337
ADMIN_SAFE="0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99"
ADMIN_BALANCE="0x56BC75E2D63100000"   # 100 ETH in hex
# Anvil's deterministic test account #0 (always available, no wallet needed)
ANVIL_KEY0="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_ADDR0="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$SCRIPT_DIR/../contracts"
DEPLOY_DIR="$SCRIPT_DIR/../deployments"
FORK_JSON="$DEPLOY_DIR/fork.json"
FORK_JSON_EXAMPLE="$DEPLOY_DIR/fork.example.json"
PID_FILE="$SCRIPT_DIR/.anvil.pid"
VAT="0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C"

# ---------------------------------------------------------------------------
# Helper: print coloured status messages
# ---------------------------------------------------------------------------
step()  { echo -e "\033[36m[demo-up] $*\033[0m"; }
ok()    { echo -e "\033[32m   OK  $*\033[0m"; }
skip()  { echo -e "\033[33m   SKIP $*\033[0m"; }
err()   { echo -e "\033[31m  ERR  $*\033[0m"; exit 1; }

# ---------------------------------------------------------------------------
# Resolve ETH_RPC_URL (env → contracts/.env → default)
# ---------------------------------------------------------------------------
get_rpc_url() {
    if [ -n "${ETH_RPC_URL:-}" ]; then
        echo "$ETH_RPC_URL"; return
    fi
    local dotenv="$CONTRACTS_DIR/.env"
    if [ -f "$dotenv" ]; then
        local v
        v=$(grep -E "^ETH_RPC_URL=" "$dotenv" | head -1 | cut -d= -f2-)
        if [ -n "$v" ]; then echo "$v"; return; fi
    fi
    echo "https://mainnet.gateway.tenderly.co"
}

# ---------------------------------------------------------------------------
# Check required tools
# ---------------------------------------------------------------------------
assert_tool() {
    command -v "$1" >/dev/null 2>&1 || err "$1 not found in PATH. Install Foundry: https://book.getfoundry.sh"
}

step "Checking required tools..."
assert_tool anvil
assert_tool forge
assert_tool cast
# jq is used to patch fork.json; install via brew/apt if missing
if ! command -v jq >/dev/null 2>&1; then
    skip "jq not found — snapshot id will be written by Python fallback"
fi
ok "anvil, forge, cast all present"

# ---------------------------------------------------------------------------
# Step 1: Start anvil (forked mainnet) in the background
# ---------------------------------------------------------------------------
step "Step 1: Starting anvil (fork-block $FORK_BLOCK)..."

RPC_URL=$(get_rpc_url)
echo "         RPC: $RPC_URL"

# Kill any previous anvil on port 8545
if lsof -ti:8545 >/dev/null 2>&1; then
    lsof -ti:8545 | xargs kill -9 2>/dev/null || true
    sleep 1
fi

anvil \
    --fork-url "$RPC_URL" \
    --fork-block-number "$FORK_BLOCK" \
    --auto-impersonate \
    --chain-id "$CHAIN_ID" \
    --silent &
ANVIL_PID=$!
echo "$ANVIL_PID" > "$PID_FILE"
echo "         anvil PID $ANVIL_PID written to $PID_FILE"

# Wait for anvil to answer RPC (poll up to 30 s)
echo "         Waiting for anvil RPC to be ready..."
READY=0
for i in $(seq 1 30); do
    sleep 1
    RESULT=$(curl -s -X POST "$ANVIL_URL" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null || true)
    if echo "$RESULT" | grep -q '"result"'; then
        READY=1; break
    fi
done
[ "$READY" -eq 1 ] || err "anvil did not start within 30 s. Check ETH_RPC_URL ($RPC_URL)."
ok "anvil ready at $ANVIL_URL (chain $CHAIN_ID)"

# ---------------------------------------------------------------------------
# Step 2: Deploy OracleGuard contracts
# ---------------------------------------------------------------------------
step "Step 2: Deploying OracleGuard contracts..."

if [ ! -f "$CONTRACTS_DIR/script/Deploy.s.sol" ]; then
    skip "script/Deploy.s.sol not found — skipping deploy step (Kapilan's script not yet available)"
else
    (
        cd "$CONTRACTS_DIR"
        forge script script/Deploy.s.sol \
            --rpc-url "$ANVIL_URL" \
            --broadcast \
            --private-key "$ANVIL_KEY0" \
            --silent
    )
    ok "Contracts deployed. deployments/fork.json written."
fi

# ---------------------------------------------------------------------------
# Step 3: Fund Admin Safe + run governance Spell (impersonated)
# ---------------------------------------------------------------------------
step "Step 3: Funding Admin Safe and running Spell..."

cast rpc anvil_setBalance "$ADMIN_SAFE" "$ADMIN_BALANCE" --rpc-url "$ANVIL_URL" >/dev/null
ok "Admin Safe $ADMIN_SAFE funded (100 ETH)"

# Self-test: impersonated call — wards check on Vat
WARDS=$(cast call "$VAT" "wards(address)(uint256)" "$ADMIN_SAFE" --rpc-url "$ANVIL_URL" 2>/dev/null || echo "call failed")
echo "         Vat.wards(AdminSafe) = $WARDS"

if [ ! -f "$CONTRACTS_DIR/script/Spell.s.sol" ]; then
    skip "script/Spell.s.sol not found — skipping spell step (Kapilan's script not yet available)"
else
    (
        cd "$CONTRACTS_DIR"
        forge script script/Spell.s.sol \
            --rpc-url "$ANVIL_URL" \
            --broadcast \
            --unlocked \
            --sender "$ADMIN_SAFE" \
            --silent
    )
    ok "Governance spell executed. SmartOSM is now the active pip."
fi

# ---------------------------------------------------------------------------
# Step 4: Take EVM snapshot → write snapshotId into deployments/fork.json
# ---------------------------------------------------------------------------
step "Step 4: Taking EVM snapshot..."

SNAPSHOT_RESP=$(curl -s -X POST "$ANVIL_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"evm_snapshot","params":[],"id":1}')
SNAPSHOT_ID=$(echo "$SNAPSHOT_RESP" | grep -oP '"result"\s*:\s*"\K[^"]+' || true)

[ -n "$SNAPSHOT_ID" ] || err "evm_snapshot returned no result. Response: $SNAPSHOT_RESP"
ok "Snapshot taken: id = $SNAPSHOT_ID"

# Initialise fork.json from example if deploy was skipped
if [ ! -f "$FORK_JSON" ]; then
    if [ -f "$FORK_JSON_EXAMPLE" ]; then
        cp "$FORK_JSON_EXAMPLE" "$FORK_JSON"
        echo "         (Initialised fork.json from fork.example.json)"
    else
        echo '{"rpc":"http://127.0.0.1:8545","chainId":31337,"forkBlock":26011000,"snapshotId":"0x0","ilk":"paxg","oracleguard":{},"maker":{},"adminSafe":"0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99"}' > "$FORK_JSON"
    fi
fi

# Patch snapshotId using jq (preferred) or python3 fallback
if command -v jq >/dev/null 2>&1; then
    jq --arg id "$SNAPSHOT_ID" '.snapshotId = $id' "$FORK_JSON" > "$FORK_JSON.tmp" && mv "$FORK_JSON.tmp" "$FORK_JSON"
else
    python3 - <<PYEOF
import json, sys
path = "$FORK_JSON"
with open(path) as f: d = json.load(f)
d["snapshotId"] = "$SNAPSHOT_ID"
with open(path, "w") as f: json.dump(d, f, indent=2)
PYEOF
fi
ok "snapshotId '$SNAPSHOT_ID' written to deployments/fork.json"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m OracleGuard demo environment is RUNNING\033[0m"
echo -e "\033[32m  RPC:       $ANVIL_URL  (chain $CHAIN_ID)\033[0m"
echo -e "\033[32m  Deployer:  $ANVIL_ADDR0\033[0m"
echo -e "\033[32m  Snapshot:  $SNAPSHOT_ID (restore with evm_revert)\033[0m"
echo -e "\033[32m  Stop:      bash scripts/demo-down.sh\033[0m"
echo -e "\033[32m================================================================\033[0m"

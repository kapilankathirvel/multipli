#!/usr/bin/env bash
# ==============================================================================
# scripts/demo-down.sh — OracleGuard demo teardown (Mac/Linux)
# ==============================================================================
# Stops the anvil process that was started by demo-up.sh
# Usage: bash scripts/demo-down.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.anvil.pid"

step()  { echo -e "\033[36m[demo-down] $*\033[0m"; }
ok()    { echo -e "\033[32m   OK  $*\033[0m"; }
warn()  { echo -e "\033[33m  WARN $*\033[0m"; }

step "Stopping OracleGuard demo environment..."

if [ -f "$PID_FILE" ]; then
    SAVED_PID=$(cat "$PID_FILE")
    if kill -0 "$SAVED_PID" 2>/dev/null; then
        kill "$SAVED_PID"
        ok "Killed anvil process (PID $SAVED_PID)"
    else
        warn "PID $SAVED_PID not found — anvil may have already exited."
    fi
    rm -f "$PID_FILE"
else
    warn ".anvil.pid not found — attempting to kill any process on port 8545..."
fi

# Belt-and-suspenders: kill anything still holding port 8545
if lsof -ti:8545 >/dev/null 2>&1; then
    lsof -ti:8545 | xargs kill -9 2>/dev/null || true
    ok "Killed lingering process on :8545"
fi

echo ""
echo -e "\033[32m================================================================\033[0m"
echo -e "\033[32m Demo environment stopped. Run bash scripts/demo-up.sh to restart.\033[0m"
echo -e "\033[32m================================================================\033[0m"

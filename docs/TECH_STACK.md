# Tech Stack & Setup (Windows-friendly)

| Layer | Tool | Version | Why |
|---|---|---|---|
| Contracts | Solidity | 0.8.24 | checked math, custom errors |
| Framework | Foundry (forge, anvil, cast) | latest stable | mainnet-fork tests, fuzz, invariants, scripts |
| Libs | forge-std | latest | cheatcodes (`deal`, `prank`, `mockCall`, `warp`) |
| Chain | Ethereum mainnet **fork** @ block 26,011,000 | n/a | real rwaUSD contracts |
| Keeper / scripts | Node 20 + TypeScript + **viem** | Node ≥ 20 | fast, typed, anvil test actions |
| Frontend | **React + Vite + TypeScript + Tailwind + Recharts + viem** | Vite 5 | fastest to build; no wallet needed (demo uses anvil accounts) |
| Package mgr | pnpm | 9 | |
| Optional | Tenderly Virtual TestNet | n/a | shareable fork for judges |

We don't need OpenZeppelin, wagmi, or RainbowKit for the MVP. The dashboard talks to anvil with viem's `createTestClient` / `createPublicClient`. Add wallet connect only if time allows.

## Install

**Foundry on Windows:** the easiest path is **WSL2 (Ubuntu)**:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version
```
Alternative (native, Git Bash): download prebuilt binaries from the Foundry GitHub releases and add them to PATH. Run all `forge`/`anvil` commands from the same environment consistently.

**Node + pnpm:**
```bash
node -v     # ≥ 20 (already installed at C:\Program Files\nodejs)
npm i -g pnpm
```

## Project bootstrap
```bash
# contracts
mkdir contracts && cd contracts
forge init --no-git --no-commit .
forge install foundry-rs/forge-std --no-git
# foundry.toml
#   solc = "0.8.24"
#   evm_version = "cancun"
#   [rpc_endpoints] mainnet = "${ETH_RPC_URL}"
#   [fuzz] runs = 256
#   [invariant] runs = 64, depth = 50

# dashboard
cd .. && pnpm create vite dashboard --template react-ts
cd dashboard && pnpm add viem recharts && pnpm add -D tailwindcss @tailwindcss/vite

# keeper
cd .. && mkdir keeper && cd keeper && pnpm init && pnpm add viem && pnpm add -D tsx typescript
```

## Running the demo locally
```bash
# terminal 1: fork mainnet
anvil --fork-url $ETH_RPC_URL --fork-block-number 26011000 --chain-id 31337 --auto-impersonate

# terminal 2: deploy + spell
cd contracts
# 2a. deploy OracleGuard from anvil account #0
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# 2b. fund + run the spell AS the Admin Safe (impersonated)
cast rpc anvil_setBalance 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99 0x56BC75E2D63100000 --rpc-url http://127.0.0.1:8545
forge script script/Spell.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
  --sender 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99

# terminal 3: dashboard
cd dashboard && pnpm dev
```
Note: the Safe is a contract. Impersonating it on anvil works for direct calls (`--auto-impersonate` / `anvil_impersonateAccount`). We don't go through Safe signatures on the fork.

## Env vars
```
ETH_RPC_URL=...
FORK_BLOCK=26011000
VITE_RPC_URL=http://127.0.0.1:8545
```

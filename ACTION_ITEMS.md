# ACTION ITEMS: things for *you* (the humans) to do

> Claude appends every follow-up / "before you submit" / "you need to" item here at the end of each prompt, and ticks it off when it's done.
> Format: `- [ ] (added <date>, source) item`, which becomes `- [x] ... ✅ <date> <how resolved>` when done.
> Engineering tasks live in `PROGRESS.md`. This file holds **non-code follow-ups, decisions, and reminders**.

## 🔴 Open

### Pitch / deck accuracy
- [ ] (added Sep 19, docs review) Find a citable source for "Oracle attacks caused 13% of DeFi exploits in 2025", or soften it to "oracle manipulation is consistently among the top DeFi exploit classes". → `docs/PITCH.md`
- [ ] (added Sep 19, docs review) Drop "first system built specifically for RWA oracles". Use "first graduated-trust oracle layer that drops into rwaUSD's deployed Maker-fork contracts without core changes." → `docs/PITCH.md`
- [ ] (added Sep 19, docs review) Update the TVL line: public reports cite ≈$340M rwaUSD supply (not "past $100M"). Use the latest figure with its source.

### Setup / housekeeping
- [ ] (added Sep 19, Phase 1) **Restart Cursor** (or open a new terminal) so the new PATH entry `%USERPROFILE%\.foundry\bin` (forge/anvil/cast) is picked up.
- [ ] (added Sep 19, Phase 1) Point `origin` at https://github.com/kapilankathirvel/multipli and push Phase 1 (commands in `docs/GIT_WORKFLOW.md`). Last attempt failed: `git add -A` was skipped and origin pointed at `oracleguard`.
- [ ] (added Sep 19, git) Optional: delete the accidental empty private repo `kapilankathirvel/oracleguard`: `gh auth refresh -h github.com -s delete_repo` then `gh repo delete kapilankathirvel/oracleguard --yes` (or GitHub → repo → Settings → Delete).
- [ ] (added Sep 19, git) Note: `multipli` is **public**. That's fine for judges, but never commit `.env` or keys (already gitignored).
- [ ] (added Sep 19, Phase 1) Optional: get a free Alchemy/Infura key if the keyless Tenderly gateway starts rate-limiting (only needed for heavy fuzz/invariant fork runs).

### Ask the Multipli team (optional, strengthens the pitch)
- [ ] (added Sep 19, design) Current Clipper `tail/cusp` and Calc params; is AutoLine or ClipperMom deployed?
- [ ] (added Sep 19, design) Who pokes the OSM/Spotter in production, and how often?
- [ ] (added Sep 19, design) What PAXG/USD heartbeat was assumed when setting `maxDelay = 24h`?
- [ ] (added Sep 19, design) Would they adopt a timelock on oracle config (our finding V5)?

## ✅ Done
- [x] (added Sep 19, Phase 1) Delete the Foundry `Counter` template files ✅ Sep 19: Claude deleted `contracts/src/Counter.sol`, `contracts/test/Counter.t.sol`, `contracts/script/Counter.s.sol`, `contracts/README.md`
- [x] (added Sep 19) Install Foundry ✅ Sep 19: forge/anvil/cast 1.5.1 installed to `%USERPROFILE%\.foundry\bin` and added to the user PATH
- [x] (added Sep 19, Phase 1) Get a mainnet RPC ✅ Sep 19: keyless archive RPC `https://mainnet.gateway.tenderly.co` set in `contracts/.env` (publicnode doesn't serve archive state)
- [x] (added Sep 19) Fill demo numbers in `docs/DEMO_SCRIPT.md` §D ✅ Sep 19: from the Baseline tests (S3: $312,319 minted vs $43,724 collateral)

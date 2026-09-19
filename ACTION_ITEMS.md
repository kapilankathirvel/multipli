# ACTION ITEMS: things for *you* (the humans) to do

> Claude appends every follow-up / "before you submit" / "you need to" item here at the end of each prompt, and ticks it off when it's done.
> Format: `- [ ] (added <date>, source) item`, which becomes `- [x] ... ✅ <date> <how resolved>` when done.
> Engineering tasks live in `PROGRESS.md`. This file holds **non-code follow-ups, decisions, and reminders**.

## 🔴 Open

### Understand before continuing (added Sep 19)
- [ ] Read `SOLUTION_EXPLAINED.md` (≈30 min): big picture, limitations, 2-min pitch, tough Q&A.
- [ ] Read `IMPLEMENTATION_EXPLAINED.md` (≈30 min): every contract and test, with numbers.
- [ ] Practise the 2-minute pitch (Part 8) and the tough questions (Part 9) out loud; share both files with Varun & Jeffrey.

### Pitch / deck accuracy
- [ ] (added Sep 19, docs review) Find a citable source for "Oracle attacks caused 13% of DeFi exploits in 2025", or soften it to "oracle manipulation is consistently among the top DeFi exploit classes". → `docs/PITCH.md`
- [ ] (added Sep 19, docs review) Drop "first system built specifically for RWA oracles". Use "first graduated-trust oracle layer that drops into rwaUSD's deployed Maker-fork contracts without core changes." → `docs/PITCH.md`
- [ ] (added Sep 19, docs review) Update the TVL line: public reports cite ≈$340M rwaUSD supply (not "past $100M"). Use the latest figure with its source.

### Setup / housekeeping
- [ ] (added Sep 19, Phase 1) **Restart Cursor** (or open a new terminal) so the new PATH entry `%USERPROFILE%\.foundry\bin` (forge/anvil/cast) is picked up.
- [ ] (added Sep 19, git) Optional: delete the accidental empty private repo `kapilankathirvel/oracleguard`: `gh auth refresh -h github.com -s delete_repo` then `gh repo delete kapilankathirvel/oracleguard --yes` (or GitHub → repo → Settings → Delete).
- [ ] (added Sep 19, git) Note: `multipli` is **public**. That's fine for judges, but never commit `.env` or keys (already gitignored).
- [ ] (added Sep 19, Phase 1) Optional: get a free Alchemy/Infura key if the keyless Tenderly gateway starts rate-limiting (only needed for heavy fuzz/invariant fork runs).

### Team (added Sep 19, team split)
- [ ] Add **Varun** and **Jeffrey** as collaborators: github.com/kapilankathirvel/multipli → Settings → Collaborators → Add people.
- [ ] Send each of them: the repo link + "open the repo in Cursor, then tell Claude: *Read CLAUDE.md and <your-name>.md, then do the next unchecked task.*"
- [ ] Tell both: **build only against the frozen interfaces** (`contracts/src/interfaces/IOracleGuard.sol`, `IPriceSource.sol`, `abi/`, `deployments/fork.example.json`), and never edit files outside their own ownership list.
- [ ] Fix the **integration checkpoint time (~hour 20)**: everyone pushes by then; you run K7 (wire calendar/Pyth, `demo-up`, dashboard goes live).

### Mentor review #1 (added Sep 19)
- [ ] Push `review.md` + the updated `kapilan.md` / `varun.md` / `jeffrey.md`, then **tell Varun his V4 validation study is now TOP priority** and Jeffrey that he has new panels + 3 slides.
- [ ] When `research/RESULTS.md` exists, fill `review.md` §R4.3 with the measured numbers and show the mentor.
- [ ] Optional: send the mentor `review.md` §R1–R3 now for early feedback (the definitions are final; only the measurements are pending).

### Integration heads-up (added Sep 19, K5)
- [ ] Tell **Varun**: `script/Deploy.s.sol` + `script/Spell.s.sol` now exist and are tested on anvil, so his `demo-up` script can call them for real (exact commands in the header comments of each script). `deployments/fork.json` is written by Deploy (gitignored).
- [ ] Tell **Jeffrey**: he can switch to live mode any time. Run anvil + Deploy + Spell (or Varun's demo-up); MockSources are controlled by anvil account #0.

### Dashboard (Jeffrey, added Sep 19 — J1/J2)
- [ ] **Review the Oracle War Room in the browser** (`cd dashboard && pnpm dev` → http://localhost:5173) and confirm the panel checklist in `dashboard/README.md` §1. Drive the scenarios from DevTools: `og('s1')`, `og('s2')`, `og('s3')`, `og('s4')`, `og('reset')`.
- [ ] (Kapilan) The dashboard's live mode names the feeds from a `oracleguard.sources` map in `deployments/fork.json` whose **keys** are `chainlink`/`pyth`/`redstone`/`dexTwap` (or `mockA/B/C`), as in `fork.example.json`. If `Deploy.s.sol` writes different keys, tell Jeffrey — otherwise the table silently falls back to slot order.

### Ask the Multipli team (optional, strengthens the pitch)
- [ ] (added Sep 19, design) Current Clipper `tail/cusp` and Calc params; is AutoLine or ClipperMom deployed?
- [ ] (added Sep 19, design) Who pokes the OSM/Spotter in production, and how often?
- [ ] (added Sep 19, design) What PAXG/USD heartbeat was assumed when setting `maxDelay = 24h`?
- [ ] (added Sep 19, design) Would they adopt a timelock on oracle config (our finding V5)?

## ✅ Done
- [x] (added Sep 19, J1/J2) Commit the dashboard (`dashboard/` was untracked) ✅ Sep 19: commit `feat(dashboard): scaffold with mock/live data layer + Oracle War Room panels (mentor review R1/R3)`
- [x] (added Sep 19, J1/J2) Confirm the R3 controller numbers hard-coded in `dashboard/src/protocol.ts` match the real deploy ✅ Sep 19: checked against K5's `script/DeployLib.sol` — greenGap 250,000 · yellowGap 50,000 · greenScore 80 · yellowScore 50 · epsBps 150 · epsLiqBps 300 · guard 6h · refill 1h · weights 2/2/2/1 (25h/1h/1h/1h) all identical. Re-check if `setIlk` config changes.
- [x] (added Sep 19) Push Phase 1 to github.com/kapilankathirvel/multipli ✅ Sep 19: pushed by Kapilan
- [x] (added Sep 19) Push the team-split commit ✅ Sep 19: pushed by Kapilan
- [x] (added Sep 19, Phase 1) Delete the Foundry `Counter` template files ✅ Sep 19: Claude deleted `contracts/src/Counter.sol`, `contracts/test/Counter.t.sol`, `contracts/script/Counter.s.sol`, `contracts/README.md`
- [x] (added Sep 19) Install Foundry ✅ Sep 19: forge/anvil/cast 1.5.1 installed to `%USERPROFILE%\.foundry\bin` and added to the user PATH
- [x] (added Sep 19, Phase 1) Get a mainnet RPC ✅ Sep 19: keyless archive RPC `https://mainnet.gateway.tenderly.co` set in `contracts/.env` (publicnode doesn't serve archive state)
- [x] (added Sep 19) Fill demo numbers in `docs/DEMO_SCRIPT.md` §D ✅ Sep 19: from the Baseline tests (S3: $312,319 minted vs $43,724 collateral)

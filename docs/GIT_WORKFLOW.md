# Git Workflow

**Rule:** Claude never commits or pushes. After every finished feature, Claude prints the exact commands and you run them.
Run all commands from the repo root: `C:\Users\Kapilan Kathirvel\Desktop\multipli`.

## One-time setup (done once)

Repo: **https://github.com/kapilankathirvel/multipli** (public)

```bash
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli"
git branch -M main
git remote set-url origin https://github.com/kapilankathirvel/multipli.git   # or: git remote add origin <url> if no origin exists
git remote -v                     # must show .../multipli.git
```

Teammates: add them on github.com → multipli → Settings → Collaborators. They clone with `git clone https://github.com/kapilankathirvel/multipli.git`.

## Per-feature routine (every time)

```bash
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli"
cd contracts && forge test && cd ..      # only push green code
git status                               # review what changed
git add -A
git commit -m "<message from the table below>"
git push                                 # first push only: git push -u origin main
```

## Commit messages, one per feature (in build order)

| Feature | Commit message |
|---|---|
| **Phase 1 (done)** | `feat(phase1): docs + fork harness + baseline exploits on real rwaUSD (S1, S3, S4)` |
| M3 sources | `feat(sources): IPriceSource, ChainlinkSource (clamp-aware), MockSource` |
| M4 aggregator | `feat(aggregator): weighted median, MAD outliers, confidence score 0-100` |
| M5 SmartOSM | `feat(osm): SmartOSM drop-in with freshness, quarantine, zero-price invariant` |
| M6 executors | `feat(executors): bounded LineExecutor and HoleExecutor` |
| M6 controller | `feat(controller): GREEN/YELLOW/RED risk controller + liquidation guard` |
| M7 scripts | `feat(scripts): Deploy and Spell scripts (Safe-impersonated install + rollback)` |
| M8 fixes | `test(fork): OracleGuard neutralises S1-S4 on real rwaUSD` |
| M9 demo | `chore(demo): one-command anvil fork + deploy + spell` |
| M10 dashboard | `feat(dashboard): Oracle War Room UI with scenario buttons` |
| H4 keeper | `feat(keeper): poke/sync loop and scenario runner` |
| H1 calendar | `feat(calendar): SessionCalendar + simulated TSLAx weekend-gap scenario` |
| H3 invariants | `test(invariant): spot>0, repay never blocked, line<=cap` |
| Ship | `docs: final README, deck notes, demo numbers` then `git tag v1.0-submission && git push --tags` |

## Safety
- Never `git add` a `.env`. It's gitignored, but check `git status` anyway.
- Before a demo, tag a known-good commit: `git tag demo-ready && git push --tags`.
- Undo the last commit *before* pushing (keeps your changes): `git reset --soft HEAD~1`.

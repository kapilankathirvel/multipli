# START HERE: foundations + study plan

> You don't need any prior blockchain knowledge. Part A tells you **what to read, in what order, and why**. Part B teaches **every concept the project is built on**, from "what is a blockchain" up to "what is an OSM", in the order you need them. Part C lets you **test yourself** before a review.
> Time to be fully ready to pitch and defend: **≈ 5 hours** of focused reading.

---

# PART A: Study plan (read in this order)

| # | File | Time | What you get from it |
|---|---|---|---|
| 1 | **`START_HERE.md`** (this file, Part B) | 90 min | The vocabulary and concepts. Everything else assumes these. |
| 2 | **`SOLUTION_EXPLAINED.md`** | 30 min | The big picture: the problem, our solution, why each design choice, limitations, the 2-minute pitch, tough Q&A |
| 3 | **`FLOW_EXPLAINED.md`** | 25 min | One price followed through every component with real numbers. Memorise §14 (the 10-line summary). |
| 4 | **`IMPLEMENTATION_EXPLAINED.md`** | 30 min | What exactly is built: every contract and test, code-level Q&A |
| 5 | **`review.md`** | 20 min | The mentor's questions and our answers: score definition, validation results (§R2.4b), what each state changes, risk reduction |
| 6 | `docs/PROBLEM.md` | 10 min | The 13 attack vectors in the legacy system (the "why") |
| 7 | `docs/DECISIONS.md` | 15 min | 11 design decisions with reasons. Judges attack decisions, so know these. |
| 8 | `docs/LIMITATIONS.md` | 10 min | Honest weaknesses + prepared answers |
| 9 | `docs/PITCH.md` | 10 min | Deck outline, business model, claims to avoid |
| 10 | Part C of this file | 20 min | Self-test. If you can answer all of it, you're ready. |

**Reference only (open when needed, don't read cover to cover):** `docs/ORACLE_DESIGN.md` (the original long design report), `docs/ONCHAIN_FACTS.md` (verified addresses and numbers), `docs/CONTRACTS_SPEC.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/DEMO_SCRIPT.md`, `research/RESULTS.md` (Varun's study).

**Team/process files (you don't need them to understand the solution):** `CLAUDE.md` (instructions for the AI), `PROGRESS.md`, `ACTION_ITEMS.md`, `kapilan.md` / `varun.md` / `jeffrey.md`, `docs/GIT_WORKFLOW.md`, `docs/SCOPE.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/TECH_STACK.md`.

---

# PART B: The foundations (read top to bottom; each layer builds on the previous)

## Layer 1: Blockchain basics

| Concept | Plain explanation | Why it matters for us |
|---|---|---|
| **Blockchain** | A shared ledger kept by thousands of computers. Everyone has the same copy, and nobody can secretly change past entries. | The protocol's rules and balances live here. |
| **Ethereum** | The blockchain that can run programs, not just track coins. | rwaUSD's core lives on Ethereum mainnet. |
| **Smart contract** | A program deployed on Ethereum. Its code and data are public, and it runs exactly as written. Nobody can stop or change it unless the code allows it. | Everything we built (Aggregator, SmartOSM, RiskController…) is a smart contract. |
| **Transaction** | A signed message that calls a contract function and changes state (e.g. "borrow 1,000 rwaUSD"). | Users borrow and repay via transactions; our `poke()`/`sync()` are transactions. |
| **Address / EOA vs contract** | An address is an account. An EOA is a person's wallet (has a private key); a contract account holds code. | The Admin Safe is a *contract* (a multisig); users are EOAs. |
| **Gas** | The fee paid to run a transaction; more computation = more gas. | SmartOSM `poke()` ≈ 247k gas vs ≈ 40k for the legacy OSM: a trade-off we must defend. |
| **Block & timestamp** | Transactions are grouped into blocks (~12s each); each block has a time. | "Stale" and "one hour delay" are measured with block timestamps. |
| **Revert** | A transaction that fails and undoes everything it did, with an error message. | "Vat/ceiling-exceeded" is a revert. That's how RED blocks borrowing. |
| **Public state** | Anyone can read any contract's storage, even "private" variables. | We read the legacy OSM's price straight from storage slot 3. |
| **Solidity** | The language Ethereum contracts are written in. | Our code is Solidity 0.8.24; Multipli's is 0.6.12. |

## Layer 2: Tokens, stablecoins and DeFi lending

| Concept | Plain explanation | Why it matters |
|---|---|---|
| **Token (ERC-20)** | A contract that tracks balances of a digital asset. | PAXG and rwaUSD are tokens. |
| **Stablecoin** | A token designed to stay at $1. Types: fiat-backed (USDC), crypto-backed / over-collateralised (DAI, **rwaUSD**), algorithmic (failed ones like UST). | rwaUSD is a *collateral-backed* stablecoin: every rwaUSD is a loan against collateral. |
| **DeFi** | Financial services run by smart contracts instead of banks. | Our whole context. |
| **CDP / vault** | Collateralised Debt Position: lock collateral, borrow stablecoins against it. Like a pawn shop, but automated. | A user's vault holds PAXG and owes rwaUSD. |
| **Over-collateralisation** | You must lock more value than you borrow. | Protects the protocol if the collateral's price falls. |
| **Collateral ratio / liquidation ratio (`mat`)** | Minimum collateral ÷ debt. rwaUSD PAXG: **140%**, so $1.40 of gold per $1 borrowed. | 10 PAXG ($43,724) → you can borrow up to $31,231. |
| **Liquidation** | If your ratio drops below 140%, anyone can trigger a sale of your collateral to repay your debt, plus a penalty (5% here). | Protects the protocol, but a **wrong low price** causes **unfair liquidations**. |
| **Keeper** | A bot/person that calls maintenance functions (liquidations, price updates) for a reward. | Keepers call `bark()` (liquidate), `poke()`, `sync()`. |
| **Dutch auction** | A price that starts high and falls until someone buys. | How liquidated collateral is sold (Clipper). |
| **Bad debt** | Debt that can never be repaid because the collateral is worth less than the loan. | The #1 thing oracle failures cause. Our S3 attack: **$268,595 of bad debt**. |
| **Debt ceiling** | The max total debt allowed against one collateral type. | Our main lever: GREEN/YELLOW/RED change it. |
| **MEV / front-running** | Profiting by reordering transactions around known events. | The OSM's "next price" is public, so traders can act on it early (vector V9). |
| **Flash loan** | Borrowing huge amounts within one transaction (repaid in the same tx). | Lets attackers manipulate thin DEX prices cheaply. That's why the DEX TWAP gets the lowest weight. |

## Layer 3: Real-World Assets (RWA)

| Concept | Plain explanation | Why it matters |
|---|---|---|
| **RWA** | A real-world asset (gold, stocks, treasury bills) represented by a token. | rwaUSD is built on RWAs, hence the name. |
| **PAXG** | Paxos Gold: 1 token = 1 troy ounce of physical gold in Paxos' vaults. ≈ **$4,372** on our fork. | The collateral we protect. |
| **Issuer / custodian risk** | The token is only as good as the company holding the real asset. | A token can trade differently from the underlying asset (incident I9). |
| **Proof of Reserve (PoR)** | An oracle that reports whether the issuer really holds the reserves. | A roadmap item (PoR-gated minting). |
| **Market hours** | Stocks trade Mon–Fri only; tokenised stocks trade 24/7 on-chain. | Weekend price gaps → the SessionCalendar makes closed markets YELLOW. |
| **NAV** | Net asset value per share (used for treasury-bill tokens). | Future collateral types. |

## Layer 4: Oracles (the heart of the problem statement)

| Concept | Plain explanation | Why it matters |
|---|---|---|
| **The oracle problem** | Blockchains can't see the outside world. They don't know the gold price unless someone brings it on-chain. Whoever brings it is trusted. | If the price is wrong, every loan decision is wrong. |
| **Oracle** | A service/contract that publishes off-chain data (prices) on-chain. | Our whole project is a better oracle system. |
| **Push oracle** | The oracle writes updates on-chain itself (e.g. **Chainlink**). | Always there, but updates only on its schedule. |
| **Pull oracle** | Signed prices are fetched off-chain and submitted by whoever needs them (e.g. **Pyth**, **RedStone**). | Fresher and cheaper, but someone must bring the update. |
| **Chainlink** | The biggest oracle network: many independent nodes (a DON) agree on a price. | rwaUSD's only price source today. |
| **Heartbeat & deviation threshold** | Chainlink updates when the price moves > X% (deviation) **or** every N hours (heartbeat). | The PAXG feed was **16.5h old** when captured. Quiet ≠ broken, which is why it gets a 25h maxAge. |
| **Round / `latestRoundData()` / decimals** | Each update is a "round". The function returns (roundId, answer, startedAt, updatedAt, …). The answer has 8 decimals. | Our ChainlinkSource converts 437247814339 → $4,372.478. |
| **minAnswer / maxAnswer (circuit breaker)** | Chainlink's hard floor/ceiling. Beyond them the feed keeps reporting the bound. | LUNA 2022: the feed reported its floor while LUNA collapsed. We detect clamped values. |
| **Pyth confidence interval** | Pyth reports price ± uncertainty. | The `conf` field in our Observation. |
| **DEX / AMM / TWAP** | Decentralised exchanges (Uniswap) set prices by trading. TWAP = time-weighted average price over a window. | Easy to manipulate for thin RWA markets → weight 1 (14%). |
| **Staleness** | The price is old because the source stopped updating. | The legacy OSM's core bug: it treats stale as valid forever. |
| **Manipulation** | Moving an oracle's price on purpose (pumping a thin market, compromising a feed). | S3 attack: $43k of gold → $312k borrowed. |
| **Single point of failure** | One source = if it fails, everything fails. | Legacy rwaUSD has exactly one feed. |
| **Correlated failure** | Several sources wrong at the same time, in the same direction (they share an upstream market, or all get manipulated). | **Our main honest limitation** (Mango, Oct 2022). |
| **Famous incidents** | Synthetix sKRW 2019 (1000× feed), Compound DAI 2020 ($89M liquidated), Black Thursday 2020 (oracle lag + crash), Pyth BTC 2021, LUNA 2022 (clamp), Mango 2022 (all oracles manipulated), USDC/SVB 2023 (real depeg). | We replayed all of them (`review.md` §R2.4b). |

## Layer 5: MakerDAO architecture (rwaUSD is a Maker fork)

**MakerDAO** is the protocol behind DAI. rwaUSD copies its contracts, so you must know Maker's vocabulary. Think of it as a bank split into specialised departments:

| Maker word | Department / meaning | rwaUSD value |
|---|---|---|
| **Vat** | The ledger: every vault, every debt, the rules | `0xbC22…` |
| **ilk** | A collateral type | `"paxg"` |
| **urn** | One user's vault | |
| **ink** | Collateral in a vault (PAXG) | |
| **art / rate** | Normalised debt × accumulated interest rate = real debt | debt ≈ $43,029 total |
| **spot** | The Vat's price **already divided by `mat`** = borrowing power per token | $4,372 ÷ 1.4 = **$3,123** |
| **line** | The debt ceiling for the ilk | $1,000,000 (we control it via LineExecutor) |
| **Line** | The global ceiling across all ilks | $5,000,000 |
| **dust** | The minimum debt per vault | $200 |
| **Spotter** | Reads the price from the **pip** and writes `spot` into the Vat. Holds `mat` and `par`. | |
| **pip** | "Price in pipe": whatever contract the Spotter reads. Swapping the pip is how we install SmartOSM. | |
| **mat** | The liquidation ratio | 1.40 |
| **par** | The reference price of the stablecoin | 1.0 |
| **Dog** | Liquidation trigger: checks a vault is unsafe and starts an auction | `bark()` |
| **hole / dirt** | The max debt in liquidation at once / the amount currently in liquidation | hole $400,000 (we control it via HoleExecutor) |
| **chop** | Liquidation penalty | 1.05 (5%) |
| **Clipper** | Runs the Dutch auction; start price = oracle price × `buf` | buf 1.10 |
| **Join (GemJoin)** | Adapter moving tokens in/out of the Vat | PAXG Join |
| **Vow / End** | Surplus & deficit accounting / global emergency shutdown | |
| **frob** | "Change my vault": deposit/withdraw collateral, borrow/repay | the borrow rule: debt ≤ line AND ink × spot ≥ debt |
| **wards / rely / deny** | Admin rights: `rely` grants, `deny` revokes | The Admin Safe is a ward everywhere |
| **spell** | A governance transaction that changes the system | Our install = one spell |
| **Mom contracts** (OsmMom, ClipperMom) | Small contracts allowed ONE emergency action | Our executors follow this pattern |

### The OSM (Oracle Security Module), in depth
Maker's price-**delay** contract, the thing the problem statement asks us to fix:
- Holds **`cur`** (the price in use now) and **`nxt`** (the price that becomes `cur` next hour).
- **`hop`** = 3600s (1h): the minimum time between updates. **`zzz`** = the time of the last update.
- **`poke()`**: anyone can call it once per hop. It asks its source (`src`) for a price; if valid, `cur ← nxt`, `nxt ← new`.
- **`peek()`**: returns `(cur, valid?)`. Only whitelisted readers (**`bud`**, added with **`kiss`**) may call it.
- **Why a delay?** If someone manipulates the price, it only affects the system an hour later: time to react (`stop()` via OsmMom).
- **`void()`**: sets the price to 0 and invalid. Spotter then sets `spot = 0`, making **every vault liquidatable**. That's the "self-destruct button".
- **The bug we found:** if the source says "invalid", `poke()` silently does nothing, so `cur` stays **valid forever**.

### PriceFeedAdapter (Multipli's own contract)
Wraps Chainlink for the OSM. Returns `(price, true)`, or `(0, false)` if the price is > 24h old, ≤ 0, or the adapter is paused. It correctly detects staleness, but the OSM ignores it.

## Layer 6: Numbers & units

| Unit | Value | Used for | Example |
|---|---|---|---|
| **WAD** | 10¹⁸ | token amounts, prices | $4,372.478 = 4,372,478,143,390,000,000,000 |
| **RAY** | 10²⁷ | ratios, `spot`, `rate`, `mat` | 1.40 = 1.4 × 10²⁷ |
| **RAD** | 10⁴⁵ (WAD × RAY) | debts, ceilings | $1M ceiling = 10⁶ × 10⁴⁵ |
| **bps** | 1/10,000 | our thresholds | 150 bps = 1.5% |

Why such big numbers? Solidity has no decimals, so values are stored as huge integers with an implied decimal point.

## Layer 7: The statistics we use

| Concept | Plain explanation | Where |
|---|---|---|
| **Mean vs median** | The mean is pulled by extremes; the median (middle value) isn't. | We use the median so one liar can't move the price. |
| **Weighted median** | Each source counts with its weight; the answer is where the cumulative weight passes half. | Weights 2/2/2/1 → no single oracle (max 2/7) can move it. |
| **MAD** | Median Absolute Deviation: the median distance from the median. A robust measure of spread. | Outlier test: > 3 × MAD (min 0.1%) from the median = outlier. |
| **Outlier / inlier** | A value far from / close to the consensus. | Outliers are excluded from price and confidence. |
| **Breakdown point** | How many bad inputs a method tolerates before failing. | We need ≥ ½ of the weight (2 of 3 majors) wrong to move the price. |
| **Confidence score** | Our 0–100 = coverage × agreement × freshness. | Drives GREEN/YELLOW/RED. |
| **False positive / false negative** | FP = alarm when nothing is wrong (annoys users). FN = no alarm when something IS wrong (dangerous). | The mentor asked for FP/FN rates; see `review.md` §R2.4b. |
| **Hysteresis** | React fast when things get worse, slowly when they get better, to avoid flapping. | Downgrade instantly; upgrade after 3 spaced healthy checks. |
| **Rate limit** | A cap per unit of time. | GREEN: ≤ $250k new debt per hour. |
| **Monte-Carlo** | Run thousands of random simulations to measure rates. | Varun's study. |

## Layer 8: Governance & security

| Concept | Plain explanation | Why it matters |
|---|---|---|
| **Multisig (Gnosis Safe)** | A wallet needing M of N signatures. rwaUSD's admin = **4-of-8 Safe**. | It controls the oracle, and we found it has **no timelock** (vector V5). |
| **Timelock** | A forced delay between approving and executing an admin change. | Recommended fix: Safe → 48h timelock. |
| **Guardian** | A fast emergency role that can only tighten, never loosen. | Our design recommendation. |
| **Principle of least privilege** | Give each component only the power it needs. | Our executors can change exactly ONE number each, within a cap. |
| **Invariant** | A property that must ALWAYS hold ("repay never fails"). | We test 6 invariants over 3,200 random actions each. |
| **Audit** | An independent security review of the code. | Needed before production (limitation L11). |
| **Rollback** | Undoing a deployment. | One transaction puts the legacy OSM back. |

## Layer 9: How we built and tested it

| Concept | Plain explanation |
|---|---|
| **Foundry** (`forge`, `anvil`, `cast`) | The toolkit: compile + test, a local blockchain, and a command-line caller |
| **Mainnet fork** | A local, exact copy of real Ethereum at block 26,011,000. We attack and fix the **real deployed rwaUSD contracts** without touching the real chain. |
| **Archive RPC** | A node that serves old blockchain state (needed for a pinned old block) |
| **Impersonation** | On a fork, act as any address (e.g. the Admin Safe) without its keys. That's how we run the spell. |
| **Unit / fork / fuzz / invariant tests** | Logic with mocks / against real contracts / random inputs / random action sequences checked against permanent properties |
| **Mock** | A fake contract for testing (our Pyth/RedStone/DEX stand-ins) |

## Layer 10: Putting it together (this project in 6 sentences)
1. **rwaUSD** lets users borrow dollars against **PAXG** (tokenised gold) using **MakerDAO**-style contracts.
2. It learns the gold price through **one Chainlink feed → an adapter → Maker's OSM** (1-hour delay) → **Spotter → Vat**.
3. The **OSM ignores "stale"** and treats old prices as valid forever. Its only emergency button sets the price to **0**, which liquidates everyone. We **proved** three attacks on the real contracts (stale borrowing, $268,595 bad debt, an unfair liquidation).
4. **OracleGuard** combines **4 oracles** (weighted median + outlier filter + a **0–100 confidence score**), replaces the OSM with a drop-in **SmartOSM** (never 0, knows its age, holds back suspicious rises), and adds a **RiskController** (GREEN/YELLOW/RED + liquidation guard).
5. It acts only through **two bounded levers**, the debt ceiling and the liquidation limit, so **repayments always work** and the price is never zeroed.
6. It installs with **one governance spell, no core changes**. Replayed historical incidents: over-borrowing hours **21 → 2**, unfair-liquidation hours **5 → 1**. The known limit, correlated manipulation, is **bounded to $250k/hour**.

---

# PART C: Self-test (answers hidden; click to reveal)

<details><summary>1. What is the oracle problem, in one sentence?</summary>Blockchains can't see off-chain data, so whoever brings prices on-chain is trusted; a wrong price makes every loan decision wrong.</details>

<details><summary>2. What do `mat`, `spot` and `line` mean, with rwaUSD's numbers?</summary>mat = liquidation ratio 1.40; spot = price ÷ mat ≈ $3,123 (borrowing power per PAXG); line = debt ceiling ($1M, which our controller manages).</details>

<details><summary>3. What does the OSM do, and why is there a delay?</summary>It stores cur and nxt and updates once per hour, so a manipulated price only takes effect an hour later, giving time to react.</details>

<details><summary>4. What exactly is the bug in the legacy OSM?</summary>When the adapter says "invalid/stale", poke() silently does nothing, so cur stays valid forever; there's no age check anywhere downstream.</details>

<details><summary>5. Why didn't anyone just make it return "invalid"?</summary>Invalid means the Spotter sets spot = 0, so every vault becomes liquidatable (the zero-price trap).</details>

<details><summary>6. How does OracleGuard compute the price, and why can't one oracle move it?</summary>A weighted median of fresh sources with MAD outlier rejection. Weights are 2/2/2/1 (total 7) and moving a median needs ≥ half the weight (3.5), so at least 2 of the 3 major oracles.</details>

<details><summary>7. What is the confidence score made of? What does losing one major oracle give?</summary>100 × Wq (coverage by weight) × Wd (agreement) × Wf (freshness). One major lost → Wq = 5/7 → ≈ 71 → YELLOW.</details>

<details><summary>8. What do GREEN / YELLOW / RED change?</summary>Only the debt ceiling: GREEN = debt + $250k refilled hourly; YELLOW = debt + $50k fixed; RED = debt (no new borrowing). Repay always works; liquidations stay on.</details>

<details><summary>9. What does the liquidation guard do, and when?</summary>When everyone agrees the live price is > 3% ABOVE the delayed price the Vat uses (a captured dip), it sets Dog.hole = 0: no new liquidations, for at most 6h.</details>

<details><summary>10. Why don't we raise `mat` when risk rises (our Round 1 idea)?</summary>mat is also the liquidation ratio. Raising it would instantly liquidate healthy vaults mid-incident.</details>

<details><summary>11. Why does SmartOSM hold back only price RISES?</summary>A wrongly high price enables over-borrowing; a drop must pass quickly so liquidations happen in a crash. Our Black Thursday replay showed the symmetric rule froze the price for 4h (ADR-011).</details>

<details><summary>12. How does RED block borrowing but not repaying?</summary>Maker's Vat only checks the ceiling when debt increases. We set line = current debt, so borrows revert and repays pass.</details>

<details><summary>13. What is our biggest limitation, and what's our answer?</summary>Correlated failures (2+ major oracles wrong together, e.g. Mango) can't be detected by any median oracle. We bound the damage (≤ $250k/h vs ≈ $957k at once), plus the 1h delay and quarantine.</details>

<details><summary>14. What exactly changes in Multipli's contracts when we install?</summary>One spell: the Spotter's pip → SmartOSM, and Vat/Dog authorise two executors that can each change one number within a cap. Rollback is one transaction.</details>

<details><summary>15. What is a mainnet fork and why is it convincing?</summary>A local exact copy of Ethereum; we attacked and then protected the REAL deployed rwaUSD contracts, not a toy copy.</details>

<details><summary>16. Name the three attacks we proved and their numbers.</summary>S1: borrowing on a 186h-old price; S3: 10 PAXG ($43,724) → $312,319 borrowed → $268,595 bad debt; S4: a healthy 145% vault liquidated by a captured −15% dip.</details>

<details><summary>17. What's a false negative in our validation, and how many did the replay find?</summary>The price was wrong but the system stayed GREEN (borrowing allowed). Over-borrowing hours: legacy 21 vs OracleGuard 2 (both Mango, capped at $250k).</details>

<details><summary>18. Why are 3 of our 4 sources simulated?</summary>To inject attack scenarios; they sit behind the same interface a real adapter uses. Chainlink is the real mainnet feed, and a real Pyth adapter plugs in via PYTH_SOURCE.</details>

<details><summary>19. What happens if nobody calls poke/sync?</summary>The price ages → SmartOSM reports STALE → the next sync sets RED. It fails safe. Production uses keeper networks plus a bounty.</details>

<details><summary>20. What would you build next?</summary>A verifiable challenge window (void a bad queued price with signed data from other oracles), a Proof-of-Reserve gate, a gold-spot anchor source, a timelock on governance, market-hours rules for tokenised stocks, an audit.</details>

If you can answer all 20 without peeking, you're ready for the review.

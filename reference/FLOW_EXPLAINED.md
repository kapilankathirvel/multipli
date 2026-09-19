# How data flows through OracleGuard (simple, complete, step by step)

> This file follows **the gold price** from the moment it enters our system to the moment it decides what a borrower or a liquidator is allowed to do. It covers **every path** the data can take: normal days, bad days, user actions, admin actions, and the dashboard.
> Written in plain language. Where a technical name matters (because you'll hear it in a review), it's explained the first time it appears.

---

## Part 0: The basics you need first (5 minutes)

### What is rwaUSD, in one picture?
Think of **a bank that gives loans against gold**:
- You **deposit gold** (a digital version called **PAXG**: 1 token = 1 ounce of real gold, ≈ **$4,372**).
- You **borrow dollars** (called **rwaUSD**) against it.
- The bank lets you borrow at most **$1 for every $1.40 of gold**. So with 10 PAXG ($43,724) you can borrow up to **$31,231**.
- If gold falls so much that you no longer have $1.40 per $1 borrowed, anyone can **sell your gold to repay your loan**, plus a 5% penalty. This is called **liquidation**.

### Why the gold price is everything
The bank is a computer program running on a blockchain (Ethereum). **It cannot look up the gold price by itself.** Someone has to tell it. That "someone" is called an **oracle** (think: a messenger).
- If the messenger says gold is worth **more** than it really is → people borrow too much → the bank **loses money** ("bad debt").
- If the messenger says gold is worth **less** than it really is → honest people's gold gets **sold unfairly**.

### The words you'll see in this file (only these)
| Word | Simple meaning |
|---|---|
| **Oracle / source** | A messenger that reports a price. We use four. |
| **PAXG** | Digital gold (1 token = 1 ounce). |
| **rwaUSD** | The digital dollar you borrow. |
| **Vault** | Your personal account at the bank: your gold + your loan. |
| **Liquidation** | Selling someone's gold because their loan became too risky. |
| **Borrowing limit ("debt ceiling")** | The maximum total the bank lets everyone borrow against gold. |
| **Keeper** | A helper bot that presses the "update" buttons. Anyone can be one. |
| **Contract** | A program on the blockchain. Each part of our system is one contract. |

### The main parts (the "cast of characters")
| Our part | Everyday comparison | Its job |
|---|---|---|
| **4 Sources** (Chainlink, Pyth, RedStone, DEX) | four messengers | Each reports the gold price and how fresh it is |
| **Aggregator** | a judge | Listens to all four, throws out liars and old news, decides one price, and says how confident it is (0–100) |
| **SmartOSM** | a noticeboard updated once an hour | Holds the price the bank *acts on*, always one hour behind, so tricks have time to be noticed |
| **Spotter** *(rwaUSD's own part)* | a clerk | Copies the noticeboard price into the bank's ledger |
| **Vat** *(rwaUSD's own part)* | the ledger / the bank itself | Records every vault and enforces the lending rules |
| **RiskController** | a traffic light | Decides 🟢 / 🟡 / 🔴 and whether to raise the 🛡️ shield |
| **LineExecutor / HoleExecutor** | two small hands | The only parts allowed to touch the bank: one changes the borrowing limit, the other can pause liquidations |
| **Dog + Clipper** *(rwaUSD's own)* | the repo man + the auction house | Start liquidations and sell the gold |

**Important:** the parts marked *(rwaUSD's own)* already existed. **We did not change their code.** We only changed *where they get their price from*, and gave our two small hands permission to adjust two numbers.

---

## Part 1: The whole journey on one page

```
  [1] PRICE ENTERS           [2] JUDGE DECIDES         [3] NOTICEBOARD            [4] BANK LEDGER
  4 messengers report  ───►  Aggregator: one price ──► SmartOSM: price the  ───►  Spotter copies it
  gold price + time          + confidence 0-100        bank acts on (1h late)     into the Vat
                                     │                         │
                                     │  (live price + score)   │ (the 1h-late price + its health)
                                     ▼                         ▼
                              [5] TRAFFIC LIGHT: RiskController compares "live" vs "1h late"
                                     │                         │
                          hand #1: borrowing limit     hand #2: pause liquidations
                                     ▼                         ▼
                              [6] THE BANK (Vat / Dog) applies its normal rules
                                     │
                     borrowers borrow / repay        liquidators sell risky gold
```
Two buttons make the data move (anyone can press them, usually a keeper bot):
- **`poke()`**: "update the noticeboard" (at most once per hour). Moves data through steps 1 → 2 → 3 → 4.
- **`sync()`**: "update the traffic light" (any time). Moves data through steps 1 → 2 → 5 → 6.

The rest of this file walks through each step, then every other path.

---

## Part 2: Before anything runs: setup (happens once)

### 2a. Building our parts ("Deploy")
Someone runs the deploy script. It creates our parts, in this order:
1. **The four messengers.**
   - The Chainlink messenger is connected to the **real** Chainlink gold feed.
   - The other three (Pyth, RedStone, DEX) are **simulated** in our demo, so we can stage attacks. They start at the same price Chainlink reports: **$4,372.478**.
2. **The judge (Aggregator).** It is told about the four messengers and how much to trust each:
   | Messenger | Trust (weight) | Too old after |
   |---|---|---|
   | Chainlink | 2 | 25 hours (it only updates when the price moves, so being quiet for hours is normal) |
   | Pyth | 2 | 1 hour |
   | RedStone | 2 | 1 hour |
   | DEX (an exchange price) | 1 (easiest to manipulate) | 1 hour |
3. **The noticeboard (SmartOSM).** It is given a starting price equal to what rwaUSD's old noticeboard currently shows ($4,372.478), so **nothing jumps** at switch-over. It's told who may read it: the Spotter, the Clipper (auction house) and the End (emergency shutdown).
4. **The two hands.**
   - Hand #1 may set the borrowing limit, but never above **$1,000,000** (today's value).
   - Hand #2 may set the liquidation limit, but never above **$400,000** (today's value).
5. **The traffic light (RiskController)**, with its rules: GREEN at 80+, RED under 50, $250k/hour, $50k, and so on.
6. rwaUSD's admins also get admin rights over all our parts. The addresses are saved to a file (`deployments/fork.json`) so the dashboard can find everything.

*(Optional: Varun's market-hours calendar and a real Pyth connection can be plugged in at this step with two settings, `CALENDAR` and `PYTH_SOURCE`.)*

### 2b. Switching the bank over ("the Spell")
rwaUSD's admins (a group wallet that needs 4 of 8 signatures) approve **one transaction** that:
1. tells the **Spotter** (clerk): "from now on, read the price from **SmartOSM**, not the old OSM";
2. gives **hand #1** permission to change the borrowing limit, and **hand #2** permission to change the liquidation limit;
3. presses both buttons once, so everything starts fresh.

**Result:** 🟢 GREEN, confidence 100, borrowing limit = today's loans ($43,029) + $250,000 = **$293,029**.
**Undo:** one transaction points the clerk back to the old OSM and takes the hands' permissions away.

---

## Part 3: Step [1]: the price enters (the four messengers)

### How each messenger gets its price
| Messenger | Where its price really comes from | In our demo |
|---|---|---|
| **Chainlink** | a network of independent companies agrees on the price and writes it to the blockchain themselves, when the price moves enough or about once a day | **real** (the actual live feed, frozen at our test block) |
| **Pyth** | price publishers (trading firms) sign prices; anyone can bring the latest one on-chain | simulated |
| **RedStone** | similar to Pyth: signed price packages brought on-chain when needed | simulated |
| **DEX TWAP** | the average price on an on-chain exchange over the last ~30 minutes | simulated |

In the demo, the simulated messengers are **updated by us** (the keeper script or the dashboard buttons call `setPrice`). In real life their own networks would update them.

### What every messenger hands to the judge
Every messenger answers the same question, "what's your price?", with a small **report card**:
```
price      how much 1 PAXG is worth, in dollars
updatedAt  when this price was published
ok         is this report usable at all? (yes / no)
```

### Cleaning the Chainlink report (the only real one)
Chainlink sends `437247814339`, which means **$4,372.47814339** (Chainlink uses 8 decimal places). Our Chainlink messenger:
- converts it to the format the rest of the system uses (18 decimal places);
- marks it **not ok** if the price is zero or negative, the time is missing or in the future, the number is absurdly large, or **the price is stuck at Chainlink's built-in floor or ceiling**. That last one is how the LUNA crash fooled others in 2022: the feed kept reporting its minimum while the real price kept falling.
- It does **not** decide whether the price is too old. That's the judge's job, so the dashboard can still show "Chainlink: $4,372, 18 hours old".

**Golden rule:** a messenger **never crashes the system**. If anything goes wrong, it just says `ok = no`.

---

## Part 4: Step [2]: the judge decides (the Aggregator)
When asked, the judge collects the four report cards and produces **one answer**:
```
mid        the price it believes
lo / hi    the lowest and highest price among the messengers it believes
score      how confident it is, 0 to 100
ok         did enough messengers agree to give an answer at all?
```

### The judge's 5 steps, with a real example
The four reports on a normal hour:
| Messenger | Price | Age | Weight |
|---|---|---|---|
| Chainlink | $4,372.5 | 18 hours | 2 |
| Pyth | $4,372.0 | 1 minute | 2 |
| RedStone | $4,373.0 | 1 minute | 2 |
| DEX | $4,371.0 | 1 minute | 1 |

**Step 1: ignore old or broken reports.** Each report must be `ok` and younger than its "too old after" limit. Chainlink is 18h old but its limit is 25h, so it's fine. All 4 pass.

**Step 2: find the weighted middle price.**
- Line the prices up from low to high and count the weights as you go:
  ```
  DEX       $4,371.0   weight 1   → running total 1
  Pyth      $4,372.0   weight 2   → running total 3
  Chainlink $4,372.5   weight 2   → running total 5   ← first to pass half of 7 (3.5)
  RedStone  $4,373.0   weight 2   → running total 7
  ```
- The middle price is **$4,372.5**.
- *Why the middle and not the average?* An average can be dragged by one crazy number; the middle can't.

**Step 3: throw out liars.**
- Measure how far each messenger is from the middle: DEX 1.5, Pyth 0.5, Chainlink 0, RedStone 0.5.
- The "typical distance" is the middle of those distances = 0.5.
- Anyone more than **3 × the typical distance** away is a liar. The distance used is never less than 0.1% of the price, so tiny disagreements don't count. Here that means $13.12.
- Everyone is within $13.12, so nobody is thrown out.

**Step 4: the final price and the range.**
- The final price = the middle of the believed messengers = **$4,372.5**.
- Lowest believed = $4,371.0; highest believed = $4,373.0.

**Step 5: the confidence score**, from three questions, each worth up to 1.0:
| Question | Rule | Here |
|---|---|---|
| **How much of the trust is still working and agreeing?** | believed weight ÷ total weight (7) | 7/7 = **1.0** |
| **How closely do they agree?** | 1.0 if identical, falling to 0 when the spread reaches 2% | spread 0.05% → **0.98** |
| **How recent is the newest price?** | 1.0 if the newest believed price is less than half its "too old" limit, then falls to 0 | newest is 1 min old → **1.0** |
| **Score** | 100 × the three multiplied | 100 × 1 × 0.98 × 1 = **98** |

`ok` = yes, because at least 2 messengers were believed.

### What happens when a messenger lies (DEX says $43,720, 10× the real price)
- The line-up becomes Pyth $4,372.0 → Chainlink $4,372.5 → RedStone $4,373.0 → DEX $43,720.
- The running total passes 3.5 at Chainlink, so the middle is still **$4,372.5**. The lie sits at the far end and can't reach the middle.
- DEX is ~$39,000 from the middle, far more than $13.12, so **thrown out**.
- Trust still working: 6/7 → **score 84 → still GREEN**. One lying exchange isn't worth restricting users over.

### How much each messenger "counts" (memorise this table)
| Messengers not believed (old / broken / lying) | Trust left | Score if the rest agree | Light |
|---|---|---|---|
| none | 7/7 | 100 | 🟢 |
| DEX only | 6/7 | ~85 | 🟢 |
| one of Chainlink / Pyth / RedStone | 5/7 | ~71 | 🟡 |
| one big one + DEX | 4/7 | ~57 | 🟡 |
| two big ones | 3/7 | ~42 | 🔴 |
| only one (or none) left | n/a | 0, and "not ok" | 🔴 |

**To actually change the price, at least 2 of the 3 big messengers must lie in the same direction.** No single messenger can do it.

---

## Part 5: Step [3]: the noticeboard (SmartOSM), when someone presses `poke()`

### The idea: a noticeboard that is always 1 hour behind
The bank doesn't act on the live price directly. It acts on a price posted on a noticeboard with **two slots**:
- **"Now" slot (`cur`)**: the price the bank uses right now.
- **"Next" slot (`nxt`)**: the price that moves into "Now" at the next update, one hour later.

**Why be one hour behind?** If someone fakes a price, it only reaches the bank an hour later, which leaves time to notice and react. rwaUSD's old noticeboard (the OSM) worked the same way; we kept that part because it's useful.

### What happens when someone presses `poke()`: all possible paths
```
Has an hour passed since the last update?
 ├─ NO  → refused ("OSM/not-passed"). Nothing changes.
 └─ YES → ask the judge for its answer
          │
          ├─ PATH A: the judge says "not ok" (too few messengers believed, e.g. all silent)
          │     → skip. Both slots stay as they are. The price is NEVER set to zero.
          │       The board notes "no good update since …" → after 2 hours it reports STALE.
          │       The hour is not used up: anyone can press poke again as soon as messengers recover.
          │
          ├─ PATH B: the new price is a big RISE (more than 5% above "Next")
          │          AND the judge isn't confident (score below 80)
          │          AND nothing is already being held back
          │     → HOLD IT BACK ("quarantine"): it is NOT put in "Next".
          │       The already-checked "Next" price still moves into "Now" (so the board keeps moving).
          │       Board status = QUARANTINED. If an hour later the rise is still there, it's accepted.
          │
          └─ PATH C: everything else (normal moves, drops of any size, rises everyone agrees on)
                → ACCEPT: "Now" ← old "Next",  "Next" ← new price
                  + immediately tell the clerk (Spotter) to copy "Now" into the bank's ledger
```

### Why only RISES get held back (and never drops)
- A fake **high** price is what lets people **borrow too much**, so a suspicious rise must be double-checked.
- A **drop** must go through fast, so that during a real crash the bank can **sell risky gold in time**.
- A fake **low** price is handled by the traffic light's 🛡️ shield instead (Part 7).
- *We learned this from our own testing:* when we replayed the 2020 "Black Thursday" crash, the old rule held back every hour of the crash and the bank kept the pre-crash price for 4 hours. We changed the rule, and it now follows a crash with only the normal 1-hour delay.

### The noticeboard over three hours (example)
| Time | Live price (judge) | "Now" slot, the bank uses | "Next" slot |
|---|---|---|---|
| 10:00 | $4,372 | $4,372 | $4,372 |
| 11:00 | $4,460 (+2%, all agree) | $4,372 | **$4,460** |
| 12:00 | $4,460 | **$4,460** | $4,460 |
The bank starts using the new price **one hour** after the market moved.

### The board's status (the traffic light reads this)
| Status | Meaning |
|---|---|
| **LIVE** | updated recently, all normal |
| **STALE** | no good update for over 2 hours (the messengers went quiet) |
| **QUARANTINED** | a suspicious rise is being held back |
| **STOPPED** | admins paused it |

### Two promises the noticeboard always keeps
1. **The price is never zero and never "invalid".** rwaUSD's old noticeboard had an emergency button that set the price to zero, which would have made *every* loan look unpaid at once. We removed that button.
2. **It always knows how old its price is**, and says so openly (STALE) instead of pretending.

---

## Part 6: Step [4]: the clerk copies the price into the bank (rwaUSD's own code)
Right after an accepted update, the **Spotter** (clerk) reads the "Now" price and writes into the bank's ledger (the **Vat**) the **borrowing power per PAXG**:
```
borrowing power per PAXG = price ÷ 1.40 = $4,372.478 ÷ 1.40 = $3,123.198
```
The Vat calls this number **`spot`**. From now on, every loan check uses it. (The clerk can also be pressed on its own by anyone; it just copies whatever the noticeboard's "Now" slot says.)

---

## Part 7: Step [5]: the traffic light (RiskController), when someone presses `sync()`

### What it looks at
The traffic light compares **two prices**:
- **the live price** from the judge (what the market says *right now*), with its confidence score;
- **the noticeboard's "Now" price** (what the bank is *actually using*, one hour behind), with its status.

**The gap between these two tells us which way the danger points.**

### How it picks the colour (checked top to bottom, first match wins)
```
🔴 RED     if the judge says "not ok", or the score is under 50
           or the noticeboard is STALE / QUARANTINED / STOPPED
           or the live price is more than 1.5% BELOW the bank's price
              (the bank thinks gold is worth more than it really is → people could borrow too much)
🟡 YELLOW  if the score is under 80, or the market is closed (e.g. a stock on a weekend)
🟢 GREEN   otherwise
```
**Getting worse is instant; getting better is slow.** To move up one colour, the light needs **3 healthy checks at least 10 minutes apart**. So nobody can press `sync()` 100 times to force it back to green.

### What each colour does: hand #1 sets the borrowing limit
Today's total loans are $43,029.
| Light | Borrowing limit | What borrowers can do |
|---|---|---|
| 🟢 **GREEN** | today's loans + **$250,000**, topped up at most **once per hour** | borrow up to $250,000 of new loans per hour (a **speed limit**, so even an undetected fake price can't be exploited all at once) |
| 🟡 **YELLOW** | today's loans + **$50,000**, fixed when YELLOW starts and **never raised** while YELLOW | only $50,000 more in total until trust returns |
| 🔴 **RED** | exactly today's loans | **no new borrowing at all** |
| any colour | n/a | **paying back always works** |

### The shield: hand #2 pauses liquidations
```
🛡️ SHIELD UP   if the judge is confident (score 80+)
              AND the live price is more than 3% ABOVE the bank's price
              (the bank thinks gold is worth LESS than it really is → honest people could lose their gold unfairly)
   → new liquidations are paused (sales already running continue)
🛡️ SHIELD DOWN when the gap closes, or after 6 hours at most (so liquidations can never be blocked forever)
```

### The two dangers and the two tools, side by side
| If the bank's price is… | The danger is… | The tool used | What stays allowed |
|---|---|---|---|
| **too HIGH** | people borrow too much → bank loses money | 🟡/🔴: limit or stop **new borrowing** | paying back, liquidations |
| **too LOW** | honest people's gold gets sold | 🛡️: pause **new liquidations** | paying back, borrowing (per colour) |

**Never touched:** the price itself, the $1.40 rule, fees, paying back.

---

## Part 8: Step [5b]: the two small hands
```
Traffic light ──"set the limit to X"──►  Hand #1 ──(X ≤ $1,000,000? yes)──► the bank's borrowing limit = X
Traffic light ──"set the pause to Y"──►  Hand #2 ──(Y ≤ $400,000?  yes)──► the bank's liquidation limit = Y  (0 = paused)
```
- They're **the only parts of our system allowed to touch the bank**, and each can change **one number**, never above its maximum.
- Only the traffic light (and rwaUSD's admins) can use them.
- Even if the traffic light had a bug, the worst that could happen is "too careful". The hands can't create money or change prices.

---

## Part 9: Step [6]: what happens at the bank (the final step)
All of this is **rwaUSD's own, unchanged code**; we only changed its inputs (the price, the borrowing limit, the liquidation limit).

### Flow: a user deposits gold
Gold goes into the bank through its gold "door" (the Join), then into the user's vault. **Always allowed**, in every colour.

### Flow: a user borrows rwaUSD
The bank checks two things:
```
1. Would total loans stay within the borrowing limit?   (set by our traffic light)
      no → refused: "Vat/ceiling-exceeded"
2. Does the user have enough gold? gold × $3,123 ≥ loan   (price from our noticeboard)
      no → refused: "Vat/not-safe"
```
*Example:* 10 PAXG → can borrow up to $31,231.
- 🟢 Allowed if this hour's budget has room.
- 🟡 Allowed if the $50k YELLOW budget has room.
- 🔴 Refused.

### Flow: a user pays back
The bank **skips check 1 entirely** when a loan goes down. That's why paying back works in every colour, always. (We tested this 3,200 times with random actions.)

### Flow: a user withdraws gold
Allowed as long as the remaining gold still covers the loan at $3,123 per PAXG. Our system doesn't block it.

### Flow: a liquidation (selling risky gold)
```
1. A liquidator (keeper) says: "this vault is under-covered, sell it" (Dog.bark)
2. The bank checks: gold × $3,123 < loan?                  (price from our noticeboard)
      no → refused: "Dog/not-unsafe"
3. The bank checks: is there room in the liquidation limit? (set by our hand #2)
      no (shield up, limit = 0) → refused: "Dog/liquidation-limit-hit"
4. The auction house (Clipper) starts a falling-price auction. It starts at the noticeboard price × 1.10,
   and buyers take the gold as the price drops.
```

---

## Part 10: A full day in the life (every part's values)
| Time | What happens in the world | Judge (live price, score) | Noticeboard | Traffic light | Users |
|---|---|---|---|---|---|
| 09:00 | normal | $4,372, **100** | LIVE, $4,372 | 🟢 limit $293k | borrow ≤ $250k/h |
| 11:00 | Chainlink stops updating (26h old) | Chainlink ignored → **71** | LIVE (others fresh) | 🟡 limit = loans + $50k | borrow ≤ $50k total |
| 13:00 | someone also makes Pyth report 10× | Pyth thrown out too → **42**, price still $4,372 | unchanged | 🔴 limit = loans | no new loans, repay OK |
| 15:00 | every messenger goes silent | "not ok", **0** | update skipped → **STALE**, price kept (never 0) | 🔴 | frozen, repay OK, **no mass liquidation** |
| 17:00 | messengers come back and agree | **100** | accepted → LIVE | still 🔴 (needs 3 spaced healthy checks) | frozen |
| 17:30 | 3 healthy checks done | 100 | LIVE | 🟡 | $50k |
| 18:00 | 3 more | 100 | LIVE | 🟢 (limit topped up) | $250k/h |

Two alternative events, to show both directions:

| Event | Judge | Noticeboard | Traffic light | Users |
|---|---|---|---|---|
| **A real crash, −15%, everyone agrees** | $3,716, score 100 | the drop is accepted at once (drops are never held back); the bank uses it an hour later | live price below the bank's → 🔴 until the board catches up | risky vaults **are** liquidated (correct) |
| **A brief −15% dip got onto the board, but the market is back** | $4,372, score 100 | "Now" = $3,716 for one hour | live price well above the bank's → 🛡️ **shield up** | healthy vaults **not** liquidated; an hour later the board catches up and the shield drops |

---

## Part 11: Every other data path

### 11a. Reading paths (nothing changes, just looking)
| Who reads | What | Why |
|---|---|---|
| Spotter, Clipper, End (whitelisted) | the noticeboard's "Now" price (`peek`) | to run the bank |
| anyone (dashboard, you, judges) | judge's answer + each messenger's report (`read`, `observations`), noticeboard price/status/age, traffic-light status, bank limits | to watch the system |
| dashboard | "event messages" the contracts shout when something happens: update accepted / skipped / held back, colour changed, shield up/down | the event log |

### 11b. The dashboard's path (Jeffrey)
Every 2 seconds it asks all our parts for their current values and draws the panels. Its scenario buttons write only into the demo: they change the simulated messengers' prices, move the local clock forward, and press `poke` / `sync`. It never changes the real rwaUSD rules.

### 11c. Admin paths (rwaUSD's admins only)
| Action | Effect |
|---|---|
| add/remove a messenger, change weights | changes the judge's inputs |
| change the traffic-light rules (thresholds, $ budgets) | changes how colours are chosen |
| stop / restart the noticeboard | freezes updates (status STOPPED → 🔴) |
| plug in the market-hours calendar | closed market → 🟡 |
| **rollback** | the clerk reads the old OSM again; the two hands lose their permissions |
*(Recommendation for production: put a waiting period in front of these, so users get time to react.)*

### 11d. Test and demo paths (not part of the real system)
- **Our tests** run on a private **copy** of Ethereum, taken at a fixed moment. They can pretend to be rwaUSD's admins and move the clock, which is how we run the attacks.
- The **simulated messengers** are how we stage "this source lies" or "this source is silent".

---

## Part 12: When things break: every failure path
| What breaks | Who notices | What happens next |
|---|---|---|
| one messenger crashes or talks nonsense | the judge (it never trusts a report blindly) | ignored; score drops by that messenger's share |
| one messenger lies | the judge's liar test | thrown out; price unchanged; score drops |
| one messenger goes quiet | the judge's age check | ignored; big one → 🟡 |
| **all** messengers go quiet | the noticeboard (update skipped → STALE) | 🔴 no new loans; price kept (never 0); repay works |
| the judge itself fails | the noticeboard (it never trusts the judge blindly either) | update skipped → eventually STALE → 🔴 |
| a sudden suspicious rise | the noticeboard | held back an hour; 🔴 meanwhile |
| a real crash while one messenger lags | the judge throws the laggard out; the drop passes | the bank follows the crash with the normal 1h delay; 🔴 on borrowing; liquidations run |
| a dip got stuck on the board | the traffic light | 🛡️ pauses new liquidations, ≤ 6h |
| **2+ big messengers lie together** (like Mango Markets, 2022) | ❌ nobody can tell; the majority agrees on the lie | **damage capped**: ≤ $250,000 of new loans per hour (the old system: ≈ $957,000 at once) |
| nobody presses the buttons | the next check sees an old board | STALE → 🔴 (fails safe) |
| the clerk fails to copy the price | the noticeboard ignores the error | the price is still stored; anyone can press the clerk again |
| a bug in the traffic light | the hands' maximums | worst case: the limit is too low or liquidations pause; never new money, never a moved price |
| admins want out | rollback transaction | back to the old system in one step |

---

## Part 13: Who is allowed to do what
| Action | Who |
|---|---|
| press `poke` (update the noticeboard), `sync` (update the traffic light), or the clerk | **anyone** |
| read the noticeboard's "Now" price | only the Spotter, Clipper and End |
| read everything else (judge, status, limits) | anyone |
| use the two hands | the traffic light (and rwaUSD's admins) |
| change the rules, add/remove messengers, stop the board, roll back | rwaUSD's admins |
| switch the bank over to our system (the spell) | rwaUSD's admins only |
| change the simulated messengers' prices | the demo account only (in real life, their own networks) |

---

## Part 14: The whole flow in 10 simple lines (memorise these)
1. **Four messengers** report the gold price. A broken one just says "not ok"; it can't crash anything.
2. **The judge** ignores old or broken reports, takes the **weighted middle** price (no single messenger can move it), and throws out liars.
3. The judge gives a **confidence score 0–100**: how much trust is working × how closely they agree × how fresh the newest price is.
4. **The noticeboard** stores that price **one hour late**, **never shows zero**, and **holds back suspicious rises** (drops always pass).
5. When the noticeboard updates, **the clerk copies it into the bank**: borrowing power = price ÷ 1.40.
6. **The traffic light** compares the **live price** with **the bank's price**, plus the score and the board's health → 🟢 / 🟡 / 🔴, and 🛡️ when the bank's price is unfairly low.
7. It acts **only through two small hands**: the **borrowing limit** ($250k/hour, then $50k, then $0) and a **pause on new liquidations** (max 6 hours).
8. **Borrowers:** the bank checks the limit and the gold. **Paying back always works.**
9. **Liquidators:** the bank checks the vault is really under-covered and that liquidations aren't paused.
10. It's all switched on by **one approval from rwaUSD's admins**, with **no change to rwaUSD's code**, and switched off by **one more**.

---

## Quick self-check
<details><summary>Where does the price enter the system?</summary>Through the four messengers (sources). Chainlink is real; the other three are simulated in the demo and updated by us or by their networks in real life.</details>
<details><summary>Which button moves the price to the bank, and which one changes the colour?</summary>poke() updates the noticeboard and (through the clerk) the bank's price; sync() updates the traffic light and the limits.</details>
<details><summary>Why does the bank use a price that is one hour old?</summary>So that a faked price only reaches the bank an hour later, leaving time to notice and react.</details>
<details><summary>What does the traffic light compare?</summary>The live price from the judge vs the one-hour-late price the bank uses, plus the confidence score and the noticeboard's health.</details>
<details><summary>Why can't one lying messenger change the price?</summary>The judge uses the weighted middle; one messenger holds at most 2 of 7 trust points, and moving the middle needs more than half (3.5).</details>
<details><summary>What can never be blocked?</summary>Paying back a loan (and depositing gold).</details>
<details><summary>What does 🛡️ do and why does it expire?</summary>It pauses new liquidations when the bank's price is unfairly low; it expires within 6 hours because blocking liquidations too long could leave the bank with bad loans.</details>

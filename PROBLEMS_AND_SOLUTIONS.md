# Problems we found, and how we solve them (in simple words)

> This file explains our project in plain language: **what is broken, why it matters, and what we did about it.** Read it when you need to explain the project to someone who isn't technical (or to yourself, quickly).

---

## First, the setting in 4 sentences
- **rwaUSD** is a digital dollar. People get it by **locking up digital gold (PAXG)** and borrowing against it, like a loan against your jewellery at a bank.
- To decide how much you can borrow, the system must know **the price of gold**. But a blockchain can't look it up by itself; it has to be *told* the price by an outside messenger called an **oracle**.
- If the oracle gives a **wrong price**, the system makes wrong decisions:
  - **price too high** → people borrow more than their gold is worth, and the system loses money;
  - **price too low** → honest people get their gold taken away unfairly.
- Today rwaUSD gets its gold price from **one messenger (Chainlink)**, passed through two middle-men contracts (**the adapter** and **the OSM**). The problem statement asks us to make this safer.

The problem statement lists five general oracle problems: **slow data, manipulation, old (stale) data, a source breaking, and not enough data**. It also asks us to fix rwaUSD's OSM and adapter specifically. Below, each problem appears with our solution.

---

## Part 1: The problems in rwaUSD's current setup (what we actually found)
We didn't just guess: we read the real contracts running on Ethereum and **attacked a copy of the real system** to prove each problem.

### Problem 1: Old prices are trusted forever 🔴 (the biggest one)
- **What happens:** the adapter correctly notices when the gold price is more than 24 hours old and says "this is too old". But the OSM **ignores that warning** and keeps using the last price as if it were fresh, **forever**.
- **Why it matters:** if gold's price drops while the feed is stuck, people can keep borrowing against the old, higher price.
- **Proof:** on our copy of the real system, the price was **186 hours old** (almost 8 days) and the system still let us borrow **31,231 rwaUSD** against it.

### Problem 2: The only emergency button destroys everything 🔴
- **What happens:** the only way to tell the system "stop trusting the price" sets the price to **zero**. A zero price makes **every single loan look unpaid at once**, so everyone's gold could be seized.
- **Why it matters:** because the button is so destructive, nobody would ever press it. So in practice there is **no safe way to react** when the price looks wrong. The system has only two modes: *trust blindly* or *self-destruct*.

### Problem 3: One messenger, no second opinion 🟠
- **What happens:** the whole system depends on **one** price source. If it is wrong, hacked, or broken, nothing notices.
- **Proof:** we swapped in a fake feed that said gold was worth 10× more. With **$43,724** of gold, we borrowed **$312,319**, leaving **$268,595 of losses** the system can never recover.

### Problem 4: A few people can change the price source instantly 🟠
- **What happens:** 4 of 8 admins can switch the price source to anything, **with no waiting period**. The only automatic safety reaction *freezes* the current price, which makes the old-price problem worse.
- **Why it matters:** if those admin keys are stolen or misused, the system can be drained within about 2 hours.

### Problem 5: A brief price dip can take honest people's gold 🟠
- **What happens:** the system uses prices with a 1-hour delay. If the price dips for a moment just as it's recorded, the system keeps using that low price for an hour, **even after the market has recovered**.
- **Proof:** a healthy loan (with 45% more gold than required) was **liquidated**, meaning the owner's gold was taken, because of a −15% dip that had already recovered.

### Problem 6: Updates are slow and depend on someone remembering 🟡
- **What happens:** the gold price feed only updates when the price moves enough, or once a day. When we checked, the "fresh" price was already **16.5 hours old**. Moving a new price into the system also takes two separate manual steps that nobody is paid to do.

### Problem 7: Not ready for other assets 🟡
- **What happens:** tokenised stocks (like Tesla shares) trade on the blockchain **on weekends too, while the real stock market is closed**. The one-size-fits-all design doesn't handle that: prices can jump on Monday morning.

*(The full technical list of 13 issues is in `docs/PROBLEM.md`.)*

---

## Part 2: Our solution, OracleGuard, in simple words

**The core idea:** instead of a system that can only say *"here's the price"* or *"price is zero"*, we built one that says **"here's the price, and here's how sure I am (0–100)"**, and then **reacts step by step** depending on how sure it is.

Think of it like a traffic light for borrowing:
- 🟢 **Green:** everything looks right, so normal borrowing is allowed (with a speed limit).
- 🟡 **Yellow:** something looks a bit off, so only small amounts of new borrowing are allowed.
- 🔴 **Red:** something is clearly wrong, so no new borrowing, but **people can always pay back**.
- 🛡️ **Shield:** if the price the system is using is unfairly *low*, taking people's gold is paused for a while.

It has three parts, which match the diagram from our first-round submission:

### Part A: Ask several messengers, not one (the "Aggregator")
- We get the gold price from **four independent sources** (Chainlink, Pyth, RedStone, and an exchange price) instead of one.
- We take the **middle value**, not the average. One liar can't drag the middle, so **no single source can change the price on its own**. It would take two of the three big sources lying the same way.
- A source that is **far away from the others** is ignored. A source that is **too old** is ignored. A source that is **broken** is ignored, and it can't crash the system.
- We then give a **confidence score from 0 to 100**, based on three simple questions:
  1. *How many trusted sources are working?*
  2. *How closely do they agree?*
  3. *How recent is the newest price?*

### Part B: A safer version of the OSM (the "SmartOSM")
- It **keeps the useful 1-hour delay** (it gives time to react if someone manipulates the price).
- It **always knows how old its price is**, and openly reports "my price is old" instead of pretending. This fixes **Problem 1**.
- It **can never report a price of zero**; the self-destruct button is removed. This fixes **Problem 2**.
- A **sudden price rise that the sources don't agree on is held back** until it's confirmed an hour later, because a fake high price is how people over-borrow. **Price drops are not held back**, so the system reacts in time during a real crash.
- It pushes the new price into the system **in one step**, not two. This helps with **Problem 6**.
- It is a **drop-in replacement**: it plugs into rwaUSD's existing contracts exactly where the old OSM was, and nothing else needs changing.

### Part C: The traffic-light controller (the "RiskController")
- It looks at the confidence score and the price the system is currently using, and chooses **Green / Yellow / Red**.
- It only ever touches **two settings**:
  1. **How much new money can be borrowed** (the borrowing limit):
     - 🟢 Green: up to **$250,000 of new loans per hour** (a speed limit, even when things look fine);
     - 🟡 Yellow: up to **$50,000** in total;
     - 🔴 Red: **nothing new**.
  2. **Whether new liquidations (taking gold from unpaid loans) are allowed**: the 🛡️ shield pauses them for **at most 6 hours** when the system's price looks unfairly low. This fixes **Problem 5**.
- It **never** changes the price, **never** blocks repayments, and **never** stops liquidations during a real crash.
- The two settings are changed through **two tiny "hands"** that can each move just one number, and never beyond a safe maximum. Even if the controller had a bug, the worst it could do is be too careful.

### How it gets installed
- **One approval transaction** by rwaUSD's admins switches the system over. **No existing rwaUSD code is changed.**
- **One transaction** switches it back if needed.

---

## Part 3: Each problem from the problem statement → our answer

| Problem statement says… | What it means simply | Our answer |
|---|---|---|
| **Latency** (slow data) | the price arrives late | Borrowing decisions look at the **live** price from 4 sources right away; the price moves into the system in one step instead of two; the slow Chainlink feed is no longer the only input. |
| **Manipulation** | someone fakes the price | Middle-of-four price (no single source can move it); far-off sources ignored; suspicious rises held back; a **speed limit on borrowing** caps the damage even if an attack slips through. |
| **Stale data** | the price is old | Every source's age is checked; SmartOSM openly reports "old"; old data turns the light **Yellow or Red** instead of being trusted forever. |
| **Data-source failures** | a source breaks | Broken sources are ignored without crashing anything; one source failing gives Yellow, not a shutdown; all failing gives Red (no new loans), but the price never goes to zero. |
| **Insufficient data availability** | not enough data | Four independent networks instead of one. Two of them are "on-demand" sources that anyone can refresh when needed. |
| **Fix rwaUSD's OSM & adapter** | the specific ask | SmartOSM replaces the OSM in place; it's proven on a copy of the real rwaUSD system, and all three proven attacks are blocked. |

---

## Part 4: Did it work? (tested on a copy of the real rwaUSD system)
| Attack | Before (today's rwaUSD) | After (with OracleGuard) |
|---|---|---|
| Borrowing on an 8-day-old price | allowed | 🟡 limited to $50k, or 🔴 blocked, and **paying back still works** |
| Fake feed says gold is 10× | **$268,595 lost** | **$0 lost**: the fake source is ignored |
| Market drops but the system's price lags | people borrow too much | 🔴 blocked immediately; liquidations keep working |
| Brief dip takes an honest person's gold | gold taken | 🛡️ **protected**, and the loan is untouched |

**We also replayed 8 famous real-world oracle failures** (from 2019–2023) through both systems:
- Hours where a wrong price allowed over-borrowing: **21 → 2**.
- Hours where honest people could lose their gold unfairly: **5 → 1**.
- Worst-case new borrowing at a wrong price: **≈ $957,000 at once → $250,000 per hour**.

This testing even **caught a mistake in our own design** (it was holding back price drops during crashes), which we then fixed.

---

## Part 5: What we honestly *don't* fully solve
1. **If most sources are fooled at the same time** (like the Mango Markets attack in 2022, where every oracle followed a manipulated market), no "ask several and take the middle" system can notice. **Our answer:** we can't detect it, but we **limit the damage** to $250,000 per hour, versus ≈ $957,000 all at once today. Fooling several independent networks on the huge gold market is also extremely expensive.
2. **3 of our 4 sources are simulated** in the demo, so we can stage attacks. The Chainlink source is the real one, and real sources plug into the same slot.
3. **It costs a bit more to run:** about 6× the fee of the old OSM per update. That's a few dollars an hour, which is small next to the money protected.
4. **The admin-key risk (Problem 4)** needs rwaUSD's team to add a waiting period (timelock) to admin changes; code alone can't force that. We recommend it.
5. **Settings such as "$250k per hour" are sensible starting values**, not yet fine-tuned on years of real data.

---

## One-line summary
> **Today rwaUSD trusts one messenger blindly, and its only safety button destroys everything. OracleGuard asks four messengers, knows how sure it is, and reacts step by step: slowing or pausing new borrowing, protecting honest users, never blocking repayments, and never crashing the price to zero.**

# Degenerus Overview

For a code-grounded contract map, trust assumptions, and “source of truth” pointers, see `AI_TEACHING_GUIDE.md`.

## Core Philosophy

**Degenerus** embeds variance across all aspects, strictly catering to risk-seeking players.

- **Non-upgradeable Core (Write-Once Wiring):** Core gameplay logic is immutable after deployment. The only privileged actions are operational (one-time wiring, emergency VRF recovery after a 3-day RNG stall, and some bond/staking toggles for liquidity), but there is no “upgrade key” that can change gameplay rules under normal operation.
- **Verifiably Fair RNG:** Randomness for daily outcomes is derived from Chainlink VRF and recorded on-chain. Trait generation is deterministic per tokenId; selections/draws are derived from the VRF word so they are auditable.
- **Yield Can Subsidize Rewards:** Some ETH in the system is staked to Lido (stETH). When yield is harvested, it can increase reward budgets. This can increase prize pools over time, but it does not guarantee profits.
- **Anti-Nit:** Designed to deter risk-averse players, MEV exploiters, and those seeking guaranteed returns.
- **Redistribution:** Later participation helps fund jackpots, affiliates, and bond payouts, while early/active players tend to get more chances at major prizes.
- **ETH-Anchored Tokenomics:** BURNIE is created as coinflip stakes (not liquid tokens) tied to ETH spent. Supply fluctuates through gambling variance. Gamepiece prices rise in ETH over time while staying stable in BURNIE.

---

## For Players (Plain English)

- When you buy gamepieces/MAPs with ETH, that ETH stays inside the on-chain system and becomes the pots that pay winners. There isn’t a “house wallet” that can quietly withdraw the pools.
- When you buy gamepieces/MAPs with **BURNIE**, that BURNIE is burned (removed from supply). This is the primary ongoing BURNIE burn mechanic.
- Each level has a “start target” before the burn phase opens. If the target is hit, jackpots and the exterminator prize start firing regularly. If the target is never hit, the main paths to big wins stay blocked.
- Burning is how you turn gamepieces into tickets and create the chance to end the level (extermination). Ending levels is what keeps the game moving and keeps payouts happening.

### Why Jackpots Tend To Grow

- A new level doesn’t open the burn phase until enough ETH has been raised relative to the previous level. This pushes the minimum “pot size” upward over time if players keep participating.
- Part of the system’s ETH is intentionally saved for jackpots and special events. As more ETH flows in and time passes (and if staking yield exists), those jackpot budgets tend to get larger.

### Latecomers → Earlier Players (The Simple Version)

- New buys refill the pots.
- Those pots pay out to people holding tickets (from burning and MAP entries). Players who entered earlier and stayed active tend to have more tickets and more “days in the draw,” so later inflows naturally end up paying earlier participants more often.
- The tradeoff is real: if a level never hits its start target, the burn phase won’t open, and many of the biggest payout paths stay locked. That’s why early players are incentivized to get the level started quickly (by participating and recruiting).

---

## Game Loop

### Level Progression

1. **Purchase Phase:** Players buy gamepieces with ETH. Must hit a target before burning phase unlocks.
2. **Degenerus Phase:** Players burn gamepieces to reduce trait counts. First trait to hit zero = "Exterminated."
3. **Exterminator wins** the prize pool and a Trophy. Level advances.
4. **Timeout:** If no extermination after ~10 daily jackpots, level auto-advances.

**Goal:** Advance levels as fast as possible. Faster = more gambling activity = higher returns for winners.

### Gamepieces & Traits

- Each gamepiece has 4 traits (one per quadrant), deterministically generated and randomly distributed.
- Burning a gamepiece: decrements trait counts, earns BURNIE credits, enters trait jackpots, completes quests.
- **MAPs:** Pay 1/4 gamepiece price for 1 trait ticket + entry into the MAP Jackpot. Early MAPing is designed to be **positive expectation in aggregate** if the game keeps progressing (because next-level tickets can win carryover jackpots early), but it’s still high variance and can lose—especially if the level never really starts or the game times out.

### Pricing

Prices increase through 100-level cycles, then reset. Creates natural progression pressure.

---

## BURNIE Token

### Creation (Variance at the Source)

BURNIE is **not minted on purchase**. Instead:

1. ETH purchases credit **coinflip stakes**
2. Stakes enter daily coinflip (~50% win rate)
3. Winners claim minted BURNIE; losers forfeit stakes
4. Auto-claim on next deposit or explicit claim

**Result:** You never get guaranteed BURNIE from playing.

### Burns

- Gamepiece + MAP purchases with BURNIE (primary sink)
- Marketplace fees (BURNIE)
- Coinflip deposits (burned on entry; wins later mint payouts)
- Decimator jackpot entries
- RNG nudges

### Coinflip Mechanics

- ~50% win rate via VRF
- Variable payout multiplier on wins
- Recycling bonus for rolling winnings forward
- Bounty for setting all-time high stakes
- Winnings are realized lazily: old flip results are “settled” when you interact again (deposit/credit/cashout).
- Coinflips are designed to be close to break-even in BURNIE over time (high variance; no guarantees).
- Coinflips also feed the **BAF** jackpot that fires every 10 levels.

---

## ETH Flow

```
ETH in (no “house wallet”)
  - Gamepiece/MAP buys (ETH)
  - Bond deposits (ETH)
        ↓
On-chain pots
  - Prize pools + jackpots
  - Bond backing (bond pool)
  - Vault reserve
        ↓
Payouts (rule-based only)
  - Jackpot / exterminator winners (claimable)
  - Bond maturities (claimable; or direct on shutdown)
  - Vault claims (by share holders)
```

**stETH Integration:** Some ETH can be staked to Lido (stETH). If yield exists, it increases total system backing and can expand reward budgets, but it does not guarantee profits.

---

## Bond System

Bonds are the game’s **time-locked payout** layer. You only get paid when a future “maturity level” is reached and settled, so bondholders are naturally incentivized to keep the game progressing.

### Key Concepts

- **Maturities:** every 5 levels
- **Sale window:** opens in advance of maturity
- **Where the money goes:** bond deposits are split on-chain between the vault reserve, bond backing, and jackpot funding (reward pool)
- **Some wins roll into bonds:** certain payout paths can convert a slice of winnings into a bond position, which only pays at maturity
- **Anti-runaway payouts:** the maturity’s payout budget is derived from what was raised, with a multiplier that drops as raises grow too fast

### Maturity Payout (Two-Lane System)

1. Your bond position is assigned to one of two lanes deterministically
2. One lane wins; the other is eliminated (high variance)
3. The winning lane’s payout is split between:
   - a pro-rata share you can claim, and
   - several “big-to-small” draw prizes paid to randomly selected lane participants

**High variance by design.** Bondholders accept the risk for larger potential payouts.

### If the Game Ends (Bond Backing on Shutdown)

- If the game goes inactive for long enough, it triggers an on-chain shutdown that drains remaining ETH/stETH into the bond system.
- Bonds then resolves maturities oldest-first using the funds that exist at shutdown (later maturities are the ones at risk of being partially funded).
- After shutdown, claims remain open for 1 year; any leftovers after that are swept to the vault (not to an admin wallet).

---

## Jackpot Systems

### Early Participation Incentives

Burning early is heavily incentivized:

1. **Early burn mini-jackpots** fire from the global reward pool during daily jackpots
2. **Dual-pool draws:** Daily jackpots draw winners for both the current level and the next level; the next-level “carryover” draw is funded primarily from the global reward pool, so getting next-level tickets early can pay before the next burn phase even opens
3. **Flywheel:** Early burners hit more jackpot draws for the same tickets

### Jackpot Types

| Type | Trigger | Pool Source |
|------|---------|-------------|
| **Daily** | Each day during Degenerus phase | current prize pool + reward pool slice |
| **Extermination** | Trait count hits zero | current prize pool |
| **Extermination Carryover** | After extermination settlement (next level tickets) | reward pool slice (1%) |
| **MAP** | End of purchase phase | Weighted by MAPs purchased |
| **BAF** | Every 10 levels | reward pool slice |
| **Decimator** | Periodic windows | BURNIE burns, bucketed by streak |

### BAF (Big-Ass Flip)

Multi-slice jackpot with allocations to: top bettors, exterminators, affiliates, and scatter draws. Fires every 10 levels and is the main “extra reward layer” for coinflippers.

### Decimator

Burn BURNIE for weighted jackpot entry. Better mint streaks = fewer competitors in your bucket.

---

## Affiliate System

Think of affiliates as the protocol’s **built-in marketing budget**: instead of paying a company to run ads, the game rewards the people who bring new participants and keep activity high.

- Referral bonuses are credited as **coinflip stake (“flip credit”)**
- Multi-level upline rewards (you can earn from other affiliates you recruit)
- The system can auto-spend part of affiliate rewards on MAPs to keep affiliates “in the draw”

---

## For Affiliates (What You Actually Get)

- You create an affiliate code with a chosen rakeback %. When someone uses your code, they may receive rakeback, and you (plus up to 2 uplines) earn rewards — including when they come back and buy again.
- Affiliate rewards are primarily credited as **flip credit** (used in the coinflip/BAF ecosystem), not as direct ETH.
- During certain phases, the system can automatically convert part of affiliate rewards into MAP entries for the affiliate, which increases jackpot ticket exposure without extra manual steps.
- Coinflips are designed to be close to break-even in BURNIE (high variance; no guarantees). This means affiliate rewards are closer to “recycling” than a pure burn, while also feeding periodic jackpots like the BAF (every 10 levels).

### Why This Is The “Marketing Budget”

- Your referrals’ ETH purchases refill the on-chain pots (prize pools + the global reward pool). Those pots are what pay jackpots, carryover jackpots, and special reward layers.
- The protocol “pays marketing” by giving affiliates flip credit (and sometimes MAP tickets) that can be used to chase jackpots or converted into transferable BURNIE through gameplay.
- If there’s market liquidity, transferable BURNIE can also be sold. Otherwise it can be spent in-game (and is burned when spent on gamepieces/MAPs).

### Why Successful Affiliates Can Be Lower-Variance Than Pure Gambling

- Your expected earnings come more from **volume you drive** (people using your code and continuing to play) than from hitting a single jackpot.
- You’re still exposed to variance (coinflip outcomes, jackpot randomness, participation), but the income stream is tied to your contribution to growth rather than one lucky event.

### Why Affiliates Like “Late” Entrants Too

- Late entrants often buy for the thrill of being close to the big events. That new ETH strengthens the pots that pay out to the whole ecosystem.
- Long-running, active accounts (including affiliates) tend to have more tickets, more eligibility windows, and more chances to be selected in draws—so late inflows often end up funding earlier participants more frequently in aggregate (while late entrants still have a real chance to win big).

Affiliate advice (normie-friendly):
- Tell your referrals to set/use your code early (referrals are designed to be one-time).
- Your best long-term strategy is consistent activity: it increases your eligibility for special jackpots and increases the amount of time you’re “in the draw.”

---

## Vault (Terminal Reserve)

Long-term safety net backing all value.

- **DGVCOIN shares** → claim BURNIE
- **DGVETH shares** → claim ETH/stETH
- Receives: bond deposit splits, excess from resolutions, final sweep after game over

---

## Game Over

- **Trigger:** 1 year with no level advancement
- **Sequence:** Drain to bonds → resolve maturities in order → 1-year claim grace period → sweep to vault

---

## Marketplace

Non-custodial gamepiece trading built into the contract. Fees (listing + trade percentage) are burned as BURNIE.

---

## Solvency & “Can The Admin Steal?”

### Why Payouts Are Solvent (Plain English)

- The system only credits ETH winnings when the ETH is already inside the system. It doesn’t create “IOUs” that aren’t backed.
- ETH is tracked in separate pots (prize pools, reward pools, bond backing, claimable winnings). Payouts can only come from these pots, and the accounting is designed so pots can’t grow without real inflows.
- If raw ETH liquidity is ever tight, the system can pay using staked ETH (stETH) instead of failing payouts.

### What The Admin Can and Can’t Do

- The admin’s job is mainly setup + keeping Chainlink VRF working (so randomness keeps arriving) and toggling some bond settings.
- The admin cannot arbitrarily withdraw the game’s ETH pools or redirect player winnings. There is no “owner withdraw” function that lets an admin drain prize pools.
- The only way funds move is through the public game rules: purchases fund the system, and winners/claimants receive payouts according to on-chain outcomes.
- Your winnings are credited to your address and claimable by you; someone else (including the admin) can’t “claim for you” unless you give them control of your wallet.

## Incentive Alignment

| Actor | Wants | Risk |
|-------|-------|------|
| **Gamepiece Buyer** | Exterminate for prize + Trophy | Worthless if not burned |
| **Coinflip Player** | Win the daily flip | ~50% total loss |
| **Bondholder** | Game reaches maturity | First claim on all ETH; only recent/underfunded maturities at risk |
| **Affiliate** | Active referrals | Revenue depends on network |
| **MAP Buyer** | Win MAP Jackpot | Sunk cost, jackpot variance |
| **Vault Holder** | Long-term accumulation | Illiquid, game-dependent |

**Core Principle:** Everyone is incentivized to keep the game progressing. Stagnation delays payouts and reduces activity, though bondholders have priority claim on all ETH if the game winds down.

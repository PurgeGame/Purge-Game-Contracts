# Degenerus Overview

## Core Philosophy

**Degenerus** embeds variance across all aspects, strictly catering to risk-seeking players.

- **Ownerless & Immutable:** No admin keys, no upgradability, no privileged actors. Once deployed, the game runs autonomously with no ability for anyone to change the rules or extract funds.
- **Verifiably Fair:** All randomness comes from Chainlink VRF—cryptographically proven to be unmanipulable by players, operators, or miners. Every outcome is auditable on-chain.
- **+EV Through Yield:** Some ETH in the system is staked to Lido (stETH). The yield continuously flows back into the reward pool—both from bond deposits and whenever bonds pay out. No house edge extracting value; yield subsidizes players.
- **Anti-Nit:** Designed to deter risk-averse players, MEV exploiters, and those seeking guaranteed returns.
- **EV Redistribution:** Late players still have fair chances at major prizes. Small negative EV for latecomers funds affiliates and gives a high-variance edge to early players.
- **ETH-Anchored Tokenomics:** BURNIE is created as coinflip stakes (not liquid tokens) tied to ETH spent. Supply fluctuates through gambling variance. Gamepiece prices rise in ETH over time while staying stable in BURNIE.

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
- **MAPs:** Pay 1/4 gamepiece price for 1 trait ticket + entry into the MAP Jackpot (primary incentive).

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

- Coinflip deposits (primary)
- Gamepiece purchases with BURNIE
- Marketplace fees
- Decimator jackpot entries
- RNG nudges

### Coinflip Mechanics

- ~50% win rate via VRF
- Variable payout multiplier on wins
- Recycling bonus for rolling winnings forward
- Bounty for setting all-time high stakes
- Unclaimed winnings expire

---

## ETH Flow

```
ETH Purchases
    ↓
nextPrizePool → currentPrizePool → rewardPool → bondPool
                      ↓                  ↓            ↓
              Exterminator Prize   Jackpots    Bond Payouts
                                                     ↓
                                              claimablePool
```

**stETH Integration:** Excess ETH stakes to Lido. Yield feeds bond payout budgets.

---

## Bond System

Bonds ensure game progression—holders only get paid at maturity, so they're incentivized to keep the game alive.

### Key Concepts

- **Maturities** every 5 levels
- **Sale window** opens before maturity
- Deposits split between vault, bond pool, and reward pool
- **Growth multiplier:** Payout scales inversely with raise growth (anti-Ponzi mechanism)

### Maturity Payout (Two-Lane System)

1. Players assigned to lanes deterministically
2. Random lane wins; other lane gets nothing (50% elimination)
3. Winning lane splits between pro-rata decimator pool and ticketed draws

**High variance by design.** Bondholders accept the risk for larger potential payouts.

---

## Jackpot Systems

### Early Participation Incentives

Burning early is heavily incentivized:

1. **Early burn mini-jackpots** fire from rewardPool during daily jackpots
2. **Dual-pool draws:** Daily jackpots draw winners from both the current level's pool and the next level's pool simultaneously
3. **Flywheel:** Early burners hit more jackpot draws for the same tickets

### Jackpot Types

| Type | Trigger | Pool Source |
|------|---------|-------------|
| **Daily** | Each day during Degenerus phase | currentPrizePool + rewardPool slice |
| **Extermination** | Trait count hits zero | currentPrizePool |
| **MAP** | End of purchase phase | Weighted by MAPs purchased |
| **BAF** | Every 10 levels | rewardPool slice |
| **Decimator** | Periodic windows | BURNIE burns, bucketed by streak |

### BAF (Big-Ass Flip)

Multi-slice jackpot with allocations to: top bettors, exterminators, affiliates, and scatter draws. Requires minimum coinflip stake + ETH mint streak.

### Decimator

Burn BURNIE for weighted jackpot entry. Better mint streaks = fewer competitors in your bucket.

---

## Affiliate System

- Referral bonuses credited as flip stakes
- Multi-level upline rewards
- Affiliates auto-spend portion of rewards on MAPs

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

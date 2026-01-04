# Degenerus: Game & Economy Overview

## Philosophy

Degenerus is a high-variance, on-chain NFT game designed for risk-seeking players.

| Principle | Meaning |
|-----------|---------|
| **Non-upgradeable** | Core gameplay is immutable; no "upgrade key" for rules |
| **Verifiably fair** | Chainlink VRF for all randomness, auditable on-chain |
| **No house wallet** | ETH stays in on-chain pots, paid out only via game rules |
| **Anti-nit** | Variance deters bots/whales seeking riskless extraction |

---

## Game Loop

### Level Cycle

1. **Purchase Phase**: Buy gamepieces with ETH (or BURNIE; BURNIE burns and does not add ETH to pots). Must hit funding target before burn phase opens.
2. **Burn Phase**: Burn gamepieces to reduce trait counts. First trait to zero (or 1 on L%10=7) = "Exterminated."
3. **Settlement**: Exterminator wins prize slice + Trophy. Level advances.
4. **Timeout**: If no extermination after ~10 daily jackpots, level auto-advances.

### Gamepieces & Traits

- Each gamepiece has 4 traits (one per quadrant), deterministically generated
- Burning decrements trait counts, earns BURNIE credits, enters jackpots
- **MAPs**: Pay 1/4 gamepiece price for 1 trait ticket + level jackpot entry

### Pricing

Prices increase through 100-level cycles, then reset.

---

## BURNIE Token

### Creation

BURNIE is **not minted on purchase**:
1. ETH purchases credit coinflip stakes
2. Stakes enter daily coinflip (~50% win rate via VRF)
3. Winners claim minted BURNIE; losers forfeit stakes

### Burns

- Gamepiece/MAP purchases with BURNIE (primary sink)
- Marketplace fees
- Coinflip entry burns
- Decimator jackpot entries
- RNG nudges

### Coinflip

- ~50% win rate, variable payout multiplier
- Recycling bonus for rolling winnings forward
- Bounty for setting all-time high stakes
- Feeds the BAF jackpot (fires every 10 levels)

---

## ETH Flow

```
ETH In                          On-Chain Buckets              Payouts
─────────────────────────────────────────────────────────────────────
Gamepiece/MAP buys (ETH)   →    Prize pools + jackpots   →   Winners
Bond deposits              →    Bond backing (bondPool)  →   Maturities
                           →    Reward pool              →   Special jackpots
                           →    Vault transfers          →   Share holders
```

**stETH**: Some ETH can be staked to Lido. Yield increases system backing and can expand reward budgets.

Some jackpots pay a MAP-ticket slice. The ETH value of those MAP rewards is routed into `nextPrizePool`,
so ticket rewards recycle ETH into future prize pools.

---

## Jackpots

| Type | Trigger | Source |
|------|---------|--------|
| **Daily** | Each day during burn phase | Prize pool + reward slice |
| **Extermination** | Trait hits zero | Prize pool |
| **Carryover** | After extermination | Reward pool (next-level tickets) |
| **Level** | End of purchase phase | Weighted by MAPs |
| **BAF** | Every 10 levels | Reward pool slice |
| **Decimator** | Periodic windows | BURNIE burns, bucketed by streak |

Note: jackpot payouts can convert a portion of ETH into MAP tickets; the MAP cost is added to `nextPrizePool`.

### Early Entry Advantage

- Daily jackpots draw winners for **both** current and next level
- Early MAPs get next-level tickets before burn phase opens
- Early burners hit more jackpot draws for the same tickets

---

## Bonds

Time-locked payouts that incentivize game progression.

### Structure

- **Maturities**: Every 10 levels (levels ending in 0)
- **Sale window**: First 5 levels of each 10-level cycle

### External Deposit Split

| Destination | Percent |
|-------------|---------|
| Bond backing (bondPool) | 20% |
| Reward pool | 10% |
| Untracked yield | 30% |
| Vault share | 40% |

### Maturity Payout

1. Position assigned to one of two lanes (deterministic)
2. One lane wins, other eliminated (high variance)
3. Winning lane splits: pro-rata share + draw prizes

### Game Over

If inactive for ~1 year (or ~2.5 years if never started):
1. Drain to bonds
2. Resolve maturities oldest-first
3. 1-year claim window
4. Sweep remainder to vault

---

## Affiliates

Built-in marketing: the protocol rewards people who bring new participants.

### How It Works

- Create affiliate code with chosen rakeback %
- Referral buys credit you + up to 2 uplines
- Rewards delivered as **flip credit** (coinflip stake)
- System can auto-buy MAPs for affiliates during purchase phase

### Why It's Effective

- Earnings tied to volume driven, not single jackpot wins
- Late entrants refill pots that pay earlier participants
- Affiliates have incentive to keep game progressing

---

## Vault

Long-term reserve with three share classes:

| Share | Claims |
|-------|--------|
| DGVB | BURNIE |
| DGVD | DGNRS |
| DGVE | ETH/stETH |

Receives: vault share of bond deposits, DGNRS escrow, bond surplus, final sweep.

---

## Marketplace

Non-custodial gamepiece trading. Fees (listing + trade %) are burned as BURNIE.

---

## Solvency & Security

### Why Payouts Are Solvent

- ETH only credited when already inside the system
- Tracked in separate pots with closed-loop accounting
- stETH fallback if raw ETH is temporarily short

### Admin Capabilities

| Can Do | Cannot Do |
|--------|-----------|
| VRF subscription upkeep | Withdraw game pots |
| Emergency VRF recovery (3-day stall) | Redirect player winnings |
| Some bond/staking toggles | Change gameplay rules |

---

## Incentive Alignment

| Actor | Wants | Risk |
|-------|-------|------|
| Gamepiece Buyer | Exterminate for prize + Trophy | Worthless if not burned |
| Coinflip Player | Win daily flip | ~50% total loss |
| Bondholder | Game reaches maturity | Lane elimination |
| Affiliate | Active referrals | Revenue depends on network |
| MAP Buyer | Win level jackpot | Sunk cost, variance |
| Vault Holder | Long-term accumulation | Illiquid, game-dependent |

**Core principle**: Everyone is incentivized to keep the game progressing.

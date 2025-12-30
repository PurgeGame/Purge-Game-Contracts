# ETH Buckets & Solvency

How ETH accounting works and why the system stays solvent.

---

## ETH Buckets (Liabilities)

The game tracks ETH liabilities in distinct buckets. Their sum represents total ETH owed.

### Player Liabilities

| Bucket | Purpose | Backing |
|--------|---------|---------|
| `claimablePool` | Aggregate player winnings (jackpots, bonds, affiliates) | 1:1 ETH/stETH |

Only increases via internal transfer from other pools or explicit deposit.

### Bond Liabilities

| Bucket | Purpose | Backing |
|--------|---------|---------|
| `bondPool` | Reserved for bond positions | Principal only |

Credits come from:
- External deposits: `bondDeposit(trackPool=true)`
- Game-originated buys: add `amount / 2`

Yield on this ETH is **not** added here (falls through as untracked surplus).

### Gameplay Rewards

| Bucket | Purpose |
|--------|---------|
| `currentPrizePool` | Active level's exterminator/jackpot pot |
| `nextPrizePool` | Accumulating pot for next level |
| `rewardPool` | General fund for daily jackpots, BAF, side-prizes |

Funded by ETH inflows and internal transfers during MAP-jackpot finalization. RewardPool save % adjusts +/- 2% based on coinflip deposits (capped at 98%).

### Reserved Pools

| Bucket | Purpose |
|--------|---------|
| `decimatorHundredPool` | Level-100 Decimator jackpot |
| `bafHundredPool` | Level-100 BAF jackpot |

Carved from `rewardPool` when needed.

---

## Solvency Guarantee

### The Invariant

```
Total Assets >= Total Liabilities

(ETH Balance + stETH Balance) >= (claimable + bond + prize + reward + special pools)
```

### Mechanism 1: Inflow Matching

Every bucket increase is coupled with an ETH inflow:

| Action | Effect |
|--------|--------|
| Mints | `nextPrizePool` increases by ETH paid (or claimable decreases by same amount) |
| Bond deposits | `bondPool` increases only with `trackPool=true` or game-originated `amount/2` |
| Jackpot allocations | Created by subtracting from other valid pools |

### Mechanism 2: Untracked Surplus (Yield)

The solvency buffer:

1. ETH staked in Lido earns yield (stETH balance grows)
2. Bond yield-share portion calls `bondDeposit(trackPool=false)`
3. **Result**: Assets increase, liabilities stay the same
4. This surplus silently backs all pools

When `claimablePool` pays out, it draws from `address(this).balance` which includes this surplus.

### Mechanism 3: stETH Interchange

ETH and stETH are fungible for solvency:
- If raw ETH is short for payouts, `_payoutWithStethFallback` transfers stETH instead
- Never reverts due to temporary ETH shortage

---

## Why Solvency Holds

1. **Liabilities never exceed inflows** - closed-loop accounting
2. **Assets grow independently** - yield adds to backing without adding liabilities
3. **No ETH leaves without payout** - every withdrawal comes from a tracked bucket

The system is always over-collateralized by design.

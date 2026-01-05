# Quest System Overview

Technical reference for the Degenerus quest mechanics.

## Source of Truth

- `contracts/DegenerusQuests.sol`
- `contracts/interfaces/IDegenerusQuests.sol`
- `contracts/DegenerusCoin.sol`

---

## Architecture

- Quest state lives in `DegenerusQuests` (standalone contract, not delegatecall)
- Coin-gated: only `DegenerusCoin` can call the `handle*` entry points
- `normalizeActiveBurnQuests` can be called by `DegenerusCoin` or `DegenerusGame`
- `DegenerusCoin` forwards gameplay events (mints, flips, burns, bonds, affiliates) to the quest contract
- Quest rewards are applied as BURNIE coinflip credit
- Daily quests rolled during jackpot processing using VRF entropy

---

## Quest Types

| Type | ID | Progress Unit |
|------|----|---------------|
| MINT_BURNIE | 0 | Whole NFT units |
| MINT_ETH | 1 | Whole NFT units |
| FLIP | 2 | BURNIE base units (6 decimals) |
| AFFILIATE | 3 | BURNIE base units |
| BURN | 4 | Whole NFT units |
| DECIMATOR | 5 | BURNIE base units |
| BOND | 6 | Wei |

For MAPs: 4 MAP mints = 1 quest unit.

---

## Daily Quest Structure

- **Two slots active per day** (`QUEST_SLOT_COUNT = 2`)
- **Day boundary**: `(block.timestamp - JACKPOT_RESET_TIME) / 1 days`
- Both slots share the same difficulty flags

### Roll Triggers

| Trigger | Quest Behavior |
|---------|----------------|
| `payDailyJackpot` | `rollDailyQuest` |
| `payCarryoverExterminationJackpot` | `rollDailyQuest` |
| `payLevelJackpot` | Force MINT_ETH + BURN |

---

## Quest Selection

### Primary Slot (Slot 0) Weights

| Type | Weight | Condition |
|------|--------|-----------|
| MINT_ETH | 5 | Always |
| MINT_BURNIE | 10 | Only if `lastPurchaseDay` |
| BURN | 2 | Only if `gameState == 3` |
| BOND | 2 | Always |
| AFFILIATE | 1 | Always |
| DECIMATOR | 4 | Only if window allowed |
| FLIP | 0 | Never primary |

### Bonus Slot (Slot 1)

- Picks different type than primary
- Default weight 1 per eligible type
- MINT_BURNIE: weight 10 when enabled
- DECIMATOR: weight 4 when enabled
- BURN: weight 2 when enabled

### Special Conditions

- **Burn**: Only when `gameState == 3`
- **Decimator**: When `decWindowOpenFlag` and level meets criteria
- **Mint Burnie**: Only when `lastPurchaseDay` is true
- **Bond**: Quest can roll any day; progress only advances when bond purchases are open (level-dependent)

---

## Difficulty

- 10-bit roll from entropy: `entropy & 0x3FF`
- High difficulty: `> 500`
- Very high difficulty: `> 750`

### Targets by Quest Type

| Type | Target Calculation |
|------|-------------------|
| Mint/Burn | 1, 2, or 3 (by difficulty), capped by tier + 1 |
| Flip | Linear between min and tier-specific max |
| Decimator | 2x the flip target |
| Affiliate | Linear between min and tier-specific max |
| Bond | 0.5x to 1.0x mintPrice (by tier) |

---

## Streaks & Tiers

### Completion Rules

- Day complete only when **both slots** are completed
- Streak increments by 1 when both completed same day
- Missing a day resets streak to 0

### Tier Calculation

```
tier = min(streak / 10, 2)
```

| Streak | Tier |
|--------|------|
| 0-9 | 0 |
| 10-19 | 1 |
| 20+ | 2 |

`baseStreak` is captured at first interaction each day for that day's requirements.

---

## Rewards

### Base Reward

- Per-slot: `(PRICE_COIN_UNIT / 5) / 2` = **100 BURNIE**

### Bonuses

| Condition | Bonus |
|-----------|-------|
| High difficulty + tier > 0 | +50 BURNIE |
| Very high difficulty + tier == 2 | +100 BURNIE |
| 10-streak milestone | +500 BURNIE |
| 20-streak milestone | +1000 BURNIE |
| 30-streak milestone | +1500 BURNIE |

### Reward Application

Rewards are added to coinflip credit:
- `depositCoinflip`: added to stake
- `notifyQuestMint/Bond/Burn`: credited as flip stake
- `decimatorBurn`: increases base amount for weighting

Event: `QuestCompleted(player, type, streak, reward, hardMode, completedBoth)`

---

## Burn Quest Conversion

When extermination ends (`gameState` leaves 3):
1. `questModule.normalizeActiveBurnQuests()` called
2. Burn quests convert to:
   - MINT_ETH (if other slot isn't MINT_ETH)
   - AFFILIATE (if other slot is MINT_ETH)
3. Version bumps, progress resets

---

## Entry Points

| Function | Called By | Source |
|----------|-----------|--------|
| `rollDailyQuest` | Coin | Jackpot module |
| `handleMint` | Coin | Gamepieces purchases |
| `handleFlip` | Coin | `depositCoinflip` |
| `handleDecimator` | Coin | `decimatorBurn` |
| `handleBondPurchase` | Coin | Bonds |
| `handleAffiliate` | Coin | Affiliate payouts |
| `handleBurn` | Coin | Game `burnTokens` |

---

## View Functions

| Function | Returns |
|----------|---------|
| `getActiveQuests()` | Quest info with tier-0 requirements |
| `playerQuestStates()` | Raw streak + progress + completion flags |
| `getPlayerQuestView()` | Player-specific with tier-adjusted requirements |

`requirements.tokenAmount` is BURNIE base units for token quests, wei for bond quests.

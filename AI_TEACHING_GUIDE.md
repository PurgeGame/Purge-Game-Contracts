# Degenerus AI Teaching Guide

Guide for AI assistants answering questions about the Degenerus contracts.

## Guidelines

- **Source of truth**: `contracts/**/*.sol` - if this guide disagrees with code, defer to code
- **Default voice**: Plain-English for players/affiliates; code pointers only when asked
- **Be explicit**: Dependencies (VRF, stETH), trust assumptions, one-time wiring
- **No hype**: Avoid guarantees; don't give financial advice
- For player-facing explanations, prefer phrasing from `GAME_AND_ECON_OVERVIEW.md`

---

## Contract Map

### Core Contracts

| Contract | Purpose |
|----------|---------|
| `DegenerusGame.sol` | State machine, ETH/stETH buckets, RNG gating |
| `DegenerusGamepieces.sol` | ERC721 gamepiece NFT |
| `BurnieCoin.sol` | BURNIE (18 decimals), coinflip, quests |
| `DegenerusQuests.sol` | Daily quest state and rewards (standalone) |
| `DegenerusVault.sol` | Vault shares and claims (BURNIE, ETH/stETH) |
| `DegenerusJackpots.sol` | BAF + Decimator jackpots |
| `DegenerusAffiliate.sol` | Referral payouts |
| `DegenerusTrophies.sol` | Non-transferable trophies |

### Modules (delegatecall)

| Module | Purpose |
|--------|---------|
| `DegenerusGameMintModule.sol` | Mint accounting, streak bonuses |
| `DegenerusGameJackpotModule.sol` | Daily/level jackpot logic |
| `DegenerusGameEndgameModule.sol` | Extermination settlement |

Quest system is a standalone contract (`DegenerusQuests.sol`) wired once by admin; it is not a delegatecall module.

### Admin & Wiring

`DegenerusAdmin.sol` handles:
- Chainlink VRF subscription management
- One-time wiring (`wireAll`)
- Emergency VRF migration (after 3-day RNG stall)

**Write-once wiring**: Most addresses have "AlreadyWired" patterns. Admin is for initial setup and VRF maintenance, not gameplay changes.

---

## Units & Time

| Constant | Value | Notes |
|----------|-------|-------|
| BURNIE decimals | 18 | |
| PRICE_COIN_UNIT | 1e21 | = 1000 BURNIE |
| JACKPOT_RESET_TIME | 82620 seconds | Day boundary anchor |
| COIN_CLAIM_DAYS | 30 | Coinflip claim window (days) |

### Day Index

```
Game: (block.timestamp - JACKPOT_RESET_TIME) / 1 days
Coin: ((block.timestamp - JACKPOT_RESET_TIME) / 1 days) + 1  // stakes for "next day"
```

### Game States

| State | Meaning |
|-------|---------|
| 1 | Setup / endgame settlement |
| 2 | Purchase + airdrop processing |
| 3 | Burn phase ("Degenerus") |
| 86 | Game over (sweep to vault) |

---

## ETH Buckets

See [ETH_BUCKETS_AND_SOLVENCY.md](ETH_BUCKETS_AND_SOLVENCY.md) for full details.

### Tracked Liabilities

| Bucket | Purpose |
|--------|---------|
| `claimablePool` | Player claimable winnings |
| `currentPrizePool` | Current level's jackpot pot |
| `nextPrizePool` | Next level accumulator |
| `rewardPool` | General jackpot funding |
| `futurePrizePoolTotal` | Aggregate of all future level reserves |
| `lootboxReservePool` | Pending loot box allocations (allocated at opening) |
| `decimatorHundredPool` | Level-100 decimator jackpot reserve |
| `bafHundredPool` | Level-100 BAF jackpot reserve |

### Solvency Pattern

- Buckets only increase from inflows or inter-bucket transfers
- `yieldPool()` computes: `(ETH + stETH) - obligations`
- Fallback: `_payoutWithStethFallback` pays stETH if ETH is short

---

## Primary Player Flows

### Unified Purchase Function

**Recommended Entry**: `DegenerusGame.purchase(gamepieceQuantity, mapQuantity, lootBoxAmount, affiliateCode, payKind)`

This is the main entry point for all ETH/claimable purchases. It allows buying any combination of:
- Gamepieces
- MAPs
- Loot boxes

**Benefits**:
- Single transaction for multiple purchase types
- 10% bonus when spending all claimable winnings (minimum 3 gamepiece-equivalents)
- Loot boxes earn affiliate rewards (50% of gamepiece rate)
- Gas efficient

**Payment modes** (`MintPaymentKind`):
- `DirectEth`: Use msg.value
- `Claimable`: Spend from claimable winnings
- `Combined`: Mix of both

**Note**: For BURNIE purchases only, use `DegenerusGamepieces.purchase()` with `payInCoin=true`

### 1. Buying Gamepieces

**Entry options**:
1. `DegenerusGame.purchase(...)` - unified purchase (recommended for ETH/claimable)
2. `DegenerusGamepieces.purchase(PurchaseParams)` - direct purchase (for BURNIE only)

**Payment options**:
- ETH/Claimable: Use `DegenerusGame.purchase()` with `MintPaymentKind`
- BURNIE: Use `DegenerusGamepieces.purchase()` with `payInCoin=true`

**Timing note**:
- Purchases are allowed whenever RNG is unlocked; in state 3 the purchase is treated as the next level.

**Flow**:
1. ETH/claimable: Routes to `DegenerusGame.recordMint(...)` -> funds `nextPrizePool`
   BURNIE: Burns token, no ETH contribution
2. Streak bonuses computed in `DegenerusGameMintModule`
3. BURNIE credits via `BurnieCoin.creditFlip(...)`
4. Affiliate handling via `DegenerusAffiliate.payAffiliate(...)`
5. In state 3, ETH/claimable mints also enqueue MAP tickets for jackpots
6. Jackpot payouts can convert a slice into MAP tickets; that MAP cost is routed into `nextPrizePool`

### 2. Buying MAPs

**Entry options**:
1. `DegenerusGame.purchase(...)` with `mapQuantity` parameter (recommended for ETH/claimable)
2. `DegenerusGamepieces.purchase(PurchaseParams)` with `PurchaseKind.Map` and `payInCoin=true` (BURNIE only)

**Pricing**:
- ETH cost: `priceWei / 4` per MAP
- BURNIE cost: `PRICE_COIN_UNIT / 4` per MAP

**Processing**:
- Queued via `enqueueMap(...)`, processed in batches during `advanceGame` state 2
- ETH/claimable MAP buys are allowed whenever RNG is unlocked (gameState does not gate)
- BURNIE MAP buys are only allowed on `lastPurchaseDay` (gameState == 2) and are blocked in state 3

### 3. Loot Boxes

**Entry**: `DegenerusGame.purchase(...)` with `lootBoxAmount` parameter

**Unified Purchase**:
- Use the main `purchase()` function with `lootBoxAmount` set (minimum 0.01 ETH)
- Can combine with gamepiece/MAP purchases in same transaction
- Loot boxes are always paid with ETH (not claimable or BURNIE)

**Day Tracking**:
- One loot box per day per player (indexed from `JACKPOT_RESET_TIME`)
- Can add to existing day's loot box
- Days are indexed independently

**Purchase Split**:

Normal mode:
- 60% → `lootboxReservePool` (allocated to random level at opening)
- 20% → `nextPrizePool`
- 20% → `rewardPool`

Presale mode (`lootboxPresaleActive == true`):
- 10% → `lootboxReservePool`
- 10% → `nextPrizePool`
- 30% → Vault (immediate transfer)
- 50% → `rewardPool`

**Opening**: `DegenerusGame.openLootBox(uint48 day)`

Requires:
- RNG unlocked (`!rngLockedFlag`)
- VRF entropy from daily advance

Reward outcomes (d20 roll):
- Rolls 0-11 (60%): MAP tickets OR gamepiece for target level (116.67% value)
  - Sub-roll (d6): 1/6 chance gamepiece if budget ≥ 4× MAP price, else tickets
- Rolls 12-15 (20%): Small BURNIE (5% normal, 10% presale)
- Rolls 16-19 (20%): Large BURNIE (195% normal, 390% presale)

Target level: `currentLevel + (0-5)` rolled uniformly at opening time
- All tickets/gamepieces awarded for single rolled level
- Ticket quantity calculated using rolled level's price
- `lootboxReservePool` → `futurePrizePool[targetLevel]` at opening

**Functions**:
- `lootboxStatus(address, uint48)` - View purchase amount and presale flag
- `startLootboxPresale()` - Admin-only, enables presale mode
- `endLootboxPresale()` - Admin-only, disables presale mode (one-way)

### 4. Burning NFTs

**Entry**: `DegenerusGame.burnTokens(uint256[] tokenIds)`

**Guards**:
- Must be `gameState == 3`
- `rngLockedFlag == false`
- Max 75 tokens per call

**Effects**:
- Decrements `traitRemaining[traitId]`
- Appends to `traitBurnTicket[level][traitId]`
- If trait hits zero -> extermination (on L%10=7, triggers at 1), settlement on next `advanceGame`

### 5. Advancing Game

**Entry**: `DegenerusGame.advanceGame(uint32 cap)`

- Anyone can call; standard path requires "minted today"
- `cap != 0` is emergency path (bounded work, no daily mint check)
- Requests Chainlink VRF, sets `rngLockedFlag`
- VRF callback: `rawFulfillRandomWords(...)`

**Jackpot execution by state**:
- State 3: `payDailyJackpot(true, ...)` for current + next level
- State 2: `payDailyJackpot(false, ...)` for purchase-phase early jackpots
- State 1: Extermination settlement + carryover jackpot

### 6. Claiming

**ETH**: `DegenerusGame.claimWinnings()` - resets to 1-wei sentinel, pays out

**BURNIE**: Lazy - `depositCoinflip(0)` triggers netting/minting via `addFlip(...)`
Coinflip claims only cover the most recent 30 resolved days; older stakes expire. Last purchase day adds +6% to the bonus percent.

---

## Level Progression

### Start Gate

Level opens burn phase when: `nextPrizePool >= lastPrizePool`

What increases `nextPrizePool`:
- ETH/claimable mints flow through `recordMint(...) -> nextPrizePool`
- BURNIE purchases don't add ETH (burn path)
- MAP rewards from jackpots: the MAP cost is moved into `nextPrizePool`
- Loot box purchases: 20% in normal mode, 10% in presale mode
- `futurePrizePool[level]` transfers to `nextPrizePool` when target level is reached

### Ratchet Mechanism

At level jackpot finalization:
1. `nextPrizePool` -> `currentPrizePool`
2. `lastPrizePool = currentPrizePool`

Next level must raise at least `lastPrizePool` to start. Minimum raises are non-decreasing.

### Level-100 Boundary

At `level % 100 == 0`: `lastPrizePool = rewardPool` (can jump start target)

### RewardPool Growth

- Direct ETH to game: `receive() -> rewardPool`
- Per-level save at level jackpot finalization
- Coinflip adjustment: +/- 2% based on last-purchase-day deposits (capped 98%)

---

## Jackpot System

### Daily Jackpots (Burn Phase)

`payDailyJackpot(true, lvl, rngWord)`:
1. Pays current level jackpot
2. Pays carryover jackpot for `lvl + 1` (next-level tickets)

MAP rewards:
- Some jackpots convert part of ETH payouts into MAP tickets; those units are queued and their ETH cost is added to `nextPrizePool`

### Extermination Flow

1. `DegenerusGameEndgameModule.finalizeEndgame(...)` pays exterminator + trait jackpot
2. `payCarryoverExterminationJackpot(...)` pays 1% rewardPool to next-level trait holders

### Special Jackpots

**BAF**: Levels where `prevLevel % 10 == 0`. Slices for top bettors, exterminators, affiliates, scatter draws.

**Decimator**: Mid-decile windows, requires BURNIE burn. Bucketed by `ethMintStreakCount`/`ethMintLevelCount`.

---

## Game Over

Triggers:
- `levelStartTime` set + 365 days inactive
- Never started + ~2.5 years from deploy

Sequence:
1. `gameOverDrainToVault()` sweeps ETH + stETH into the vault
2. Game state transitions to GAMEOVER (86)

---

## Trust & Dependencies

### What's Immutable

- Core rules in deployed bytecode
- Write-once wiring (AlreadyWired patterns)
- No off-chain servers for settlement

### Dependencies

- **Chainlink VRF**: Required for randomness. 3-day stall triggers emergency recovery path.
- **Lido stETH**: Optional staking for yield buffer

### Admin Powers

| Allowed | Not Allowed |
|---------|-------------|
| VRF rotation after 3-day stall | Arbitrary pool withdrawal |
| One-time wiring (`wireAll`) | Gameplay rule changes |
| VRF subscription management | Redirect player winnings |

---

## Common Reverts

| Error | Cause | Check |
|-------|-------|-------|
| `MustMintToday` | No ETH mint this day slot | Need DirectEth/Claimable mint |
| `NotTimeYet` | Wrong phase or day not rolled | Check `gameState`, day index |
| `RngNotReady` / `RngLocked` | VRF in-flight | `rngLocked()`, wait for callback |
| `NotDecimatorWindow` | Outside decimator window | `decWindow()` |

---

## View Functions

| Function | Returns |
|----------|---------|
| `purchaseInfo()` | Current level, phase, pricing |
| `mintPrice()` | Current gamepiece price |
| `nextPrizePoolView()` | Accumulated next-level pot |
| `prizePoolTargetView()` | Start target (lastPrizePool) |
| `getWinnings()` | Player's claimable ETH |
| `rngLocked()` | Whether VRF is in-flight |
| `rngStalledForThreeDays()` | Emergency recovery eligible |
| `lootboxStatus(address, uint48)` | Loot box amount and presale flag for player/day |
| `futurePrizePoolView(uint24)` | Reserved pool for specific level |
| `futurePrizePoolTotalView()` | Aggregate of all future level reserves |

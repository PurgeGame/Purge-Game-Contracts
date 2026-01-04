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
| `DegenerusCoin.sol` | BURNIE (6 decimals), coinflip, quests |
| `DegenerusQuests.sol` | Daily quest state and rewards (standalone) |
| `DegenerusBonds.sol` | Maturity cycles, game-over resolution |
| `DegenerusVault.sol` | Three share classes (BURNIE, DGNRS, ETH/stETH) |
| `DegenerusJackpots.sol` | BAF + Decimator jackpots |
| `DegenerusAffiliate.sol` | Referral payouts |
| `DegenerusTrophies.sol` | Non-transferable trophies |

### Modules (delegatecall)

| Module | Purpose |
|--------|---------|
| `DegenerusGameMintModule.sol` | Mint accounting, streak bonuses |
| `DegenerusGameJackpotModule.sol` | Daily/level jackpot logic |
| `DegenerusGameEndgameModule.sol` | Extermination settlement |
| `DegenerusGameBondModule.sol` | Staking, yield, game-over drain |

Quest system is a standalone contract (`DegenerusQuests.sol`) wired once by admin; it is not a delegatecall module.

### Admin & Wiring

`DegenerusAdmin.sol` handles:
- Chainlink VRF subscription management
- One-time wiring (`wireAll`)
- Emergency VRF migration (after 3-day RNG stall)
- Bond presale controls

**Write-once wiring**: Most addresses have "AlreadyWired" patterns. Admin is for initial setup and VRF maintenance, not gameplay changes.

---

## Units & Time

| Constant | Value | Notes |
|----------|-------|-------|
| BURNIE decimals | 6 | |
| PRICE_COIN_UNIT | 1e9 | = 1000 BURNIE |
| JACKPOT_RESET_TIME | 82620 seconds | Day boundary anchor |

### Day Index

```
Game: (block.timestamp - JACKPOT_RESET_TIME) / 1 days
Coin: ((block.timestamp - JACKPOT_RESET_TIME) / 1 days) + 1  // stakes for "next day"
```

### Game States

| State | Meaning |
|-------|---------|
| 0 | Shutdown (post-drain) |
| 1 | Pregame / endgame settlement |
| 2 | Purchase + airdrop processing |
| 3 | Burn phase ("Degenerus") |

---

## ETH Buckets

See [ETH_BUCKETS_AND_SOLVENCY.md](ETH_BUCKETS_AND_SOLVENCY.md) for full details.

### Tracked Liabilities

| Bucket | Purpose |
|--------|---------|
| `claimablePool` | Player claimable winnings |
| `bondPool` | Bond obligation backing |
| `currentPrizePool` | Current level's jackpot pot |
| `nextPrizePool` | Next level accumulator |
| `rewardPool` | General jackpot funding |

### Solvency Pattern

- Buckets only increase from inflows or inter-bucket transfers
- Untracked surplus: `bondDeposit(trackPool=false)` increases assets without increasing liabilities
- `yieldPool()` computes: `(ETH + stETH) - obligations`
- Fallback: `_payoutWithStethFallback` pays stETH if ETH is short

---

## Primary Player Flows

### 1. Buying Gamepieces

**Entry**: `DegenerusGamepieces.purchase(PurchaseParams)`

**Payment options** (`MintPaymentKind`):
- `payInCoin=true`: burns BURNIE, no ETH transfer
- `payInCoin=false` uses `MintPaymentKind`:
  - `DirectEth`: msg.value
  - `Claimable`: from DegenerusGame balance
  - `Combined`: mix

**Flow**:
1. `payInCoin=false`: NFT routes to `DegenerusGame.recordMint(...)` -> funds `nextPrizePool`
   `payInCoin=true`: burns BURNIE, no ETH contribution
2. Streak bonuses computed in `DegenerusGameMintModule`
3. BURNIE credits via `DegenerusCoin.creditFlip(...)`
4. Affiliate handling via `DegenerusAffiliate.payAffiliate(...)`
5. In state 3, ETH/claimable mints also enqueue MAP tickets for jackpots
6. Jackpot payouts can convert a slice into MAP tickets; that MAP cost is routed into `nextPrizePool`

### 2. Buying MAPs

Same `purchase(...)` entry with `PurchaseKind.Map`.
- ETH cost: `priceWei / 4` per MAP
- BURNIE cost: `PRICE_COIN_UNIT / 4` per MAP
- Queued via `enqueueMap(...)`, processed in batches during `advanceGame` state 2

### 3. Burning NFTs

**Entry**: `DegenerusGame.burnTokens(uint256[] tokenIds)`

**Guards**:
- Must be `gameState == 3`
- `rngLockedFlag == false`
- Max 75 tokens per call

**Effects**:
- Decrements `traitRemaining[traitId]`
- Appends to `traitBurnTicket[level][traitId]`
- If trait hits zero -> extermination (on L%10=7, triggers at 1), settlement on next `advanceGame`

### 4. Advancing Game

**Entry**: `DegenerusGame.advanceGame(uint32 cap)`

- Anyone can call; standard path requires "minted today"
- `cap != 0` is emergency path (bounded work, no daily mint check)
- Requests Chainlink VRF, sets `rngLockedFlag`
- VRF callback: `rawFulfillRandomWords(...)`

**Jackpot execution by state**:
- State 3: `payDailyJackpot(true, ...)` for current + next level
- State 2: `payDailyJackpot(false, ...)` for purchase-phase early jackpots
- State 1: Extermination settlement + carryover jackpot

### 5. Claiming

**ETH**: `DegenerusGame.claimWinnings()` - resets to 1-wei sentinel, pays out

**BURNIE**: Lazy - `depositCoinflip(0)` triggers netting/minting via `addFlip(...)`

---

## Level Progression

### Start Gate

Level opens burn phase when: `nextPrizePool >= lastPrizePool`

What increases `nextPrizePool`:
- ETH/claimable mints flow through `recordMint(...) -> nextPrizePool`
- BURNIE purchases don't add ETH (burn path)
- MAP rewards from jackpots: the MAP cost is moved into `nextPrizePool`

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
- Yield skims: `bondUpkeep(...)` adds `yieldTotal / 20` to rewardPool

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

## Bonds

### Deposit Splits (External)

| Destination | % |
|-------------|---|
| bondPool (tracked) | 20 |
| rewardPool | 10 |
| Untracked yield | 30 |
| Vault (stETH preferred) | 40 |

Presale: 30% vault / 50% rewardPool / 20% yield (no bondPool)

Game-originated buys: no internal split, use game's existing ETH

### VRF

Bonds has separate VRF interface for lane resolution.

### Game Over

Triggers:
- `levelStartTime` set + 365 days inactive
- Never started + ~2.5 years from deploy

Sequence:
1. `gameOverDrainToBonds()` -> `DegenerusGameBondModule.drainToBonds(...)`
2. `DegenerusBonds.gameOver()` resolves maturities oldest-first
3. 1-year claim window
4. `sweepExpiredPools()` to vault

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
| Bond staking target (`setRewardStakeTargetBps`) | Gameplay rule changes |
| Presale management | Redirect player winnings |

---

## Common Reverts

| Error | Cause | Check |
|-------|-------|-------|
| `MustMintToday` | No ETH mint this day slot | Need DirectEth/Claimable mint |
| `NotTimeYet` | Wrong phase or day not rolled | Check `gameState`, day index |
| `RngNotReady` / `RngLocked` | VRF in-flight | `rngLocked()`, wait for callback |
| `NotDecimatorWindow` | Outside decimator window | `decWindow()` |
| Bond deposits disabled | Wrong level window or RNG lock | `_bondPurchasesOpen`, level % 10 < 5 |

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

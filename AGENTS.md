# PurgeGame / Degenerus - Agent Guide

This repo is about verifying that the on-chain game behaves exactly as designed. Your primary goal is to write and run thorough tests for the Solidity contracts so behavior aligns with the design intent described in the docs.

## Source of Truth
- Code is the final authority: `contracts/**/*.sol`.
- Design intent and plain-English explanations:
  - `AI_TEACHING_GUIDE.md` (code map + intent)
  - `GAME_AND_ECON_OVERVIEW.md` (player-facing design intent)
  - `ETH_BUCKETS_AND_SOLVENCY.md` (accounting + solvency invariants)

If docs disagree with code, defer to code and flag the mismatch.

## Repo Map (What You Are Testing)
- Core contracts:
  - `contracts/DegenerusGame.sol` (state machine, ETH/stETH buckets, RNG gate)
  - `contracts/DegenerusGamepieces.sol` (ERC721, purchase flows)
  - `contracts/DegenerusCoin.sol` (BURNIE, coinflip, decimator burns)
  - `contracts/DegenerusBonds.sol` (maturities, bond payouts)
  - `contracts/DegenerusJackpots.sol` (BAF + Decimator jackpot logic)
  - `contracts/DegenerusAffiliate.sol` (referrals + rakeback)
  - `contracts/DegenerusVault.sol` (vault shares and claims)
  - `contracts/DegenerusTrophies.sol` (non-transferable trophies)
- Modules used via delegatecall:
  - `contracts/modules/DegenerusGameMintModule.sol`
  - `contracts/modules/DegenerusGameJackpotModule.sol`
  - `contracts/modules/DegenerusGameEndgameModule.sol`
  - `contracts/modules/DegenerusGameBondModule.sol`
  - `contracts/modules/DegenerusQuestModule.sol`
- Tests and harnesses:
  - JS tests in `test/`
  - Solidity harnesses/mocks in `contracts/test/`

## Quick Commands
- Install: `npm install`
- Compile: `npm run compile`
- Unit tests: `npm test`
- Local sim: `npm run sim:local -- --days 30 --players 6`
- Sim report: `npm run sim:report`

## Design Intent (Short Form)
- Non-upgradeable core; wiring is write-once.
- RNG via Chainlink VRF; RNG stalls trigger a 3-day emergency recovery path.
- No admin withdraw of game pots; payouts only via rules.
- ETH accounting is bucketed and must remain solvent (assets >= liabilities).
- High variance by design (jackpots, coinflips, bonds, time locks).

## Key Units and Time
- BURNIE decimals: 6.
- `PRICE_COIN_UNIT = 1e9` (1000 BURNIE).
- Day index uses `JACKPOT_RESET_TIME = 82620`.
- Game state: 0 = shutdown, 1 = endgame, 2 = purchase, 3 = burn.
- Level cycles: 100-level bands; BAF every 10 levels; bond maturity every 5 levels.
- Game over: inactivity ~365 days triggers drain to bonds; 1-year claim window after.

## Testing Priorities (Order Matters)
1. Solvency and bucket accounting
2. Permissioning + write-once wiring
3. State machine + time/RNG gating
4. Economic flows and payout correctness
5. Edge cases at boundaries (levels, days, caps, rounding)

## Core Invariants to Prove
- Buckets only grow from valid inflows or internal transfers.
- Total assets (ETH + stETH) always cover total liabilities.
- `bondDeposit(trackPool=false)` increases assets without increasing liabilities.
- `claimablePool` only increases from existing pools or bond deposits.
- No paths allow admin to withdraw user funds outside rules.
- Write-once wiring cannot be overwritten after initialization.

## Subsystem Test Checklist

### DegenerusGame (state machine)
- `advanceGame` transitions are correct across `gameState`.
- Day gating: `MustMintToday`, `NotTimeYet` rules.
- RNG gating: `rngLockedFlag` blocks burn and jackpot actions.
- Start target: `nextPrizePool >= lastPrizePool` must be enforced.
- Level boundaries (level % 100 == 0) reset `lastPrizePool` to `rewardPool`.
- Game over drain after 365 days of inactivity.

### Gamepieces (purchase + MAP)
- ETH vs claimable vs combined payment paths.
- MAP pricing (ETH and BURNIE) and queue/processing behavior.
- Affiliate rakeback and upline reward handling.
- Mint streak tracking and its effect on decimator/coin logic.

### Coin (BURNIE + coinflip)
- Coinflip stakes are credited, wins are minted lazily.
- Burn paths (gamepiece/MAP purchases, marketplace fees, decimator burns).
- Flip totals affect reward pool percent (+/- 2%) with 98% cap.

### Jackpots (daily, extermination, MAP, BAF, Decimator)
- Daily jackpot runs for current and next level (carryover).
- Extermination and carryover extermination payouts.
- MAP jackpot finalization moves `nextPrizePool` -> `currentPrizePool`.
- BAF triggers every 10 levels and uses jackpot slices correctly.
- Decimator window enforcement and bucket weighting.

### Bonds
- Maturity cadence (every 5 levels) and lane selection.
- Deposit splits: vault share, bond backing, reward share.
- Game-over drain resolves maturities in order.
- stETH/ETH liquidity handling for payouts.

### Vault
- Share issuance and claim flows for BURNIE and ETH/stETH.
- Vault mint allowance and presale claim flows.

### Affiliate
- Multi-level upline rewards and rakeback.
- Auto MAP purchase behavior during purchase phase.

### Trophies / NFT utils
- Trophy transfers are blocked; approvals revert.
- Trait generation is deterministic for tokenId.

## Suggested Testing Techniques
- Use Hardhat time travel to simulate day/level boundaries.
- Use mocks in `contracts/test/`:
  - `MockVRFCoordinator.sol` for RNG.
  - `MockStETH.sol` for stETH fallback.
  - `EndgameHarness.sol` / `ExposedDegenerusGamepieces.sol` for internal access.
- Prefer property-like tests for invariants (bucket sums, state transitions).
- When adding tests, keep them deterministic and isolate RNG inputs.

## Dependencies and Trust Assumptions to Validate
- Chainlink VRF availability and subscription wiring.
- Lido stETH integration for yield/solvency.
- `DegenerusAdmin` can rotate VRF after 3-day stall and toggle bond settings.

## How to Report Issues
- Provide the contract/function and a minimal repro.
- If the issue is a mismatch with intent, cite the doc and the code location.

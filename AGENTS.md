# Degenerus Agent Testing Guide

Goal: Verify on-chain behavior matches design intent via thorough testing.

## Source of Truth

1. **Code**: `contracts/**/*.sol`
2. **Design docs**: `AI_TEACHING_GUIDE.md`, `GAME_AND_ECON_OVERVIEW.md`, `ETH_BUCKETS_AND_SOLVENCY.md`

If docs disagree with code, defer to code and flag the mismatch.

---

## Quick Commands

```bash
npm install          # Install dependencies
npm run compile      # Compile contracts
npm test             # Run unit tests
npm run sim:local -- --days 30 --players 6  # Local simulation
npm run sim:report   # Simulation report
```

---

## Contract Map

### Core

| Contract | Purpose |
|----------|---------|
| `DegenerusGame.sol` | State machine, ETH/stETH buckets, RNG |
| `DegenerusGamepieces.sol` | ERC721, purchase flows |
| `DegenerusCoin.sol` | BURNIE, coinflip, decimator |
| `DegenerusBonds.sol` | Maturities, bond payouts |
| `DegenerusJackpots.sol` | BAF + Decimator jackpots |
| `DegenerusAffiliate.sol` | Referrals + rakeback |
| `DegenerusVault.sol` | Vault shares and claims |
| `DegenerusTrophies.sol` | Non-transferable trophies |
| `DegenerusQuests.sol` | Daily quest state and rewards |

### Modules (delegatecall)

- `DegenerusGameMintModule.sol`
- `DegenerusGameJackpotModule.sol`
- `DegenerusGameEndgameModule.sol`
- `DegenerusGameBondModule.sol`

Quest system is standalone (`DegenerusQuests.sol`), not a delegatecall module.

### Test Infrastructure

- Tests: `test/`
- Mocks: `contracts/test/` (MockVRFCoordinator, MockStETH, harnesses)

---

## Key Constants

| Constant | Value |
|----------|-------|
| BURNIE decimals | 6 |
| PRICE_COIN_UNIT | 1e9 (= 1000 BURNIE) |
| JACKPOT_RESET_TIME | 82620 seconds |
| Game states | 0=shutdown, 1=pregame/endgame settlement, 2=purchase, 3=burn |
| BAF trigger | Every 10 levels |
| Bond maturity | Every 10 levels |
| Game over | ~365 days inactive |

---

## Testing Priorities

1. **Solvency**: Bucket accounting, assets >= liabilities
2. **Permissions**: Write-once wiring, access control
3. **State machine**: Time/RNG gating, phase transitions
4. **Gas**: `advanceGame(0)` must stay under 16.7M (target <15M)
5. **Economics**: Payout correctness, jackpot math
6. **Edge cases**: Level/day boundaries, caps, rounding

---

## Core Invariants

- Buckets grow only from valid inflows or internal transfers
- `(ETH + stETH) >= sum(all tracked buckets)`
- `bondDeposit(trackPool=false)` increases assets without liabilities
- `claimablePool` increases only from existing pools or bond deposits
- No admin paths to withdraw user funds
- Write-once wiring cannot be overwritten

---

## Subsystem Checklist

### Game State Machine

- [ ] `advanceGame` transitions correctly across states
- [ ] `MustMintToday` / `NotTimeYet` rules enforced
- [ ] `rngLockedFlag` blocks burn and jackpots
- [ ] Start target: `nextPrizePool >= lastPrizePool`
- [ ] Level-100 resets `lastPrizePool` to `rewardPool`
- [ ] Game over drain after 365 days inactive

### Gamepieces

- [ ] ETH vs claimable vs combined payments
- [ ] MAP pricing (ETH and BURNIE) and queue processing
- [ ] Affiliate rakeback and upline rewards
- [ ] Mint streak tracking

### Coin (BURNIE)

- [ ] Coinflip stakes credited, wins minted lazily
- [ ] Burn paths (purchases, marketplace, decimator)
- [ ] Flip totals affect reward pool % (+/- 2%, max 98%)

### Jackpots

- [ ] Daily: current + next level (carryover)
- [ ] Extermination + carryover extermination
- [ ] Level jackpot finalizes pool transitions
- [ ] BAF every 10 levels
- [ ] Decimator window enforcement

### Bonds

- [ ] Maturity every 5 levels, lane selection
- [ ] Deposit splits correct
- [ ] Game-over drain resolves in order
- [ ] stETH/ETH fallback for payouts

### Vault

- [ ] Share issuance and claims
- [ ] Mint allowance and presale flows

### Affiliate

- [ ] Multi-level upline rewards
- [ ] Auto-MAP during purchase phase

### Trophies

- [ ] Transfers blocked, approvals revert
- [ ] Trait generation deterministic

---

## Testing Techniques

- **Time travel**: Hardhat for day/level boundaries
- **Mocks**: `MockVRFCoordinator`, `MockStETH`, harnesses
- **Property tests**: Invariants on bucket sums, state transitions
- **Determinism**: Isolate RNG inputs

---

## Dependencies to Validate

- Chainlink VRF availability and subscription
- Lido stETH integration
- `DegenerusAdmin` can rotate VRF after 3-day stall

---

## Reporting Issues

Include:
- Contract/function name
- Minimal reproduction steps
- If doc mismatch: cite doc section and code location

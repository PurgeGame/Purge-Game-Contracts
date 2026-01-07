# Degenerus

On-chain, high-variance NFT game on Ethereum.

## Core Contracts

| Contract | Purpose |
|----------|---------|
| `DegenerusGame.sol` | State machine, ETH/stETH buckets, RNG gating |
| `DegenerusGamepieces.sol` | ERC721 gamepiece NFTs, purchase flows |
| `DegenerusCoin.sol` | BURNIE token (6 decimals), coinflip, quests |
| `DegenerusQuests.sol` | Daily quest state and rewards |
| `DegenerusBonds.sol` | Bond maturities, time-locked payouts |
| `DegenerusJackpots.sol` | BAF + Decimator jackpots |
| `DegenerusAffiliate.sol` | Referrals, rakeback, uplines |
| `DegenerusVault.sol` | Vault shares (BURNIE, DGNRS, ETH/stETH) |
| `DegenerusTrophies.sol` | Non-transferable trophies |

## Quick Start

```bash
npm install
npm run compile
npm test
```

## Deploy Constants

This repo uses precomputed addresses in `contracts/DeployConstants.sol`. Generate it with:

```bash
node scripts/deploy/precompute-addresses.js --config scripts/deploy/deploy-config.sepolia.json
node scripts/deploy/precompute-addresses.js --config scripts/deploy/deploy-config.mainnet.json
```

Update `deployer` and `startNonce` in the config before generating. VRF settings are still wired post-deploy.

CLI alternative (no config file edit):

```bash
node scripts/deploy/build-constants.js --deployer 0xYOUR_DEPLOYER --startNonce 0 --network sepolia
```

All-in-one (generate constants, compile, deploy in order, verify addresses):

```bash
node scripts/deploy/deploy-and-verify.js --deployer 0xYOUR_DEPLOYER --startNonce 0 --network sepolia
```

## Documentation

- [Game & Economy Overview](GAME_AND_ECON_OVERVIEW.md) - Player-facing design
- [AI Teaching Guide](AI_TEACHING_GUIDE.md) - Code map and contract details
- [ETH Buckets & Solvency](ETH_BUCKETS_AND_SOLVENCY.md) - Accounting invariants
- [Quest System](QUEST_SYSTEM_OVERVIEW.md) - Quest mechanics reference
- [Agent Testing Guide](AGENTS.md) - Testing priorities and commands
- [Simple Summary](CORE_SYSTEMS_SUMMARY.md) - Plain-English basics

## Key Design Points

- **Non-upgradeable core**: Gameplay logic is immutable after deployment
- **No admin withdraw**: ETH only moves via game rules, not owner functions
- **VRF randomness**: Chainlink VRF for auditable outcomes
- **High variance**: Designed for risk-seeking players, not guaranteed returns

# Degenerus

On-chain, high-variance NFT game on Ethereum.

## Core Contracts

| Contract | Purpose |
|----------|---------|
| `DegenerusGame.sol` | State machine, ETH/stETH buckets, RNG gating |
| `DegenerusGamepieces.sol` | ERC721 gamepiece NFTs, purchase flows |
| `BurnieCoin.sol` | BURNIE token (18 decimals), coinflip, quests |
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

## Production Deployment

This repo uses **precalculated addresses + compile-time constants** for maximum security and gas efficiency.

### Quick Deploy (Recommended)

Production-ready script with comprehensive safety checks:

```bash
# Sepolia testnet
node scripts/deploy/deploy-production.js --network sepolia

# Mainnet
node scripts/deploy/deploy-production.js --network mainnet
```

**Features:**
- ✅ Pre-flight validation (balance, network, gas, nonce)
- ✅ Address verification after each deployment
- ✅ Cross-reference validation
- ✅ 5-second confirmation window
- ✅ Comprehensive error handling

**📖 Full Guide:** [docs/PRODUCTION_DEPLOY_GUIDE.md](docs/PRODUCTION_DEPLOY_GUIDE.md)

**🔒 Security Analysis:** [docs/SECURITY_AND_GAS_ANALYSIS.md](docs/SECURITY_AND_GAS_ANALYSIS.md)

### Alternative: Manual Deploy

Generate constants separately, then deploy:

```bash
# Generate DeployConstants.sol
node scripts/deploy/precompute-addresses.js --config scripts/deploy/deploy-config.sepolia.json

# Deploy all contracts
node scripts/deploy/deploy-and-verify.js --deployer 0xYOUR_DEPLOYER --startNonce 0 --network sepolia
```

**Note:** VRF configuration still requires post-deploy `DegenerusAdmin.wireVrf()` call.

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

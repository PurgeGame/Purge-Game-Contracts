# Purge Game — Solana Workspace

This directory houses the Anchor-based implementation of Purge Game and its supporting programs. The goal is to mirror the Solidity feature set while embracing Solana-native primitives.

## Structure
- `programs/purge_game`: Core game loop (minting, purge phases, jackpots, endgame).
- `programs/purge_coin`: SPL token utilities for PURGE coin (staking, coinflip, jackpots).
- `programs/purge_trophies`: Trophy accounting, map rewards, and end-level settlement helpers.
- `tests/`: Anchor Program Test suite (TypeScript) for integration coverage (`purge_game`, `purge_coin`, `purge_trophies`).
- `migrations/`: Anchor migration scripts (seed helpers + optional bootstrap flows).

## Getting Started
1. Install Anchor CLI (`cargo install --git https://github.com/coral-xyz/anchor anchor-cli`).
2. Install Node deps: `npm install` (or `yarn install`) to pull in Anchor TS tooling.
3. Build the programs: `anchor build`.
4. Run the TypeScript tests: `anchor test`.

### Optional: scripted seeding
- `DE` toggles in `migrations/deploy.ts` are controlled via env vars:
  - `DEPLOY_PURGE_GAME=true anchor run migrate` boots the core game PDAs.
  - `DEPLOY_PURGE_COIN=true` seeds the coin program (set `SEED_SAMPLE_BET=true` for demo bet data).
  - `DEPLOY_PURGE_TROPHIES=true` initializes trophy PDAs.
  - `SEED_MAP_MINT=true` (with `DEPLOY_PURGE_GAME`) enqueues a sample map reward entry for testing queue drains.

> **Note**: Program IDs in `Anchor.toml` are placeholders. Replace them with deterministic addresses derived from finalized keypairs before deployment.

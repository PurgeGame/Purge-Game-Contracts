# Solana Side Project — Execution Checklist

## Immediate Tasks
- [ ] Fill in real program IDs and commit deterministic keypairs for `purge_game`, `purge_coin`, and `purge_trophies`.
- [ ] Flesh out Anchor accounts/instruction arguments to cover minting, jackpots, coinflip, and trophy flows.
- [ ] Define SPL token mint/treasury accounts and wire CPI calls between programs.
- [ ] Model prize pools (SOL + PURGE) using escrow PDAs; decide on lamport vs token flows per jackpot type.
- [ ] Implement RNG provider integration (Switchboard VRF or alternative) and design request/fulfill handshake.

## Cross-Project Alignment
- [ ] Catalogue Solidity constants that must match Solana config (prices, thresholds, jackpot splits).
- [ ] Enumerate events emitted in Solidity and design equivalent Anchor events for analytics parity.
- [ ] Draft migration strategy for player balances and traits if running both chains in parallel.

## Tooling & Testing
- [ ] Add workspace-level npm scripts (`anchor-build`, `anchor-test`) and ensure CI coverage.
- [ ] Port representative Hardhat tests into Anchor Program Tests for behavior parity.
- [ ] Set up localnet fixtures (airdrop, mint seeding) to mirror existing mainnet assumptions.

## Frontend / Client Work
- [ ] Generate Anchor IDLs and integrate them into the web client (`@coral-xyz/anchor` + wallet adapters).
- [ ] Update minting UI to toggle between EVM and Solana networks with shared UX components.
- [ ] Design analytics endpoints to surface jackpots, purge stats, and leaderboards on Solana.

## Governance & Operations
- [ ] Decide on multisig/authority structure for program upgrades (e.g., Realms governance, multisig PDA).
- [ ] Plan audit timeline and budget once core logic is ported.
- [ ] Document deployment runbooks (devnet → testnet → mainnet-beta) including upgrade authority transfers.

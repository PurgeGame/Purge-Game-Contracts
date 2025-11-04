# Purge Game — Solana Port Game Plan

## 1. Vision & Objectives
- Deliver a feature-parity Purge Game on Solana using Anchor, re-implementing the current Solidity game/Affiliate mechanics with Solana-native patterns.
- Preserve the UX pillars (NFT mint/purge loop, jackpots, coinflip, trophies) while leveraging Solana performance (parallelism, lower fees).
- Keep the fork long-lived: document deltas from the EVM version and enable selective backports of upstream Solidity changes.

## 2. Current Solidity Blueprint (Parity Targets)
- `PurgeGame` orchestrates NFT minting, jackpots, purge phases, VRF hooks, and module delegatecalls.
- `Purgecoin` is a 6-decimal ERC20 with staking, jackpots, burn mechanics, and affiliate accounting.
- `PurgeGameNFT` provides the ERC721 asset, RNG gating, and metadata rendering link.
- `PurgeGameTrophies` tracks trophies, handles end-level processing, and integrates map payouts.
- `PurgeGameJackpotModule` and `PurgeGameEndgameModule` extend the core via `delegatecall` to handle jackpot distribution and slow-path settlement.

## 3. Solana Architecture Overview
- **Programs**
  - `purge_game`: Anchor program hosting the core state machine, minting, purge phases, RNG lock, and jackpot/endgame entry points.
  - `purge_coin`: SPL Token extensions in Rust (mint authority PDA + CPI helpers) covering staking, burns, coinflip jackpots, and affiliate payouts.
  - `purge_trophies`: Program managing trophy minting/state and map payout logic.
  - Optional micro-programs for modular jackpots/endgame if state layout requires isolation; otherwise keep as Anchor modules within `purge_game`.
- **Off-chain Services**
  - Keeper/daemon for scheduled instructions (jackpot draws, endgame ticks).
  - VRF provider integration (Switchboard/Chainlink Functions).
  - Indexer + frontend API to aggregate dynamic traits, leaderboards, and randomness history.

## 4. State Mapping (EVM → Solana)
| Solidity Storage | Solana Mapping |
| --- | --- |
| `PurgeGame` storage slots (levels, pools, RNG words, counters) | Single PDA account (e.g. `GameState`) with serialized struct; large arrays (trait tickets) split across paginated PDA accounts. |
| `claimableWinnings`, `traitPurgeTicket`, `mintPacked_` mappings | Dedicated per-player PDAs or account seeds derived from player + level; consider bitmap compression for ticket arrays. |
| `pendingMapMints` dynamic array | Queue PDA storing pending mint structs; processed via batched instructions. |
| `Purgecoin` balances/allowances | SPL Token mint using Token-2022 features; allowances via CPI or custom PDA-based approvals. |
| Staking lanes (`Stake` data pack) | PDA storing per-player stake lanes with Borsh-serialized structs; use fixed-size arrays for 3 lanes. |
| `PurgeGameNFT` ERC721 | Metaplex Core (token metadata program) or compressed NFTs; integrate custom mint authority logic inside `purge_game`. |
| Delegatecall modules | Anchor instruction handlers; share state via context accounts to mimic module writes. |

## 5. Instruction Surface (Initial Cut)
1. `initialize_game` — bootstrap PDAs, configure authorities, seed trait counts.
2. `mint_nft` — mint purge NFT + update pools; enforce price thresholds (SOL + SPL hybrid payments).
3. `purge_tokens` — handle purge event, record tickets, adjust jackpots.
4. `advance_level` — transition phases, snapshot prize pools, queue endgame tasks.
5. `process_jackpot_daily` / `process_jackpot_map` — run jackpot logic, credit winners via Coin CPI.
6. `finalize_endgame_step` — iterate slow-path payouts with capping similar to `DEFAULT_PAYOUTS_PER_TX`.
7. `coinflip_place_bet`, `coinflip_resolve` — staking/bet flows in `purge_coin`.
8. `affiliate_register`, `affiliate_reward` — track affiliate codes and payouts.
9. `trophy_award`, `trophy_stake_sample` — replicate trophy module functions.
10. Administrative instructions for price updates, trait seed rebuild, RNG locking.

## 5.1 Account Schema (Draft)
| Account | Seeds | Owner | Purpose |
| --- | --- | --- | --- |
| `GameState` | `["game-state"]` | `purge_game` | Global config, pools, RNG state, counters. |
| `GameTreasury` | `["game-treasury"]` | `purge_game` | SOL escrow for mint proceeds + jackpots. |
| `PurgeMintAuthority` | `["purge-mint-authority"]` | `purge_game` | PDA acting as signer when minting NFTs or SPL tokens. |
| `PlayerState` | `["player", player]` | `purge_game` | Tracks per-player mint data, streaks, purge tickets pointer. |
| `RngRequestState` | `["rng-request"]` | `purge_game` | Persists VRF request metadata awaiting fulfillment. |
| `TraitTicketPage` | `["ticket", level, trait, page]` | `purge_game` | Stores participant pubkeys for trait jackpots in paginated fashion. |
| `PendingMapMintQueue` | `["map-mint-queue"]` | `purge_game` | FIFO queue (ring buffer) for map rewards awaiting mint. |
| `CoinState` | `["purge-coin"]` | `purge_coin` | Core PURGE token config (mint, thresholds, jackpots). |
| `CoinTreasury` | `["coin-treasury"]` | Token Program | SPL token account holding jackpot balances. |
| `BountyVault` | `["bounty"]` | Token Program | PURGE bounty accruals for biggest flips. |
| `AffiliateState` | `["affiliate", code]` | `purge_coin` | Per-code stats: earned, total referrals, streak data. |
| `StakeState` | `["stake", player]` | `purge_coin` | Stores up to 3 staking lanes mirroring Solidity struct. |
| `TrophyState` | `["trophies"]` | `purge_trophies` | Config (basis points, game authority, CPI targets). |
| `TrophyVault` | `["trophy-vault"]` | `purge_trophies` | Aggregates SOL rewards before distribution. |
| `MapRewardQueue` | `["map-reward-queue"]` | `purge_trophies` | Buffered map payouts awaiting settlement. |
| `StakeSampleState` | `["stake-sample"]` | `purge_trophies` | Tracks RNG seed for trophy staking draws. |

## 5.2 Instruction Flow (Happy Path)
1. **Mint NFT**
   - Accounts: `GameState`, `GameTreasury`, `PlayerState`, payer accounts, Mint/Metadata PDAs.
   - Steps: verify phase, collect payment (SOL/SPL), mint NFT via Metaplex CPI, append ticket entry to `TraitTicketPage`, update streak counters.
2. **Purge Tokens**
   - Accounts: `GameState`, `PlayerState`, relevant `TraitTicketPage` PDAs, NFT token accounts.
   - Steps: burn NFT, update trait counters, queue jackpots, allocate share to `GameTreasury` / `CoinTreasury`.
3. **Advance Level**
   - Accounts: `GameState`, `GameTreasury`, optional `PendingMapMintQueue`.
   - Steps: snapshot `prize_pool` → `level_prize_pool`, roll `carryover`, toggle `phase`, emit Anchor event.
4. **Process Jackpot (Daily / Map)**
   - Accounts: `GameState`, `GameTreasury`, `CoinState`, `CoinTreasury`, `TraitTicketPage` slices, winners' token accounts.
   - Steps: derive entropy, draw winners, send SOL/PURGE payouts, credit leftover coin to bounty.
5. **Finalize Endgame Step**
   - Accounts: `GameState`, payout recipients (batched), `CoinState`, `TrophyState`.
   - Steps: pay participants in chunks (`DEFAULT_PAYOUTS_PER_TX` analogue), settle exterminator bonus, call `purge_coin`/`purge_trophies` CPIs.
6. **Coinflip Resolve**
   - Accounts: `CoinState`, bettor stake PDA, `CoinTreasury`, external RNG fulfillment account.
   - Steps: mark bet settled, transfer PURGE amounts, update jackpots/bounty as necessary.
7. **Map Mint Queue Management**
   - Accounts: `GameState`, `PendingMapMintQueue`, authority signer.
   - Steps: enqueue map rewards during purge/advance flows; cron workers dequeue in batches to feed downstream mint/trophy logic.
8. **Trait Ticket Pagination**
   - Accounts: `GameState`, `TraitTicketPage`, `player` reference, authority signer.
   - Steps: initialize paged ticket PDAs, append player entries, clear pages post-distribution.

## 6. Key Adaptations
- **Account Model**: Replace implicit storage writes with explicit account passing; design account graphs per instruction to avoid exceeding compute/byte limits.
- **Randomness**: Swap Chainlink VRF for Switchboard VRF or on-chain randomness oracles; ensure asynchronous pattern (request + fulfill instruction) matches Solana.
- **Timing/Keepers**: Use cron-like off-chain service to trigger `process_jackpot_*` and `finalize_endgame_step`.
- **Monetary Flows**: For SOL prizes, hold lamports in PDA escrow accounts; for PURGE token prizes, rely on CPI to Token Program.
- **Serialization**: Use Borsh for Anchor accounts; design structs to stay under 10kB where possible (e.g., chunk trait tickets).
- **Front-end**: Update client SDK to Anchor-generated IDL; integrate with @solana/web3.js and @project-serum/anchor for interactions.

## 7. Tooling & Repo Layout
```
solana-port/
  Anchor.toml
  programs/
    purge_game/
    purge_coin/
    purge_trophies/
  tests/
    purge_game.ts
    purge_coin.ts
    purge_trophies.ts
  migrations/
  README.md
```
- Maintain `contracts/` (Solidity) and `solana-port/` side-by-side for reference.
- Add workspace scripts (`yarn anchor build`, `yarn anchor test`) and linting (rustfmt, clippy).

## 8. Multi-Chain Outlook
- After Solana parity, evaluate Move-based targets (Aptos/Sui) by reusing design doc structure.
- For EVM L2 deployments, continue using Solidity codebase with chain-specific configs; share gameplay constants via centralized config file to minimize drift.

## 9. Phase Plan & Milestones
1. **Foundations (Week 0-2)**: Anchor workspace scaffolding, PDA schema, mint/airdrop skeleton, docs.
2. **Core Loop (Week 2-6)**: NFT mint/purge, prize pool accounting, RNG gating, level transitions.
3. **Economy (Week 6-10)**: Purgecoin staking/burning, jackpots, affiliate payouts, SPL token integration.
4. **Endgame + Trophies (Week 10-14)**: Endgame settlement loops, trophy program, map payouts.
5. **Testing & Audit (Week 14-18)**: Program test coverage, fuzzing, security review prep.
6. **Launch Prep (Week 18+)**: Devnet dry runs, mainnet-beta deployment, front-end integration.

## 10. Open Questions / Follow-Ups
- Final decision on NFT standard (Metaplex Core vs. compressed NFTs) and rendering approach.
- Choice of VRF provider and service-level guarantees.
- Whether to maintain delegatecall-style module split via multiple programs or consolidated instruction set.
- Compliance requirements for affiliate payouts when handling SOL/SPL rewards.

## 11. Module Deep-Dives
### Purge Game Program
- **State Highlights**
  - `GameState`: tracks pricing, level/phase, jackpots, RNG words, carry-overs, and pending queues.
  - `TraitTicketPage`: paginated winners list for traits; chunked at 64 seats/page to fit Solana size limits.
  - `PendingMapMintQueue`: ring buffer for map rewards; off-chain keepers drain queue and mint NFTs/trophies.
- **Instruction Hooks**
  - `mint_nft`: collects SOL and/or PURGE via CPI, mints NFT, records trait ticket, updates streak counters.
  - `purge_tokens`: burns NFTs, updates trait counts, increments prize pools, enqueues map rewards, toggles early purge metrics.
  - `add_trait_ticket` / `clear_trait_ticket_page`: manage paginated participant lists per trait, keeping accounts under 10kB.
  - `process_jackpot_*`: uses RNG word (or on-chain entropy) to draw winners; interacts with PurgeCoin CPI for payouts and Bounty updates.
  - `finalize_endgame_step`: throttle payouts to stay within compute budget, handles exterminator reward and coinflip settlement gating.
  - `request_rng` / `fulfill_rng`: request/response pair for VRF provider; ensures asynchronous randomness pipeline.

### Purge Coin Program
- **State Highlights**
  - `PurgeCoinState`: central config (min bet/burn, house edge, jackpot pools).
  - `StakeState`: 3-lane staking structure mirroring Solidity bitpacking but stored as explicit structs.
  - `AffiliateState`: per-code aggregator capturing earnings, pending claims, level sync.
  - `BetAccount`: persistent bet record keyed by deterministic `bet_id` so settle instructions can rehydrate context.
- **Instruction Hooks**
  - `place_bet`: verifies thresholds, locks PURGE in treasury, updates stake lane data.
  - `settle_bet`: invoked by PurgeGame or keeper, writes result, pays out (or moves losses to jackpot pool).
  - `record_burn`: burns PURGE through CPI, increments total burned for BAF/decimator logic.
  - `award_affiliate`: credits affiliates, optionally sweeps pending claims into SOL/SPL accounts.
  - `claim_affiliate`: admin/keeper instruction to release pending affiliate balances.
  - `sync_jackpot`: entrypoint for PurgeGame to pipe SOL/PURGE amounts into coin-side pools.

### Purge Trophies Program
- **State Highlights**
  - `TrophyState`: holds authority (game owner), map reward parameters, CPI targets.
  - `MapRewardQueue`: buffered map payouts, drained during end-level settlement or dedicated cron.
  - `StakeSampleState`: persisted randomness seed for sampling staked trophies (for future expansions).
- **Instruction Hooks**
  - `award_trophy`: minted by game authority; increments vault with deferred lamports and stores metadata.
  - `process_end_level`: drains queue, pays map rewards, coordinates with PurgeCoin for affiliate payouts and extrinsics.
  - `enqueue_map_reward` / `pop_map_reward`: game-managed queue operations to prevent compute spikes.

## 12. Integration Timeline (Detailed)
| Phase | Duration | Key Outputs | Dependencies |
| --- | --- | --- | --- |
| Foundations | Weeks 0-2 | PDA scaffolding, pricing config, documentation | Anchor workspace, base programs compiling |
| Core Loop | Weeks 2-6 | `mint_nft`, `purge_tokens`, `advance_level` baseline, basic RNG request/fulfill | VRF design, NFT mint strategy |
| Economy | Weeks 6-10 | PurgeCoin staking/burning flows, jackpot pools, affiliate ledger | SPL token CPI wiring, treasury accounts |
| Endgame/Trophies | Weeks 10-14 | End-level settlement, map rewards queue, trophy minting MVP | Game + coin blocks functioning |
| QA & Security | Weeks 14-18 | Program tests, devnet soak, audit-ready artifact | Off-chain keepers, VRF harness |
| Launch Prep | 18+ | Devnet rehearsal, mainnet-beta deployment, front-end parity | Audit sign-off, program upgrades |

## 13. Off-Chain Components
- **Keepers/Workers**
  - Jackpot scheduler: triggers `process_jackpot_daily` and `process_jackpot_map` based on blocktime heuristics.
  - Endgame finisher: repeatedly executes `finalize_endgame_step` until level distribution completes.
  - Map reward drainer: consumes `MapRewardQueue` in small batches.
- **Services**
  - VRF proxy: orchestrates Switchboard or custom randomness provider, enqueues `fulfill_rng`.
  - Indexer: aggregates events into analytics DB (jackpot winners, purge counts, affiliate streaks).
  - Frontend API: exposes Solana data to existing UI, bridging EVM and Solana stats.

## 14. Risk Register
- **State Bloat**: trait ticket arrays and map queues risk exceeding account size limits -> mitigated via pagination and chunked queues.
- **Compute Limits**: jackpot/endgame loops must stay under 200k CU; enforce batching and partial progress returns.
- **Randomness Reliability**: VRF provider outages stall game progression -> maintain fallback entropy and manual override instructions.
- **Cross-Program Invocations**: CPI depth and account sizes require careful design; use lightweight helper programs or pre-serialized contexts.
- **Economic Parity**: differences in SPL vs ERC20 semantics may introduce rounding/precision edge cases; design tests mirroring Solidity scenarios.

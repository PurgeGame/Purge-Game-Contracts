// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*╔══════════════════════════════════════════════════════════════════════════════╗
  ║                                                                              ║
  ║                        DEGENERUS JACKPOTS CONTRACT                           ║
  ║                                                                              ║
  ║  Standalone contract managing two distinct jackpot systems:                  ║
  ║  1. BAF (Big Ass Flip) - Rewards top coinflip bettors per level              ║
  ║  2. Decimator - Pro-rata distribution to burn participants                   ║
  ║                                                                              ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                           ARCHITECTURE OVERVIEW                              ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                                                                              ║
  ║  ┌─────────────────────────────────────────────────────────────────────────┐ ║
  ║  │                       BAF JACKPOT FLOW                                  │ ║
  ║  │                                                                         │ ║
  ║  │  Coin Contract                                                          │ ║
  ║  │       │                                                                 │ ║
  ║  │       ▼ recordBafFlip(player, lvl, amount)                              │ ║
  ║  │  ┌─────────────────┐                                                    │ ║
  ║  │  │ BAF Leaderboard │ ← Top 4 bettors tracked per level                  │ ║
  ║  │  │  (bafTop[lvl])  │   Weighted by player bonus multiplier              │ ║
  ║  │  └────────┬────────┘                                                    │ ║
  ║  │           │                                                             │ ║
  ║  │           ▼ Level ends → runBafJackpot()                                │ ║
  ║  │  ┌─────────────────────────────────────────────────────────────────┐    │ ║
  ║  │  │                    PRIZE DISTRIBUTION (100%)                    │    │ ║
  ║  │  ├─────────────────────────────────────────────────────────────────┤    │ ║
  ║  │  │ 10% → Top BAF bettor for level                                  │    │ ║
  ║  │  │ 10% → Top coinflip bettor from last 24h window                  │    │ ║
  ║  │  │  5% → Random pick: 3rd or 4th BAF leaderboard slot              │    │ ║
  ║  │  │ 10% → Exterminator draw (from prior 20 levels, 5/3/2/0%)        │    │ ║
  ║  │  │ 10% → Affiliate draw (top referrers, prior 20 levels)           │    │ ║
  ║  │  │ 10% → Retro tops (sample recent levels, 5/3/2/0%)               │    │ ║
  ║  │  │ 20% → Scatter 1st place (50 rounds × 4 trait tickets)           │    │ ║
  ║  │  │ 25% → Scatter 2nd place (50 rounds × 4 trait tickets)           │    │ ║
  ║  │  └─────────────────────────────────────────────────────────────────┘    │ ║
  ║  │                                                                         │ ║
  ║  │  ELIGIBILITY: coinflipAmountLastDay >= 5000 BURNIE                      │ ║
  ║  │               AND ethMintStreakCount >= 3                               │ ║
  ║  └─────────────────────────────────────────────────────────────────────────┘ ║
  ║                                                                              ║
  ║  ┌─────────────────────────────────────────────────────────────────────────┐ ║
  ║  │                     DECIMATOR JACKPOT FLOW                              │ ║
  ║  │                                                                         │ ║
  ║  │  Coin Contract                                                          │ ║
  ║  │       │                                                                 │ ║
  ║  │       ▼ recordDecBurn(player, lvl, bucket, baseAmount, multBps)         │ ║
  ║  │  ┌─────────────────────────────────────────────────────────────────┐    │ ║
  ║  │  │                    BUCKET SYSTEM                                │    │ ║
  ║  │  │                                                                 │    │ ║
  ║  │  │  bucket (denom): 2..10 (player's chosen denominator)            │    │ ║
  ║  │  │  subBucket: 0..(denom-1), derived from hash(player,lvl,bucket)  │    │ ║
  ║  │  │                                                                 │    │ ║
  ║  │  │  decBucketBurnTotal[lvl][denom][sub] += delta                   │    │ ║
  ║  │  │  decBurn[lvl][player] = {burn, bucket, subBucket, claimed}      │    │ ║
  ║  │  └─────────────────────────────────────────────────────────────────┘    │ ║
  ║  │           │                                                             │ ║
  ║  │           ▼ Level ends → runDecimatorJackpot()                          │ ║
  ║  │  ┌─────────────────────────────────────────────────────────────────┐    │ ║
  ║  │  │  For each denom 2..10:                                          │    │ ║
  ║  │  │    winningSub = hash(rngWord, denom) % denom                    │    │ ║
  ║  │  │    totalBurn += decBucketBurnTotal[lvl][denom][winningSub]      │    │ ║
  ║  │  │                                                                 │    │ ║
  ║  │  │  Snapshot: poolWei, totalBurn, active=true                      │    │ ║
  ║  │  │  (actual distribution deferred to claims)                       │    │ ║
  ║  │  └─────────────────────────────────────────────────────────────────┘    │ ║
  ║  │           │                                                             │ ║
  ║  │           ▼ claimDecimatorJackpot(lvl)                                  │ ║
  ║  │  ┌─────────────────────────────────────────────────────────────────┐    │ ║
  ║  │  │  If player's subBucket == winningSub for their denom:           │    │ ║
  ║  │  │    payout = (poolWei × playerBurn) / totalBurn                  │    │ ║
  ║  │  │                                                                 │    │ ║
  ║  │  │  Pro-rata share based on burn contribution                      │    │ ║
  ║  │  └─────────────────────────────────────────────────────────────────┘    │ ║
  ║  └─────────────────────────────────────────────────────────────────────────┘ ║
  ║                                                                              ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                         SECURITY CONSIDERATIONS                              ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                                                                              ║
  ║  1. ACCESS CONTROL:                                                          ║
  ║     • onlyCoin: recordBafFlip, recordDecBurn (hooks from coin contract)      ║
  ║     • onlyGame: runBafJackpot, runDecimatorJackpot, consumeDecClaim          ║
  ║     • bondsAdmin: one-time wire() function                                   ║
  ║                                                                              ║
  ║  2. SET-ONCE WIRING:                                                         ║
  ║     • coin, game, affiliate addresses locked after first set                 ║
  ║     • Prevents malicious contract replacement                                ║
  ║                                                                              ║
  ║  3. RNG FAIRNESS:                                                            ║
  ║     • VRF-derived randomness from game contract                              ║
  ║     • Entropy chained via keccak256 for multiple draws                       ║
  ║     • Subbucket selection deterministic once RNG committed                   ║
  ║                                                                              ║
  ║  4. DOUBLE-CLAIM PREVENTION:                                                 ║
  ║     • DecEntry.claimed flag prevents re-claiming                             ║
  ║     • Checked before payout calculation                                      ║
  ║                                                                              ║
  ║  5. ELIGIBILITY GATES:                                                       ║
  ║     • BAF requires 5000+ BURNIE coinflip in last 24h                         ║
  ║     • BAF requires 3+ ETH mint streak                                        ║
  ║     • Prevents sybil/dormant account exploitation                            ║
  ║                                                                              ║
  ║  6. OVERFLOW PROTECTION:                                                     ║
  ║     • Solidity 0.8+ automatic checks                                         ║
  ║     • uint192 cap on burn amounts (explicit saturation)                      ║
  ║     • Score capped at uint96.max for leaderboard                             ║
  ║                                                                              ║
  ║  7. UNFILLED PRIZE HANDLING:                                                 ║
  ║     • Unawarded shares returned via returnAmountWei                          ║
  ║     • No funds locked if no eligible winners                                 ║
  ║                                                                              ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                           TRUST ASSUMPTIONS                                  ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                                                                              ║
  ║  TRUSTED CONTRACTS (set-once after construction):                            ║
  ║  • coin:          DegenerusCoin (calls recordBafFlip, recordDecBurn)         ║
  ║  • degenerusGame: Core game (calls runBafJackpot, runDecimatorJackpot)       ║
  ║  • affiliate:     Affiliate program (queries for top referrers)              ║
  ║  • bonds:         Bonds contract (immutable from constructor)                ║
  ║  • bondsAdmin:    Admin for one-time wiring (immutable)                      ║
  ║                                                                              ║
  ╚══════════════════════════════════════════════════════════════════════════════╝*/

import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";
import {IDegenerusAffiliate} from "./interfaces/IDegenerusAffiliate.sol";
import {IDegenerusJackpots} from "./interfaces/IDegenerusJackpots.sol";

// ===========================================================================
// External Interfaces
// ===========================================================================

/// @notice View interface for coin contract jackpot-related queries.
/// @dev Used to retrieve coinflip statistics for eligibility and leaderboards.
interface IDegenerusCoinJackpotView {
    /// @notice Get player's coinflip amount in the last 24-hour window.
    /// @param player Address to query.
    /// @return Total coinflip amount in last day.
    function coinflipAmountLastDay(address player) external view returns (uint256);

    /// @notice Get top coinflip bettor for a specific level.
    /// @param lvl Level number to query.
    /// @return player Top bettor address.
    /// @return score Bettor's score.
    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score);

    /// @notice Get top coinflip bettor from the last 24-hour window.
    /// @return player Top bettor address.
    /// @return score Bettor's score.
    function coinflipTopLastDay() external view returns (address player, uint96 score);
}

// ===========================================================================
// Contract
// ===========================================================================

/**
 * @title DegenerusJackpots
 * @author Burnie Degenerus
 * @notice Standalone contract managing BAF and Decimator jackpot systems.
 * @dev DegenerusCoin forwards flips/burns into this contract; game calls to resolve jackpots.
 *      - BAF: Leaderboard-based distribution to top coinflip bettors
 *      - Decimator: Pro-rata bucket-based distribution to burn participants
 * @custom:security-contact burnie@degener.us
 */
contract DegenerusJackpots is IDegenerusJackpots {
    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                              ERRORS                                  ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Custom errors for gas-efficient reverts. Each error maps to a       ║
      ║  specific failure condition in jackpot operations.                   ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Decimator claim round not active for this level.
    error DecClaimInactive();

    /// @notice Player already claimed Decimator jackpot for this level.
    error DecAlreadyClaimed();

    /// @notice Player's subbucket did not win the Decimator draw.
    error DecNotWinner();

    /// @notice Attempted to change an already-set address in wire().
    error AlreadyWired();

    /// @notice Caller is not the bonds contract.
    error OnlyBonds();

    /// @notice Caller is not the bondsAdmin.
    error OnlyAdmin();

    /// @notice Caller is not the coin contract.
    error OnlyCoin();

    /// @notice Caller is not the game contract.
    error OnlyGame();

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                              STRUCTS                                 ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Data structures for BAF leaderboard and Decimator burn tracking.    ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Leaderboard entry for BAF coinflip stakes.
    /// @dev Packed into single slot: address (160) + score (96) = 256 bits.
    struct PlayerScore {
        address player; // Player address
        uint96 score;   // Weighted coinflip stake (whole tokens, capped at uint96.max)
    }

    /// @notice Per-player BAF totals within an active level.
    /// @dev Resets when player participates in a new level.
    struct BafEntry {
        uint256 total; // Total weighted flips this level (raw units, not capped)
        uint24 level;  // Level number this entry belongs to
    }

    /// @notice Per-player Decimator burn tracking for a specific level.
    /// @dev Packed for gas efficiency: burn (192) + bucket (8) + subBucket (8) + claimed (8) = 216 bits.
    ///      - bucket: Player's chosen denominator (2-10)
    ///      - subBucket: Deterministic assignment 0..(bucket-1) from hash
    ///      - claimed: 0 = unclaimed, 1 = claimed
    struct DecEntry {
        uint192 burn;      // Total BURNIE burned by player this level (capped at uint192.max)
        uint8 bucket;      // Player's denominator choice (locked at first burn)
        uint8 subBucket;   // Deterministic subbucket from hash(player, lvl, bucket)
        uint8 claimed;     // Claim flag (0 or 1)
    }

    /// @notice Snapshot of a Decimator claim round for a level.
    /// @dev Created when runDecimatorJackpot is called.
    ///      - poolWei: ETH prize pool for this level
    ///      - totalBurn: Sum of burns in winning subbuckets across all denoms
    ///      - active: True once snapshotted, enables claims
    struct DecClaimRound {
        uint256 poolWei;   // ETH prize pool available for claims
        uint248 totalBurn; // Total qualifying burn (denominator for pro-rata)
        bool active;       // True = claims enabled
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                        HELPER FUNCTIONS                              ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Internal pure/view helpers used by jackpot logic.                   ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Sample a recent level (1-20 levels back) for retro prize selection.
    ///      Biases retro rewards toward fresh play by limiting lookback window.
    /// @param lvl Current level number.
    /// @param entropy Random entropy for offset selection.
    /// @return Recent level number (0 if lvl is too small).
    function _recentLevel(uint24 lvl, uint256 entropy) private pure returns (uint24) {
        uint256 offset = (entropy % 20) + 1; // 1..20
        if (lvl > offset) {
            return lvl - uint24(offset);
        }
        return 0;
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                       IMMUTABLE & WIRED STATE                        ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Trusted contract addresses. bonds/bondsAdmin are immutable from     ║
      ║  construction; coin/game/affiliate are set-once via wire().          ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Coin contract for coinflip stats queries.
    /// @dev Set once via wire(). Used for eligibility checks and leaderboards.
    IDegenerusCoinJackpotView public coin;

    /// @notice Core game contract for jackpot resolution and player queries.
    /// @dev Set once via wire(). Trusted caller for runBafJackpot/runDecimatorJackpot.
    IDegenerusGame public degenerusGame;

    /// @notice Affiliate program contract for referrer queries.
    /// @dev Set once via wire(). Used for affiliate draw in BAF.
    address private affiliate;

    /// @notice Admin address for one-time wire() function.
    /// @dev Immutable from construction. Cannot be changed.
    address public immutable bondsAdmin;

    /// @notice Bonds contract address.
    /// @dev Immutable from construction. Not currently used but reserved.
    address public immutable bonds;

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                            CONSTANTS                                 ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Fixed values for prize calculations and bucket configuration.       ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev BURNIE token base unit (6 decimals = 1e6).
    uint256 private constant MILLION = 1e6;

    /// @dev BURNIE unit per ETH mint (1000 BURNIE).
    uint256 private constant PRICE_COIN_UNIT = 1000 * MILLION;

    /// @dev Basis points denominator (10000 = 100%).
    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Multiplier cap for Decimator burns (200 mints worth).
    uint256 private constant DECIMATOR_MULTIPLIER_CAP = 200 * PRICE_COIN_UNIT;

    /// @dev Bit offset in bondMask for scatter winner flags.
    ///      First 128 bits for direct winners, upper bits for scatter.
    uint256 private constant BAF_SCATTER_MASK_OFFSET = 128;

    /// @dev Number of scatter winners receiving special bond/map treatment.
    ///      Last 40 scatter winners get bondMask flags set.
    uint8 private constant BAF_SCATTER_BOND_WINNERS = 40;

    /// @dev Maximum denominator for Decimator buckets (2-10 inclusive).
    uint8 private constant DECIMATOR_MAX_DENOM = 10;

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                         BAF STATE STORAGE                            ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Per-player BAF totals and top-4 leaderboard per level.              ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Per-player weighted coinflip totals for current level.
    ///      Resets when player participates in new level.
    mapping(address => BafEntry) internal bafTotals;

    /// @dev Top-4 coinflip bettors for BAF per level (sorted by score descending).
    mapping(uint24 => PlayerScore[4]) internal bafTop;

    /// @dev Current length of bafTop array for each level (0-4).
    mapping(uint24 => uint8) internal bafTopLen;

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                       DECIMATOR STATE STORAGE                        ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Per-level burn tracking with bucket/subbucket system for claims.    ║
      ║                                                                      ║
      ║  BUCKET SYSTEM:                                                      ║
      ║  - Player selects denominator (2-10) at first burn                   ║
      ║  - Subbucket (0..denom-1) assigned deterministically from hash       ║
      ║  - At resolution, one winning subbucket per denom is selected        ║
      ║  - Winners get pro-rata share of pool based on burn contribution     ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Per-level, per-player Decimator burn tracking.
    ///      Earlier levels remain claimable after player participates in later ones.
    mapping(uint24 => mapping(address => DecEntry)) internal decBurn;

    /// @dev Aggregated burn totals per level/denom/subbucket.
    ///      decBucketBurnTotal[lvl][denom][sub] = total burn in that subbucket.
    ///      Array sized [11][11] to allow direct indexing (denom 0-10, sub 0-10).
    mapping(uint24 => uint256[11][11]) internal decBucketBurnTotal;

    /// @dev Active Decimator claim round by level.
    ///      Snapshotted when runDecimatorJackpot is called.
    mapping(uint24 => DecClaimRound) internal decClaimRound;

    /// @dev Packed winning subbucket per denominator for a level.
    ///      4 bits each for denom 2..10 (36 bits total, fits in uint64).
    ///      Layout: bits 0-3 = denom 2, bits 4-7 = denom 3, etc.
    mapping(uint24 => uint64) internal decBucketOffsetPacked;

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                      MODIFIERS & ACCESS CONTROL                      ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Access control for trusted callers only.                            ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Restricts function to coin contract only.
    ///      Used for recordBafFlip and recordDecBurn hooks.
    modifier onlyCoin() {
        if (msg.sender != address(coin)) revert OnlyCoin();
        _;
    }

    /// @dev Restricts function to game contract only.
    ///      Used for runBafJackpot, runDecimatorJackpot, consumeDecClaim.
    modifier onlyGame() {
        if (msg.sender != address(degenerusGame)) revert OnlyGame();
        _;
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                           CONSTRUCTOR                                ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Initialize immutable bonds/admin addresses.                         ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Initialize the jackpots contract with bonds and admin addresses.
    /// @dev Both addresses must be non-zero. These are immutable after construction.
    /// @param bonds_ Bonds contract address.
    /// @param bondsAdmin_ Admin address for one-time wire() call.
    constructor(address bonds_, address bondsAdmin_) {
        if (bonds_ == address(0) || bondsAdmin_ == address(0)) revert OnlyBonds();
        bonds = bonds_;
        bondsAdmin = bondsAdmin_;
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                         WIRING FUNCTIONS                             ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  One-time setup for coin/game/affiliate addresses.                   ║
      ║  Uses set-once pattern: addresses cannot be changed after first set. ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Wire trusted contract addresses (one-time setup).
    /// @dev Access: bondsAdmin only. Uses set-once pattern for each address.
    ///      SECURITY: Prevents malicious contract replacement after initial wiring.
    /// @param addresses Array of addresses: [coin, game, affiliate].
    function wire(address[] calldata addresses) external override {
        address admin = bondsAdmin;
        if (msg.sender != admin) revert OnlyAdmin();

        _setCoin(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setAffiliate(addresses.length > 2 ? addresses[2] : address(0));
    }

    /// @dev Internal set-once setter for coin address.
    ///      Reverts if attempting to change after initial set.
    function _setCoin(address coinAddr) private {
        if (coinAddr == address(0)) return;
        address current = address(coin);
        if (current == address(0)) {
            coin = IDegenerusCoinJackpotView(coinAddr);
        } else if (coinAddr != current) {
            revert AlreadyWired();
        }
    }

    /// @dev Internal set-once setter for game address.
    ///      Reverts if attempting to change after initial set.
    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(degenerusGame);
        if (current == address(0)) {
            degenerusGame = IDegenerusGame(gameAddr);
        } else if (gameAddr != current) {
            revert AlreadyWired();
        }
    }

    /// @dev Internal set-once setter for affiliate address.
    ///      Reverts if attempting to change after initial set.
    function _setAffiliate(address affiliateAddr) private {
        if (affiliateAddr == address(0)) return;
        address current = affiliate;
        if (current == address(0)) {
            affiliate = affiliateAddr;
        } else if (affiliateAddr != current) {
            revert AlreadyWired();
        }
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                      COIN CONTRACT HOOKS                             ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Called by DegenerusCoin to record coinflip/burn activity.           ║
      ║  These hooks build state used by jackpot resolution.                 ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Record a coinflip stake for BAF leaderboard tracking.
    /// @dev Access: coin contract only. Called on every manual coinflip.
    ///      - Resets player's total if they're participating in a new level
    ///      - Weights the flip amount by player's bonus multiplier (in bps)
    ///      - Updates top-4 leaderboard for the level
    /// @param player Address of the player.
    /// @param lvl Current game level.
    /// @param amount Raw flip amount (before weighting).
    function recordBafFlip(address player, uint24 lvl, uint256 amount) external override onlyCoin {
        BafEntry storage entry = bafTotals[player];

        // Reset total if player is participating in a new level
        if (entry.level != lvl) {
            entry.level = lvl;
            entry.total = 0;
        }

        // Weight the flip by player's bonus multiplier (10000 bps = 1x)
        uint256 multBps = degenerusGame.playerBonusMultiplier(player);
        uint256 weighted = (amount * multBps) / 10000;

        // Accumulate weighted total (unchecked safe: reasonable values won't overflow uint256)
        unchecked {
            entry.total += weighted;
        }

        // Update top-4 leaderboard with new total
        _updateBafTop(lvl, player, entry.total);
    }

    /// @notice Record a Decimator burn for jackpot eligibility.
    /// @dev Access: coin contract only. Called on every Decimator burn.
    ///      - First burn locks player's bucket (denominator) choice
    ///      - Subbucket is deterministically assigned from hash
    ///      - Subsequent burns in same level accumulate in locked bucket
    ///      - Burn amount capped at uint192.max (saturating)
    /// @param player Address of the player.
    /// @param lvl Current game level.
    /// @param bucket Player's chosen denominator (2-10).
    /// @param baseAmount Burn amount before multiplier (includes quest rewards).
    /// @param multBps Player bonus multiplier in bps.
    /// @return bucketUsed The bucket actually used (may differ if already locked).
    function recordDecBurn(
        address player,
        uint24 lvl,
        uint8 bucket,
        uint256 baseAmount,
        uint256 multBps
    ) external override onlyCoin returns (uint8 bucketUsed) {
        DecEntry storage e = decBurn[lvl][player];
        uint192 prevBurn = e.burn;

        // First burn this level: lock bucket and assign deterministic subbucket
        if (e.bucket == 0) {
            e.bucket = bucket;
            e.subBucket = _decSubbucketFor(player, lvl, bucket);
            e.claimed = 0;
        }

        bucketUsed = e.bucket;

        uint256 effectiveAmount = _decEffectiveAmount(uint256(prevBurn), baseAmount, multBps);

        // Accumulate burn with uint192 saturation
        uint256 updated = uint256(prevBurn) + effectiveAmount;
        if (updated > type(uint192).max) updated = type(uint192).max;
        uint192 newBurn = uint192(updated);
        e.burn = newBurn;

        // Update subbucket aggregate if burn increased
        uint192 delta = newBurn - prevBurn;
        if (delta != 0) {
            _decUpdateSubbucket(lvl, bucketUsed, e.subBucket, delta);
        }

        return bucketUsed;
    }

    /// @dev Apply multiplier until the cap is reached; extra amount is counted at 1x.
    function _decEffectiveAmount(
        uint256 prevBurn,
        uint256 baseAmount,
        uint256 multBps
    ) private pure returns (uint256 effectiveAmount) {
        if (baseAmount == 0) return 0;
        if (multBps <= BPS_DENOMINATOR || prevBurn >= DECIMATOR_MULTIPLIER_CAP) {
            return baseAmount;
        }

        uint256 remaining = DECIMATOR_MULTIPLIER_CAP - prevBurn;
        uint256 fullEffective = (baseAmount * multBps) / BPS_DENOMINATOR;
        if (fullEffective <= remaining) return fullEffective;

        uint256 maxMultBase = (remaining * BPS_DENOMINATOR) / multBps;
        if (maxMultBase > baseAmount) maxMultBase = baseAmount;
        uint256 multiplied = (maxMultBase * multBps) / BPS_DENOMINATOR;
        effectiveAmount = multiplied + (baseAmount - maxMultBase);
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                      BAF JACKPOT RESOLUTION                          ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Distributes ETH prize pool to various winner categories.            ║
      ║                                                                      ║
      ║  PRIZE DISTRIBUTION:                                                 ║
      ║  ┌─────────────────────────────────────────────────────────────────┐ ║
      ║  │ 10% │ Top BAF bettor for this level (bondMask bit set)         │ ║
      ║  │ 10% │ Top coinflip bettor from last 24h window                 │ ║
      ║  │  5% │ Random pick: 3rd or 4th BAF slot                         │ ║
      ║  │ 10% │ Exterminator draw (prior 20 levels, 5/3/2/0%)            │ ║
      ║  │ 10% │ Affiliate draw (top referrers, 5/3/2/0%)                 │ ║
      ║  │ 10% │ Retro tops (sample recent levels, 5/3/2/0%)              │ ║
      ║  │ 20% │ Scatter 1st place (50 rounds × 4 trait tickets)          │ ║
      ║  │ 25% │ Scatter 2nd place (50 rounds × 4 trait tickets)          │ ║
      ║  └─────────────────────────────────────────────────────────────────┘ ║
      ║                                                                      ║
      ║  ELIGIBILITY (required for all winners):                             ║
      ║  • coinflipAmountLastDay >= 5000 BURNIE                              ║
      ║  • ethMintStreakCount >= 3                                           ║
      ║                                                                      ║
      ║  SECURITY:                                                           ║
      ║  • VRF-derived randomness for all random selections                  ║
      ║  • Entropy chained via keccak256 for independence                    ║
      ║  • Unfilled prizes returned via returnAmountWei                      ║
      ║  • bondMask encodes special handling for game contract               ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Resolve the BAF jackpot for a level.
    /// @dev Access: game contract only. Called at level end.
    ///      Distributes poolWei across multiple winner categories with eligibility checks.
    ///      Returns arrays of winners/amounts plus bondMask for special handling.
    /// @param poolWei Total ETH prize pool for distribution.
    /// @param lvl Level number being resolved.
    /// @param rngWord VRF-derived randomness seed.
    /// @return winners Array of winner addresses.
    /// @return amounts Array of prize amounts corresponding to winners.
    /// @return bondMask Bitmask indicating which winners get special bond/map treatment.
    /// @return returnAmountWei Unawarded prize amount to return to caller.
    function runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        override
        onlyGame
        returns (address[] memory winners, uint256[] memory amounts, uint256 bondMask, uint256 returnAmountWei)
    {
        uint256 P = poolWei;
        // Max distinct winners: 1 (top BAF) + 1 (top flip) + 1 (pick) + 3 (exterminator draw) + 3 (affiliate draw) + 3 (retro) + 50 + 50 (scatter buckets) = 112.
        address[] memory tmpW = new address[](112);
        uint256[] memory tmpA = new uint256[](112);
        uint256 n;
        uint256 toReturn;
        uint256 mask;

        uint256 entropy = rngWord;
        uint256 salt;

        {
            // Slice A: 10% to the top BAF bettor for the level.
            uint256 topPrize = P / 10;
            (address w, ) = _bafTop(lvl, 0);
            if (_creditOrRefund(w, topPrize, tmpW, tmpA, n)) {
                mask |= (uint256(1) << n);
                unchecked {
                    ++n;
                }
            } else {
                toReturn += topPrize;
            }
        }

        {
            // Slice A2: 10% to the top coinflip bettor from the last day window.
            uint256 topPrize = P / 10;
            (address w, ) = coin.coinflipTopLastDay();
            if (_creditOrRefund(w, topPrize, tmpW, tmpA, n)) {
                mask |= (uint256(1) << n);
                unchecked {
                    ++n;
                }
            } else {
                toReturn += topPrize;
            }
        }

        {
            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
            uint256 prize = P / 20;
            uint8 pick = 2 + uint8(entropy & 1);
            (address w, ) = _bafTop(lvl, pick);
            // Slice B: 5% to either the 3rd or 4th BAF leaderboard slot (pseudo-random tie-break).
            if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
                mask |= (uint256(1) << n);
                unchecked {
                    ++n;
                }
            } else {
                toReturn += prize;
            }
        }

        {
            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
        }

        {
            // Slice B2: exterminator achievers (past 20 levels) share 10% across four descending prizes (5/3/2/0%).
            uint256[4] memory exPrizes = [(P * 5) / 100, (P * 3) / 100, (P * 2) / 100, uint256(0)];
            uint256 exterminatorSlice;
            unchecked {
                exterminatorSlice = exPrizes[0] + exPrizes[1] + exPrizes[2];
            }

            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));

            address[20] memory exCandidates;
            uint256[20] memory exScores;
            uint8 exCount;

            // Collect exterminators from each of the prior 20 levels (deduped).
            for (uint8 offset = 1; offset <= 20; ) {
                if (lvl <= offset) break;
                address ex = degenerusGame.levelExterminator(uint24(lvl - offset));
                if (ex != address(0)) {
                    bool seen;
                    for (uint8 i; i < exCount; ) {
                        if (exCandidates[i] == ex) {
                            seen = true;
                            break;
                        }
                        unchecked {
                            ++i;
                        }
                    }
                    if (!seen) {
                        exCandidates[exCount] = ex;
                        exScores[exCount] = _bafScore(ex, lvl);
                        unchecked {
                            ++exCount;
                        }
                    }
                }
                unchecked {
                    ++offset;
                }
            }

            // Shuffle candidate order to randomize draws.
            for (uint8 i = exCount; i > 1; ) {
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint256 j = entropy % i;
                uint8 idxA = i - 1;
                address addrTmp = exCandidates[idxA];
                exCandidates[idxA] = exCandidates[j];
                exCandidates[j] = addrTmp;
                uint256 scoreTmp = exScores[idxA];
                exScores[idxA] = exScores[j];
                exScores[j] = scoreTmp;
                unchecked {
                    --i;
                }
            }

            address[4] memory exWinners;
            uint256[4] memory exWinnerScores;
            uint8 exWinCount;

            for (uint8 i; i < exCount && exWinCount < 4; ) {
                address cand = exCandidates[i];
                if (_eligible(cand)) {
                    exWinners[exWinCount] = cand;
                    exWinnerScores[exWinCount] = exScores[i];
                    unchecked {
                        ++exWinCount;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            if (exWinCount == 0) {
                toReturn += exterminatorSlice;
            } else {
                // Sort by BAF score so higher scores take the larger cuts (5/3/2/0%).
                for (uint8 i; i < exWinCount; ) {
                    uint8 bestIdx = i;
                    for (uint8 j = i + 1; j < exWinCount; ) {
                        if (exWinnerScores[j] > exWinnerScores[bestIdx]) {
                            bestIdx = j;
                        }
                        unchecked {
                            ++j;
                        }
                    }
                    if (bestIdx != i) {
                        address wTmp = exWinners[i];
                        exWinners[i] = exWinners[bestIdx];
                        exWinners[bestIdx] = wTmp;
                        uint256 sTmp = exWinnerScores[i];
                        exWinnerScores[i] = exWinnerScores[bestIdx];
                        exWinnerScores[bestIdx] = sTmp;
                    }
                    unchecked {
                        ++i;
                    }
                }

                uint256 paidEx;
                uint8 maxExWinners = exWinCount;
                if (maxExWinners > 4) {
                    maxExWinners = 4;
                }
                for (uint8 i; i < maxExWinners; ) {
                    uint256 prize = exPrizes[i];
                    paidEx += prize;
                    if (prize != 0) {
                        tmpW[n] = exWinners[i];
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }
                if (paidEx < exterminatorSlice) {
                    toReturn += exterminatorSlice - paidEx;
                }
            }
        }

        {
            // Slice C: affiliate achievers (past 20 levels) share 10% across four descending prizes.
            uint256[4] memory affiliatePrizes = [(P * 5) / 100, (P * 3) / 100, (P * 2) / 100, uint256(0)];
            uint256 affiliateSlice;
            unchecked {
                affiliateSlice = affiliatePrizes[0] + affiliatePrizes[1] + affiliatePrizes[2] + affiliatePrizes[3];
            }

            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));

            address affiliateAddr = affiliate;
            IDegenerusAffiliate affiliateContract = IDegenerusAffiliate(affiliateAddr);
            address[20] memory candidates;
            uint256[20] memory candidateScores;
            uint8 candidateCount;

            // Collect the top affiliate from each of the prior 20 levels (deduped).
            for (uint8 offset = 1; offset <= 20; ) {
                if (lvl <= offset) break;
                (address player, ) = affiliateContract.affiliateTop(uint24(lvl - offset));
                if (player != address(0)) {
                    bool seen;
                    for (uint8 i; i < candidateCount; ) {
                        if (candidates[i] == player) {
                            seen = true;
                            break;
                        }
                        unchecked {
                            ++i;
                        }
                    }
                    if (!seen) {
                        candidates[candidateCount] = player;
                        candidateScores[candidateCount] = _bafScore(player, lvl);
                        unchecked {
                            ++candidateCount;
                        }
                    }
                }
                unchecked {
                    ++offset;
                }
            }

            // Shuffle candidate order to randomize draws.
            for (uint8 i = candidateCount; i > 1; ) {
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint256 j = entropy % i;
                uint8 idxA = i - 1;
                address addrTmp = candidates[idxA];
                candidates[idxA] = candidates[j];
                candidates[j] = addrTmp;
                uint256 scoreTmp = candidateScores[idxA];
                candidateScores[idxA] = candidateScores[j];
                candidateScores[j] = scoreTmp;
                unchecked {
                    --i;
                }
            }

            address[4] memory affiliateWinners;
            uint256[4] memory affiliateScores;
            uint8 winnerCount;

            for (uint8 i; i < candidateCount && winnerCount < 4; ) {
                address cand = candidates[i];
                if (_eligible(cand)) {
                    affiliateWinners[winnerCount] = cand;
                    affiliateScores[winnerCount] = candidateScores[i];
                    unchecked {
                        ++winnerCount;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            if (winnerCount == 0) {
                toReturn += affiliateSlice;
            } else {
                // Sort by BAF score so higher scores take the larger cuts (5/3/2/0%).
                for (uint8 i; i < winnerCount; ) {
                    uint8 bestIdx = i;
                    for (uint8 j = i + 1; j < winnerCount; ) {
                        if (affiliateScores[j] > affiliateScores[bestIdx]) {
                            bestIdx = j;
                        }
                        unchecked {
                            ++j;
                        }
                    }
                    if (bestIdx != i) {
                        address wTmp = affiliateWinners[i];
                        affiliateWinners[i] = affiliateWinners[bestIdx];
                        affiliateWinners[bestIdx] = wTmp;
                        uint256 sTmp = affiliateScores[i];
                        affiliateScores[i] = affiliateScores[bestIdx];
                        affiliateScores[bestIdx] = sTmp;
                    }
                    unchecked {
                        ++i;
                    }
                }

                uint256 paid;
                uint8 maxWinners = winnerCount;
                if (maxWinners > 4) {
                    maxWinners = 4;
                }
                for (uint8 i; i < maxWinners; ) {
                    uint256 prize = affiliatePrizes[i];
                    paid += prize;
                    if (prize != 0) {
                        tmpW[n] = affiliateWinners[i];
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }
                if (paid < affiliateSlice) {
                    toReturn += affiliateSlice - paid;
                }
            }
        }

        {
            uint256 slice = P / 10;
            uint256[4] memory prizes = [(slice * 5) / 10, (slice * 3) / 10, (slice * 2) / 10, uint256(0)];

            for (uint8 s; s < 4; ) {
                // Slice D: retro top bettors — sample recent levels to bias toward fresh play (10% total).
                // Retro top rewards: sample two recent levels (1..20 back) and pick the lower level.
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint24 lvlA = _recentLevel(lvl, entropy);
                (address candA, ) = coin.coinflipTop(lvlA);

                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint24 lvlB = _recentLevel(lvl, entropy);
                (address candB, ) = coin.coinflipTop(lvlB);

                address chosen;
                bool validA = candA != address(0);
                bool validB = candB != address(0);
                if (validA && validB) {
                    if (lvlA <= lvlB) {
                        chosen = candA;
                    } else {
                        chosen = candB;
                    }
                } else if (validA) {
                    chosen = candA;
                } else if (validB) {
                    chosen = candB;
                }

                uint256 prize = prizes[s];
                bool credited;
                if (prize != 0) {
                    credited = _creditOrRefund(chosen, prize, tmpW, tmpA, n);
                }
                if (credited) {
                    unchecked {
                        ++n;
                    }
                } else if (prize != 0) {
                    toReturn += prize;
                }
                unchecked {
                    ++s;
                }
            }
        }

        // Scatter slice: 200 total draws (4 tickets * 50 rounds). Per round, take top-2 by BAF score.
        // Game applies special map/bond handling for the last BAF_SCATTER_BOND_WINNERS scatter winners via `bondMask`.
        {
            // Slice E: scatter tickets from trait sampler so casual participants can land smaller cuts.
            uint256 scatterTop = (P * 20) / 100;
            uint256 scatterSecond = (P * 25) / 100;
            address[50] memory firstWinners;
            address[50] memory secondWinners;
            uint256 firstCount;
            uint256 secondCount;
            uint256 scatterStart = n;

            // 50 rounds of 4-ticket sampling (total 200 tickets).
            for (uint8 round; round < 50; ) {
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                (, , address[] memory tickets) = degenerusGame.sampleTraitTickets(entropy);

                // Pick up to 4 tickets from the sampled set.
                uint256 limit = tickets.length;
                if (limit > 4) limit = 4;

                address best;
                uint256 bestScore;
                address second;
                uint256 secondScore;

                for (uint256 i; i < limit; ) {
                    address cand = tickets[i];
                    uint256 score = _bafScore(cand, lvl);
                    if (score > bestScore) {
                        second = best;
                        secondScore = bestScore;
                        best = cand;
                        bestScore = score;
                    } else if (score > secondScore && cand != best) {
                        second = cand;
                        secondScore = score;
                    }
                    unchecked {
                        ++i;
                    }
                }

                // Bucket winners if eligible and capacity not exceeded; otherwise refund their would-be share later.
                if (firstCount < 50 && _eligible(best)) {
                    firstWinners[firstCount] = best;
                    unchecked {
                        ++firstCount;
                    }
                }
                if (secondCount < 50 && _eligible(second)) {
                    secondWinners[secondCount] = second;
                    unchecked {
                        ++secondCount;
                    }
                }

                unchecked {
                    ++round;
                }
            }

            if (firstCount == 0) {
                toReturn += scatterTop;
            } else {
                uint256 per = scatterTop / firstCount;
                uint256 rem = scatterTop - per * firstCount;
                toReturn += rem;
                if (per != 0) {
                    for (uint256 i; i < firstCount; ) {
                        tmpW[n] = firstWinners[i];
                        tmpA[n] = per;
                        unchecked {
                            ++n;
                            ++i;
                        }
                    }
                }
            }

            if (secondCount == 0) {
                toReturn += scatterSecond;
            } else {
                uint256 per2 = scatterSecond / secondCount;
                uint256 rem2 = scatterSecond - per2 * secondCount;
                toReturn += rem2;
                if (per2 != 0) {
                    for (uint256 i; i < secondCount; ) {
                        tmpW[n] = secondWinners[i];
                        tmpA[n] = per2;
                        unchecked {
                            ++n;
                            ++i;
                        }
                    }
                }
            }

            uint256 scatterCount = n - scatterStart;
            if (scatterCount != 0) {
                uint256 targetSpecialCount = scatterCount < BAF_SCATTER_BOND_WINNERS
                    ? scatterCount
                    : BAF_SCATTER_BOND_WINNERS;
                for (uint256 i; i < targetSpecialCount; ) {
                    uint256 idx = (scatterStart + scatterCount - 1) - i;
                    mask |= (uint256(1) << (BAF_SCATTER_MASK_OFFSET + idx));
                    unchecked {
                        ++i;
                    }
                }
            }
        }

        winners = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ) {
            winners[i] = tmpW[i];
            amounts[i] = tmpA[i];
            unchecked {
                ++i;
            }
        }

        bondMask = mask;

        // Clean up leaderboard state for this level
        _clearBafTop(lvl);
        return (winners, amounts, bondMask, toReturn);
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                    DECIMATOR JACKPOT RESOLUTION                      ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Snapshots winning subbuckets for deferred claim distribution.       ║
      ║                                                                      ║
      ║  RESOLUTION FLOW:                                                    ║
      ║  1. For each denom 2..10, select random winning subbucket            ║
      ║  2. Sum total burns across all winning subbuckets                    ║
      ║  3. Snapshot poolWei and totalBurn for claims                        ║
      ║  4. Players claim pro-rata share via claimDecimatorJackpot           ║
      ║                                                                      ║
      ║  CLAIM FORMULA:                                                      ║
      ║  payout = (poolWei × playerBurn) / totalBurn                         ║
      ║                                                                      ║
      ║  SECURITY:                                                           ║
      ║  • VRF-derived randomness for subbucket selection                    ║
      ║  • No double snapshots (returns pool if already active)              ║
      ║  • Returns full pool if no qualifying burns                          ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Snapshot Decimator jackpot winners for deferred claims.
    /// @dev Access: game contract only. Called at level end.
    ///      Selects winning subbucket per denominator and snapshots totals.
    ///      Actual distribution happens via claim functions.
    /// @param poolWei Total ETH prize pool for this level.
    /// @param lvl Level number being resolved.
    /// @param rngWord VRF-derived randomness seed.
    /// @return returnAmountWei Amount to return (non-zero if no winners or already snapshotted).
    function runDecimatorJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        override
        onlyGame
        returns (uint256 returnAmountWei)
    {
        // Decimator jackpots defer ETH distribution to per-player claims
        DecClaimRound storage round = decClaimRound[lvl];

        // Prevent double-snapshotting: return pool if already active
        if (round.active) {
            return poolWei;
        }

        uint256 totalBurn;
        uint64 packedOffsets;

        // Select winning subbucket for each denominator (2-10)
        uint256 decSeed = rngWord;
        for (uint8 denom = 2; denom <= DECIMATOR_MAX_DENOM; ) {
            // Deterministically select winning subbucket from VRF
            uint8 winningSub = _decWinningSubbucket(decSeed, denom);
            packedOffsets = _packDecWinningSubbucket(packedOffsets, denom, winningSub);

            // Accumulate burn total from winning subbucket
            uint256 subTotal = decBucketBurnTotal[lvl][denom][winningSub];
            if (subTotal != 0) {
                totalBurn += subTotal;
            }

            unchecked {
                ++denom;
            }
        }

        // Store packed winning subbuckets for claim validation
        decBucketOffsetPacked[lvl] = packedOffsets;

        // No qualifying burns: return full pool
        if (totalBurn == 0) {
            return poolWei;
        }

        // Snapshot claim round for deferred distribution
        round.poolWei = poolWei;
        round.totalBurn = uint248(totalBurn);
        round.active = true;

        return 0; // All funds held for claims
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                      DECIMATOR CLAIM FUNCTIONS                       ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Allow players to claim their pro-rata share of Decimator jackpot.   ║
      ║                                                                      ║
      ║  CLAIM REQUIREMENTS:                                                 ║
      ║  • Round must be active (snapshotted via runDecimatorJackpot)        ║
      ║  • Player must not have already claimed                              ║
      ║  • Player's subbucket must match winning subbucket for their denom   ║
      ║                                                                      ║
      ║  SECURITY:                                                           ║
      ║  • claimed flag prevents double-claims                               ║
      ║  • Pro-rata calculation based on snapshotted totals                  ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Internal claim validation and marking.
    ///      Validates eligibility and marks as claimed if successful.
    /// @param player Address claiming the jackpot.
    /// @param lvl Level to claim from.
    /// @return amountWei Pro-rata payout amount.
    function _consumeDecClaim(address player, uint24 lvl) internal returns (uint256 amountWei) {
        DecClaimRound storage round = decClaimRound[lvl];
        if (!round.active) revert DecClaimInactive();

        DecEntry storage e = decBurn[lvl][player];
        if (e.claimed != 0) revert DecAlreadyClaimed();

        // Calculate pro-rata share if player's subbucket won
        uint64 packedOffsets = decBucketOffsetPacked[lvl];
        uint256 totalBurn = uint256(round.totalBurn);
        amountWei = _decClaimableFromEntry(round.poolWei, totalBurn, e, lvl, packedOffsets);
        if (amountWei == 0) revert DecNotWinner();

        // Mark as claimed to prevent double-claiming
        e.claimed = 1;
    }

    /// @notice Consume Decimator claim on behalf of player.
    /// @dev Access: game contract only. Used for game-initiated claims.
    /// @param player Address to claim for.
    /// @param lvl Level to claim from.
    /// @return amountWei Pro-rata payout amount.
    function consumeDecClaim(address player, uint24 lvl) external onlyGame returns (uint256 amountWei) {
        return _consumeDecClaim(player, lvl);
    }

    /// @notice Claim Decimator jackpot for caller.
    /// @dev Public function for players to claim their own jackpot.
    ///      Credits payout to player's claimable balance via game contract.
    /// @param lvl Level to claim from.
    function claimDecimatorJackpot(uint24 lvl) external {
        uint256 amountWei = _consumeDecClaim(msg.sender, lvl);
        degenerusGame.creditDecJackpotClaim(msg.sender, amountWei);
    }

    /// @notice Batch claim Decimator jackpots for multiple players.
    /// @dev Permissionless: anyone can trigger claims for others.
    ///      Gas-efficient for processing multiple claims at once.
    /// @param players Array of player addresses to claim for.
    /// @param lvl Level to claim from.
    function claimDecimatorJackpotBatch(address[] calldata players, uint24 lvl) external {
        uint256 len = players.length;
        if (len == 0) return;
        uint256[] memory amounts = new uint256[](len);
        for (uint256 i; i < len; ) {
            uint256 amountWei = _consumeDecClaim(players[i], lvl);
            amounts[i] = amountWei;
            unchecked {
                ++i;
            }
        }
        degenerusGame.creditDecJackpotClaimBatch(players, amounts);
    }

    /// @notice Check if player can claim Decimator jackpot for a level.
    /// @dev View function for UI to show claimable amounts.
    /// @param player Address to check.
    /// @param lvl Level to check.
    /// @return amountWei Claimable amount (0 if not winner or already claimed).
    /// @return winner True if player is a winner for this level.
    function decClaimable(address player, uint24 lvl) external view returns (uint256 amountWei, bool winner) {
        DecClaimRound storage round = decClaimRound[lvl];
        return _decClaimable(round, player, lvl);
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                      INTERNAL HELPER FUNCTIONS                       ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Utility functions for eligibility, bucket packing, and scoring.     ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Check if player meets BAF eligibility requirements.
    ///      Requirements:
    ///      - 5000+ BURNIE coinflip in last 24 hours
    ///      - 3+ consecutive ETH mint streak
    /// @param player Address to check.
    /// @return True if player is eligible for BAF prizes.
    function _eligible(address player) internal view returns (bool) {
        if (coin.coinflipAmountLastDay(player) < 5_000 * MILLION) return false;
        return degenerusGame.ethMintStreakCount(player) >= 3;
    }

    /// @dev Credit prize to eligible winner or return false for refund.
    ///      Writes to preallocated buffers if eligible.
    /// @param candidate Potential winner address.
    /// @param prize Prize amount in wei.
    /// @param winnersBuf Pre-allocated winners array.
    /// @param amountsBuf Pre-allocated amounts array.
    /// @param idx Current write index.
    /// @return credited True if winner was credited (eligible and non-zero prize).
    function _creditOrRefund(
        address candidate,
        uint256 prize,
        address[] memory winnersBuf,
        uint256[] memory amountsBuf,
        uint256 idx
    ) private view returns (bool credited) {
        if (prize == 0) return false;
        if (_eligible(candidate)) {
            winnersBuf[idx] = candidate;
            amountsBuf[idx] = prize;
            return true;
        }
        return false;
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                    DECIMATOR BUCKET HELPERS                          ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Packing/unpacking for winning subbucket storage and calculation.    ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Deterministically select winning subbucket for a denominator.
    /// @param entropy VRF-derived randomness.
    /// @param denom Denominator (2-10).
    /// @return Winning subbucket index (0 to denom-1).
    function _decWinningSubbucket(uint256 entropy, uint8 denom) private pure returns (uint8) {
        if (denom == 0) return 0;
        return uint8(uint256(keccak256(abi.encode(entropy, denom))) % denom);
    }

    /// @dev Pack a winning subbucket into the packed uint64.
    ///      Layout: 4 bits per denom, starting at denom 2.
    /// @param packed Current packed value.
    /// @param denom Denominator to pack (2-10).
    /// @param sub Winning subbucket for this denom.
    /// @return Updated packed value.
    function _packDecWinningSubbucket(uint64 packed, uint8 denom, uint8 sub) private pure returns (uint64) {
        uint8 shift = (denom - 2) << 2; // 4 bits per denom
        uint64 mask = uint64(0xF) << shift;
        return (packed & ~mask) | ((uint64(sub) & 0xF) << shift);
    }

    /// @dev Unpack a winning subbucket from the packed uint64.
    /// @param packed Packed winning subbuckets.
    /// @param denom Denominator to unpack (2-10).
    /// @return Winning subbucket for this denom.
    function _unpackDecWinningSubbucket(uint64 packed, uint8 denom) private pure returns (uint8) {
        if (denom < 2) return 0;
        uint8 shift = (denom - 2) << 2;
        return uint8((packed >> shift) & 0xF);
    }

    /// @dev Calculate pro-rata claimable amount for a player's DecEntry.
    /// @param poolWei Total pool available for claims.
    /// @param totalBurn Total qualifying burn (denominator).
    /// @param e Player's DecEntry storage reference.
    /// @param lvl Level number.
    /// @param packedOffsets Packed winning subbuckets.
    /// @return amountWei Player's pro-rata share (0 if not winner).
    function _decClaimableFromEntry(
        uint256 poolWei,
        uint256 totalBurn,
        DecEntry storage e,
        uint24 lvl,
        uint64 packedOffsets
    ) private view returns (uint256 amountWei) {
        if (totalBurn == 0) return 0;

        uint8 denom = e.bucket;
        uint8 sub = e.subBucket;
        uint192 entryBurn = e.burn;

        // No participation or zero burn
        if (denom == 0 || entryBurn == 0) return 0;

        // Check if player's subbucket matches winning subbucket
        uint8 winningSub = _unpackDecWinningSubbucket(packedOffsets, denom);
        if (sub != winningSub) return 0;

        // Safety check: verify subbucket has burns
        if (decBucketBurnTotal[lvl][denom][winningSub] == 0) return 0;

        // Pro-rata share: (pool × playerBurn) / totalBurn
        amountWei = (poolWei * uint256(entryBurn)) / totalBurn;
    }

    /// @dev Internal view helper for decClaimable.
    /// @param round DecClaimRound storage reference.
    /// @param player Address to check.
    /// @param lvl Level number.
    /// @return amountWei Claimable amount.
    /// @return winner True if player is a winner.
    function _decClaimable(
        DecClaimRound storage round,
        address player,
        uint24 lvl
    ) internal view returns (uint256 amountWei, bool winner) {
        uint256 totalBurn = uint256(round.totalBurn);
        if (!round.active || totalBurn == 0) return (0, false);

        DecEntry storage e = decBurn[lvl][player];
        if (e.claimed != 0) return (0, false);

        uint64 packedOffsets = decBucketOffsetPacked[lvl];
        amountWei = _decClaimableFromEntry(round.poolWei, totalBurn, e, lvl, packedOffsets);
        winner = amountWei != 0;
    }

    /// @dev Update aggregated burn totals for a subbucket.
    /// @param lvl Level number.
    /// @param denom Denominator (bucket).
    /// @param sub Subbucket index.
    /// @param delta Burn amount to add.
    function _decUpdateSubbucket(
        uint24 lvl,
        uint8 denom,
        uint8 sub,
        uint192 delta
    ) internal {
        if (delta == 0 || denom == 0) return;
        decBucketBurnTotal[lvl][denom][sub] += uint256(delta);
    }

    /// @dev Deterministically assign subbucket for a player.
    ///      Hash of (player, lvl, bucket) ensures consistent assignment.
    /// @param player Address.
    /// @param lvl Level number.
    /// @param bucket Denominator.
    /// @return Subbucket index (0 to bucket-1).
    function _decSubbucketFor(address player, uint24 lvl, uint8 bucket) private pure returns (uint8) {
        if (bucket == 0) return 0;
        return uint8(uint256(keccak256(abi.encodePacked(player, lvl, bucket))) % bucket);
    }

    /*╔══════════════════════════════════════════════════════════════════════╗
      ║                      BAF LEADERBOARD HELPERS                         ║
      ╠══════════════════════════════════════════════════════════════════════╣
      ║  Maintain sorted top-4 leaderboard per level.                        ║
      ╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Get player's BAF score for a level.
    /// @param player Address to query.
    /// @param lvl Level number.
    /// @return Weighted coinflip total (0 if player not in this level).
    function _bafScore(address player, uint24 lvl) private view returns (uint256) {
        BafEntry storage e = bafTotals[player];
        if (e.level != lvl) return 0;
        return e.total;
    }

    /// @dev Convert raw score to capped uint96 (whole tokens only).
    /// @param s Raw score in base units.
    /// @return Capped score in whole tokens.
    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    /// @dev Update top-4 BAF leaderboard with new stake.
    ///      Maintains sorted order (highest score first).
    ///      Handles: existing player update, new player insertion, capacity management.
    /// @param lvl Level number.
    /// @param player Address.
    /// @param stake New total stake for player.
    function _updateBafTop(uint24 lvl, address player, uint256 stake) private {
        uint96 score = _score96(stake);
        PlayerScore[4] storage board = bafTop[lvl];
        uint8 len = bafTopLen[lvl];

        // Check if player already on leaderboard
        uint8 existing = 4; // sentinel: not found
        for (uint8 i; i < len; ) {
            if (board[i].player == player) {
                existing = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Case 1: Player already on board - update and re-sort if improved
        if (existing < 4) {
            if (score <= board[existing].score) return; // No improvement
            board[existing].score = score;
            // Bubble up if score increased
            uint8 idx = existing;
            while (idx > 0 && board[idx].score > board[idx - 1].score) {
                PlayerScore memory tmp = board[idx - 1];
                board[idx - 1] = board[idx];
                board[idx] = tmp;
                unchecked {
                    --idx;
                }
            }
            return;
        }

        // Case 2: Board not full - insert in sorted position
        if (len < 4) {
            uint8 insert = len;
            while (insert > 0 && score > board[insert - 1].score) {
                board[insert] = board[insert - 1];
                unchecked {
                    --insert;
                }
            }
            board[insert] = PlayerScore({player: player, score: score});
            bafTopLen[lvl] = len + 1;
            return;
        }

        // Case 3: Board full - replace bottom if score is higher
        if (score <= board[3].score) return; // Not good enough
        uint8 idx2 = 3;
        while (idx2 > 0 && score > board[idx2 - 1].score) {
            board[idx2] = board[idx2 - 1];
            unchecked {
                --idx2;
            }
        }
        board[idx2] = PlayerScore({player: player, score: score});
    }

    /// @dev Get player at leaderboard position.
    /// @param lvl Level number.
    /// @param idx Position (0 = top).
    /// @return player Address at position (address(0) if empty).
    /// @return score Player's score.
    function _bafTop(uint24 lvl, uint8 idx) private view returns (address player, uint96 score) {
        uint8 len = bafTopLen[lvl];
        if (idx >= len) return (address(0), 0);
        PlayerScore memory entry = bafTop[lvl][idx];
        return (entry.player, entry.score);
    }

    /// @dev Clear leaderboard state for a level after jackpot resolution.
    ///      Called at end of runBafJackpot to free storage.
    /// @param lvl Level number.
    function _clearBafTop(uint24 lvl) private {
        uint8 len = bafTopLen[lvl];
        if (len != 0) {
            delete bafTopLen[lvl];
        }
        for (uint8 i; i < len; ) {
            delete bafTop[lvl][i];
            unchecked {
                ++i;
            }
        }
    }
}

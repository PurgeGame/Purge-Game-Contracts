// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContractAddresses} from "../ContractAddresses.sol";

/**
 * @title DegenerusGameStorage
 * @author Burnie Degenerus
 * @notice Shared storage layout between DegenerusGame and its delegatecall modules.
 *
 * @dev ARCHITECTURE OVERVIEW
 * -----------------------------------------------------------------------------
 * This contract defines the canonical storage layout for the Degenerus game ecosystem.
 * It is inherited by:
 *   - DegenerusGame (main contract, holds actual state)
 *   - DegenerusGameEndgameModule (delegatecall module)
 *   - DegenerusGameJackpotModule (delegatecall module)
 *   - DegenerusGameMintModule (delegatecall module)
 *
 * DELEGATECALL PATTERN:
 * When DegenerusGame calls `module.delegatecall(...)`, the module's code executes
 * in the context of DegenerusGame's storage. This means:
 *   1. Storage slots MUST match exactly between the main contract and all modules.
 *   2. This contract ensures slot alignment by providing a single source of truth.
 *   3. Never add storage variables to module contracts — they would collide with game storage.
 *
 * STORAGE SLOT LAYOUT (EVM assigns slots sequentially):
 * -----------------------------------------------------------------------------
 *
 * +-----------------------------------------------------------------------------+
 * | SLOT 0 (32 bytes) — Timing, Batching, FSM                                   |
 * +-----------------------------------------------------------------------------+
 * | [0:6]   levelStartTime           uint48   Timestamp when level opened       |
 * | [6:12]  dailyIdx                 uint48   Monotonic day counter             |
 * | [12:18] rngRequestTime           uint48   When last VRF request was fired   |
 * | [18:22] airdropMapsProcessedCount uint32  Maps handled in current batch     |
 * | [22:26] airdropIndex             uint32   Index into pendingMapMints        |
 * | [26:29] level                    uint24   Current game level (1-indexed)    |
 * | [29:31] lastExterminatedTrait    uint16   Last cleared trait (420=sentinel) |
 * | [31:32] gameState                uint8    FSM: 0-3,86 (pre/setup/purc/burn) |
 * +-----------------------------------------------------------------------------+
 *   Total: 6+6+6+4+4+3+2+1 = 32 bytes ✓ (perfectly packed)
 *
 * +-----------------------------------------------------------------------------+
 * | SLOT 1 (32 bytes) — Cursors, Counters, Boolean Flags                        |
 * +-----------------------------------------------------------------------------+
 * | [0:4]   traitRebuildCursor       uint32   Cursor for trait count reseeding  |
 * | [4:8]   airdropMultiplier        uint32   Bonus multiplier (scaled)         |
 * | [8:9]   jackpotCounter           uint8    Jackpots processed this level     |
 * | [9:10]  earlyBurnPercent         uint8    Previous pool % in early burn     |
 * | [10:11] levelJackpotPaid         bool     Level jackpot executed flag       |
 * | [11:12] lastPurchaseDay          bool     Prize target met flag             |
 * | [12:13] decWindowOpen            bool     Decimator window latch            |
 * | [13:14] rngLockedFlag            bool     Waiting for VRF fulfillment       |
 * | [14:15] rngFulfilled             bool     VRF lifecycle tracker             |
 * | [15:16] traitCountsSeedQueued    bool     Initial traits staged flag        |
 * | [16:17] decimatorHundredReady    bool     Level %100 special primed         |
 * | [17:18] exterminationInvertFlag  bool     Exterminator bonus inversion      |
 * | [18:19] mapJackpotType           uint8    0=none, 1=daily, 2=purchase       |
* | [19:20] lastLevelJackpotCount    uint8    Jackpots processed last level     |
* | [20:32] <padding>                         12 bytes unused                   |
 * +-----------------------------------------------------------------------------+
*   Total: 4+4+12 = 20 bytes (12 bytes padding)
 *
 * +-----------------------------------------------------------------------------+
 * | SLOT 2 (32 bytes) — Price                                                   |
 * +-----------------------------------------------------------------------------+
 * | [0:16]  price                    uint128  Current mint price in wei         |
 * | [16:32] <padding>                         16 bytes unused                   |
 * +-----------------------------------------------------------------------------+
 *
 * SLOTS 3+ — Full-width variables, arrays, and mappings
 * -----------------------------------------------------------------------------
 * Each uint256, array length, or mapping root occupies its own slot.
 * Dynamic arrays: length at slot N, data at keccak256(N).
 * Mappings: value at keccak256(key . slot).
 *
 * SECURITY CONSIDERATIONS
 * -----------------------------------------------------------------------------
 * 1. SLOT STABILITY: Never reorder, remove, or change types of existing variables.
 *    Append-only additions are safe for non-upgradeable contracts.
 *
 * 2. DELEGATECALL SAFETY: All modules inherit this exact layout. If a module
 *    declared its own storage variables, they would occupy the same slots as
 *    game data, causing catastrophic corruption.
 *
 * 3. ACCESS CONTROL: All variables are `internal`, preventing external reads.
 *    Public getters in DegenerusGame expose only what's needed.
 *
 * 4. INITIALIZATION: Default values are set inline. For critical variables:
 *    - levelStartTime = type(uint48).max (sentinel: game not started)
 *    - lastExterminatedTrait = 420 (sentinel: no trait exterminated)
*    - gameState = 2 (initialized to PURCHASE state)
 *    - decWindowOpen = true (decimator window starts open)
 *    - rngFulfilled = true (no pending request at deploy)
 *    - price = 0.025 ether (initial mint price)
 *    - lastPrizePool = 125 ether (bootstrap value for % calculations)
 *
 * 5. OVERFLOW PROTECTION: Solidity 0.8+ provides automatic overflow checks.
 *    `unchecked` blocks in modules are intentional optimizations for safe ops.
 *
 * 6. MAPPING COLLISION: Mappings use keccak256(key . slot), making collisions
 *    computationally infeasible. The traitBurnTicket nested mapping uses
 *    keccak256(traitId . keccak256(level . slot)) for data location.
 *
 * UPGRADE NOTES
 * -----------------------------------------------------------------------------
 * This contract is NOT upgradeable (no proxy pattern). However, if future
 * versions are deployed, they MUST preserve this exact layout to allow
 * state migration or fork compatibility. Document any additions here.
 *
 * VARIABLE DOCUMENTATION
 * -----------------------------------------------------------------------------
 * See inline comments for each variable group below.
 */
abstract contract DegenerusGameStorage {
    // =========================================================================
    // CONSTANTS
    // =========================================================================

    /// @dev Conversion factor for BURNIE token amounts.
    ///      BURNIE uses 18 decimals, so 1000 BURNIE = 1e21 base units.
    ///      Used in price calculations: price / PRICE_COIN_UNIT = BURNIE per mint.
    uint256 internal constant PRICE_COIN_UNIT = 1000 ether;
    uint8 internal constant GAME_STATE_SETUP = 1;
    uint8 internal constant GAME_STATE_PURCHASE = 2;
    uint8 internal constant GAME_STATE_BURN = 3;
    uint8 internal constant GAME_STATE_GAMEOVER = 86;

    // =========================================================================
    // SLOT 0: Level Timing, Batching, and Finite State Machine
    // =========================================================================
    // These variables pack into a single 32-byte storage slot for gas efficiency.
    // Order matters: EVM packs from low to high within a slot.

    /// @dev Timestamp when the current level opened for purchase phase.
    ///      Initialized to uint48.max as a sentinel indicating "game not started".
    ///      Used for inactivity guard timing and purchase-phase weekly jackpots.
    ///
    ///      SECURITY: uint48 holds timestamps until year 8.9 million — safe for any
    ///      realistic game lifetime. Overflow is not a concern.
    uint48 internal levelStartTime = type(uint48).max;

    /// @dev Monotonically increasing "day" counter derived from block timestamps.
    ///      Incremented during game progression; used to key RNG words and track
    ///      daily jackpot eligibility. NOT tied to calendar days — it's game-relative.
    ///
    ///      SECURITY: uint48 allows ~281 trillion increments — effectively unlimited.
    uint48 internal dailyIdx;

    /// @dev Timestamp when the last VRF (Chainlink) request was submitted.
    ///      Used for timeout detection: if rngRequestTime + timeout < now and
    ///      rngLockedFlag is still true, the game can recover via fallback RNG.
    ///
    ///      SECURITY: Timeout mechanism prevents permanent lockup if VRF fails.
    uint48 internal rngRequestTime;

    /// @dev Count of map mints processed within the current airdrop batch.
    ///      Reset to 0 when advancing to a new player in pendingMapMints.
    ///      Used with playerMapMintsOwed to track partial batch completion.
    ///
    ///      SECURITY: uint32 supports up to ~4B mints per player — far exceeds
    ///      realistic airdrop volumes.
    uint32 internal airdropMapsProcessedCount;

    /// @dev Index into the pendingMapMints array for batched airdrop processing.
    ///      Allows gas-bounded iteration: process N mints, save progress, continue
    ///      in subsequent transactions until all airdrops are complete.
    ///
    ///      SECURITY: Batch processing prevents DoS from large airdrop queues.
    uint32 internal airdropIndex;

    /// @dev Current game level (1-indexed). Levels progress through purchase and
    ///      burn phases, with jackpots at various milestones.
    ///
    ///      PUBLIC: Exposed for frontend/analytics. Read-only externally.
    ///
    ///      SECURITY: uint24 supports ~16M levels — game would take millennia
    ///      to overflow at realistic progression rates.
    uint24 public level = 1;

    /// @dev The last trait ID that was exterminated this level.
    ///      420 is a sentinel value meaning "no extermination yet" or "timed out".
    ///      Valid trait IDs are 0-255, so 420 is unambiguously a sentinel.
    ///
    ///      DESIGN: Easter egg reference (420). Functional as a clear sentinel.
    uint16 internal lastExterminatedTrait = 420;

    /// @dev Finite State Machine for game phases:
    ///      0 = reserved (unused)
    ///      1 = setup (awaiting start or between major phases)
    ///      2 = purchase (mint/airdrop phase; initialized state)
    ///      3 = burn window (extermination phase)
    ///      86 = game over (terminal)
    ///
    ///      PUBLIC: Exposed for frontend state queries.
    ///
    ///      SECURITY: State transitions are guarded by modifiers in DegenerusGame.
    ///      Invalid state transitions revert, preventing exploitation.
    uint8 public gameState = GAME_STATE_PURCHASE;

    // =========================================================================
    // SLOT 1: Cursors, Counters, and Boolean Flags
    // =========================================================================
    // Boolean flags pack efficiently (1 byte each in EVM). Total: 23 bytes used (9 bytes padding).

    /// @dev Progress cursor for reseeding trait counts at level start.
    ///      Used in batched trait initialization to avoid gas limits.
    uint32 internal traitRebuildCursor;

    /// @dev Airdrop bonus multiplier (scaled integer representation).
    ///      Applied during map mint calculations for promotional events.
    uint32 internal airdropMultiplier;

    /// @dev Count of jackpots processed within the current level.
    ///      Capped at 10 (JACKPOT_LEVEL_CAP in JackpotModule); triggers level
    ///      advancement when reached. Reset at level start.
    ///
    ///      SECURITY: uint8 is sufficient (max 255, only need 0-10).
    uint8 internal jackpotCounter;

    /// @dev Percentage of previous prize pool carried into early burn reward.
    ///      Range 0-255 (but practically 0-100%). Used for early burn bonus
    ///      calculations in the jackpot module.
    uint8 internal earlyBurnPercent;

    /// @dev True once the level jackpot has been executed for the
    ///      current purchase phase. Prevents double-payment.
    ///
    ///      SECURITY: Critical for jackpot integrity. Reset at level transition.
    bool internal levelJackpotPaid;

    /// @dev True once the prize target is met for current level.
    ///      When true, next tick skips normal daily/jackpot prep and proceeds
    ///      to burn window. Allows early level completion on high activity.
    bool internal lastPurchaseDay;

    /// @dev Latch to hold decimator window open until RNG is requested.
    ///      Set true at level start; cleared when decimator phase begins.
    ///      Default true ensures first decimator window is properly gated.
    bool internal decWindowOpen = true;

    /// @dev True while waiting for VRF (Chainlink) fulfillment.
    ///      Prevents duplicate RNG requests and gates state transitions
    ///      that depend on randomness.
    ///
    ///      SECURITY: Critical for RNG integrity. Prevents re-entrancy
    ///      attacks on RNG-dependent operations.
    bool internal rngLockedFlag;

    /// @dev Tracks VRF lifecycle; true when no pending request exists.
    ///      Default true because at deploy, no request is outstanding.
    ///      Set false when requesting, true when fulfilled.
    ///
    ///      SECURITY: Works with rngLockedFlag to ensure RNG consistency.
    bool internal rngFulfilled = true;

    /// @dev True if initial trait counts were staged and await overwrite.
    ///      Used during level initialization to handle batched seeding.
    bool internal traitCountsSeedQueued;

    /// @dev True when level % 100 decimator special is primed and ready.
    ///      Milestone levels (100, 200, etc.) have special decimator rewards.
    bool internal decimatorHundredReady;

    /// @dev Toggles inversion of exterminator bonus on certain levels.
    ///      Adds variety to extermination mechanics across levels.
    bool internal exterminationInvertFlag;


    /// @dev Unified MAP jackpot pending type. Daily and purchase MAP jackpots are
    ///      mutually exclusive, so a single enum tracks which (if any) is queued:
    ///      0 = none, 1 = daily, 2 = purchase.
    ///      Timeout is computed on-the-fly from jackpotCounter >= JACKPOT_LEVEL_CAP.
    uint8 internal mapJackpotType;

    /// @dev Snapshot of how many daily jackpots ran in the level that just ended.
    ///      Used to scale the carryover extermination jackpot when the level ended early.
    uint8 internal lastLevelJackpotCount;


    // =========================================================================
    // SLOT 2: Mint Price
    // =========================================================================

    /// @dev Current price to mint one gamepiece, in wei.
    ///      uint128 supports up to ~340 undecillion wei (~3.4e20 ETH) — far
    ///      beyond any realistic price point.
    ///
    ///      Default 0.025 ether = 25 finney = initial launch price.
    ///
    ///      SECURITY: Price updates are game-controlled. uint128 prevents
    ///      overflow in multiplication with reasonable quantities.
    uint128 internal price = uint128(0.025 ether / ContractAddresses.COST_DIVISOR);

    // =========================================================================
    // SLOTS 3+: Full-Width Balances and Pools
    // =========================================================================
    // Each uint256 occupies its own 32-byte slot. These track ETH/token flows.

    /// @dev Prize pool snapshot from the previous level.
    ///      Used as denominator for early burn percentage calculations.
    ///      Bootstrap value of 125 ether (divided by COST_DIVISOR on testnet) ensures non-zero denominator at launch.
    ///
    ///      SECURITY: Never zero after initialization, preventing division by zero.
    uint256 internal lastPrizePool = 125 ether / ContractAddresses.COST_DIVISOR;

    /// @dev Active prize pool for the current level.
    ///      Accumulated from mint fees and distributed via jackpots.
    uint256 internal currentPrizePool;

    /// @dev Pre-funded prize pool for the next level.
    ///      Allows carryover mechanics and smooth level transitions.
    uint256 internal nextPrizePool;

    /// @dev Aggregate ETH available for rewards (jackpots, bonuses, etc.).
    ///      Funded by mint fees and managed by jackpot distribution logic.
    uint256 internal rewardPool;

    /// @dev Baseline ETH allocated per daily jackpot.
    ///      Set during calcPrizePoolForLevelJackpot; consumed by payDailyJackpot.
    ///      Escalating BPS (610-1225) applied per jackpot index.
    uint256 internal dailyJackpotBase;

    /// @dev Reserved pool for the level-100 decimator special reward.
    ///      Accumulated separately to ensure milestone payouts are funded.
    uint256 internal decimatorHundredPool;

    /// @dev Reserved pool for the BAF (Burn and Flip?) 100-level special.
    ///      Similar to decimatorHundredPool for a different milestone reward.
    uint256 internal bafHundredPool;

    /// @dev Latest VRF random word, or 0 if a request is pending.
    ///      Written by VRF callback; consumed by game logic for randomness.
    ///
    ///      SECURITY: 0 indicates pending state. Game logic checks rngFulfilled
    ///      flag rather than checking for non-zero to avoid edge cases.
    uint256 internal rngWordCurrent;

    /// @dev Last VRF request ID, used to match fulfillment callbacks.
    ///      Prevents processing stale or mismatched VRF responses.
    ///
    ///      SECURITY: Request ID matching prevents replay attacks on RNG.
    uint256 internal vrfRequestId;


    /// @dev Number of reverse flips purchased against current RNG word.
    ///      Tracks flip activity for jackpot sizing adjustments.
    uint256 internal totalFlipReversals;

    // =========================================================================
    // Minting and Airdrop Queues
    // =========================================================================

    /// @dev Queue of player addresses awaiting map gamepiece mints.
    ///      Processed in batches via airdropIndex cursor.
    ///      Dynamic array: length at slot N, data at keccak256(N).
    ///
    ///      SECURITY: Batched processing with gas budgeting prevents DoS.
    ///      Array growth is bounded by game mechanics (mint limits).
    address[] internal pendingMapMints;

    /// @dev Map gamepiece count owed per player, consumed during batch processing.
    ///      Decremented as airdrops are processed; reaches 0 when complete.
    ///
    ///      DESIGN: Separate from pendingMapMints to allow partial batching
    ///      within a single player's owed amount.
    mapping(address => uint32) internal playerMapMintsOwed;

    /// @dev Per-level exterminator addresses (key = level).
    ///      Records who performed the final extermination for each level.
    ///      Used for cosmetic/trophy purposes.
    mapping(uint24 => address) internal levelExterminators;

    // =========================================================================
    // Token State and Jackpot Mechanics
    // =========================================================================

    /// @dev ETH claimable by players from jackpot winnings.
    ///      Credited by jackpot logic; withdrawn via claim function.
    ///
    ///      SECURITY: Pull pattern — players withdraw their own funds.
    ///      Prevents reentrancy by separating credit from transfer.
    mapping(address => uint256) internal claimableWinnings;

    /// @dev Aggregate ETH liability across all claimableWinnings entries.
    ///      Used for solvency checks: game must hold >= claimablePool ETH.
    ///
    ///      INVARIANT: claimablePool == sum(claimableWinnings[*])
    ///      Maintained by crediting/debiting both in tandem.
    uint256 internal claimablePool;

    /// @dev Nested mapping: level -> trait ID (0-255) -> array of ticket holders.
    ///      Used for jackpot winner selection: random index into trait's array.
    ///
    ///      STRUCTURE: traitBurnTicket[level][traitId] = address[]
    ///      Each burn adds the burner's address, allowing duplicate entries
    ///      (more burns = more tickets = higher win probability).
    ///
    ///      STORAGE: Slot for mapping root, then:
    ///        - keccak256(level . slot) gives the 256-element array of arrays
    ///        - Each inner array has length at its slot, data at keccak256(slot)
    ///
    ///      SECURITY: Array growth bounded by total gamepiece supply per level.
    mapping(uint24 => address[][256]) internal traitBurnTicket;

    /// @dev Per-day trait hit counters used for jackpot trait selection.
    ///      Index layout: [0-7] symbols, [8-15] colors, [16-79] combined traits.
    ///      80 elements * 4 bytes = 320 bytes = 10 storage slots (packed).
    ///
    ///      SECURITY: Fixed-size array prevents unbounded growth.
    ///      uint32 per counter supports ~4B burns per trait per day.
    uint32[80] internal dailyBurnCount;

    /// @dev Remaining supply per trait ID (0-255).
    ///      Decremented on burns; used for extermination detection.
    ///      256 elements * 4 bytes = 1024 bytes = 32 storage slots (packed).
    ///
    ///      SECURITY: Fixed-size, bounded by initial supply seeding.
    uint32[256] internal traitRemaining;

    /// @dev Supply per trait ID at burn phase start.
    ///      Snapshot taken at mint→burn transition; used to calculate
    ///      map vs burn ticket splits for jackpot fairness.
    ///
    ///      SECURITY: Snapshot prevents manipulation during burn phase.
    uint32[256] internal traitStartRemaining;

    /// @dev Bit-packed mint history per player.
    ///      Layout defined by ETH_* constants in DegenerusGame:
    ///      - Tracks mint counts, bonuses, and eligibility flags.
    ///      - Single SLOAD/SSTORE for all mint-related player data.
    ///
    ///      SECURITY: Packing reduces gas and storage footprint.
    ///      Bit manipulation requires careful masking (done in DegenerusGame).
    mapping(address => uint256) internal mintPacked_;

    // =========================================================================
    // RNG History
    // =========================================================================

    /// @dev VRF random words keyed by dailyIdx.
    ///      0 means "not yet recorded" (no request fulfilled for that day).
    ///      Historical words enable verifiable replay of past randomness.
    ///
    ///      SECURITY: Immutable once written; provides audit trail for RNG.
    mapping(uint48 => uint256) internal rngWordByDay;

    // =========================================================================
    // Coinflip Statistics (Last Purchase Day)
    // =========================================================================

    /// @dev Total coinflip deposits during lastPurchaseDay = true (current level).
    ///      Used for jackpot sizing adjustments based on flip activity.
    uint256 internal lastPurchaseDayFlipTotal;

    /// @dev Previous level's lastPurchaseDay coinflip deposits.
    ///      Compared with current to detect activity trends (doubled/halved).
    ///      Affects reward pool retention percentage in jackpot calculations.
    uint256 internal lastPurchaseDayFlipTotalPrev;

    /// @dev MAP units for the pending MAP jackpot (slot 1).
    ///      For daily: units for current-level draw.
    ///      For purchase: the only units slot used.
    ///      Units are computed at scheduling time to avoid price drift.
    uint256 internal mapJackpotUnits1;

    /// @dev MAP units for the pending MAP jackpot (slot 2).
    ///      For daily: units for carryover (next-level) draw.
    ///      For purchase: unused (remains 0).
    uint256 internal mapJackpotUnits2;
}

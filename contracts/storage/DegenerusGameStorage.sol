// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DegenerusGameStorage
 * @notice Shared storage layout between the core game contract and its delegatecall modules.
 *         Centralizing slot definitions prevents layout drift; keep ordering stable across upgrades.
 *
 * Slot map:
 * - Slot 0: level timers + airdrop cursors + FSM (level / gameState)
 * - Slot 1: rebuild cursor + jackpot counters + decimator latch
 * - Slot 2: RNG / trait flags
 * - Slot 3: price (wei) + priceCoin (unit)
 * Everything else starts at slot 4+ (full-width balances, arrays, mappings).
 */
abstract contract DegenerusGameStorage {
    // ---------------------------------------------------------------------
    // Core packed state (slots 0-2)
    // ---------------------------------------------------------------------

    // Slot 0: level timing, airdrop batching, and the main FSM flags.
    uint48 internal levelStartTime = type(uint48).max; // timestamp when current level opened (sentinel max pre-start)
    uint48 internal dailyIdx; // monotonically increasing "day" counter derived from level start
    uint48 internal rngRequestTime; // when the last RNG request was fired (for timeout checks)
    uint32 internal airdropMapsProcessedCount; // maps handled within current airdrop batch
    uint32 internal airdropIndex; // index into pendingMapMints for batched airdrops
    uint24 public level = 1; // current level (1-indexed)
    uint16 internal lastExterminatedTrait = 420; // last trait cleared this level; 420 == TRAIT_ID_TIMEOUT sentinel
    uint8 public gameState = 1; // FSM: 0=idle,1=pregame,2=airdrop/mint,3=burn window

    // Slot 1: actor pointers and sub-state cursors.
    uint32 internal traitRebuildCursor; // progress cursor when reseeding trait counts
    uint32 internal airdropMultiplier; // airdrop bonus multiplier (scaled integer)
    uint8 internal jackpotCounter; // jackpots processed within the current level
    uint8 internal earlyBurnPercent; // % of previous prize pool carried into early burn reward (0-255)
    bool internal mapJackpotPaid; // true once the map jackpot has been executed for the current purchase phase
    bool internal lastPurchaseDay; // true once the map prize target is met; next tick skips daily/jackpot prep
    bool internal decWindowOpen = true; // latch to hold decimator window open until RNG is requested

    // Slot 2: RNG/trait flags.
    bool internal earlyBurnBoostArmed; // true if the next jackpot should apply the boost
    bool internal rngLockedFlag; // true while waiting for VRF fulfillment
    bool internal rngFulfilled = true; // tracks VRF lifecycle; default true pre-first request
    bool internal traitCountsSeedQueued; // true if initial trait counts were staged and await overwrite flag
    bool internal decimatorHundredReady; // true when level % 100 decimator special is primed
    bool internal exterminationInvertFlag; // toggles inversion of exterminator bonus on certain levels

    // ---------------------------------------------------------------------
    // Pricing, pooled balances, and treasury pointers
    // ---------------------------------------------------------------------

    // Slot 3: price (wei) + priceCoin (unit) packed into one word. Both capped well below uint128.
    uint128 internal price = 0.025 ether;
    uint128 internal priceCoin = 1_000_000_000;

    // Pooled balances (ETH/BURNIE and jackpots)
    uint256 internal lastPrizePool = 125 ether; // prize pool snapshot from the previous level
    uint256 internal currentPrizePool; // active prize pool for the current level
    uint256 internal nextPrizePool; // pre-funded prize pool for the next level
    uint256 internal rewardPool; // aggregate ETH available for rewards
    uint256 internal dailyJackpotBase; // baseline ETH allocated per daily jackpot
    uint256 internal decimatorHundredPool; // reserved pool for the level-100 decimator special
    uint256 internal bafHundredPool; // reserved pool for the BAF 100-level special
    uint256 internal rngWordCurrent; // latest VRF word (or 0 if pending)
    uint256 internal vrfRequestId; // last VRF request id used to match fulfillments
    uint256 internal bondPool; // ETH dedicated to bond obligations (lives in game unless gameOver flushes to bonds)
    uint256 internal totalFlipReversals; // number of reverse flips purchased against current RNG

    // External sinks and lifecycle flags
    uint48 public deployTimestamp; // deployment timestamp for long-tail inactivity guard
    address internal bonds; // bonds contract wired once post-deploy
    address internal vault; // reward vault for BURNIE/ETH/stETH routing
    bool internal bondGameOver; // true once bondPool has been flushed to bonds for direct claims

    // ---------------------------------------------------------------------
    // Minting / airdrops
    // ---------------------------------------------------------------------
    address[] internal pendingMapMints; // queue of players awaiting map mints
    mapping(address => uint32) internal playerMapMintsOwed; // map NFT count owed per player (consumed during batching)
    address[] internal levelExterminators; // per-level exterminator (index = level-1)

    // ---------------------------------------------------------------------
    // Token / trait state
    // ---------------------------------------------------------------------
    mapping(address => uint256) internal claimableWinnings; // ETH claimable by players
    uint256 internal claimablePool; // aggregate ETH owed via claimableWinnings
    mapping(uint24 => address[][256]) internal traitBurnTicket; // level -> trait id -> ticket owner list
    uint32[80] internal dailyBurnCount; // per-day trait hit counters used for jackpot selection
    uint32[256] internal traitRemaining; // remaining supply per trait id
    uint32[256] internal traitStartRemaining; // supply per trait id at burn start (map/burn ticket split)
    mapping(address => uint256) internal mintPacked_; // bit-packed mint history (see DegenerusGame ETH_* constants for layout)

    // ---------------------------------------------------------------------
    // Bond maintenance
    // ---------------------------------------------------------------------
    bool internal bondMaintenancePending; // true while bond maintenance needs dedicated advanceGame calls

    // ---------------------------------------------------------------------
    // RNG history
    // ---------------------------------------------------------------------
    mapping(uint48 => uint256) internal rngWordByDay; // VRF words keyed by dailyIdx; 0 means "not yet recorded"

    // ---------------------------------------------------------------------
    // Cosmetic trophies
    // ---------------------------------------------------------------------
    address internal trophies; // standalone trophy contract (purely cosmetic)
    address internal affiliateProgramAddr; // cached affiliate program (for trophies)

    // ---------------------------------------------------------------------
    // Coinflip deposit tracking (last purchase day)
    // ---------------------------------------------------------------------
    uint256 internal lastPurchaseDayFlipTotal; // coinflip deposits while lastPurchaseDay is true (current level)
    uint256 internal lastPurchaseDayFlipTotalPrev; // previous level's lastPurchaseDay coinflip deposits
}

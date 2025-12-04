// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct PendingJackpotBondMint {
    uint96 basePerBondWei; // win-odds base per bond (capped at 0.5 ETH)
    uint16 cursor; // how many recipients have been minted from this batch
    uint16 quantity; // total bonds to mint for this batch
    uint16 offset; // rotation offset into winners when deriving recipients
    bool stake; // whether bonds should be staked/soulbound
    address[] winners; // jackpot winners used to derive bond recipients (keeps ordering deterministic)
}

struct ClaimableBondInfo {
    uint128 weiAmount; // ETH value earmarked for bonds (capped to keep struct in one slot)
    uint96 basePerBondWei; // preferred base per bond (0 defaults to 0.5 ether)
    bool stake; // whether bonds should be staked/soulbound
}

/**
 * @title PurgeGameStorage
 * @notice Shared storage layout between the core game contract and its delegatecall modules.
 *         Keeping all slot definitions in a single contract prevents layout drift.
 *
 * Storage layout summary (slots 0-3):
 * - Slot 0: level timers + airdrop cursors + FSM (level / gameState)
 * - Slot 1: rebuild cursor + jackpot counters + decimator latch
 * - Slot 2: RNG / trait flags (pricing and other scalars pack after the flag block)
 * Everything else starts at slot 4+ (full-width balances, arrays, mappings).
 */
abstract contract PurgeGameStorage {
    // ---------------------------------------------------------------------
    // Packed core state (slots 0-2)
    // ---------------------------------------------------------------------

    // Slot 0: level timing, airdrop batching, and the main FSM flags.
    uint48 internal levelStartTime = type(uint48).max; // timestamp when current level opened (sentinel max pre-start)
    uint48 internal dailyIdx; // monotonically increasing "day" counter derived from level start
    uint48 internal rngRequestTime; // when the last RNG request was fired (for timeout checks)
    uint32 internal airdropMapsProcessedCount; // maps handled within current airdrop batch
    uint32 internal airdropIndex; // index into pendingMapMints for batched airdrops
    uint24 public level = 1; // current level (1-indexed)
    uint16 internal lastExterminatedTrait = 420; // last trait purged this level; 420 == TRAIT_ID_TIMEOUT sentinel
    uint8 public gameState = 1; // FSM: 0=idle,1=pregame,2=airdrop/mint,3=purge window

    // Slot 1: actor pointers and sub-state cursors.
    uint32 internal traitRebuildCursor; // progress cursor when reseeding trait counts
    uint32 internal airdropMultiplier = 1; // airdrop bonus multiplier (scaled integer)
    uint8 internal jackpotCounter; // jackpots processed within the current level
    uint8 internal earlyPurgePercent; // % of previous prize pool carried into early purge reward (0-255)
    bool internal mapJackpotPaid; // true once the map jackpot has been executed for the current purchase phase
    bool internal lastPurchaseDay; // true once the map prize target is met; next tick skips daily/jackpot prep
    bool internal decWindowOpen = true; // latch to hold decimator window open until RNG is requested

    // Slot 2: RNG/trait flags + stETH address.
    bool internal earlyPurgeBoostArmed; // true if the next jackpot should apply the boost
    bool internal rngLockedFlag; // true while waiting for VRF fulfillment
    bool internal rngFulfilled = true; // tracks VRF lifecycle; default true pre-first request
    bool internal traitCountsSeedQueued; // true if initial trait counts were staged and await overwrite flag
    bool internal decimatorHundredReady; // true when level % 100 decimator special is primed
    bool internal exterminationInvertFlag; // toggles inversion of exterminator bonus on certain levels

    // ---------------------------------------------------------------------
    // Pricing and pooled balances
    // ---------------------------------------------------------------------

    // Slot 3: price (wei) + priceCoin (unit) packed into one word. Both capped well below uint128.
    uint128 internal price = 0.025 ether;
    uint128 internal priceCoin = 1_000_000_000;

    uint256 internal lastPrizePool = 125 ether; // prize pool snapshot from the previous level
    uint256 internal currentPrizePool; // active prize pool for the current level
    uint256 internal nextPrizePool; // pre-funded prize pool for the next level
    uint256 internal rewardPool; // aggregate ETH available for rewards
    uint256 internal dailyJackpotBase; // baseline ETH allocated per daily jackpot
    uint256 internal decimatorHundredPool; // reserved pool for the level-100 decimator special
    uint256 internal bafHundredPool; // reserved pool for the BAF 100-level special
    uint256 internal rngWordCurrent; // latest VRF word (or 0 if pending)
    uint256 internal vrfRequestId; // last VRF request id used to match fulfillments
    uint256 internal totalFlipReversals; // number of reverse flips purchased against current RNG
    uint256 internal principalStEth; // stETH principal the contract has staked
    uint48 public deployTimestamp; // deployment timestamp for long-tail inactivity guard
    uint48 internal shutdownRngRequestDay; // day index used when requesting RNG during shutdown/idle drain

    // ---------------------------------------------------------------------
    // Minting / airdrops
    // ---------------------------------------------------------------------
    address[] internal pendingMapMints; // queue of players awaiting map mints
    mapping(address => uint32) internal playerMapMintsOwed; // map NFT count owed per player (consumed during batching)
    address[] internal levelExterminators; // per-level exterminator (index = level-1)
    mapping(uint24 => bool) internal levelExterminatorPaid; // tracks whether exterminator payout was already processed

    // ---------------------------------------------------------------------
    // Token / trait state
    // ---------------------------------------------------------------------
    mapping(address => uint256) internal claimableWinnings; // ETH claimable by players
    mapping(uint24 => address[][256]) internal traitPurgeTicket; // level -> trait id -> ticket owner list
    uint32[80] internal dailyPurgeCount; // per-day trait hit counters used for jackpot selection
    uint32[256] internal traitRemaining; // remaining supply per trait id
    mapping(address => uint256) internal mintPacked_; // bit-packed mint history (see PurgeGame ETH_* constants for layout)

    // Bond maintenance state
    uint24 internal lastBondFundingLevel; // tracks the last level where bond funding was performed
    uint48 internal lastBondResolutionDay; // last day index that auto bond resolution ran
    uint256 internal bondCreditEscrow; // ETH escrowed to back bond-credit prize funding
    mapping(address => bool) internal autoBondLiquidate; // opt-in flag to auto-liquidate bond credits into winnings

    // ---------------------------------------------------------------------
    // RNG history
    // ---------------------------------------------------------------------
    mapping(uint48 => uint256) internal rngWordByDay; // VRF words keyed by dailyIdx; 0 means "not yet recorded"

    // ---------------------------------------------------------------------
    // Bond credits (non-withdrawable)
    // ---------------------------------------------------------------------
    mapping(address => uint256) internal bondCredit; // Credit from bond sales that can be spent on mints

    // ---------------------------------------------------------------------
    // Jackpot bond batching (deferred minting for gas safety)
    // ---------------------------------------------------------------------
    PendingJackpotBondMint[] internal pendingJackpotBondMints; // queued bond batches funded by jackpots
    uint256 internal pendingJackpotBondCursor; // cursor into pendingJackpotBondMints for incremental processing
    mapping(address => ClaimableBondInfo) internal claimableBondInfo; // per-player bond credits (only spendable on bonds)

    // ---------------------------------------------------------------------
    // Cosmetic trophies
    // ---------------------------------------------------------------------
    address internal trophies; // standalone trophy contract (purely cosmetic)
    address internal affiliateProgramAddr; // cached affiliate program (for trophies)
}

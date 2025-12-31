// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IDegenerusQuests.sol";
import "./interfaces/IDegenerusGame.sol";

/**
 * @title DegenerusQuests
 * @author Burnie Degenerus
 * @notice Tracks two rotating daily quests and validates player progress against Degenerus game actions.
 *
 * @dev Architecture Overview
 * ─────────────────────────────────────────────────────────────────────────────
 * This contract operates as an external standalone contract (NOT delegatecall)
 * called by the Degenerus coin contract. It manages:
 *   1. Daily quest rolling using VRF entropy
 *   2. Per-player progress tracking with version-gated resets
 *   3. Streak accounting with tier-based reward scaling
 *
 * Security Model
 * ─────────────────────────────────────────────────────────────────────────────
 * • All player-action handlers are coin-gated via `onlyCoin` modifier
 * • Quest normalization allows coin OR game to trigger via `onlyCoinOrGame`
 * • Admin-only `wire()` for one-time game address binding
 * • No external calls to untrusted contracts — only reads trusted `questGame`
 * • No ETH handling or callbacks — reentrancy is not a concern
 *
 * Quest Lifecycle
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. Coin calls `rollDailyQuest()` with VRF entropy at day transition
 * 2. Two quest slots are seeded with weighted random types and difficulty flags
 * 3. Player actions trigger handle* functions (handleMint, handleFlip, etc.)
 * 4. Progress accumulates until target is met; completion updates streak
 * 5. Both slots must complete for streak credit (prevents partial farming)
 *
 * Progress Versioning
 * ─────────────────────────────────────────────────────────────────────────────
 * Each quest has a monotonic `version` field. When a quest mutates mid-day
 * (e.g., burn quest converts to mint when burning is disabled), the version
 * bumps and stale player progress is automatically reset via `_questSyncProgress`.
 *
 * Streak & Tier System
 * ─────────────────────────────────────────────────────────────────────────────
 * • Streaks increment only when BOTH slots complete on a day
 * • Tiers (0-2) are derived from streak in spans of 10
 * • Higher tiers unlock higher quest targets but also better rewards
 * • Missing a day resets streak to zero
 */
contract DegenerusQuests is IDegenerusQuests {
    // =========================================================================
    //                              CUSTOM ERRORS
    // =========================================================================

    /// @dev Thrown when caller is not the authorized coin contract.
    error OnlyCoin();
    /// @dev Thrown when caller is not the admin address.
    error OnlyAdmin();
    /// @dev Thrown when attempting to re-wire the game address.
    error AlreadyWired();
    /// @dev Thrown when quest day is invalid (unused in current impl but reserved).
    error InvalidQuestDay();
    /// @dev Thrown when entropy value is invalid (unused in current impl but reserved).
    error InvalidEntropy();
    /// @dev Thrown when a zero address is passed to constructor.
    error ZeroAddress();

    // =========================================================================
    //                              CONSTANTS
    // =========================================================================

    // ─────────────────────────────────────────────────────────────────────────
    // Unit Conversions
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev 1 million base units — BURNIE has 6 decimals, so 1e6 = 1 BURNIE.
    uint256 private constant MILLION = 1e6;

    /// @dev Price unit for reward calculations (1000 BURNIE in base units).
    uint256 private constant PRICE_COIN_UNIT = 1_000_000_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Quest Type Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Number of concurrent quest slots per day.
    uint8 private constant QUEST_SLOT_COUNT = 2;

    /// @dev Quest type: mint NFTs using BURNIE tokens.
    uint8 private constant QUEST_TYPE_MINT_BURNIE = 0;
    /// @dev Quest type: mint NFTs using ETH.
    uint8 private constant QUEST_TYPE_MINT_ETH = 1;
    /// @dev Quest type: stake BURNIE in the coinflip mechanism.
    uint8 private constant QUEST_TYPE_FLIP = 2;
    /// @dev Quest type: earn affiliate commissions.
    uint8 private constant QUEST_TYPE_AFFILIATE = 3;
    /// @dev Quest type: burn NFTs (only available in burn game state).
    uint8 private constant QUEST_TYPE_BURN = 4;
    /// @dev Quest type: participate in decimator burns.
    uint8 private constant QUEST_TYPE_DECIMATOR = 5;
    /// @dev Quest type: purchase bonds.
    uint8 private constant QUEST_TYPE_BOND = 6;
    /// @dev Total number of quest types for iteration bounds.
    uint8 private constant QUEST_TYPE_COUNT = 7;

    // ─────────────────────────────────────────────────────────────────────────
    // Difficulty Flags (packed into quest.flags)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Flag indicating high difficulty (rolled > 500/1024).
    uint8 private constant QUEST_FLAG_HIGH_DIFFICULTY = 1 << 0;
    /// @dev Flag indicating very high difficulty (rolled > 750/1024).
    uint8 private constant QUEST_FLAG_VERY_HIGH_DIFFICULTY = 1 << 1;

    // ─────────────────────────────────────────────────────────────────────────
    // Streak & Tier Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Maximum tier index (0, 1, 2 = three tiers).
    uint8 private constant QUEST_TIER_MAX_INDEX = 2;
    /// @dev Number of consecutive days per tier upgrade (streak / 10 = tier).
    uint32 private constant QUEST_TIER_STREAK_SPAN = 10;
    /// @dev Bitmask for completed slots (0b11 for 2 slots).
    uint8 private constant QUEST_STATE_COMPLETED_SLOTS_MASK = (uint8(1) << QUEST_SLOT_COUNT) - 1;
    /// @dev Flag bit indicating streak was already credited this day.
    uint8 private constant QUEST_STATE_STREAK_CREDITED = 1 << 7;

    // ─────────────────────────────────────────────────────────────────────────
    // Quest Target Minimums
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Minimum token target for affiliate/general quests (250 BURNIE).
    uint16 private constant QUEST_MIN_TOKEN = 250;
    /// @dev Minimum flip stake target (1000 BURNIE).
    uint16 private constant QUEST_MIN_FLIP_STAKE_TOKEN = 1_000;
    /// @dev Level boundary for special decimator quest availability.
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;

    // =========================================================================
    //                           IMMUTABLE ADDRESSES
    // =========================================================================

    /// @notice The coin contract authorized to drive quest logic.
    /// @dev Set at construction; all handle* functions require msg.sender == coin.
    address public immutable coin;

    /// @notice The admin address authorized for one-time wiring.
    address public immutable admin;

    // =========================================================================
    //                              STATE VARIABLES
    // =========================================================================

    /// @dev Reference to the Degenerus game contract for state queries.
    ///      Set via `wire()` and cannot be changed after initial binding.
    IDegenerusGame private questGame;

    // =========================================================================
    //                                 STRUCTS
    // =========================================================================

    /**
     * @notice Definition of a quest that is active for the current day.
     * @dev Stored in the `activeQuests` array (one per slot).
     *
     * Layout (memory):
     * ┌─────────────┬──────────┬───────┬─────────┬─────────────────────────────┐
     * │ day (48b)   │ type(8b) │ flags │ version │ entropy (256b full word)    │
     * └─────────────┴──────────┴───────┴─────────┴─────────────────────────────┘
     *
     * Version Semantics:
     * - Increments when quest is first seeded each day
     * - Increments again if quest type converts mid-day (burn → mint)
     * - Player progress is invalidated when version mismatches
     */
    struct DailyQuest {
        uint48 day;       // Quest day identifier (derived by caller, not block timestamp)
        uint8 questType;  // One of the QUEST_TYPE_* constants
        uint8 flags;      // Difficulty flags (HIGH/VERY_HIGH)
        uint32 version;   // Bumped when quest mutates mid-day to reset stale player progress
        uint256 entropy;  // VRF-derived entropy used for targets and difficulty flags
    }

    /**
     * @notice Progress and streak bookkeeping per player.
     * @dev Stored per-player in `questPlayerState` mapping.
     *
     * Streak Mechanics:
     * - `streak` increments only when BOTH slots complete on a day
     * - `baseStreak` snapshots streak at day start for consistent tier calculation
     * - `lastActiveDay` tracks any slot completion (not just full completion)
     * - Missing a day (gap > 1 between lastActiveDay and currentDay) resets streak
     *
     * Progress Versioning:
     * - `lastProgressDay[slot]` and `lastQuestVersion[slot]` must match active quest
     * - Mismatch triggers automatic progress reset via `_questSyncProgress`
     *
     * Completion Mask Layout:
     * ┌─────────────────────────────────┬─────────┬─────────┐
     * │ bit 7: STREAK_CREDITED          │ bit 1   │ bit 0   │
     * │ (prevents double streak credit) │ slot 1  │ slot 0  │
     * └─────────────────────────────────┴─────────┴─────────┘
     */
    struct PlayerQuestState {
        uint32 lastCompletedDay;                    // Last day where BOTH quests completed
        uint32 lastActiveDay;                       // Last day where ANY quest slot completed
        uint32 streak;                              // Current streak of days with full completion
        uint32 baseStreak;                          // Snapshot of streak at start of day (for rewards)
        uint32 lastSyncDay;                         // Day we last reset progress/completionMask
        uint32[QUEST_SLOT_COUNT] lastProgressDay;   // Per-slot: day when progress was recorded
        uint32[QUEST_SLOT_COUNT] lastQuestVersion;  // Per-slot: quest version when progress was recorded
        uint128[QUEST_SLOT_COUNT] progress;         // Per-slot: accumulated progress toward targets
        uint8 completionMask;                       // Bits 0-1: slot completion; bit 7: streak credited
    }

    // =========================================================================
    //                              QUEST STORAGE
    // =========================================================================

    /// @dev Active quests for the current day (indexed by slot 0/1).
    DailyQuest[QUEST_SLOT_COUNT] private activeQuests;

    /// @dev Per-player quest state including progress and streak.
    mapping(address => PlayerQuestState) private questPlayerState;

    // ─────────────────────────────────────────────────────────────────────────
    // Packed Target Tables
    // ─────────────────────────────────────────────────────────────────────────
    // These constants encode per-tier maximum targets as 16-bit values packed
    // into a uint256. Tier 0 occupies bits [0:15], tier 1 [16:31], etc.
    // Use `_questPackedValue(packed, tier)` to extract.

    /// @dev Packed flip stake maximums per tier (in BURNIE tokens, not base units).
    uint256 private constant QUEST_FLIP_PACKED = 0x000000000000000000000dac0ce40c1c0b540a8c09c408fc0834076c06a405dc;

    /// @dev Packed affiliate earning maximums per tier (in BURNIE tokens).
    uint256 private constant QUEST_AFFILIATE_PACKED =
        0x00000000000000000000060e060e060e060e060e060e04e203e80320028a01f4;

    /// @dev Monotonically increasing version counter for quest invalidation.
    uint32 private questVersionCounter = 1;

    // =========================================================================
    //                              CONSTRUCTOR
    // =========================================================================

    /**
     * @notice Deploys the quest contract with immutable coin and admin references.
     * @param coin_ Coin contract authorized to drive quest logic (all handle* calls).
     * @param admin_ Admin address authorized to wire the game contract.
     * @dev Both addresses are immutable after deployment. The game contract must
     *      be wired separately via `wire()` to complete initialization.
     */
    constructor(address coin_, address admin_) {
        if (coin_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        coin = coin_;
        admin = admin_;
    }

    // =========================================================================
    //                              MODIFIERS
    // =========================================================================

    /// @dev Restricts access to the authorized coin contract only.
    modifier onlyCoin() {
        if (msg.sender != coin) revert OnlyCoin();
        _;
    }

    /// @dev Restricts access to coin or game contract (for quest normalization).
    modifier onlyCoinOrGame() {
        address sender = msg.sender;
        if (sender != coin && sender != address(questGame)) revert OnlyCoin();
        _;
    }

    /// @dev Restricts access to the admin address only.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // =========================================================================
    //                           ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Wire the Degenerus game contract reference.
     * @param addresses Array where addresses[0] is the game contract.
     * @dev Set-once pattern: reverts with AlreadyWired if called again with a
     *      different address. Safe to call multiple times with the same address.
     */
    function wire(address[] calldata addresses) external onlyAdmin {
        _setGame(addresses.length > 0 ? addresses[0] : address(0));
    }

    /// @dev Internal setter for game address with set-once protection.
    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(questGame);
        if (current == address(0)) {
            questGame = IDegenerusGame(gameAddr);
        } else if (gameAddr != current) {
            revert AlreadyWired();
        }
    }

    // =========================================================================
    //                         QUEST ROLLING (COIN-ONLY)
    // =========================================================================

    /**
     * @notice Roll the daily quest set using VRF entropy.
     * @param day Quest day identifier (monotonicity enforced by caller).
     * @param entropy VRF entropy word; second slot reuses swapped halves.
     * @return rolled Always true on success.
     * @return questTypes The two quest types rolled [slot0, slot1].
     * @return highDifficulty True if difficulty roll exceeded threshold.
     *
     * @dev Entropy Usage:
     * - Slot 0 uses `entropy` directly for type selection and targets
     * - Slot 1 uses `(entropy >> 128) | (entropy << 128)` (swapped halves)
     * - Difficulty flags are derived once from `entropy & 0x3FF` and shared
     */
    function rollDailyQuest(
        uint48 day,
        uint256 entropy
    ) external onlyCoin returns (bool rolled, uint8[2] memory questTypes, bool highDifficulty) {
        return _rollDailyQuest(day, entropy, false, false);
    }

    /**
     * @notice Roll quests with optional overrides for testing/admin controls.
     * @param day Quest day identifier.
     * @param entropy VRF entropy word.
     * @param forceMintEth If true, slot 0 is forced to MINT_ETH type.
     * @param forceBurn If true, slot 1 is forced to BURN type (overrides game state check).
     * @dev Overrides are useful for ensuring specific quest types appear during testing
     *      or when admin wants to guarantee certain quests are available.
     */
    function rollDailyQuestWithOverrides(
        uint48 day,
        uint256 entropy,
        bool forceMintEth,
        bool forceBurn
    ) external onlyCoin returns (bool rolled, uint8[2] memory questTypes, bool highDifficulty) {
        return _rollDailyQuest(day, entropy, forceMintEth, forceBurn);
    }

    /**
     * @notice Normalize active quests when burning becomes disallowed mid-day.
     * @dev Called when game transitions out of burn state (e.g., extermination).
     *      Converts any active BURN quests to MINT_ETH or AFFILIATE, bumping
     *      version to invalidate stale player progress.
     *
     * Conversion Logic:
     * - If the OTHER slot is MINT_ETH → convert to AFFILIATE
     * - Otherwise → convert to MINT_ETH
     * This ensures the two slots never have duplicate types.
     */
    function normalizeActiveBurnQuests() external onlyCoinOrGame {
        DailyQuest[QUEST_SLOT_COUNT] storage quests = activeQuests;
        bool burnAllowed = _canRollBurnQuest(quests[0].day != 0 ? quests[0].day : quests[1].day);
        if (burnAllowed) return;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest storage quest = quests[slot];
            if (quest.questType == QUEST_TYPE_BURN) {
                _convertBurnQuest(quests, slot);
            }
            unchecked {
                ++slot;
            }
        }
    }

    /**
     * @dev Internal quest rolling logic shared by public entry points.
     *
     * Flow:
     * 1. Check game state for burn/decimator quest eligibility
     * 2. Generate primary quest type via weighted random selection
     * 3. Generate bonus quest type (distinct from primary)
     * 4. Derive shared difficulty flags from entropy
     * 5. Seed both quest slots with types, entropy, and versioning
     */
    function _rollDailyQuest(
        uint48 day,
        uint256 entropy,
        bool forceMintEth,
        bool forceBurn
    ) private returns (bool rolled, uint8[2] memory questTypes, bool highDifficulty) {
        DailyQuest[QUEST_SLOT_COUNT] storage quests = activeQuests;
        bool burnAllowed = _canRollBurnQuest(day) || forceBurn;
        bool decAllowed = _canRollDecimatorQuest();

        uint256 primaryEntropy = entropy;
        // Swap 128-bit halves to derive independent entropy for slot 1
        uint256 bonusEntropy = (entropy >> 128) | (entropy << 128);

        uint8 primaryType = forceMintEth ? QUEST_TYPE_MINT_ETH : _primaryQuestType(primaryEntropy, burnAllowed, decAllowed);
        uint8 bonusType = forceBurn
            ? QUEST_TYPE_BURN
            : _bonusQuestType(bonusEntropy, primaryType, burnAllowed, decAllowed);

        // Single difficulty roll per day, shared by both slots for consistency
        uint8 flags = _difficultyFlags(uint16(primaryEntropy & 0x3FF));
        _seedQuestType(quests[0], day, primaryEntropy, primaryType, flags);
        _seedQuestType(quests[1], day, bonusEntropy, bonusType, flags);

        questTypes[0] = quests[0].questType;
        questTypes[1] = quests[1].questType;
        highDifficulty = (flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        return (true, questTypes, highDifficulty);
    }

    // =========================================================================
    //                      PROGRESS HANDLERS (COIN-ONLY)
    // =========================================================================
    // All handle* functions follow a common pattern:
    // 1. Early-exit if player/amount invalid or no active quest day
    // 2. Sync player state (reset streak if day missed, snapshot baseStreak)
    // 3. Find matching quest slot for the action type
    // 4. Sync slot progress (reset if day/version changed)
    // 5. Accumulate progress and check against tier-adjusted target
    // 6. On completion, credit rewards and check if other slot also completes
    //
    // Return values are consistent across all handlers:
    // - reward: BURNIE tokens to credit (in base units, 6 decimals)
    // - hardMode: True if quest had high difficulty flag
    // - questType: The type of quest that was processed
    // - streak: Player's current streak after this action
    // - completed: True if a quest was completed by this action

    /**
     * @notice Handle mint progress for a player; covers both BURNIE and ETH paid mints.
     * @param player The player who performed the mint.
     * @param quantity Number of NFTs minted.
     * @param paidWithEth True if ETH was used (MINT_ETH quest), false for BURNIE (MINT_BURNIE).
     * @dev Iterates both slots since both could theoretically match (though in practice
     *      the rolling logic ensures only one slot has each mint type).
     */
    function handleMint(
        address player,
        uint32 quantity,
        bool paidWithEth
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }

        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        uint256 priceUnit = PRICE_COIN_UNIT;
        bool matched;
        bool aggregatedCompleted;
        bool aggregatedHardMode;
        uint8 fallbackType = quests[0].questType;
        uint8 aggregatedQuestType = fallbackType;
        uint32 aggregatedStreak = state.streak;
        uint256 aggregatedReward;

        // Check both slots for matching mint quest type
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            if (
                (!paidWithEth && quest.questType == QUEST_TYPE_MINT_BURNIE) ||
                (paidWithEth && quest.questType == QUEST_TYPE_MINT_ETH)
            ) {
                matched = true;
                fallbackType = quest.questType;
                (reward, hardMode, questType, streak, completed) = _questHandleMintSlot(
                    state,
                    quests,
                    quest,
                    slot,
                    quantity,
                    tier,
                    priceUnit
                );
                if (completed) {
                    aggregatedReward += reward;
                    aggregatedQuestType = questType;
                    aggregatedStreak = streak;
                    aggregatedCompleted = true;
                    if (hardMode) {
                        aggregatedHardMode = true;
                    }
                }
            }
            unchecked {
                ++slot;
            }
        }
        if (aggregatedCompleted) {
            return (aggregatedReward, aggregatedHardMode, aggregatedQuestType, aggregatedStreak, true);
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_MINT_BURNIE, state.streak, false);
    }

    /**
     * @notice Handle flip/unstake progress credited in BURNIE base units (6 decimals).
     * @param player The player who staked/unstaked.
     * @param flipCredit Amount of BURNIE staked/unstaked (in base units).
     * @dev Progress tracks cumulative flip volume for the day.
     */
    function handleFlip(
        address player,
        uint256 flipCredit
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || flipCredit == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_FLIP);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_FLIP, state.streak, false);
        }

        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        uint8 tier = _questTier(state.baseStreak);
        uint128 progressAfter = _clampedAdd128(state.progress[slotIndex], flipCredit);
        state.progress[slotIndex] = progressAfter;
        uint256 target = uint256(_questFlipTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        if (progressAfter < target) {
            return (0, false, quest.questType, state.streak, false);
        }

        uint256 priceUnit = PRICE_COIN_UNIT;
        return _questCompleteWithPair(state, quests, slotIndex, quest, priceUnit, 0);
    }

    /**
     * @notice Handle decimator burns counted in BURNIE base units (6 decimals).
     * @param player The player who performed the decimator burn.
     * @param burnAmount Amount of BURNIE burned (in base units).
     * @dev Decimator quests have 2x the target of equivalent flip quests.
     */
    function handleDecimator(
        address player,
        uint256 burnAmount
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || burnAmount == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = PRICE_COIN_UNIT;

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_DECIMATOR);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_DECIMATOR, state.streak, false);
        }
        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        state.progress[slotIndex] = _clampedAdd128(state.progress[slotIndex], burnAmount);
        uint256 target = uint256(_questDecimatorTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        if (state.progress[slotIndex] < target) {
            return (0, false, quest.questType, state.streak, false);
        }
        return _questCompleteWithPair(state, quests, slotIndex, quest, priceUnit, 0);
    }

    /**
     * @notice Handle bond purchases tracked by the base-per-bond size (wei).
     * @param player The player who purchased bonds.
     * @param basePerBondWei ETH value per bond purchased (in wei).
     * @dev Bond quests are only available during specific level windows.
     *      Target is dynamically calculated based on current mint price.
     */
    function handleBondPurchase(
        address player,
        uint256 basePerBondWei
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || basePerBondWei == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);

        // Bond purchases are only valid during specific level windows
        IDegenerusGame game_ = questGame;
        if (!_bondPurchasesOpen(game_.level())) {
            return (0, false, quests[0].questType, state.streak, false);
        }

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_BOND);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_BOND, state.streak, false);
        }

        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = PRICE_COIN_UNIT;
        uint256 priceWei = game_.mintPrice();
        if (priceUnit == 0 || priceWei == 0) {
            return (0, false, quest.questType, state.streak, false);
        }

        state.progress[slotIndex] = _clampedAdd128(state.progress[slotIndex], basePerBondWei);
        uint256 target = _questBondTargetWei(tier, quest.flags, quest.entropy, priceWei);
        if (state.progress[slotIndex] < target) {
            return (0, false, quest.questType, state.streak, false);
        }
        return _questCompleteWithPair(state, quests, slotIndex, quest, priceUnit, priceWei);
    }

    /**
     * @notice Handle affiliate earnings credited in BURNIE base units (6 decimals).
     * @param player The affiliate who earned commission.
     * @param amount BURNIE earned from affiliate referrals (in base units).
     */
    function handleAffiliate(
        address player,
        uint256 amount
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || amount == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = PRICE_COIN_UNIT;

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_AFFILIATE);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_AFFILIATE, state.streak, false);
        }
        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        state.progress[slotIndex] = _clampedAdd128(state.progress[slotIndex], amount);
        uint256 target = uint256(_questAffiliateTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        if (state.progress[slotIndex] < target) {
            return (0, false, quest.questType, state.streak, false);
        }
        return _questCompleteWithPair(state, quests, slotIndex, quest, priceUnit, 0);
    }

    /**
     * @notice Handle burn quest progress in whole NFTs.
     * @param player The player who burned NFTs.
     * @param quantity Number of NFTs burned.
     * @dev Burn quests are only available when game is in burn state (gameState == 3).
     *      Uses the same target calculation as mint quests (small integer targets).
     */
    function handleBurn(
        address player,
        uint32 quantity
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || quantity == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = PRICE_COIN_UNIT;

        bool matched;
        uint8 fallbackType = quests[0].questType;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay || quest.questType != QUEST_TYPE_BURN) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            matched = true;
            fallbackType = quest.questType;
            _questSyncProgress(state, slot, currentDay, quest.version);
            state.progress[slot] = _clampedAdd128(state.progress[slot], quantity);
            uint32 target = _questMintTarget(tier, quest.flags, quest.entropy);
            if (state.progress[slot] >= target) {
                return _questCompleteWithPair(state, quests, slot, quest, priceUnit, 0);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_BURN, state.streak, false);
    }

    // =========================================================================
    //                            VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice View helper for frontends; returns quest baselines at tier zero.
     * @return quests Array of QuestInfo structs with type, day, difficulty, and requirements.
     * @dev Uses tier 0 (streak = 0) for baseline requirements. Frontends should use
     *      `getPlayerQuestView` for player-specific tier-adjusted requirements.
     *
     * Note: Burn quests are downgraded to MINT_ETH/AFFILIATE in the returned view
     * when the game is not in burn state, matching the UI behavior.
     */
    function getActiveQuests() external view override returns (QuestInfo[2] memory quests) {
        DailyQuest[QUEST_SLOT_COUNT] memory local = _materializeActiveQuestsForView();
        uint48 currentDay = _currentQuestDay(local);
        PlayerQuestState memory emptyState;
        uint8 baseTier = 0;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            (quests[slot], , ) = _questViewData(local[slot], emptyState, slot, baseTier, currentDay);
            unchecked {
                ++slot;
            }
        }
    }

    /**
     * @dev Returns active quests, downgrading burn slots in-memory when burning is not allowed.
     *
     * This is a VIEW-ONLY transformation. The storage `activeQuests` is never modified here.
     * The actual storage-level conversion happens via `normalizeActiveBurnQuests()` when
     * the game state changes.
     *
     * Downgrade Logic:
     * - If slot has BURN quest but burning is disabled → convert to MINT_ETH
     * - Unless other slot already has MINT_ETH → then convert to AFFILIATE
     */
    function _materializeActiveQuestsForView() private view returns (DailyQuest[QUEST_SLOT_COUNT] memory local) {
        local = activeQuests;
        bool burnAllowed = _canRollBurnQuest(_currentQuestDay(local));
        if (burnAllowed) return local;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            if (local[slot].questType == QUEST_TYPE_BURN) {
                uint8 otherSlot = slot == 0 ? uint8(1) : uint8(0);
                bool otherMintEth = local[otherSlot].questType == QUEST_TYPE_MINT_ETH;
                local[slot].questType = otherMintEth ? QUEST_TYPE_AFFILIATE : QUEST_TYPE_MINT_ETH;
            }
            unchecked {
                ++slot;
            }
        }
    }

    /**
     * @notice Returns raw player quest state for debugging/analytics.
     * @param player The player address to query.
     * @return streak Current streak count.
     * @return lastCompletedDay Last day where both quests were completed.
     * @return progress Per-slot progress values (only valid if day/version match).
     * @return completed Per-slot completion flags for current day.
     */
    function playerQuestStates(
        address player
    )
        external
        view
        override
        returns (uint32 streak, uint32 lastCompletedDay, uint128[2] memory progress, bool[2] memory completed)
    {
        DailyQuest[QUEST_SLOT_COUNT] memory local = activeQuests;
        PlayerQuestState memory state = questPlayerState[player];
        uint48 currentDay = _currentQuestDay(local);
        streak = state.streak;
        lastCompletedDay = state.lastCompletedDay;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = local[slot];
            // Only return progress if it's valid for the current quest day/version
            progress[slot] = _questProgressValid(state, quest, slot, currentDay) ? state.progress[slot] : 0;
            completed[slot] = _questCompleted(state, quest, slot);
            unchecked {
                ++slot;
            }
        }
    }

    /**
     * @notice Player-specific view of quests with tier-adjusted requirements and progress.
     * @param player The player address to query.
     * @return viewData Comprehensive view including quests, progress, completion, and streak.
     *
     * @dev Handles streak decay preview: if player missed a day (gap > 1), the effective
     *      streak shown is 0, matching what would happen on their next action.
     *
     * This is the recommended view function for frontends displaying quest UI.
     */
    function getPlayerQuestView(address player) external view override returns (PlayerQuestView memory viewData) {
        DailyQuest[QUEST_SLOT_COUNT] memory local = _materializeActiveQuestsForView();
        uint48 currentDay = _currentQuestDay(local);
        PlayerQuestState memory state = questPlayerState[player];

        // Preview streak decay: if player missed a day, show 0 streak
        uint32 effectiveStreak = state.streak;
        if (state.lastCompletedDay != 0 && currentDay > uint48(state.lastCompletedDay + 1)) {
            effectiveStreak = 0;
        }
        // Use synced baseStreak if already active today, otherwise preview effective streak
        uint32 effectiveBaseStreak = (state.lastSyncDay == currentDay) ? state.baseStreak : effectiveStreak;

        viewData.lastCompletedDay = state.lastCompletedDay;
        viewData.baseStreak = effectiveBaseStreak;

        uint8 tier = _questTier(effectiveBaseStreak);
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            (viewData.quests[slot], viewData.progress[slot], viewData.completed[slot]) = _questViewData(
                local[slot],
                state,
                slot,
                tier,
                currentDay
            );
            unchecked {
                ++slot;
            }
        }
    }

    // =========================================================================
    //                           INTERNAL HELPERS
    // =========================================================================

    // ─────────────────────────────────────────────────────────────────────────
    // View Data Assembly
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Shared helper for view functions to pack quest info/progress consistently.
     * @param quest The quest definition to pack.
     * @param state Player's quest state (can be empty for baseline views).
     * @param slot Slot index (0 or 1).
     * @param tier Player's tier for requirement calculation.
     * @param currentDay The active quest day.
     * @return info Packed QuestInfo struct.
     * @return progress Player's current progress (0 if invalid/stale).
     * @return completed True if player has completed this slot today.
     */
    function _questViewData(
        DailyQuest memory quest,
        PlayerQuestState memory state,
        uint8 slot,
        uint8 tier,
        uint48 currentDay
    ) private view returns (QuestInfo memory info, uint128 progress, bool completed) {
        info = QuestInfo({
            day: quest.day,
            questType: quest.questType,
            highDifficulty: (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0,
            requirements: _questRequirementsForTier(quest, tier)
        });
        if (_questProgressValid(state, quest, slot, currentDay)) {
            progress = state.progress[slot];
        }
        completed = _questCompleted(state, quest, slot);
    }

    /**
     * @dev Decode quest requirements for a particular tier (streak bucket).
     * @param quest The quest to calculate requirements for.
     * @param tier The tier (0-2) based on player's streak.
     * @return req Requirements struct with either mints count or tokenAmount.
     *
     * Note: Different quest types use different requirement fields:
     * - MINT_BURNIE, MINT_ETH, BURN → req.mints (small integer count)
     * - FLIP, DECIMATOR, AFFILIATE → req.tokenAmount (BURNIE base units)
     * - BOND → req.tokenAmount (wei)
     */
    function _questRequirementsForTier(
        DailyQuest memory quest,
        uint8 tier
    ) private view returns (QuestRequirements memory req) {
        uint8 qType = quest.questType;
        if (qType == QUEST_TYPE_MINT_BURNIE) {
            req.mints = _questMintTarget(tier, quest.flags, quest.entropy);
        } else if (qType == QUEST_TYPE_MINT_ETH) {
            req.mints = _questMintTarget(tier, quest.flags, quest.entropy);
        } else if (qType == QUEST_TYPE_BURN) {
            req.mints = _questMintTarget(tier, quest.flags, quest.entropy);
        } else if (qType == QUEST_TYPE_FLIP) {
            req.tokenAmount = uint256(_questFlipTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        } else if (qType == QUEST_TYPE_DECIMATOR) {
            req.tokenAmount = uint256(_questDecimatorTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        } else if (qType == QUEST_TYPE_AFFILIATE) {
            req.tokenAmount = uint256(_questAffiliateTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        } else if (qType == QUEST_TYPE_BOND) {
            uint256 priceWei = questGame.mintPrice();
            req.tokenAmount = _questBondTargetWei(tier, quest.flags, quest.entropy, priceWei);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Quest Conversion & Lookup
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Downgrades burn quests to ETH mint (or affiliate) when burning is paused.
     * @param quests Storage reference to active quests array.
     * @param slot The slot index to convert.
     *
     * Critical: This function bumps the quest version to invalidate any existing
     * player progress. Without this, a player could accumulate burn progress,
     * then claim it against the converted mint/affiliate quest.
     */
    function _convertBurnQuest(DailyQuest[QUEST_SLOT_COUNT] storage quests, uint8 slot) private {
        DailyQuest storage quest = quests[slot];
        uint8 otherSlot = slot == 0 ? uint8(1) : uint8(0);
        DailyQuest storage other = quests[otherSlot];
        // Avoid duplicate quest types
        bool otherMintEth = other.questType == QUEST_TYPE_MINT_ETH;
        quest.questType = otherMintEth ? QUEST_TYPE_AFFILIATE : QUEST_TYPE_MINT_ETH;
        quest.version = _nextQuestVersion(); // Invalidates stale progress
    }

    /**
     * @dev Returns the active quest of a given type for the current day, if present.
     * @param quests Memory array of active quests.
     * @param currentDay The current quest day.
     * @param questType The type to search for.
     * @return quest The matching quest (empty if not found).
     * @return slotIndex The slot index (type(uint8).max if not found).
     */
    function _currentDayQuestOfType(
        DailyQuest[QUEST_SLOT_COUNT] memory quests,
        uint48 currentDay,
        uint8 questType
    ) private pure returns (DailyQuest memory quest, uint8 slotIndex) {
        slotIndex = type(uint8).max; // Sentinel for "not found"
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory candidate = quests[slot];
            if (candidate.day == currentDay && candidate.questType == questType) {
                quest = candidate;
                slotIndex = slot;
                return (quest, slotIndex);
            }
            unchecked {
                ++slot;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Game State Queries
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Burn quests are only enabled when the core game is in burn state.
     * @return True if gameState == 3 (burn window open).
     */
    function _canRollBurnQuest(uint48 /*questDay*/) private view returns (bool) {
        IDegenerusGame game_ = questGame;
        return game_.gameState() == 3;
    }

    /**
     * @dev Decimator quests are unlocked at specific level boundaries.
     * @return True if decimator quests can be rolled.
     *
     * Availability Rules:
     * 1. decWindowOpenFlag must be true (set by game during decimator windows)
     * 2. Level 100, 200, 300... (multiples of DECIMATOR_SPECIAL_LEVEL)
     * 3. Level 15, 25, 35... ending in 5 (except 95, 195, etc.)
     */
    function _canRollDecimatorQuest() private view returns (bool) {
        IDegenerusGame game_ = questGame;
        if (!game_.decWindowOpenFlag()) return false;
        uint24 lvl = game_.level();
        // Always available at 100-level milestones
        if (lvl != 0 && (lvl % DECIMATOR_SPECIAL_LEVEL) == 0) return true;
        // Available at X5 levels (15, 25, 35...) except X95
        if (lvl < 15) return false;
        return (lvl % 10) == 5 && (lvl % 100) != 95;
    }

    /**
     * @dev Determines if bond purchases are allowed at the given level.
     * @param currLevel The current game level.
     * @return open True if bond purchases are open.
     *
     * Bond Windows:
     * - Levels 1-5: open
     * - Levels 6-9: closed
     * - Levels X0-X4: open (10-14, 20-24, etc.)
     * - Levels X5-X9: closed (15-19, 25-29, etc.)
     */
    function _bondPurchasesOpen(uint24 currLevel) private pure returns (bool open) {
        if (currLevel == 0) return false;
        if (currLevel < 10) return currLevel < 6;
        return (currLevel % 10) < 5;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Arithmetic Utilities
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Adds delta to current, clamping at uint128 max to prevent overflow.
     * @param current The current progress value.
     * @param delta The amount to add.
     * @return The sum, capped at type(uint128).max.
     *
     * Note: Uses unchecked block for gas efficiency since we manually handle overflow.
     */
    function _clampedAdd128(uint128 current, uint256 delta) private pure returns (uint128) {
        unchecked {
            uint256 sum = uint256(current) + delta;
            if (sum > type(uint128).max) {
                sum = type(uint128).max;
            }
            return uint128(sum);
        }
    }

    /**
     * @dev Increments and returns the quest version counter.
     * @return newVersion The new version number.
     *
     * Used to invalidate stale progress when:
     * - A new quest is seeded for the day
     * - A quest type converts mid-day (burn → mint)
     */
    function _nextQuestVersion() private returns (uint32 newVersion) {
        newVersion = questVersionCounter++;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Progress Handling
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Processes a mint against a given quest slot, updating progress and returning rewards.
     * @param state Storage reference to player's quest state.
     * @param quests Memory copy of active quests (for pair completion check).
     * @param quest The specific quest being processed.
     * @param slot The slot index (0 or 1).
     * @param quantity Number of NFTs minted.
     * @param tier Player's current tier for target calculation.
     * @param priceUnit Price unit for reward calculation.
     */
    function _questHandleMintSlot(
        PlayerQuestState storage state,
        DailyQuest[QUEST_SLOT_COUNT] memory quests,
        DailyQuest memory quest,
        uint8 slot,
        uint32 quantity,
        uint8 tier,
        uint256 priceUnit
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _questSyncProgress(state, slot, quest.day, quest.version);
        state.progress[slot] = _clampedAdd128(state.progress[slot], quantity);
        uint32 target = _questMintTarget(tier, quest.flags, quest.entropy);
        if (state.progress[slot] >= target) {
            return _questCompleteWithPair(state, quests, slot, quest, priceUnit, 0);
        }
        return (0, false, quest.questType, state.streak, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State Synchronization
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Resets per-day bookkeeping and streak if a day was missed.
     * @param state Storage reference to player's quest state.
     * @param currentDay The current quest day.
     *
     * Streak Reset Logic:
     * - Uses lastActiveDay if set (any slot completion), else lastCompletedDay
     * - If gap > 1 day, streak resets to 0 (missed day penalty)
     * - On new day, resets completionMask and snapshots baseStreak
     *
     * baseStreak Snapshot:
     * - Captures streak at start of day for consistent tier calculation
     * - Prevents tier from changing mid-action if streak increments
     */
    function _questSyncState(PlayerQuestState storage state, uint48 currentDay) private {
        uint32 anchorDay = state.lastActiveDay != 0 ? state.lastActiveDay : state.lastCompletedDay;
        if (anchorDay != 0 && currentDay > uint48(anchorDay + 1)) {
            state.streak = 0; // Full miss (no quest completion) for at least one day
        }
        if (state.lastSyncDay != currentDay) {
            state.lastSyncDay = uint32(currentDay);
            state.completionMask = 0;
            state.baseStreak = state.streak; // Snapshot for consistent rewards
        }
    }

    /**
     * @dev Clears progress for a slot when the tracked day or quest version differs.
     * @param state Storage reference to player's quest state.
     * @param slot The slot index to sync.
     * @param currentDay The current quest day.
     * @param questVersion The current quest version.
     *
     * This is the key anti-exploit mechanism:
     * - Progress from a previous day cannot be applied to today's quest
     * - Progress from before a quest conversion cannot be applied after
     */
    function _questSyncProgress(
        PlayerQuestState storage state,
        uint8 slot,
        uint48 currentDay,
        uint32 questVersion
    ) private {
        if (state.lastProgressDay[slot] != currentDay || state.lastQuestVersion[slot] != questVersion) {
            state.lastProgressDay[slot] = uint32(currentDay);
            state.lastQuestVersion[slot] = questVersion;
            state.progress[slot] = 0;
        }
    }

    /**
     * @dev Progress is only valid when it matches the active quest day and version.
     * @param state Player's quest state (memory copy for view functions).
     * @param quest The quest to validate against.
     * @param slot The slot index.
     * @param currentDay The current quest day.
     * @return True if progress is valid and should be displayed/used.
     */
    function _questProgressValid(
        PlayerQuestState memory state,
        DailyQuest memory quest,
        uint8 slot,
        uint48 currentDay
    ) private pure returns (bool) {
        if (quest.day == 0 || quest.day != currentDay) {
            return false;
        }
        return state.lastProgressDay[slot] == quest.day && state.lastQuestVersion[slot] == quest.version;
    }

    /**
     * @dev Completion is bound to the quest day and per-slot completion mask.
     * @param state Player's quest state.
     * @param quest The quest to check.
     * @param slot The slot index.
     * @return True if this slot is marked complete for today.
     */
    function _questCompleted(
        PlayerQuestState memory state,
        DailyQuest memory quest,
        uint8 slot
    ) private pure returns (bool) {
        if (quest.day == 0) {
            return false;
        }
        return state.lastSyncDay == quest.day && (state.completionMask & uint8(1 << slot)) != 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tier & Target Calculations
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Group streak into tiers to avoid per-day bespoke tables.
     * @param streak Player's current streak.
     * @return Tier index (0, 1, or 2).
     *
     * Tier Ranges:
     * - Tier 0: streak 0-9
     * - Tier 1: streak 10-19
     * - Tier 2: streak 20+ (capped)
     */
    function _questTier(uint32 streak) private pure returns (uint8) {
        uint32 tier = streak / QUEST_TIER_STREAK_SPAN;
        if (tier > QUEST_TIER_MAX_INDEX) {
            tier = QUEST_TIER_MAX_INDEX;
        }
        return uint8(tier);
    }

    /**
     * @dev Extracts a 16-bit value from a packed uint256 by tier index.
     * @param packed The packed value containing multiple 16-bit entries.
     * @param tier The tier index (each tier is 16 bits).
     * @return The extracted 16-bit value for the tier.
     */
    function _questPackedValue(uint256 packed, uint8 tier) private pure returns (uint16) {
        return uint16((packed >> (tier * 16)) & 0xFFFF);
    }

    /**
     * @dev Derives a target between min and max using a 10-bit difficulty input.
     * @param minVal Minimum target value.
     * @param maxVal Maximum target value.
     * @param difficulty 10-bit difficulty value (0-1023).
     * @return Target value linearly interpolated between min and max.
     *
     * Formula: target = min + (difficulty * (max - min + 1)) / 1024
     * This gives uniform distribution across the range.
     */
    function _questLinearTarget(uint32 minVal, uint32 maxVal, uint16 difficulty) private pure returns (uint32) {
        if (maxVal <= minVal) {
            return minVal;
        }
        uint32 range = maxVal - minVal;
        uint32 target = minVal;
        target += uint32((uint256(difficulty) * (uint256(range) + 1)) / 1024);
        if (target > maxVal) {
            target = maxVal;
        }
        return target;
    }

    /**
     * @dev Extracts the 10-bit difficulty value from entropy.
     * @param entropy The quest entropy.
     * @return 10-bit difficulty (0-1023).
     */
    function _difficultyForTarget(uint8 /*questFlags*/, uint256 entropy) private pure returns (uint16) {
        return uint16(entropy & 0x3FF);
    }

    /**
     * @dev Calculate mint/burn target (small integer: 1-3).
     * @param tier Player's tier.
     * @param flags Quest difficulty flags (unused, reserved).
     * @param entropy Quest entropy for target derivation.
     * @return Target number of mints/burns required.
     *
     * Target Thresholds:
     * - difficulty > 750: target = 3 (capped by tier+1)
     * - difficulty > 500: target = 2 (capped by tier+1)
     * - otherwise: target = 1
     */
    function _questMintTarget(uint8 tier, uint8 flags, uint256 entropy) private pure returns (uint32) {
        uint16 difficulty = _difficultyForTarget(flags, entropy);
        uint32 target = 1;
        if (difficulty > 750) {
            target = 3;
        } else if (difficulty > 500) {
            target = 2;
        }
        // Cap target by tier: tier 0 max 1, tier 1 max 2, tier 2 max 3
        uint32 maxTarget = uint32(tier) + 1;
        if (target > maxTarget) {
            target = maxTarget;
        }
        return target;
    }

    /**
     * @dev Calculate flip stake target in BURNIE tokens (not base units).
     * @param tier Player's tier.
     * @param flags Quest difficulty flags.
     * @param entropy Quest entropy.
     * @return Target in BURNIE tokens (multiply by MILLION for base units).
     */
    function _questFlipTargetTokens(uint8 tier, uint8 flags, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_FLIP_PACKED, tier);
        uint16 difficulty = _difficultyForTarget(flags, entropy);
        return _questLinearTarget(QUEST_MIN_FLIP_STAKE_TOKEN, uint32(maxVal), difficulty);
    }

    /**
     * @dev Calculate decimator target (2x flip target).
     * @param tier Player's tier.
     * @param flags Quest difficulty flags.
     * @param entropy Quest entropy.
     * @return Target in BURNIE tokens.
     *
     * Note: Includes overflow protection (returns max uint32 if doubled overflows).
     */
    function _questDecimatorTargetTokens(uint8 tier, uint8 flags, uint256 entropy) private pure returns (uint32) {
        uint32 base = _questFlipTargetTokens(tier, flags, entropy);
        uint32 doubled = base * 2;
        if (doubled < base) {
            return type(uint32).max; // Overflow protection
        }
        return doubled;
    }

    /**
     * @dev Calculate affiliate earnings target in BURNIE tokens.
     * @param tier Player's tier.
     * @param flags Quest difficulty flags.
     * @param entropy Quest entropy.
     * @return Target in BURNIE tokens.
     */
    function _questAffiliateTargetTokens(uint8 tier, uint8 flags, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_AFFILIATE_PACKED, tier);
        uint16 difficulty = _difficultyForTarget(flags, entropy);
        return _questLinearTarget(QUEST_MIN_TOKEN, uint32(maxVal), difficulty);
    }

    /**
     * @dev Calculate bond purchase target in wei.
     * @param tier Player's tier.
     * @param flags Quest difficulty flags.
     * @param entropy Quest entropy.
     * @param priceWei Current mint price in wei.
     * @return Target in wei.
     *
     * Range:
     * - Minimum: 0.5x mint price
     * - Maximum: 1.0x mint price at tier 2
     */
    function _questBondTargetWei(uint8 tier, uint8 flags, uint256 entropy, uint256 priceWei) private pure returns (uint256) {
        if (priceWei == 0) return 0;
        uint256 minWei = priceWei >> 1; // 0.5x mint price
        uint256 span = priceWei / 2;    // Additional 0.5x range
        uint256 tierMax = minWei + (span * tier) / QUEST_TIER_MAX_INDEX;
        if (tierMax <= minWei) return minWei;

        uint16 difficulty = _difficultyForTarget(flags, entropy);
        uint256 target = minWei + (uint256(difficulty) * (tierMax - minWei)) / 1024;
        if (target > tierMax) target = tierMax;
        return target;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Quest Type Selection
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Map entropy to difficulty flags.
     * @param difficulty 10-bit difficulty value (0-1023).
     * @return flags Difficulty flags to store in quest.
     *
     * Thresholds:
     * - > 750: HIGH + VERY_HIGH flags (both set)
     * - > 500: HIGH flag only
     * - <= 500: No flags
     */
    function _difficultyFlags(uint16 difficulty) private pure returns (uint8 flags) {
        if (difficulty > 750) {
            return QUEST_FLAG_HIGH_DIFFICULTY | QUEST_FLAG_VERY_HIGH_DIFFICULTY;
        }
        if (difficulty > 500) {
            return QUEST_FLAG_HIGH_DIFFICULTY;
        }
        return 0;
    }

    /**
     * @dev Select the primary quest type (slot 0) using weighted random selection.
     * @param entropy VRF entropy for randomness.
     * @param burnAllowed True if burn quests can be rolled.
     * @param decAllowed True if decimator quests can be rolled.
     * @return The selected quest type.
     *
     * Weight Distribution:
     * - MINT_ETH: 5 (most common)
     * - DECIMATOR: 4 (when allowed)
     * - BOND: 2
     * - BURN: 2 (when allowed)
     * - MINT_BURNIE: 1
     * - AFFILIATE: 1
     * - FLIP: 0 (not available as primary)
     */
    function _primaryQuestType(uint256 entropy, bool burnAllowed, bool decAllowed) private pure returns (uint8) {
        uint16[QUEST_TYPE_COUNT] memory weights;
        uint16 total;

        weights[QUEST_TYPE_MINT_ETH] = 5;
        weights[QUEST_TYPE_MINT_BURNIE] = 1;
        if (burnAllowed) {
            weights[QUEST_TYPE_BURN] = 2;
        }
        weights[QUEST_TYPE_BOND] = 2;
        weights[QUEST_TYPE_AFFILIATE] = 1;
        if (decAllowed) {
            weights[QUEST_TYPE_DECIMATOR] = 4;
        }

        // Sum weights
        for (uint8 i; i < QUEST_TYPE_COUNT; ) {
            total += weights[i];
            unchecked {
                ++i;
            }
        }

        if (total == 0) {
            return QUEST_TYPE_MINT_ETH; // Fallback
        }

        // Weighted random selection
        uint256 roll = entropy % uint256(total);
        for (uint8 candidate; candidate < QUEST_TYPE_COUNT; ) {
            uint16 weight = weights[candidate];
            if (weight != 0) {
                if (roll < weight) {
                    return candidate;
                }
                roll -= weight;
            }
            unchecked {
                ++candidate;
            }
        }

        return QUEST_TYPE_MINT_ETH; // Fallback
    }

    /**
     * @dev Select the bonus quest type (slot 1), distinct from primary.
     * @param entropy VRF entropy (typically swapped halves of primary entropy).
     * @param primaryType The primary quest type (to exclude from selection).
     * @param burnAllowed True if burn quests can be rolled.
     * @param decAllowed True if decimator quests can be rolled.
     * @return The selected quest type.
     *
     * Key Differences from Primary:
     * - Excludes the primary type (no duplicate quests)
     * - Base weight is 1 for all types (more uniform)
     * - Decimator still gets 4x weight when allowed
     * - Burn still gets 2x weight when allowed
     */
    function _bonusQuestType(
        uint256 entropy,
        uint8 primaryType,
        bool burnAllowed,
        bool decAllowed
    ) private pure returns (uint8) {
        uint16[QUEST_TYPE_COUNT] memory weights;
        uint16 total;

        for (uint8 candidate; candidate < QUEST_TYPE_COUNT; ) {
            // Skip primary type (no duplicates)
            if (candidate == primaryType) {
                unchecked {
                    ++candidate;
                }
                continue;
            }
            // Skip disabled types
            if (!burnAllowed && candidate == QUEST_TYPE_BURN) {
                unchecked {
                    ++candidate;
                }
                continue;
            }
            if (!decAllowed && candidate == QUEST_TYPE_DECIMATOR) {
                unchecked {
                    ++candidate;
                }
                continue;
            }

            // Apply type-specific weights
            uint16 weight = 1;
            if (candidate == QUEST_TYPE_DECIMATOR && decAllowed) {
                weight = 4;
            } else if (candidate == QUEST_TYPE_BURN && burnAllowed) {
                weight = 2;
            }

            weights[candidate] = weight;
            total += weight;

            unchecked {
                ++candidate;
            }
        }

        // Fallback if no valid types (shouldn't happen in practice)
        if (total == 0) {
            return primaryType == QUEST_TYPE_MINT_ETH ? QUEST_TYPE_AFFILIATE : QUEST_TYPE_MINT_ETH;
        }

        // Weighted random selection
        uint256 roll = entropy % uint256(total);
        for (uint8 candidate; candidate < QUEST_TYPE_COUNT; ) {
            uint16 weight = weights[candidate];
            if (weight != 0) {
                if (roll < weight) {
                    return candidate;
                }
                roll -= weight;
            }
            unchecked {
                ++candidate;
            }
        }

        return primaryType == QUEST_TYPE_MINT_ETH ? QUEST_TYPE_AFFILIATE : QUEST_TYPE_MINT_ETH;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Quest Completion & Rewards
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Completes a quest slot, credits streak when all slots finish, and returns rewards.
     * @param state Storage reference to player's quest state.
     * @param slot The slot index being completed.
     * @param quest The quest being completed.
     * @param priceUnit Price unit for base reward calculation.
     * @return reward BURNIE tokens earned (in base units).
     * @return hardMode True if quest had high difficulty flag.
     * @return questType The completed quest type.
     * @return streak Player's streak after completion.
     * @return completed True if completion was successful.
     *
     * Streak Logic:
     * - Streak only increments when BOTH slots are completed
     * - QUEST_STATE_STREAK_CREDITED bit prevents double-crediting
     * - lastCompletedDay only updates on full completion (both slots)
     *
     * Reward Calculation:
     * - Base: 20% of mint cost / 2 slots = 10% per slot (in BURNIE)
     * - + Difficulty bonus (50 or 100 BURNIE based on tier and flags)
     * - + Tier upgrade bonus (500-1500 BURNIE on 10/20/30 streak milestones)
     */
    function _questComplete(
        PlayerQuestState storage state,
        uint8 slot,
        DailyQuest memory quest,
        uint256 priceUnit
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        uint8 mask = state.completionMask;
        uint8 slotMask = uint8(1 << slot);

        // Already completed this slot today
        if ((mask & slotMask) != 0) {
            return (0, false, quest.questType, state.streak, false);
        }

        // Mark slot as complete
        mask |= slotMask;
        if (quest.day > state.lastActiveDay) {
            state.lastActiveDay = uint32(quest.day);
        }

        uint32 newStreak = state.streak;
        bool streakJustUpdated;

        // Streak is credited only when ALL slots are complete
        if (
            (mask & QUEST_STATE_COMPLETED_SLOTS_MASK) == QUEST_STATE_COMPLETED_SLOTS_MASK &&
            (mask & QUEST_STATE_STREAK_CREDITED) == 0
        ) {
            mask |= QUEST_STATE_STREAK_CREDITED;
            newStreak = state.streak + 1;
            state.streak = newStreak;
            state.lastCompletedDay = uint32(quest.day);
            streakJustUpdated = true;
        }
        state.completionMask = mask;

        // Calculate rewards
        bool isHard = (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        uint32 rewardStreak = streakJustUpdated ? newStreak : state.baseStreak;
        // Base reward: 20% of mint cost split across slots
        uint256 rewardShare = (priceUnit / 5) / QUEST_SLOT_COUNT;
        uint8 rewardTier = _questTier(rewardStreak);
        rewardShare += _questDifficultyBonus(quest.flags, rewardTier);
        if (streakJustUpdated) {
            rewardShare += _questTierUpgradeBonus(newStreak);
        }
        return (rewardShare, isHard, quest.questType, newStreak, true);
    }

    /**
     * @dev Completes a quest and checks if the paired quest can also complete.
     * @param state Storage reference to player's quest state.
     * @param quests Memory copy of active quests.
     * @param slot The slot being completed.
     * @param quest The quest being completed.
     * @param priceUnit Price unit for reward calculation.
     * @param priceWei Price in wei (for bond quest target calculation).
     *
     * This function enables "combo completion" where completing one quest
     * can automatically complete the other if its progress already meets target.
     * This is a UX optimization to avoid requiring separate transactions.
     */
    function _questCompleteWithPair(
        PlayerQuestState storage state,
        DailyQuest[QUEST_SLOT_COUNT] memory quests,
        uint8 slot,
        DailyQuest memory quest,
        uint256 priceUnit,
        uint256 priceWei
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        (reward, hardMode, questType, streak, completed) = _questComplete(state, slot, quest, priceUnit);
        if (!completed) {
            return (reward, hardMode, questType, streak, false);
        }

        // Check the other slot; if it already meets the target, complete it now
        uint8 otherSlot = slot ^ 1; // XOR to flip 0↔1
        (
            uint256 extraReward,
            bool extraHard,
            uint8 extraType,
            uint32 extraStreak,
            bool extraCompleted
        ) = _maybeCompleteOther(state, quests, otherSlot, priceUnit, priceWei);

        // Aggregate rewards from paired completion
        if (extraCompleted) {
            reward += extraReward;
            if (extraHard) hardMode = true;
            questType = extraType;
            streak = extraStreak;
        }
    }

    /**
     * @dev Attempts to complete the other slot if its progress meets the target.
     * @param state Storage reference to player's quest state.
     * @param quests Memory copy of active quests.
     * @param slot The slot to check for completion.
     * @param priceUnit Price unit for reward calculation.
     * @param priceWei Price in wei (for bond quest target calculation).
     */
    function _maybeCompleteOther(
        PlayerQuestState storage state,
        DailyQuest[QUEST_SLOT_COUNT] memory quests,
        uint8 slot,
        uint256 priceUnit,
        uint256 priceWei
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest memory quest = quests[slot];
        uint48 currentDay = _currentQuestDay(quests);

        // Skip if quest is not for today
        if (quest.day == 0 || quest.day != currentDay) {
            return (0, false, quest.questType, state.streak, false);
        }
        // Skip if already completed
        if ((state.completionMask & uint8(1 << slot)) != 0) {
            return (0, false, quest.questType, state.streak, false);
        }

        uint8 tier = _questTier(state.baseStreak);
        if (!_questReady(state, quest, slot, tier, priceWei)) {
            return (0, false, quest.questType, state.streak, false);
        }

        return _questComplete(state, slot, quest, priceUnit);
    }

    /**
     * @dev Checks if a quest slot's progress meets or exceeds the target.
     * @param state Storage reference to player's quest state.
     * @param quest The quest to check.
     * @param slot The slot index.
     * @param tier Player's tier for target calculation.
     * @param priceWei Price in wei (for bond quest target).
     * @return True if progress >= target.
     */
    function _questReady(
        PlayerQuestState storage state,
        DailyQuest memory quest,
        uint8 slot,
        uint8 tier,
        uint256 priceWei
    ) private view returns (bool) {
        if (!_questProgressValid(state, quest, slot, quest.day)) return false;
        uint256 progress = state.progress[slot];

        if (quest.questType == QUEST_TYPE_MINT_BURNIE) {
            return progress >= _questMintTarget(tier, quest.flags, quest.entropy);
        }
        if (quest.questType == QUEST_TYPE_MINT_ETH) {
            return progress >= _questMintTarget(tier, quest.flags, quest.entropy);
        }
        if (quest.questType == QUEST_TYPE_BURN) {
            return progress >= _questMintTarget(tier, quest.flags, quest.entropy);
        }
        if (quest.questType == QUEST_TYPE_FLIP) {
            return progress >= uint256(_questFlipTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        }
        if (quest.questType == QUEST_TYPE_DECIMATOR) {
            return progress >= uint256(_questDecimatorTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        }
        if (quest.questType == QUEST_TYPE_AFFILIATE) {
            return progress >= uint256(_questAffiliateTargetTokens(tier, quest.flags, quest.entropy)) * MILLION;
        }
        if (quest.questType == QUEST_TYPE_BOND) {
            uint256 weiPrice = priceWei != 0 ? priceWei : questGame.mintPrice();
            return progress >= _questBondTargetWei(tier, quest.flags, quest.entropy, weiPrice);
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bonus Calculations
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Fixed per-quest difficulty bonus based on tier.
     * @param questFlags The quest's difficulty flags.
     * @param tier Player's tier (determines bonus eligibility).
     * @return bonusReward Bonus in BURNIE base units.
     *
     * Bonus Structure:
     * - VERY_HIGH + tier 2: 100 BURNIE
     * - HIGH + tier 1+: 50 BURNIE
     * - Otherwise: 0
     */
    function _questDifficultyBonus(uint8 questFlags, uint8 tier) private pure returns (uint256 bonusReward) {
        if ((questFlags & QUEST_FLAG_VERY_HIGH_DIFFICULTY) != 0 && tier >= QUEST_TIER_MAX_INDEX) {
            return 100 * MILLION;
        }
        if ((questFlags & QUEST_FLAG_HIGH_DIFFICULTY) != 0 && tier > 0) {
            return 50 * MILLION;
        }
        return 0;
    }

    /**
     * @dev Fixed rewards on streak milestones (10, 20, 30 days).
     * @param streak Player's streak after completion.
     * @return bonusReward Milestone bonus in BURNIE base units.
     *
     * Bonus Structure:
     * - Streak 10: 500 BURNIE
     * - Streak 20: 1000 BURNIE
     * - Streak 30+: 1500 BURNIE (capped)
     */
    function _questTierUpgradeBonus(uint32 streak) private pure returns (uint256 bonusReward) {
        if (streak == 0 || (streak % QUEST_TIER_STREAK_SPAN) != 0) return 0;
        uint32 step = streak / QUEST_TIER_STREAK_SPAN;
        if (step > 3) step = 3; // Cap at 3x multiplier
        return uint256(step) * 500 * MILLION;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Quest Seeding
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Seeds a quest slot with a new quest definition.
     * @param quest Storage reference to the quest slot.
     * @param day The quest day identifier.
     * @param entropy VRF entropy for target calculation.
     * @param questType The quest type to seed.
     * @param flags Shared difficulty flags.
     *
     * Note: Always bumps version to invalidate any stale player progress.
     */
    function _seedQuestType(
        DailyQuest storage quest,
        uint48 day,
        uint256 entropy,
        uint8 questType,
        uint8 flags
    ) private {
        quest.day = day;
        quest.questType = questType;
        quest.flags = flags;
        quest.entropy = entropy;
        quest.version = _nextQuestVersion();
    }

    /**
     * @dev Helper to read the active day from either slot.
     * @param quests Memory array of active quests.
     * @return The current quest day (prefers slot 0 if both are set).
     */
    function _currentQuestDay(DailyQuest[QUEST_SLOT_COUNT] memory quests) private pure returns (uint48) {
        uint48 day0 = quests[0].day;
        if (day0 != 0) return day0;
        return quests[1].day;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IDegenerusQuestModule.sol";
import "../interfaces/IDegenerusGame.sol";

/// @title DegenerusQuestModule
/// @notice Tracks two rotating daily quests and validates player progress against Degenerus game actions.
/// @dev All entry points are coin-gated; randomness is supplied by the coin contract.
contract DegenerusQuestModule is IDegenerusQuestModule {
    error OnlyCoin();
    error AlreadyWired();
    error InvalidQuestDay();
    error InvalidEntropy();

    uint256 private constant MILLION = 1e6;
    uint8 private constant QUEST_SLOT_COUNT = 2;
    // Quest types (generated pseudo-randomly per slot)
    uint8 private constant QUEST_TYPE_MINT_ANY = 0;
    uint8 private constant QUEST_TYPE_MINT_ETH = 1;
    uint8 private constant QUEST_TYPE_FLIP = 2;
    uint8 private constant QUEST_TYPE_AFFILIATE = 3;
    uint8 private constant QUEST_TYPE_BURN = 4;
    uint8 private constant QUEST_TYPE_DECIMATOR = 5;
    uint8 private constant QUEST_TYPE_BOND = 6;
    uint8 private constant QUEST_TYPE_COUNT = 7;

    // Quest flags for difficulty and forced behavior
    uint8 private constant QUEST_FLAG_HIGH_DIFFICULTY = 1 << 0;
    uint8 private constant QUEST_FLAG_VERY_HIGH_DIFFICULTY = 1 << 1;
    uint8 private constant QUEST_FLAG_FORCE_BURN = 1 << 2;

    // Tiering and streak accounting
    uint8 private constant QUEST_TIER_MAX_INDEX = 10;
    uint32 private constant QUEST_TIER_STREAK_SPAN = 7;
    uint8 private constant QUEST_STATE_COMPLETED_SLOTS_MASK = (uint8(1) << QUEST_SLOT_COUNT) - 1;
    uint8 private constant QUEST_STATE_STREAK_CREDITED = 1 << 7;
    uint8 private constant QUEST_STATE_ETH_PRIMED = 1 << 5;

    // Baseline minima for quest targets and rarer decimator level trigger
    uint16 private constant QUEST_MIN_TOKEN = 250;
    uint16 private constant QUEST_MIN_FLIP_STAKE_TOKEN = 1_000;
    uint16 private constant QUEST_MIN_MINT = 1;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;
    uint256 private constant QUEST_BOND_MIN_WEI = 25e15; // 0.025 ETH
    uint256 private constant QUEST_BOND_MAX_WEI = 0.5 ether;

    address public immutable coin;
    IDegenerusGame private questGame;

    /// @notice Definition of a quest that is active for the current day.
    struct DailyQuest {
        uint48 day; // Quest day identifier (derived by caller, not block timestamp)
        uint8 questType; // One of the QUEST_TYPE_* constants
        uint8 flags; // Difficulty and forced burn flags
        uint32 version; // Bumped when quest mutates mid-day to reset stale player progress
        uint256 entropy; // VRF-derived entropy used for targets and difficulty flags
    }

    /// @notice Progress and streak bookkeeping per player.
    struct PlayerQuestState {
        uint32 lastCompletedDay; // Last day where the primary quest was completed
        uint32 streak; // Current streak of days with full completion
        uint32 baseStreak; // Snapshot of streak at start of day (used for rewards)
        uint32 lastSyncDay; // Day we last reset progress/completionMask
        uint32[QUEST_SLOT_COUNT] lastProgressDay; // Tracks per-slot progress day to auto-reset
        uint32[QUEST_SLOT_COUNT] lastQuestVersion; // Quest version used when progress was recorded
        uint128[QUEST_SLOT_COUNT] progress; // Accumulated progress toward targets per slot
        uint32 forcedProgressDay; // Day used for ETH priming accumulation
        uint128 forcedProgress; // Progress toward ETH priming target
        uint8 completionMask; // Bit 0/1 for slot completion, plus ETH_PRIMED/STREAK_CREDITED bits
    }

    DailyQuest[QUEST_SLOT_COUNT] private activeQuests;
    mapping(address => PlayerQuestState) private questPlayerState;

    // Packed per-tier maxima (16 bits per tier index) for quest target generation.
    uint256 private constant QUEST_MINT_ANY_PACKED = 0x0000000000000000000000080008000800080008000700060005000400030002;
    uint256 private constant QUEST_MINT_ETH_PACKED = 0x0000000000000000000000050005000400040004000300030002000200020001;
    uint256 private constant QUEST_FLIP_PACKED = 0x000000000000000000000dac0ce40c1c0b540a8c09c408fc0834076c06a405dc;
    uint256 private constant QUEST_AFFILIATE_PACKED =
        0x00000000000000000000060e060e060e060e060e060e04e203e80320028a01f4;

    uint32 private questVersionCounter = 1;
    /// @param coin_ Coin contract that is authorized to drive quest logic.
    constructor(address coin_) {
        coin = coin_;
    }

    /// @notice Wire the Degenerus game contract using an address array ([game]); set-once per slot.
    function wire(address[] calldata addresses) external onlyCoin {
        _setGame(addresses.length > 0 ? addresses[0] : address(0));
    }

    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(questGame);
        if (current == address(0)) {
            questGame = IDegenerusGame(gameAddr);
        } else if (gameAddr != current) {
            revert AlreadyWired();
        }
    }

    modifier onlyCoin() {
        if (msg.sender != coin) revert OnlyCoin();
        _;
    }

    /// @notice Roll the daily quest set using VRF entropy.
    /// @param day Quest day identifier (monotonicity enforced by caller).
    /// @param entropy VRF entropy word; second slot reuses swapped halves.
    function rollDailyQuest(
        uint48 day,
        uint256 entropy
    ) external onlyCoin returns (bool rolled, uint8 questType, bool highDifficulty) {
        return _rollDailyQuest(day, entropy, false, false);
    }

    /// @notice Roll quests with optional overrides for testing/admin controls.
    function rollDailyQuestWithOverrides(
        uint48 day,
        uint256 entropy,
        bool forceMintEth,
        bool forceBurn
    ) external onlyCoin returns (bool rolled, uint8 questType, bool highDifficulty) {
        return _rollDailyQuest(day, entropy, forceMintEth, forceBurn);
    }

    /// @notice Normalize active quests when burning becomes disallowed mid-day (extermination to game state 1).
    function normalizeActiveBurnQuests() external onlyCoin {
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

    function _rollDailyQuest(
        uint48 day,
        uint256 entropy,
        bool forceMintEth,
        bool forceBurn
    ) private returns (bool rolled, uint8 questType, bool highDifficulty) {
        DailyQuest[QUEST_SLOT_COUNT] storage quests = activeQuests;
        bool burnAllowed = _canRollBurnQuest(day) || forceBurn;
        bool decAllowed = _canRollDecimatorQuest();

        uint256 primaryEntropy = entropy;
        uint256 bonusEntropy = (entropy >> 128) | (entropy << 128); // swap halves for slot1

        uint8 primaryType = forceMintEth ? QUEST_TYPE_MINT_ETH : _primaryQuestType(primaryEntropy);
        uint8 bonusType = forceBurn
            ? QUEST_TYPE_BURN
            : _bonusQuestType(bonusEntropy, primaryType, burnAllowed, decAllowed, _canRollBafQuest());

        _seedQuestType(quests[0], day, primaryEntropy, primaryType);
        quests[0].flags &= ~QUEST_FLAG_FORCE_BURN;

        _seedQuestType(quests[1], day, bonusEntropy, bonusType);
        if (forceBurn) {
            quests[1].flags |= QUEST_FLAG_FORCE_BURN;
        } else {
            quests[1].flags &= ~QUEST_FLAG_FORCE_BURN;
        }

        bool hardMode = (quests[0].flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        return (true, quests[0].questType, hardMode);
    }

    /// @notice Handle mint progress for a player; covers both coin and ETH paid mints.
    function handleMint(
        address player,
        uint32 quantity,
        bool paidWithEth
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || quantity == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }

        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        bool mintedReady = _ethMintReady(state, player);

        if (!mintedReady) {
            if (!paidWithEth) {
                return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
            }
            _syncForcedProgress(state, currentDay);
            state.forcedProgress = _clampedAdd128(state.forcedProgress, quantity);
            uint256 entropySource = quests[0].day == currentDay ? quests[0].entropy : quests[1].entropy;
            uint32 forcedTarget = _questMintEthTarget(tier, entropySource);
            if (state.forcedProgress >= forcedTarget) {
                return _questCompleteForced(state, currentDay);
            }
            return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
        }

        uint256 priceUnit = questGame.coinPriceUnit();
        bool matched;
        bool aggregatedCompleted;
        bool aggregatedHardMode;
        uint8 fallbackType = quests[0].questType;
        uint8 aggregatedQuestType = fallbackType;
        uint32 aggregatedStreak = state.streak;
        uint256 aggregatedReward;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            if (quest.questType == QUEST_TYPE_MINT_ANY || (paidWithEth && quest.questType == QUEST_TYPE_MINT_ETH)) {
                matched = true;
                fallbackType = quest.questType;
                (reward, hardMode, questType, streak, completed) = _questHandleMintSlot(
                    state,
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
        return (0, false, matched ? fallbackType : QUEST_TYPE_MINT_ANY, state.streak, false);
    }

    /// @notice Handle flip/unstake progress credited in DEGEN base units (6 decimals).
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
        if (!_ethMintReady(state, player)) {
            return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
        }

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_FLIP);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_FLIP, state.streak, false);
        }

        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        uint8 tier = _questTier(state.baseStreak);
        uint128 progressAfter = _clampedAdd128(state.progress[slotIndex], flipCredit);
        state.progress[slotIndex] = progressAfter;
        uint256 target = uint256(_questFlipTargetTokens(tier, quest.entropy)) * MILLION;
        if (progressAfter < target) {
            return (0, false, quest.questType, state.streak, false);
        }

        uint256 priceUnit = questGame.coinPriceUnit();
        return _questComplete(state, slotIndex, quest, priceUnit);
    }

    /// @notice Handle decimator burns counted in DEGEN base units (6 decimals).
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
        if (!_ethMintReady(state, player)) {
            return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
        }
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = questGame.coinPriceUnit();

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_DECIMATOR);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_DECIMATOR, state.streak, false);
        }
        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        state.progress[slotIndex] = _clampedAdd128(state.progress[slotIndex], burnAmount);
        uint256 target = uint256(_questDecimatorTargetTokens(tier, quest.entropy)) * MILLION;
        if (state.progress[slotIndex] >= target) {
            return _questComplete(state, slotIndex, quest, priceUnit);
        }
        return (0, false, quest.questType, state.streak, false);
    }

    /// @notice Handle bond purchases tracked by the base-per-bond size (wei).
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
        if (!_ethMintReady(state, player)) {
            return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
        }

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_BOND);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_BOND, state.streak, false);
        }

        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = questGame.coinPriceUnit();
        uint256 priceWei = questGame.mintPrice();
        if (priceUnit == 0 || priceWei == 0) {
            return (0, false, quest.questType, state.streak, false);
        }

        uint256 coinEquivalent = (basePerBondWei * priceUnit) / priceWei;
        if (coinEquivalent == 0) {
            return (0, false, quest.questType, state.streak, false);
        }
        state.progress[slotIndex] = _clampedAdd128(state.progress[slotIndex], coinEquivalent);
        uint256 target = _questBondTargetCoin(tier, quest.entropy, priceUnit);
        if (state.progress[slotIndex] < target) {
            return (0, false, quest.questType, state.streak, false);
        }
        return _questComplete(state, slotIndex, quest, priceUnit);
    }

    /// @notice Handle affiliate earnings credited in DEGEN base units (6 decimals).
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
        if (!_ethMintReady(state, player)) {
            return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
        }
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = questGame.coinPriceUnit();

        (DailyQuest memory quest, uint8 slotIndex) = _currentDayQuestOfType(quests, currentDay, QUEST_TYPE_AFFILIATE);
        if (slotIndex == type(uint8).max) {
            return (0, false, QUEST_TYPE_AFFILIATE, state.streak, false);
        }
        _questSyncProgress(state, slotIndex, currentDay, quest.version);
        state.progress[slotIndex] = _clampedAdd128(state.progress[slotIndex], amount);
        uint256 target = uint256(_questAffiliateTargetTokens(tier, quest.entropy)) * MILLION;
        if (state.progress[slotIndex] >= target) {
            return _questComplete(state, slotIndex, quest, priceUnit);
        }
        return (0, false, quest.questType, state.streak, false);
    }

    /// @notice Handle burn quest progress in whole NFTs.
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
        if (!_ethMintReady(state, player)) {
            return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
        }
        uint8 tier = _questTier(state.baseStreak);
        uint256 priceUnit = questGame.coinPriceUnit();

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
            uint32 target = _questBurnTarget(tier, quest.entropy);
            if (state.progress[slot] >= target) {
                return _questComplete(state, slot, quest, priceUnit);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_BURN, state.streak, false);
    }

    /// @notice View helper for frontends; returns quest baselines at tier zero.
    function getActiveQuests() external view override returns (QuestInfo[2] memory quests) {
        DailyQuest[QUEST_SLOT_COUNT] memory local = _materializeActiveQuestsForView();
        uint48 currentDay = _currentQuestDay(local);
        PlayerQuestState memory emptyState;
        uint8 baseTier = 0; // Baseline requirements with zero streak (use getPlayerQuestView for player-specific tiers)
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            (quests[slot], , ) = _questViewData(local[slot], emptyState, slot, baseTier, currentDay);
            unchecked {
                ++slot;
            }
        }
    }

    /// @dev Returns active quests, downgrading burn slots in-memory when burning is not allowed.
    /// Only this view-only path performs a downgrade; stateful flows never modify slots here.
    function _materializeActiveQuestsForView() private view returns (DailyQuest[QUEST_SLOT_COUNT] memory local) {
        local = activeQuests;
        bool burnAllowed = _canRollBurnQuest(_currentQuestDay(local));
        if (burnAllowed) return local;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            if (local[slot].questType == QUEST_TYPE_BURN) {
                uint8 otherSlot = slot == 0 ? uint8(1) : uint8(0);
                bool otherMintEth = local[otherSlot].questType == QUEST_TYPE_MINT_ETH;
                local[slot].questType = otherMintEth ? QUEST_TYPE_AFFILIATE : QUEST_TYPE_MINT_ETH;
                local[slot].flags &= ~QUEST_FLAG_FORCE_BURN;
            }
            unchecked {
                ++slot;
            }
        }
    }

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
            progress[slot] = _questProgressValid(state, quest, slot, currentDay) ? state.progress[slot] : 0;
            completed[slot] = _questCompleted(state, quest, slot);
            unchecked {
                ++slot;
            }
        }
    }

    /// @notice Player-specific view of quests with tier-adjusted requirements and progress.
    function getPlayerQuestView(address player) external view override returns (PlayerQuestView memory viewData) {
        DailyQuest[QUEST_SLOT_COUNT] memory local = _materializeActiveQuestsForView();
        uint48 currentDay = _currentQuestDay(local);
        PlayerQuestState memory state = questPlayerState[player];
        uint32 effectiveStreak = state.streak;
        if (state.lastCompletedDay != 0 && currentDay > uint48(state.lastCompletedDay + 1)) {
            effectiveStreak = 0;
        }
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

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Shared helper for view functions to pack quest info/progress consistently.
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

    /// @dev Decode quest requirements for a particular tier (streak bucket).
    function _questRequirementsForTier(
        DailyQuest memory quest,
        uint8 tier
    ) private view returns (QuestRequirements memory req) {
        uint8 qType = quest.questType;
        if (qType == QUEST_TYPE_MINT_ANY) {
            req.mints = _questMintAnyTarget(tier, quest.entropy);
        } else if (qType == QUEST_TYPE_MINT_ETH) {
            req.mints = _questMintEthTarget(tier, quest.entropy);
        } else if (qType == QUEST_TYPE_BURN) {
            req.mints = _questBurnTarget(tier, quest.entropy);
        } else if (qType == QUEST_TYPE_FLIP) {
            req.tokenAmount = uint256(_questFlipTargetTokens(tier, quest.entropy)) * MILLION;
        } else if (qType == QUEST_TYPE_DECIMATOR) {
            req.tokenAmount = uint256(_questDecimatorTargetTokens(tier, quest.entropy)) * MILLION;
        } else if (qType == QUEST_TYPE_AFFILIATE) {
            req.tokenAmount = uint256(_questAffiliateTargetTokens(tier, quest.entropy)) * MILLION;
        } else if (qType == QUEST_TYPE_BOND) {
            uint256 priceUnit = questGame.coinPriceUnit();
            req.tokenAmount = _questBondTargetCoin(tier, quest.entropy, priceUnit);
        }
    }

    /// @dev Downgrades burn quests to ETH mint (or affiliate) when burning is paused, bumping version to reset progress.
    function _convertBurnQuest(DailyQuest[QUEST_SLOT_COUNT] storage quests, uint8 slot) private {
        DailyQuest storage quest = quests[slot];
        uint8 otherSlot = slot == 0 ? uint8(1) : uint8(0);
        DailyQuest storage other = quests[otherSlot];
        bool otherMintEth = other.questType == QUEST_TYPE_MINT_ETH;
        quest.questType = otherMintEth ? QUEST_TYPE_AFFILIATE : QUEST_TYPE_MINT_ETH;
        quest.flags &= ~QUEST_FLAG_FORCE_BURN;
        quest.version = _nextQuestVersion();
    }

    /// @dev Returns the active quest of a given type for the current day, if present.
    function _currentDayQuestOfType(
        DailyQuest[QUEST_SLOT_COUNT] memory quests,
        uint48 currentDay,
        uint8 questType
    ) private pure returns (DailyQuest memory quest, uint8 slotIndex) {
        slotIndex = type(uint8).max;
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

    /// @dev Burn quests are only enabled when the core game is in burn state (gameState == 3).
    function _canRollBurnQuest(uint48 /*questDay*/) private view returns (bool) {
        IDegenerusGame game_ = questGame;
        if (address(game_) == address(0)) {
            return false;
        }
        return game_.gameState() == 3;
    }

    /// @dev BAF quests map to flip quest at BAF levels (level milestones, multiples of 100).
    function _canRollBafQuest() private view returns (bool) {
        IDegenerusGame game_ = questGame;
        if (address(game_) == address(0)) {
            return false;
        }
        uint24 lvl = game_.level();
        return lvl != 0 && (lvl % 100) == 0;
    }

    /// @dev Decimator quests are unlocked at specific level boundaries.
    function _canRollDecimatorQuest() private view returns (bool) {
        IDegenerusGame game_ = questGame;
        if (address(game_) == address(0)) {
            return false;
        }
        uint24 lvl = game_.level();
        if (lvl != 0 && (lvl % DECIMATOR_SPECIAL_LEVEL) == 0) {
            return true;
        }
        if (lvl < 25) {
            return false;
        }
        bool standard = (lvl % 10) == 5 && (lvl % 100) != 95;
        return standard;
    }

    function _clampedAdd128(uint128 current, uint256 delta) private pure returns (uint128) {
        unchecked {
            uint256 sum = uint256(current) + delta;
            if (sum > type(uint128).max) {
                sum = type(uint128).max;
            }
            return uint128(sum);
        }
    }

    function _nextQuestVersion() private returns (uint32 newVersion) {
        newVersion = questVersionCounter++;
    }

    /// @dev Processes a mint against a given quest slot, updating progress and emitting rewards when complete.
    function _questHandleMintSlot(
        PlayerQuestState storage state,
        DailyQuest memory quest,
        uint8 slot,
        uint32 quantity,
        uint8 tier,
        uint256 priceUnit
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _questSyncProgress(state, slot, quest.day, quest.version);
        state.progress[slot] = _clampedAdd128(state.progress[slot], quantity);
        uint32 target = quest.questType == QUEST_TYPE_MINT_ANY
            ? _questMintAnyTarget(tier, quest.entropy)
            : _questMintEthTarget(tier, quest.entropy);
        if (state.progress[slot] >= target) {
            return _questComplete(state, slot, quest, priceUnit);
        }
        return (0, false, quest.questType, state.streak, false);
    }

    /// @dev Resets per-day bookkeeping and streak if a day was missed.
    function _questSyncState(PlayerQuestState storage state, uint48 currentDay) private {
        if (state.lastCompletedDay != 0 && currentDay > uint48(state.lastCompletedDay + 1)) {
            state.streak = 0;
        }
        if (state.lastSyncDay != currentDay) {
            state.lastSyncDay = uint32(currentDay);
            state.completionMask = 0;
            state.baseStreak = state.streak;
        }
    }

    /// @dev Clears progress for a slot when the tracked day or quest version differs.
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

    /// @dev Progress is only valid when it matches the active quest day and version.
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

    /// @dev Completion is bound to the quest day and per-slot completion mask.
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

    /// @dev Clears ETH priming progress when the day rolls over.
    function _syncForcedProgress(PlayerQuestState storage state, uint48 currentDay) private {
        if (state.forcedProgressDay != currentDay) {
            state.forcedProgressDay = uint32(currentDay);
            state.forcedProgress = 0;
        }
    }

    /// @dev Group streak into tiers to avoid per-day bespoke tables.
    function _questTier(uint32 streak) private pure returns (uint8) {
        uint32 tier = streak / QUEST_TIER_STREAK_SPAN;
        if (tier > QUEST_TIER_MAX_INDEX) {
            tier = QUEST_TIER_MAX_INDEX;
        }
        return uint8(tier);
    }

    function _questPackedValue(uint256 packed, uint8 tier) private pure returns (uint16) {
        return uint16((packed >> (tier * 16)) & 0xFFFF);
    }

    /// @dev Derives a target between min and max using a 10-bit difficulty input.
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

    function _questMintAnyTarget(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_MINT_ANY_PACKED, tier);
        uint16 difficulty = uint16(entropy & 0x3FF);
        return _questLinearTarget(QUEST_MIN_MINT, uint32(maxVal), difficulty);
    }

    function _questMintEthTarget(uint8 tier, uint256 entropy) private pure returns (uint32) {
        if (tier == 0) {
            return QUEST_MIN_MINT;
        }
        uint16 maxVal = _questPackedValue(QUEST_MINT_ETH_PACKED, tier);
        uint16 difficulty = uint16(entropy & 0x3FF);
        return _questLinearTarget(QUEST_MIN_MINT, uint32(maxVal), difficulty);
    }

    function _questBurnTarget(uint8 tier, uint256 entropy) private pure returns (uint32) {
        return _questMintEthTarget(tier, entropy);
    }

    function _questFlipTargetTokens(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_FLIP_PACKED, tier);
        uint16 difficulty = uint16(entropy & 0x3FF);
        return _questLinearTarget(QUEST_MIN_FLIP_STAKE_TOKEN, uint32(maxVal), difficulty);
    }

    function _questDecimatorTargetTokens(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint32 base = _questFlipTargetTokens(tier, entropy);
        uint32 doubled = base * 2;
        if (doubled < base) {
            return type(uint32).max;
        }
        return doubled;
    }

    function _questAffiliateTargetTokens(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_AFFILIATE_PACKED, tier);
        uint16 difficulty = uint16(entropy & 0x3FF);
        return _questLinearTarget(QUEST_MIN_TOKEN, uint32(maxVal), difficulty);
    }

    function _questBondTargetCoin(uint8 tier, uint256 entropy, uint256 priceUnit) private pure returns (uint256) {
        if (priceUnit == 0) return 0;
        if (tier == 0) return priceUnit; // tier0 always 1 price unit

        uint256 maxCoin = priceUnit * 5; // cap at 5x price unit for max tier
        uint256 step = (maxCoin - priceUnit) / QUEST_TIER_MAX_INDEX;
        uint256 tierMin = priceUnit + (step * tier);
        uint256 tierMax = tier == QUEST_TIER_MAX_INDEX ? maxCoin : (tierMin + step);
        if (tierMax <= tierMin) return tierMin;

        uint16 difficulty = uint16(entropy & 0x3FF);
        uint256 target = tierMin + (uint256(difficulty) * (tierMax - tierMin)) / 1024;
        if (target > tierMax) target = tierMax;
        return target;
    }

    /// @dev Map entropy to difficulty flags.
    function _difficultyFlags(uint16 difficulty) private pure returns (uint8 flags) {
        if (difficulty >= 900) {
            return QUEST_FLAG_HIGH_DIFFICULTY | QUEST_FLAG_VERY_HIGH_DIFFICULTY;
        }
        if (difficulty >= 800) {
            return QUEST_FLAG_HIGH_DIFFICULTY;
        }
        return 0;
    }

    /// @dev Select the primary quest type (daily quest) from the limited pool.
    function _primaryQuestType(uint256 entropy) private pure returns (uint8) {
        uint8 roll = uint8(entropy % 3); // {mintEth, affiliate, bond}
        if (roll == 0) return QUEST_TYPE_MINT_ETH;
        if (roll == 1) return QUEST_TYPE_AFFILIATE;
        return QUEST_TYPE_BOND;
    }

    /// @dev Select the bonus quest type (distinct from primary) respecting burn/decimator availability.
    function _bonusQuestType(
        uint256 entropy,
        uint8 primaryType,
        bool burnAllowed,
        bool decAllowed,
        bool bafAllowed
    ) private pure returns (uint8) {
        if (decAllowed) {
            return QUEST_TYPE_DECIMATOR;
        }
        if (bafAllowed) {
            return QUEST_TYPE_FLIP;
        }
        for (uint8 attempt; attempt < QUEST_TYPE_COUNT * 2; ) {
            uint8 candidate = uint8((entropy + attempt) % QUEST_TYPE_COUNT);
            if (candidate == primaryType) {
                unchecked {
                    ++attempt;
                }
                continue;
            }
            if (!burnAllowed && candidate == QUEST_TYPE_BURN) {
                unchecked {
                    ++attempt;
                }
                continue;
            }
            if (!decAllowed && candidate == QUEST_TYPE_DECIMATOR) {
                candidate = QUEST_TYPE_FLIP;
                if (candidate == primaryType) {
                    unchecked {
                        ++attempt;
                    }
                    continue;
                }
            }
            return candidate;
        }
        return primaryType == QUEST_TYPE_MINT_ETH ? QUEST_TYPE_AFFILIATE : QUEST_TYPE_MINT_ETH;
    }

    /// @dev Marks ETH mint priming complete without granting a reward.
    function _questCompleteForced(
        PlayerQuestState storage state,
        uint48 currentDay
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        state.completionMask |= QUEST_STATE_ETH_PRIMED;
        state.forcedProgressDay = uint32(currentDay);
        return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
    }

    /// @dev Completes a quest slot, credits streak when all slots finish, and returns the proportional reward.
    function _questComplete(
        PlayerQuestState storage state,
        uint8 slot,
        DailyQuest memory quest,
        uint256 priceUnit
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        uint8 slotMask = uint8(1 << slot);
        if ((state.completionMask & slotMask) != 0) {
            return (0, false, quest.questType, state.streak, false);
        }
        state.completionMask |= slotMask;
        uint32 newStreak = state.streak;
        bool streakJustUpdated;
        if ((state.completionMask & QUEST_STATE_STREAK_CREDITED) == 0 && slot == 0) {
            state.completionMask |= QUEST_STATE_STREAK_CREDITED;
            newStreak = state.streak + 1;
            state.streak = newStreak;
            state.lastCompletedDay = uint32(quest.day);
            streakJustUpdated = true;
        }
        bool isHard = (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        uint32 rewardStreak = streakJustUpdated ? newStreak : state.baseStreak;
        uint256 baseReward = _questBaseReward(rewardStreak, quest.flags, priceUnit);
        uint256 rewardShare = baseReward / QUEST_SLOT_COUNT;
        if (streakJustUpdated) {
            rewardShare += _questStreakBonus(newStreak, priceUnit);
        }
        return (rewardShare, isHard, quest.questType, newStreak, true);
    }

    /// @dev Base reward scales with streak tiers and difficulty modifiers, before per-slot split.
    function _questBaseReward(
        uint32 streak,
        uint8 questFlags,
        uint256 priceUnit
    ) private pure returns (uint256 totalReward) {
        totalReward = priceUnit / 5; // 20% of mint coin cost
        uint8 tier = _questTier(streak);
        if ((questFlags & QUEST_FLAG_HIGH_DIFFICULTY) != 0 && streak >= QUEST_TIER_STREAK_SPAN) {
            totalReward += priceUnit / 20; // +5% for high difficulty
        }
        if ((questFlags & QUEST_FLAG_VERY_HIGH_DIFFICULTY) != 0 && tier >= 4) {
            totalReward += priceUnit / 20; // +5% for very high difficulty in upper tiers
        }
    }

    /// @dev Bonus applied when a new streak milestone is reached (paid once per day on the final slot).
    function _questStreakBonus(uint32 streak, uint256 priceUnit) private pure returns (uint256 bonusReward) {
        if (streak < 5) return 0;
        if (streak != 5 && (streak % 10) != 0) return 0;
        uint256 bonus = uint256(streak) * (priceUnit / 10); // 10% of mint coin cost per streak unit
        uint256 maxBonus = priceUnit * 3; // Cap at 3x mint coin cost
        if (bonus > maxBonus) bonus = maxBonus;
        return bonus;
    }

    /// @dev Seeds a quest slot with a given type and difficulty flags.
    function _seedQuestType(DailyQuest storage quest, uint48 day, uint256 entropy, uint8 questType) private {
        uint16 difficulty = uint16(entropy & 0x3FF);
        quest.day = day;
        quest.questType = questType;
        quest.flags = _difficultyFlags(difficulty);
        quest.entropy = entropy;
        quest.version = _nextQuestVersion();
    }

    /// @dev Helper to read the active day from either slot (slot0 preferred).
    function _currentQuestDay(DailyQuest[QUEST_SLOT_COUNT] memory quests) private pure returns (uint48) {
        uint48 day0 = quests[0].day;
        if (day0 != 0) return day0;
        return quests[1].day;
    }

    /// @dev ETH mint eligibility is based on the last ETH mint level being within three levels.
    function _hasRecentEthMint(address player) private view returns (bool) {
        if (player == address(0)) {
            return false;
        }
        IDegenerusGame game_ = questGame;
        if (address(game_) == address(0)) {
            return false;
        }
        uint24 lastLevel = game_.ethMintLastLevel(player);
        if (lastLevel == 0) {
            return false;
        }
        uint24 currentLevel = game_.level();
        if (currentLevel <= lastLevel) {
            return true;
        }
        return currentLevel - lastLevel <= 3;
    }

    /// @dev ETH priming can be satisfied via forced progress (same day) or recent ETH mint history.
    function _ethMintReady(PlayerQuestState storage state, address player) private view returns (bool) {
        if ((state.completionMask & QUEST_STATE_ETH_PRIMED) != 0) {
            return true;
        }
        return _hasRecentEthMint(player);
    }
}

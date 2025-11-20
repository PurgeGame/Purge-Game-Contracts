// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IPurgeQuestModule.sol";
import "../interfaces/IPurgeGame.sol";

contract PurgeQuestModule is IPurgeQuestModule {
    error OnlyCoin();
    error InvalidQuestDay();
    error InvalidEntropy();

    uint256 private constant MILLION = 1e6;
    uint8 private constant QUEST_SLOT_COUNT = 2;
    uint8 private constant QUEST_TYPE_MINT_ANY = 0;
    uint8 private constant QUEST_TYPE_MINT_ETH = 1;
    uint8 private constant QUEST_TYPE_FLIP = 2;
    uint8 private constant QUEST_TYPE_STAKE = 3;
    uint8 private constant QUEST_TYPE_AFFILIATE = 4;
    uint8 private constant QUEST_TYPE_PURGE = 5;
    uint8 private constant QUEST_TYPE_DECIMATOR = 6;
    uint8 private constant QUEST_TYPE_COUNT = 7;
    uint8 private constant QUEST_FLAG_HIGH_DIFFICULTY = 1 << 0;
    uint8 private constant QUEST_STAKE_REQUIRE_PRINCIPAL = 1 << 0;
    uint8 private constant QUEST_STAKE_REQUIRE_DISTANCE = 1 << 1;
    uint8 private constant QUEST_STAKE_REQUIRE_RISK = 1 << 2;
    uint8 private constant QUEST_TIER_MAX_INDEX = 10;
    uint32 private constant QUEST_TIER_STREAK_SPAN = 7;
    uint8 private constant QUEST_STATE_COMPLETED_SLOT0 = 1 << 0;
    uint8 private constant QUEST_STATE_COMPLETED_SLOTS_MASK = (uint8(1) << QUEST_SLOT_COUNT) - 1;
    uint8 private constant QUEST_STATE_STREAK_CREDITED = 1 << 7;
    uint16 private constant QUEST_MIN_TOKEN = 250;
    uint16 private constant QUEST_MIN_MINT = 1;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;

    address public immutable coin;
    IPurgeGame private questGame;

    struct DailyQuest {
        uint48 day;
        uint8 questType;
        uint8 stakeMask;
        uint8 stakeRisk;
        uint8 flags;
        uint256 entropy;
    }

    struct PlayerQuestState {
        uint32 lastCompletedDay;
        uint32 streak;
        uint32 baseStreak;
        uint32 lastSyncDay;
        uint32[QUEST_SLOT_COUNT] lastProgressDay;
        uint128[QUEST_SLOT_COUNT] progress;
        uint32 forcedProgressDay;
        uint128 forcedProgress;
        uint8 completionMask;
    }

    DailyQuest[QUEST_SLOT_COUNT] private activeQuests;
    mapping(address => PlayerQuestState) private questPlayerState;
    uint48 private forcedMintEthQuestDay;

    uint256 private constant QUEST_MINT_ANY_PACKED = 0x0000000000000000000000080008000800080008000700060005000400030002;
    uint256 private constant QUEST_MINT_ETH_PACKED = 0x0000000000000000000000050005000400040004000300030002000200020001;
    uint256 private constant QUEST_FLIP_PACKED = 0x0000000000000000000009c409c408fc076c060e04e203e80320028a01f40190;
    uint256 private constant QUEST_STAKE_PRINCIPAL_PACKED =
        0x0000000000000000000009c409c40898072105dc04c903e8033902a3020d0190;
    uint256 private constant QUEST_AFFILIATE_PACKED =
        0x00000000000000000000060e060e060e060e060e060e04e203e80320028a01f4;
    uint256 private constant QUEST_STAKE_DISTANCE_MIN_PACKED =
        0x00000000000000000000001900190019001900190019001900190014000f000a;
    uint256 private constant QUEST_STAKE_DISTANCE_MAX_PACKED =
        0x00000000000000000000004b004b004b004b00460041003c00370032002d0028;

    constructor(address coin_) {
        coin = coin_;
    }

    function wireGame(address game_) external onlyCoin {
        questGame = IPurgeGame(game_);
    }

    modifier onlyCoin() {
        if (msg.sender != coin) revert OnlyCoin();
        _;
    }

    function primeMintEthQuest(uint48 day) external onlyCoin {
        forcedMintEthQuestDay = day;
    }

    function getQuestDetails() external view override returns (QuestDetail[QUEST_SLOT_COUNT] memory quests) {
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = activeQuests[slot];
            quests[slot] = QuestDetail({
                day: quest.day,
                questType: quest.questType,
                highDifficulty: (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0,
                stakeMask: quest.stakeMask,
                stakeRisk: quest.stakeRisk,
                entropy: quest.entropy
            });
            unchecked {
                ++slot;
            }
        }
    }

    function rollDailyQuest(
        uint48 day,
        uint256 entropy
    ) external onlyCoin returns (bool rolled, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk) {
        if (day == 0) revert InvalidQuestDay();
        if (entropy == 0) revert InvalidEntropy();
        DailyQuest[QUEST_SLOT_COUNT] storage quests = activeQuests;
        bool purgeAllowed = _canRollPurgeQuest();
        bool decAllowed = _canRollDecimatorQuest();
        _normalizeActivePurgeQuestsStorage(quests, purgeAllowed);
        if (_questsCurrent(quests, day)) {
            DailyQuest storage current = quests[0];
            bool hard = (current.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
            return (false, current.questType, hard, current.stakeMask, current.stakeRisk);
        }
        bool forceMintEth;
        uint48 forcedDay = forcedMintEthQuestDay;
        if (forcedDay != 0 && day >= forcedDay) {
            forceMintEth = day == forcedDay;
            forcedMintEthQuestDay = 0;
        }
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            uint8 exclude = slot == 0 ? type(uint8).max : quests[0].questType;
            uint256 slotEntropy = entropy;
            if (slot == 1) {
                // Re-use the other half of the VRF word instead of hashing again.
                slotEntropy = (entropy >> 128) | (entropy << 128);
            }
            _seedQuest(quests[slot], day, slotEntropy, exclude);
            if (slot == 0 && forceMintEth) {
                quests[slot].questType = QUEST_TYPE_MINT_ETH;
            } else {
                _applyQuestTypeConstraints(quests, slot, purgeAllowed, decAllowed);
            }
            unchecked {
                ++slot;
            }
        }
        _ensureDistinctQuestTypes(quests, purgeAllowed, decAllowed, day, entropy);
        DailyQuest storage primary = quests[0];
        bool hardMode = (primary.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        return (true, primary.questType, hardMode, primary.stakeMask, primary.stakeRisk);
    }

    function handleMint(
        address player,
        uint32 quantity,
        bool paidWithEth
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _normalizeActivePurgeQuests();
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        bool mintedRecently = _hasRecentEthMint(player);
        if (player == address(0) || quantity == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }

        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        if (!mintedRecently) {
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
                    tier
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

    function handleFlip(
        address player,
        uint256 flipCredit
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _normalizeActivePurgeQuests();
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || flipCredit == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        bool matched;
        uint8 fallbackType = quests[0].questType;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay || quest.questType != QUEST_TYPE_FLIP) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            matched = true;
            fallbackType = quest.questType;
            _questSyncProgress(state, slot, currentDay);
            uint128 clamped = _clampToUint128(flipCredit);
            if (clamped > state.progress[slot]) {
                state.progress[slot] = clamped;
            }
            uint256 target = uint256(_questFlipTargetTokens(tier, quest.entropy)) * MILLION;
            if (state.progress[slot] >= target) {
                return _questComplete(state, slot, quest);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_FLIP, state.streak, false);
    }

    function handleDecimator(
        address player,
        uint256 burnAmount
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _normalizeActivePurgeQuests();
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || burnAmount == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        bool matched;
        uint8 fallbackType = quests[0].questType;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay || quest.questType != QUEST_TYPE_DECIMATOR) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            matched = true;
            fallbackType = quest.questType;
            _questSyncProgress(state, slot, currentDay);
            uint128 clamped = _clampToUint128(burnAmount);
            if (clamped > state.progress[slot]) {
                state.progress[slot] = clamped;
            }
            uint256 target = uint256(_questDecimatorTargetTokens(tier, quest.entropy)) * MILLION;
            if (state.progress[slot] >= target) {
                return _questComplete(state, slot, quest);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_DECIMATOR, state.streak, false);
    }

    function handleStake(
        address player,
        uint256 principal,
        uint24 distance,
        uint8 risk
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _normalizeActivePurgeQuests();
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        if (player == address(0) || currentDay == 0) {
            return (0, false, quests[0].questType, questPlayerState[player].streak, false);
        }
        PlayerQuestState storage state = questPlayerState[player];
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        bool matched;
        uint8 fallbackType = quests[0].questType;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay || quest.questType != QUEST_TYPE_STAKE) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            matched = true;
            fallbackType = quest.questType;
            bool meets = true;
            if ((quest.stakeMask & QUEST_STAKE_REQUIRE_PRINCIPAL) != 0) {
                uint256 requiredPrincipal = uint256(_questStakePrincipalTarget(tier, quest.entropy)) * MILLION;
                meets = principal >= requiredPrincipal;
            }
            if (meets && (quest.stakeMask & QUEST_STAKE_REQUIRE_DISTANCE) != 0) {
                uint16 requiredDistance = _questStakeDistanceTarget(tier, quest.entropy);
                meets = distance >= requiredDistance;
            }
            if (meets && (quest.stakeMask & QUEST_STAKE_REQUIRE_RISK) != 0) {
                meets = risk >= quest.stakeRisk;
            }
            if (meets) {
                return _questComplete(state, slot, quest);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_STAKE, state.streak, false);
    }

    function handleAffiliate(
        address player,
        uint256 amount
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _normalizeActivePurgeQuests();
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || amount == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        bool matched;
        uint8 fallbackType = quests[0].questType;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay || quest.questType != QUEST_TYPE_AFFILIATE) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            matched = true;
            fallbackType = quest.questType;
            _questSyncProgress(state, slot, currentDay);
            state.progress[slot] = _clampedAdd128(state.progress[slot], amount);
            uint256 target = uint256(_questAffiliateTargetTokens(tier, quest.entropy)) * MILLION;
            if (state.progress[slot] >= target) {
                return _questComplete(state, slot, quest);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_AFFILIATE, state.streak, false);
    }

    function handlePurge(
        address player,
        uint32 quantity
    ) external onlyCoin returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _normalizeActivePurgeQuests();
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || quantity == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);
        uint8 tier = _questTier(state.baseStreak);

        bool matched;
        uint8 fallbackType = quests[0].questType;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = quests[slot];
            if (quest.day != currentDay || quest.questType != QUEST_TYPE_PURGE) {
                unchecked {
                    ++slot;
                }
                continue;
            }
            matched = true;
            fallbackType = quest.questType;
            _questSyncProgress(state, slot, currentDay);
            state.progress[slot] = _clampedAdd128(state.progress[slot], quantity);
            uint32 target = _questPurgeTarget(tier, quest.entropy);
            if (state.progress[slot] >= target) {
                return _questComplete(state, slot, quest);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_PURGE, state.streak, false);
    }

    function getActiveQuest()
        external
        view
        override
        returns (uint48 day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk)
    {
        DailyQuest[QUEST_SLOT_COUNT] memory local = _materializeActiveQuestsForView();
        DailyQuest memory quest = local[0];
        return (
            quest.day,
            quest.questType,
            (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0,
            quest.stakeMask,
            quest.stakeRisk
        );
    }

    function getActiveQuests() external view override returns (QuestInfo[2] memory quests) {
        DailyQuest[QUEST_SLOT_COUNT] memory local = _materializeActiveQuestsForView();
        for (uint8 slot2; slot2 < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = local[slot2];
            quests[slot2] = QuestInfo({
                day: quest.day,
                questType: quest.questType,
                highDifficulty: (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0,
                stakeMask: quest.stakeMask,
                stakeRisk: quest.stakeRisk
            });
            unchecked {
                ++slot2;
            }
        }
    }

    function _materializeActiveQuestsForView()
        private
        view
        returns (DailyQuest[QUEST_SLOT_COUNT] memory local)
    {
        local = activeQuests;
        bool purgeAllowed = _canRollPurgeQuest();
        if (purgeAllowed) return local;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            if (local[slot].questType == QUEST_TYPE_PURGE) {
                uint8 otherSlot = slot == 0 ? uint8(1) : uint8(0);
                if (local[otherSlot].questType == QUEST_TYPE_MINT_ETH) {
                    local[slot].questType = QUEST_TYPE_STAKE;
                    (local[slot].stakeMask, local[slot].stakeRisk) = _stakeQuestMaskAndRisk(local[slot].entropy);
                } else {
                    local[slot].questType = QUEST_TYPE_MINT_ETH;
                    local[slot].stakeMask = 0;
                    local[slot].stakeRisk = 0;
                }
            }
            unchecked {
                ++slot;
            }
        }
    }

    function playerQuestState(
        address player
    ) external view override returns (uint32 streak, uint32 lastCompletedDay, uint128 progress, bool completedToday) {
        PlayerQuestState memory state = questPlayerState[player];
        streak = state.streak;
        lastCompletedDay = state.lastCompletedDay;
        DailyQuest memory quest = activeQuests[0];
        if (quest.day != 0 && state.lastProgressDay[0] == quest.day) {
            progress = state.progress[0];
            completedToday =
                state.lastSyncDay == quest.day &&
                (state.completionMask & QUEST_STATE_COMPLETED_SLOT0) != 0;
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
        PlayerQuestState memory state = questPlayerState[player];
        streak = state.streak;
        lastCompletedDay = state.lastCompletedDay;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = activeQuests[slot];
            if (quest.day != 0 && state.lastProgressDay[slot] == quest.day) {
                progress[slot] = state.progress[slot];
                completed[slot] = state.lastSyncDay == quest.day && (state.completionMask & uint8(1 << slot)) != 0;
            } else {
                progress[slot] = 0;
                completed[slot] = false;
            }
            unchecked {
                ++slot;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _normalizeActivePurgeQuests() private {
        DailyQuest[QUEST_SLOT_COUNT] storage quests = activeQuests;
        bool purgeAllowed = _canRollPurgeQuest();
        _normalizeActivePurgeQuestsStorage(quests, purgeAllowed);
    }

    function _normalizeActivePurgeQuestsStorage(
        DailyQuest[QUEST_SLOT_COUNT] storage quests,
        bool purgeAllowed
    ) private {
        if (purgeAllowed) return;
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest storage quest = quests[slot];
            if (quest.questType == QUEST_TYPE_PURGE) {
                _convertPurgeQuest(quests, slot);
            }
            unchecked {
                ++slot;
            }
        }
    }

    function _convertPurgeQuest(DailyQuest[QUEST_SLOT_COUNT] storage quests, uint8 slot) private {
        DailyQuest storage quest = quests[slot];
        uint8 otherSlot = slot == 0 ? uint8(1) : uint8(0);
        DailyQuest storage other = quests[otherSlot];
        if (other.questType == QUEST_TYPE_MINT_ETH) {
            quest.questType = QUEST_TYPE_STAKE;
            (quest.stakeMask, quest.stakeRisk) = _stakeQuestMaskAndRisk(quest.entropy);
        } else {
            quest.questType = QUEST_TYPE_MINT_ETH;
            quest.stakeMask = 0;
            quest.stakeRisk = 0;
        }
    }

    function _canRollPurgeQuest() private view returns (bool) {
        IPurgeGame game_ = questGame;
        if (address(game_) == address(0)) {
            return false;
        }
        return game_.gameState() == 3;
    }

    function _canRollDecimatorQuest() private view returns (bool) {
        IPurgeGame game_ = questGame;
        if (address(game_) == address(0)) {
            return false;
        }
        uint24 lvl = game_.level();
        if (lvl == DECIMATOR_SPECIAL_LEVEL) {
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

    function _clampToUint128(uint256 value) private pure returns (uint128) {
        return value > type(uint128).max ? type(uint128).max : uint128(value);
    }

    function _questHandleMintSlot(
        PlayerQuestState storage state,
        DailyQuest memory quest,
        uint8 slot,
        uint32 quantity,
        uint8 tier
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _questSyncProgress(state, slot, quest.day);
        state.progress[slot] = _clampedAdd128(state.progress[slot], quantity);
        uint32 target = quest.questType == QUEST_TYPE_MINT_ANY
            ? _questMintAnyTarget(tier, quest.entropy)
            : _questMintEthTarget(tier, quest.entropy);
        if (state.progress[slot] >= target) {
            return _questComplete(state, slot, quest);
        }
        return (0, false, quest.questType, state.streak, false);
    }

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

    function _questSyncProgress(PlayerQuestState storage state, uint8 slot, uint48 currentDay) private {
        if (state.lastProgressDay[slot] != currentDay) {
            state.lastProgressDay[slot] = uint32(currentDay);
            state.progress[slot] = 0;
        }
    }

    function _syncForcedProgress(PlayerQuestState storage state, uint48 currentDay) private {
        if (state.forcedProgressDay != currentDay) {
            state.forcedProgressDay = uint32(currentDay);
            state.forcedProgress = 0;
        }
    }

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

    function _questMintAnyTarget(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_MINT_ANY_PACKED, tier);
        if (maxVal <= QUEST_MIN_MINT) {
            return QUEST_MIN_MINT;
        }
        uint256 rand = _questRand(entropy, QUEST_TYPE_MINT_ANY, tier, 0);
        return uint32(rand % maxVal) + QUEST_MIN_MINT;
    }

    function _questMintEthTarget(uint8 tier, uint256 entropy) private pure returns (uint32) {
        if (tier == 0) {
            return QUEST_MIN_MINT;
        }
        uint16 maxVal = _questPackedValue(QUEST_MINT_ETH_PACKED, tier);
        if (maxVal <= QUEST_MIN_MINT) {
            return QUEST_MIN_MINT;
        }
        uint256 rand = _questRand(entropy, QUEST_TYPE_MINT_ETH, tier, 0);
        return uint32(rand % maxVal) + QUEST_MIN_MINT;
    }

    function _questPurgeTarget(uint8 tier, uint256 entropy) private pure returns (uint32) {
        return _questMintEthTarget(tier, entropy);
    }

    function _questFlipTargetTokens(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_FLIP_PACKED, tier);
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_FLIP, tier, 0);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questDecimatorTargetTokens(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint32 base = _questFlipTargetTokens(tier, entropy);
        uint32 doubled = base * 2;
        if (doubled < base) {
            return type(uint32).max;
        }
        return doubled;
    }

    function _questStakePrincipalTarget(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_STAKE_PRINCIPAL_PACKED, tier);
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_STAKE, tier, 1);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questStakeDistanceTarget(uint8 tier, uint256 entropy) private pure returns (uint16) {
        uint16 minVal = _questPackedValue(QUEST_STAKE_DISTANCE_MIN_PACKED, tier);
        uint16 maxVal = _questPackedValue(QUEST_STAKE_DISTANCE_MAX_PACKED, tier);
        uint256 range = uint256(maxVal) - minVal + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_STAKE, tier, 2);
        return uint16(uint256(minVal) + (rand % range));
    }

    function _questAffiliateTargetTokens(uint8 tier, uint256 entropy) private pure returns (uint32) {
        uint16 maxVal = _questPackedValue(QUEST_AFFILIATE_PACKED, tier);
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_AFFILIATE, tier, 0);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questRand(uint256 entropy, uint8 questType, uint8 tier, uint8 salt) private pure returns (uint256) {
        if (entropy == 0) return 0;
        return uint256(keccak256(abi.encode(entropy, questType, tier, salt)));
    }

    function _applyQuestTypeConstraints(
        DailyQuest[QUEST_SLOT_COUNT] storage quests,
        uint8 slot,
        bool purgeAllowed,
        bool decAllowed
    ) private {
        DailyQuest storage quest = quests[slot];
        if (quest.questType == QUEST_TYPE_PURGE && !purgeAllowed) {
            _convertPurgeQuest(quests, slot);
        } else if (quest.questType == QUEST_TYPE_DECIMATOR && !decAllowed) {
            quest.questType = QUEST_TYPE_FLIP;
        }
    }

    function _ensureDistinctQuestTypes(
        DailyQuest[QUEST_SLOT_COUNT] storage quests,
        bool purgeAllowed,
        bool decAllowed,
        uint48 day,
        uint256 entropy
    ) private {
        if (QUEST_SLOT_COUNT < 2) return;
        uint8 referenceType = quests[0].questType;
        if (quests[1].questType != referenceType) return;
        for (uint8 attempt; attempt < QUEST_TYPE_COUNT * 2; ) {
            uint256 attemptEntropy = uint256(keccak256(abi.encode(entropy, day, attempt + 1)));
            _seedQuest(quests[1], day, attemptEntropy, referenceType);
            _applyQuestTypeConstraints(quests, 1, purgeAllowed, decAllowed);
            if (quests[1].questType != referenceType) {
                return;
            }
            unchecked {
                ++attempt;
            }
        }
        quests[1].questType = _fallbackQuestType(referenceType, purgeAllowed, decAllowed);
    }

    function _fallbackQuestType(
        uint8 exclude,
        bool purgeAllowed,
        bool decAllowed
    ) private pure returns (uint8) {
        for (uint8 offset = 1; offset < QUEST_TYPE_COUNT; ) {
            uint8 candidate = uint8((uint256(exclude) + offset) % QUEST_TYPE_COUNT);
            if (candidate == QUEST_TYPE_PURGE && !purgeAllowed) {
                candidate = (exclude == QUEST_TYPE_MINT_ETH) ? QUEST_TYPE_STAKE : QUEST_TYPE_MINT_ETH;
            } else if (candidate == QUEST_TYPE_DECIMATOR && !decAllowed) {
                candidate = QUEST_TYPE_FLIP;
            }
            if (candidate != exclude) {
                return candidate;
            }
            unchecked {
                ++offset;
            }
        }
        return QUEST_TYPE_MINT_ETH;
    }

    function _questCompleteForced(
        PlayerQuestState storage state,
        uint48 currentDay
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        if ((state.completionMask & QUEST_STATE_STREAK_CREDITED) == 0) {
            state.completionMask |= QUEST_STATE_STREAK_CREDITED;
            uint32 newStreak = state.streak + 1;
            state.streak = newStreak;
            state.lastCompletedDay = uint32(currentDay);
        }
        return (0, false, QUEST_TYPE_MINT_ETH, state.streak, true);
    }

    function _questComplete(
        PlayerQuestState storage state,
        uint8 slot,
        DailyQuest memory quest
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        uint8 slotMask = uint8(1 << slot);
        if ((state.completionMask & slotMask) != 0) {
            return (0, false, quest.questType, state.streak, false);
        }
        state.completionMask |= slotMask;
        uint32 newStreak = state.streak;
        if ((state.completionMask & QUEST_STATE_STREAK_CREDITED) == 0) {
            uint8 completedSlots = state.completionMask & QUEST_STATE_COMPLETED_SLOTS_MASK;
            if (completedSlots == QUEST_STATE_COMPLETED_SLOTS_MASK) {
                state.completionMask |= QUEST_STATE_STREAK_CREDITED;
                newStreak = state.streak + 1;
                state.streak = newStreak;
                state.lastCompletedDay = uint32(quest.day);
            }
        }
        bool isHard = (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        uint256 totalReward = _questTotalReward(newStreak, quest.flags);
        uint256 rewardShare = totalReward / QUEST_SLOT_COUNT;
        return (rewardShare, isHard, quest.questType, newStreak, true);
    }

    function _questTotalReward(uint32 streak, uint8 questFlags) private pure returns (uint256 totalReward) {
        totalReward = 200 * MILLION;
        if (streak >= 5 && (streak == 5 || (streak % 10) == 0)) {
            uint256 bonus = uint256(streak) * 100;
            if (bonus > 3000) bonus = 3000;
            totalReward += bonus * MILLION;
        }
        if ((questFlags & QUEST_FLAG_HIGH_DIFFICULTY) != 0 && streak >= QUEST_TIER_STREAK_SPAN) {
            totalReward += 100 * MILLION;
        }
    }

    function _stakeQuestMaskAndRisk(uint256 entropy) private pure returns (uint8 mask, uint8 risk) {
        mask = QUEST_STAKE_REQUIRE_DISTANCE;
        bool requirePrincipal = ((entropy >> 16) & 1) == 0;
        if (requirePrincipal) {
            mask |= QUEST_STAKE_REQUIRE_PRINCIPAL;
        } else {
            mask |= QUEST_STAKE_REQUIRE_RISK;
            risk = uint8(2 + uint8((entropy >> 40) % 10));
        }
    }

    function _seedQuest(DailyQuest storage quest, uint48 day, uint256 entropy, uint8 excludeType) private {
        uint8 qType = uint8(entropy % QUEST_TYPE_COUNT);
        if (excludeType != type(uint8).max && qType == excludeType) {
            qType = uint8((qType + 1 + uint8(entropy % (QUEST_TYPE_COUNT - 1))) % QUEST_TYPE_COUNT);
        }
        uint8 flags = (uint16(entropy & 0x3FF) >= 900) ? QUEST_FLAG_HIGH_DIFFICULTY : 0;
        uint8 mask;
        uint8 risk;
        if (qType == QUEST_TYPE_STAKE) {
            (mask, risk) = _stakeQuestMaskAndRisk(entropy);
        }
        quest.day = day;
        quest.questType = qType;
        quest.stakeMask = mask;
        quest.stakeRisk = risk;
        quest.flags = flags;
        quest.entropy = entropy;
    }

    function _questsCurrent(DailyQuest[QUEST_SLOT_COUNT] storage quests, uint48 day) private view returns (bool) {
        if (day == 0) return false;
        return quests[0].day == day && quests[1].day == day;
    }

    function _currentQuestDay(DailyQuest[QUEST_SLOT_COUNT] memory quests) private pure returns (uint48) {
        uint48 day0 = quests[0].day;
        if (day0 != 0) return day0;
        return quests[1].day;
    }

    function _hasRecentEthMint(address player) private view returns (bool) {
        if (player == address(0)) {
            return false;
        }
        IPurgeGame game_ = questGame;
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
}

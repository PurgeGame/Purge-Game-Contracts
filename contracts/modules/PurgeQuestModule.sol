// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IPurgeQuestModule.sol";

contract PurgeQuestModule is IPurgeQuestModule {
    error OnlyCoin();
    error InvalidQuestDay();

    uint256 private constant MILLION = 1e6;
    uint8 private constant QUEST_SLOT_COUNT = 2;
    uint8 private constant QUEST_TYPE_MINT_ANY = 0;
    uint8 private constant QUEST_TYPE_MINT_ETH = 1;
    uint8 private constant QUEST_TYPE_FLIP = 2;
    uint8 private constant QUEST_TYPE_STAKE = 3;
    uint8 private constant QUEST_TYPE_AFFILIATE = 4;
    uint8 private constant QUEST_TYPE_COUNT = 5;
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

    address public immutable coin;

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
    mapping(address => bool) private hasEthMint;

    uint16[11] private questMintAnyMax = [
        uint16(2),
        uint16(3),
        uint16(4),
        uint16(5),
        uint16(6),
        uint16(7),
        uint16(8),
        uint16(9),
        uint16(10),
        uint16(11),
        uint16(12)
    ];
    uint16[11] private questMintEthMax = [
        uint16(2),
        uint16(4),
        uint16(5),
        uint16(6),
        uint16(7),
        uint16(8),
        uint16(9),
        uint16(9),
        uint16(9),
        uint16(9),
        uint16(9)
    ];
    uint16[11] private questFlipMax = [
        uint16(400),
        uint16(500),
        uint16(650),
        uint16(800),
        uint16(1000),
        uint16(1250),
        uint16(1550),
        uint16(1900),
        uint16(2300),
        uint16(2500),
        uint16(2500)
    ];
    uint16[11] private questStakePrincipalMax = [
        uint16(400),
        uint16(525),
        uint16(675),
        uint16(825),
        uint16(1000),
        uint16(1225),
        uint16(1500),
        uint16(1825),
        uint16(2200),
        uint16(2500),
        uint16(2500)
    ];
    uint16[11] private questAffiliateMax = [
        uint16(500),
        uint16(650),
        uint16(800),
        uint16(1000),
        uint16(1250),
        uint16(1550),
        uint16(1550),
        uint16(1550),
        uint16(1550),
        uint16(1550),
        uint16(1550)
    ];
    uint16[11] private questStakeDistanceMin = [
        uint16(10),
        uint16(15),
        uint16(20),
        uint16(25),
        uint16(25),
        uint16(25),
        uint16(25),
        uint16(25),
        uint16(25),
        uint16(25),
        uint16(25)
    ];
    uint16[11] private questStakeDistanceMax = [
        uint16(40),
        uint16(45),
        uint16(50),
        uint16(55),
        uint16(60),
        uint16(65),
        uint16(70),
        uint16(75),
        uint16(75),
        uint16(75),
        uint16(75)
    ];

    constructor(address coin_) {
        coin = coin_;
    }

    modifier onlyCoin() {
        if (msg.sender != coin) revert OnlyCoin();
        _;
    }

    function rollDailyQuest(uint48 day, uint256 entropy)
        external
        onlyCoin
        returns (bool rolled, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk)
    {
        if (day == 0) revert InvalidQuestDay();
        DailyQuest[QUEST_SLOT_COUNT] storage quests = activeQuests;
        if (_questsCurrent(quests, day)) {
            DailyQuest storage current = quests[0];
            bool hard = (current.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
            return (false, current.questType, hard, current.stakeMask, current.stakeRisk);
        }
        if (entropy == 0) {
            entropy = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, day, coin)));
        }
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            uint8 exclude = slot == 0 ? type(uint8).max : quests[0].questType;
            uint256 slotEntropy = uint256(keccak256(abi.encode(entropy, slot)));
            _seedQuest(quests[slot], day, slotEntropy, exclude);
            unchecked {
                ++slot;
            }
        }
        DailyQuest storage primary = quests[0];
        bool hardMode = (primary.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        return (true, primary.questType, hardMode, primary.stakeMask, primary.stakeRisk);
    }

    function handleMint(address player, uint32 quantity, bool paidWithEth)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        bool hadEthMint = hasEthMint[player];
        if (paidWithEth && !hadEthMint) {
            hasEthMint[player] = true;
        }
        if (player == address(0) || quantity == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }

        _questSyncState(state, currentDay);

        if (!hadEthMint) {
            if (!paidWithEth) {
                return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
            }
            _syncForcedProgress(state, currentDay);
            uint256 updatedForced = uint256(state.forcedProgress) + quantity;
            if (updatedForced > type(uint128).max) updatedForced = type(uint128).max;
            state.forcedProgress = uint128(updatedForced);
            uint256 entropySource = quests[0].day == currentDay ? quests[0].entropy : quests[1].entropy;
            uint32 forcedTarget = _questMintEthTarget(state.baseStreak, entropySource);
            if (state.forcedProgress >= forcedTarget) {
                return _questCompleteForced(state, currentDay);
            }
            return (0, false, QUEST_TYPE_MINT_ETH, state.streak, false);
        }

        bool matched;
        uint8 fallbackType = quests[0].questType;
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
                (reward, hardMode, questType, streak, completed) = _questHandleMintSlot(state, quest, slot, quantity);
                if (completed) {
                    return (reward, hardMode, questType, streak, completed);
                }
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_MINT_ANY, state.streak, false);
    }

    function handleFlip(address player, uint256 flipCredit)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || flipCredit == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);

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
            uint256 clamped = flipCredit;
            if (clamped > type(uint128).max) clamped = type(uint128).max;
            if (clamped > state.progress[slot]) {
                state.progress[slot] = uint128(clamped);
            }
            uint256 target = uint256(_questFlipTargetTokens(state.baseStreak, quest.entropy)) * MILLION;
            if (state.progress[slot] >= target) {
                return _questComplete(state, slot, quest);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_FLIP, state.streak, false);
    }

    function handleStake(address player, uint256 principal, uint24 distance, uint8 risk)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        if (player == address(0) || currentDay == 0) {
            return (0, false, quests[0].questType, questPlayerState[player].streak, false);
        }
        PlayerQuestState storage state = questPlayerState[player];
        _questSyncState(state, currentDay);

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
            uint8 tier = _questTier(state.baseStreak);
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

    function handleAffiliate(address player, uint256 amount)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        DailyQuest[QUEST_SLOT_COUNT] memory quests = activeQuests;
        uint48 currentDay = _currentQuestDay(quests);
        PlayerQuestState storage state = questPlayerState[player];
        if (player == address(0) || amount == 0 || currentDay == 0) {
            return (0, false, quests[0].questType, state.streak, false);
        }
        _questSyncState(state, currentDay);

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
            uint256 updated = uint256(state.progress[slot]) + amount;
            if (updated > type(uint128).max) updated = type(uint128).max;
            state.progress[slot] = uint128(updated);
            uint256 target = uint256(_questAffiliateTargetTokens(state.baseStreak, quest.entropy)) * MILLION;
            if (state.progress[slot] >= target) {
                return _questComplete(state, slot, quest);
            }
            unchecked {
                ++slot;
            }
        }
        return (0, false, matched ? fallbackType : QUEST_TYPE_AFFILIATE, state.streak, false);
    }

    function getActiveQuest()
        external
        view
        override
        returns (uint48 day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk)
    {
        DailyQuest memory quest = activeQuests[0];
        return (quest.day, quest.questType, (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0, quest.stakeMask, quest.stakeRisk);
    }

    function getActiveQuests() external view override returns (QuestInfo[2] memory quests) {
        for (uint8 slot; slot < QUEST_SLOT_COUNT; ) {
            DailyQuest memory quest = activeQuests[slot];
            quests[slot] = QuestInfo({
                day: quest.day,
                questType: quest.questType,
                highDifficulty: (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0,
                stakeMask: quest.stakeMask,
                stakeRisk: quest.stakeRisk
            });
            unchecked {
                ++slot;
            }
        }
    }

    function playerQuestState(address player)
        external
        view
        override
        returns (uint32 streak, uint32 lastCompletedDay, uint128 progress, bool completedToday)
    {
        PlayerQuestState memory state = questPlayerState[player];
        streak = state.streak;
        lastCompletedDay = state.lastCompletedDay;
        DailyQuest memory quest = activeQuests[0];
        if (quest.day != 0 && state.lastProgressDay[0] == quest.day) {
            progress = state.progress[0];
            completedToday = state.lastSyncDay == quest.day && (state.completionMask & QUEST_STATE_COMPLETED_SLOT0) != 0;
        }
    }

    function playerQuestStates(address player)
        external
        view
        override
        returns (
            uint32 streak,
            uint32 lastCompletedDay,
            uint128[2] memory progress,
            bool[2] memory completed
        )
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

    function _questHandleMintSlot(
        PlayerQuestState storage state,
        DailyQuest memory quest,
        uint8 slot,
        uint32 quantity
    ) private returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) {
        _questSyncProgress(state, slot, quest.day);
        uint256 updated = uint256(state.progress[slot]) + quantity;
        if (updated > type(uint128).max) updated = type(uint128).max;
        state.progress[slot] = uint128(updated);
        uint32 target = quest.questType == QUEST_TYPE_MINT_ANY
            ? _questMintAnyTarget(state.baseStreak, quest.entropy)
            : _questMintEthTarget(state.baseStreak, quest.entropy);
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

    function _questMintAnyTarget(uint32 streak, uint256 entropy) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        uint16 maxVal = questMintAnyMax[tier];
        if (maxVal <= QUEST_MIN_MINT) {
            return QUEST_MIN_MINT;
        }
        uint256 rand = _questRand(entropy, QUEST_TYPE_MINT_ANY, tier, 0);
        return uint32(rand % maxVal) + QUEST_MIN_MINT;
    }

    function _questMintEthTarget(uint32 streak, uint256 entropy) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        if (tier == 0) {
            return QUEST_MIN_MINT;
        }
        uint16 maxVal = questMintEthMax[tier];
        if (maxVal <= QUEST_MIN_MINT) {
            return QUEST_MIN_MINT;
        }
        uint256 rand = _questRand(entropy, QUEST_TYPE_MINT_ETH, tier, 0);
        return uint32(rand % maxVal) + QUEST_MIN_MINT;
    }

    function _questFlipTargetTokens(uint32 streak, uint256 entropy) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        uint16 maxVal = questFlipMax[tier];
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_FLIP, tier, 0);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questStakePrincipalTarget(uint8 tier, uint256 entropy) private view returns (uint32) {
        uint16 maxVal = questStakePrincipalMax[tier];
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_STAKE, tier, 1);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questStakeDistanceTarget(uint8 tier, uint256 entropy) private view returns (uint16) {
        uint16 minVal = questStakeDistanceMin[tier];
        uint16 maxVal = questStakeDistanceMax[tier];
        uint256 range = uint256(maxVal) - minVal + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_STAKE, tier, 2);
        return uint16(uint256(minVal) + (rand % range));
    }

    function _questAffiliateTargetTokens(uint32 streak, uint256 entropy) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        uint16 maxVal = questAffiliateMax[tier];
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(entropy, QUEST_TYPE_AFFILIATE, tier, 0);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questRand(uint256 entropy, uint8 questType, uint8 tier, uint8 salt) private pure returns (uint256) {
        if (entropy == 0) return 0;
        return uint256(keccak256(abi.encode(entropy, questType, tier, salt)));
    }

    function _questCompleteForced(PlayerQuestState storage state, uint48 currentDay)
        private
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
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
        if ((questFlags & QUEST_FLAG_HIGH_DIFFICULTY) != 0) {
            totalReward += 100 * MILLION;
        }
    }

    function _seedQuest(
        DailyQuest storage quest,
        uint48 day,
        uint256 entropy,
        uint8 excludeType
    ) private {
        uint8 qType = uint8(entropy % QUEST_TYPE_COUNT);
        if (excludeType != type(uint8).max && qType == excludeType) {
            qType = uint8((qType + 1 + uint8(entropy % (QUEST_TYPE_COUNT - 1))) % QUEST_TYPE_COUNT);
        }
        uint8 flags = (uint16(entropy & 0x3FF) >= 900) ? QUEST_FLAG_HIGH_DIFFICULTY : 0;
        uint8 mask;
        uint8 risk;
        if (qType == QUEST_TYPE_STAKE) {
            mask = QUEST_STAKE_REQUIRE_DISTANCE;
            bool requirePrincipal = ((entropy >> 16) & 1) == 0;
            if (requirePrincipal) {
                mask |= QUEST_STAKE_REQUIRE_PRINCIPAL;
            } else {
                mask |= QUEST_STAKE_REQUIRE_RISK;
            }
            if ((mask & QUEST_STAKE_REQUIRE_RISK) != 0) {
                risk = uint8(2 + uint8((entropy >> 40) % 10));
            }
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
}

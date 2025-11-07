// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IPurgeQuestModule.sol";

contract PurgeQuestModule is IPurgeQuestModule {
    error OnlyCoin();
    error InvalidQuestDay();

    uint256 private constant MILLION = 1e6;
    uint8 private constant QUEST_TYPE_MINT_ANY = 0;
    uint8 private constant QUEST_TYPE_MINT_ETH = 1;
    uint8 private constant QUEST_TYPE_FLIP = 2;
    uint8 private constant QUEST_TYPE_STAKE = 3;
    uint8 private constant QUEST_TYPE_AFFILIATE = 4;
    uint8 private constant QUEST_TYPE_COUNT = 5;
    uint8 private constant QUEST_FLAG_HIGH_DIFFICULTY = 1 << 0;
    uint8 private constant QUEST_STATE_COMPLETED = 1 << 0;
    uint8 private constant QUEST_STAKE_REQUIRE_PRINCIPAL = 1 << 0;
    uint8 private constant QUEST_STAKE_REQUIRE_DISTANCE = 1 << 1;
    uint8 private constant QUEST_STAKE_REQUIRE_RISK = 1 << 2;
    uint8 private constant QUEST_TIER_MAX_INDEX = 10;
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
        uint32 lastProgressDay;
        uint32 lastCompletedDay;
        uint32 streak;
        uint128 progress;
        uint8 flags;
    }

    DailyQuest private activeQuest;
    mapping(address => PlayerQuestState) private questPlayerState;

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
        DailyQuest storage quest = activeQuest;
        if (quest.day == day) {
            return (false, quest.questType, (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0, quest.stakeMask, quest.stakeRisk);
        }
        if (entropy == 0) {
            entropy = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, day, coin)));
        }
        uint8 qType = uint8(entropy % QUEST_TYPE_COUNT);
        uint8 flags = (uint16(entropy & 0x3FF) >= 900) ? QUEST_FLAG_HIGH_DIFFICULTY : 0;
        uint8 mask;
        uint8 risk;
        if (qType == QUEST_TYPE_STAKE) {
            uint8 first = uint8((entropy >> 16) % 3);
            uint8 second = uint8((entropy >> 24) % 3);
            if (second == first) {
                second = uint8((second + 1) % 3);
            }
            mask = (uint8(1) << first) | (uint8(1) << second);
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
        return (true, qType, (flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0, mask, risk);
    }

    function handleMint(address player, uint32 quantity, bool paidWithEth)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        if (player == address(0) || quantity == 0) {
            return (0, false, activeQuest.questType, questPlayerState[player].streak, false);
        }
        return _questHandleMint(player, quantity, paidWithEth);
    }

    function handleFlip(address player, uint256 stakeCredit)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        if (player == address(0) || stakeCredit == 0 || activeQuest.day == 0 || activeQuest.questType != QUEST_TYPE_FLIP) {
            return (0, false, activeQuest.questType, questPlayerState[player].streak, false);
        }
        PlayerQuestState storage state = questPlayerState[player];
        _questSyncState(state, activeQuest.day);
        if (stakeCredit > state.progress) {
            uint256 clamped = stakeCredit;
            if (clamped > type(uint128).max) clamped = type(uint128).max;
            state.progress = uint128(clamped);
        }
        uint256 target = uint256(_questFlipTargetTokens(state.streak)) * MILLION;
        if (state.progress >= target) {
            return _questComplete(state);
        }
        return (0, false, activeQuest.questType, state.streak, false);
    }

    function handleStake(address player, uint256 principal, uint24 distance, uint8 risk)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        DailyQuest memory quest = activeQuest;
        if (player == address(0) || quest.day == 0 || quest.questType != QUEST_TYPE_STAKE) {
            return (0, false, quest.questType, questPlayerState[player].streak, false);
        }
        PlayerQuestState storage state = questPlayerState[player];
        _questSyncState(state, quest.day);
        bool meets = true;
        uint8 tier = _questTier(state.streak);
        if ((quest.stakeMask & QUEST_STAKE_REQUIRE_PRINCIPAL) != 0) {
            uint256 requiredPrincipal = uint256(_questStakePrincipalTarget(tier)) * MILLION;
            meets = principal >= requiredPrincipal;
        }
        if (meets && (quest.stakeMask & QUEST_STAKE_REQUIRE_DISTANCE) != 0) {
            uint16 requiredDistance = _questStakeDistanceTarget(tier);
            meets = distance >= requiredDistance;
        }
        if (meets && (quest.stakeMask & QUEST_STAKE_REQUIRE_RISK) != 0) {
            meets = risk >= quest.stakeRisk;
        }
        if (meets) {
            return _questComplete(state);
        }
        return (0, false, quest.questType, state.streak, false);
    }

    function handleAffiliate(address player, uint256 amount)
        external
        onlyCoin
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        if (player == address(0) || amount == 0 || activeQuest.day == 0 || activeQuest.questType != QUEST_TYPE_AFFILIATE) {
            return (0, false, activeQuest.questType, questPlayerState[player].streak, false);
        }
        PlayerQuestState storage state = questPlayerState[player];
        _questSyncState(state, activeQuest.day);
        uint256 updated = uint256(state.progress) + amount;
        if (updated > type(uint128).max) updated = type(uint128).max;
        state.progress = uint128(updated);
        uint256 target = uint256(_questAffiliateTargetTokens(state.streak)) * MILLION;
        if (state.progress >= target) {
            return _questComplete(state);
        }
        return (0, false, activeQuest.questType, state.streak, false);
    }

    function getActiveQuest()
        external
        view
        override
        returns (uint48 day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk)
    {
        DailyQuest memory quest = activeQuest;
        return (quest.day, quest.questType, (quest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0, quest.stakeMask, quest.stakeRisk);
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
        if (state.lastProgressDay == activeQuest.day) {
            progress = state.progress;
            completedToday = (state.flags & QUEST_STATE_COMPLETED) != 0;
        } else {
            progress = 0;
            completedToday = false;
        }
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _questHandleMint(address player, uint32 quantity, bool paidWithEth)
        private
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        DailyQuest memory quest = activeQuest;
        if (quest.day == 0) {
            PlayerQuestState storage emptyState = questPlayerState[player];
            return (0, false, quest.questType, emptyState.streak, false);
        }
        PlayerQuestState storage state = questPlayerState[player];
        _questSyncState(state, quest.day);
        if (quest.questType == QUEST_TYPE_MINT_ANY || (paidWithEth && quest.questType == QUEST_TYPE_MINT_ETH)) {
            uint256 updated = uint256(state.progress) + quantity;
            if (updated > type(uint128).max) updated = type(uint128).max;
            state.progress = uint128(updated);
            uint32 target = quest.questType == QUEST_TYPE_MINT_ANY
                ? _questMintAnyTarget(state.streak)
                : _questMintEthTarget(state.streak);
            if (state.progress >= target) {
                return _questComplete(state);
            }
        }
        return (0, false, quest.questType, state.streak, false);
    }

    function _questSyncState(PlayerQuestState storage state, uint48 currentDay) private {
        if (state.lastCompletedDay != 0 && currentDay > uint48(state.lastCompletedDay + 1)) {
            state.streak = 0;
        }
        if (state.lastProgressDay != currentDay) {
            state.lastProgressDay = uint32(currentDay);
            state.progress = 0;
            state.flags = 0;
        }
    }

    function _questTier(uint32 streak) private pure returns (uint8) {
        uint32 tier = streak / 5;
        if (tier > QUEST_TIER_MAX_INDEX) {
            tier = QUEST_TIER_MAX_INDEX;
        }
        return uint8(tier);
    }

    function _questMintAnyTarget(uint32 streak) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        uint16 maxVal = questMintAnyMax[tier];
        if (maxVal <= QUEST_MIN_MINT) {
            return QUEST_MIN_MINT;
        }
        uint256 rand = _questRand(QUEST_TYPE_MINT_ANY, tier, 0);
        return uint32(rand % maxVal) + QUEST_MIN_MINT;
    }

    function _questMintEthTarget(uint32 streak) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        uint16 maxVal = questMintEthMax[tier];
        if (maxVal <= QUEST_MIN_MINT) {
            return QUEST_MIN_MINT;
        }
        uint256 rand = _questRand(QUEST_TYPE_MINT_ETH, tier, 0);
        return uint32(rand % maxVal) + QUEST_MIN_MINT;
    }

    function _questFlipTargetTokens(uint32 streak) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        uint16 maxVal = questFlipMax[tier];
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(QUEST_TYPE_FLIP, tier, 0);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questStakePrincipalTarget(uint8 tier) private view returns (uint32) {
        uint16 maxVal = questStakePrincipalMax[tier];
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(QUEST_TYPE_STAKE, tier, 1);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questStakeDistanceTarget(uint8 tier) private view returns (uint16) {
        uint16 minVal = questStakeDistanceMin[tier];
        uint16 maxVal = questStakeDistanceMax[tier];
        uint256 range = uint256(maxVal) - minVal + 1;
        uint256 rand = _questRand(QUEST_TYPE_STAKE, tier, 2);
        return uint16(uint256(minVal) + (rand % range));
    }

    function _questAffiliateTargetTokens(uint32 streak) private view returns (uint32) {
        uint8 tier = _questTier(streak);
        uint16 maxVal = questAffiliateMax[tier];
        uint256 range = uint256(maxVal) - QUEST_MIN_TOKEN + 1;
        uint256 rand = _questRand(QUEST_TYPE_AFFILIATE, tier, 0);
        return uint32(uint256(QUEST_MIN_TOKEN) + (rand % range));
    }

    function _questRand(uint8 questType, uint8 tier, uint8 salt) private view returns (uint256) {
        uint256 entropy = activeQuest.entropy;
        if (entropy == 0) return 0;
        return uint256(keccak256(abi.encode(entropy, questType, tier, salt)));
    }

    function _questComplete(PlayerQuestState storage state)
        private
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed)
    {
        if ((state.flags & QUEST_STATE_COMPLETED) != 0) {
            return (0, false, activeQuest.questType, state.streak, false);
        }
        state.flags |= QUEST_STATE_COMPLETED;
        uint32 newStreak = state.streak + 1;
        state.streak = newStreak;
        state.lastCompletedDay = uint32(activeQuest.day);

        uint256 totalReward = 200 * MILLION;
        if (newStreak >= 5 && (newStreak == 5 || (newStreak % 10) == 0)) {
            uint256 bonus = uint256(newStreak) * 100;
            if (bonus > 5000) bonus = 5000;
            totalReward += bonus * MILLION;
        }
        bool isHard = (activeQuest.flags & QUEST_FLAG_HIGH_DIFFICULTY) != 0;
        if (isHard) {
            totalReward += 100 * MILLION;
        }
        return (totalReward, isHard, activeQuest.questType, newStreak, true);
    }
}


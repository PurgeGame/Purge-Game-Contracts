// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct QuestInfo {
    uint48 day;
    uint8 questType;
    bool highDifficulty;
    uint8 stakeMask;
    uint8 stakeRisk;
}

struct QuestDetail {
    uint48 day;
    uint8 questType;
    bool highDifficulty;
    uint8 stakeMask;
    uint8 stakeRisk;
    uint256 entropy;
}

interface IPurgeQuestModule {
    function wireGame(address game) external;

    function primeMintEthQuest(uint48 day) external;

    function rollDailyQuest(uint48 day, uint256 entropy)
        external
        returns (bool rolled, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forcePurge)
        external
        returns (bool rolled, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);

    function handleMint(address player, uint32 quantity, bool paidWithEth)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handleFlip(address player, uint256 flipCredit)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handleDecimator(address player, uint256 burnAmount)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handleStake(address player, uint256 principal, uint24 distance, uint8 risk)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handleAffiliate(address player, uint256 amount)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handlePurge(address player, uint32 quantity)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function getActiveQuest()
        external
        view
        returns (uint48 day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);

    function getActiveQuests() external view returns (QuestInfo[2] memory quests);

    function getQuestDetails() external view returns (QuestDetail[2] memory quests);

    function playerQuestState(address player)
        external
        view
        returns (uint32 streak, uint32 lastCompletedDay, uint128 progress, bool completedToday);

    function playerQuestStates(address player)
        external
        view
        returns (
            uint32 streak,
            uint32 lastCompletedDay,
            uint128[2] memory progress,
            bool[2] memory completed
        );
}

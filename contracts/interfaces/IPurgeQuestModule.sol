// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct QuestRequirements {
    uint32 mints; // Number of mints/purges required (whole NFTs)
    uint256 tokenAmount; // PURGE base units (6 decimals) for token-denominated quests or stake principal; wei for bond size quests
    uint16 stakeDistance; // Minimum stake distance when required
    uint8 stakeRisk; // Minimum stake risk when required
}

struct QuestInfo {
    uint48 day;
    uint8 questType;
    bool highDifficulty;
    uint8 stakeMask;
    uint8 stakeRisk;
    QuestRequirements requirements;
}

struct PlayerQuestView {
    QuestInfo[2] quests;
    uint128[2] progress;
    bool[2] completed;
    uint32 lastCompletedDay;
    uint32 baseStreak;
}

interface IPurgeQuestModule {
    function wire(address[] calldata addresses) external;

    function rollDailyQuest(uint48 day, uint256 entropy)
        external
        returns (bool rolled, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forcePurge)
        external
        returns (bool rolled, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);

    function normalizeActivePurgeQuests() external;

    function handleMint(address player, uint32 quantity, bool paidWithEth)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handleFlip(address player, uint256 flipCredit)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handleDecimator(address player, uint256 burnAmount)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed);

    function handleBondPurchase(address player, uint256 basePerBondWei)
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

    function getActiveQuests() external view returns (QuestInfo[2] memory quests);

    function playerQuestStates(address player)
        external
        view
        returns (
            uint32 streak,
            uint32 lastCompletedDay,
            uint128[2] memory progress,
            bool[2] memory completed
        );

    function getPlayerQuestView(address player) external view returns (PlayerQuestView memory viewData);
}

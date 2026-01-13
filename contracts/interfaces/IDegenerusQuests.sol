// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct QuestRequirements {
    uint32 mints; // Number of mints/burns required (whole gamepieces)
    uint256 tokenAmount; // BURNIE base units (18 decimals) for token-denominated quests; wei for ETH-denominated quests
}

struct QuestInfo {
    uint48 day;
    uint8 questType;
    bool highDifficulty;
    QuestRequirements requirements;
}

struct PlayerQuestView {
    QuestInfo[2] quests;
    uint128[2] progress;
    bool[2] completed;
    uint32 lastCompletedDay;
    uint32 baseStreak;
}

interface IDegenerusQuests {
    function rollDailyQuest(uint48 day, uint256 entropy)
        external
        returns (bool rolled, uint8[2] memory questTypes, bool highDifficulty);
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forceBurn)
        external
        returns (bool rolled, uint8[2] memory questTypes, bool highDifficulty);

    function normalizeActiveBurnQuests() external;

    function handleMint(address player, uint32 quantity, bool paidWithEth)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth);

    function handleFlip(address player, uint256 flipCredit)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth);

    function handleDecimator(address player, uint256 burnAmount)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth);

    function handleAffiliate(address player, uint256 amount)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth);

    function handleBurn(address player, uint32 quantity)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth);

    function handleLootBox(address player, uint256 amountWei)
        external
        returns (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth);

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

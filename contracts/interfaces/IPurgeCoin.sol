// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {QuestInfo, PlayerQuestView} from "./IPurgeQuestModule.sol";

interface IPurgeCoin {
    function jackpots() external view returns (address);
    function affiliateProgram() external view returns (address);

    function bonusCoinflip(address player, uint256 amount) external;

    function burnie(uint256 amount, address stethToken) external payable;

    function burnCoin(address target, uint256 amount) external;

    function claimPresaleAffiliateBonus() external;

    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch,
        uint256 priceCoinUnit
    ) external returns (bool);

    function recordStakeResolution(uint24 level, uint48 day) external;

    function addToBounty(uint256 amount) external;

    function rewardTopFlipBonus(uint48 day, uint256 amount) external;

    function resetCoinflipLeaderboard(uint48 day) external;

    function coinflipTop(uint24 level) external view returns (address player, uint96 score);

    function playerLuckbox(address player) external view returns (uint256);

    function rollDailyQuest(uint48 day, uint256 entropy) external;
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forcePurge) external;

    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external;

    function notifyQuestPurge(address player, uint32 quantity) external;

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

    function bondPayment(address to, uint256 amount) external;
}

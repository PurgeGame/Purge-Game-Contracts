// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {QuestInfo} from "./IPurgeQuestModule.sol";

interface IPurgeCoin {
    function bonusCoinflip(address player, uint256 amount, bool rngReady) external;

    function burnie(uint256 amount) external payable;

    function burnCoin(address target, uint256 amount) external;

    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external returns (uint256);

    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch,
        uint256 priceCoinUnit
    ) external returns (bool);

    function coinflipWorkPending(uint24 level) external view returns (bool);

    function addToBounty(uint256 amount) external;

    function rewardTopFlipBonus(uint256 amount) external;

    function lastBiggestFlip() external view returns (address);

    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    ) external returns (bool finished, address[] memory winners, uint256[] memory amounts, uint256 returnAmountWei);

    function resetAffiliateLeaderboard(uint24 lvl) external;

    function resetCoinflipLeaderboard() external;

    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory);
    function getTopAffiliate() external view returns (address);

    function playerLuckbox(address player) external view returns (uint256);

    function primeMintEthQuest(uint48 day) external;

    function rollDailyQuest(uint48 day, uint256 entropy) external;
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forcePurge) external;

    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external;

    function notifyQuestPurge(address player, uint32 quantity) external;

    function getActiveQuest()
        external
        view
        returns (uint48 day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);

    function getActiveQuests() external view returns (QuestInfo[2] memory quests);

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

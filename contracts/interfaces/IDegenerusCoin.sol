// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {QuestInfo, PlayerQuestView} from "./IDegenerusQuestModule.sol";

interface IDegenerusCoin {
    function jackpots() external view returns (address);
    function affiliateProgram() external view returns (address);

    function creditFlip(address player, uint256 amount) external;
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;

    function burnCoin(address target, uint256 amount) external;

    function claimPresaleAffiliateBonus() external;

    function processCoinflipPayouts(
        uint24 level,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch,
        uint256 priceCoinUnit
    ) external returns (bool);

    function recordStakeResolution(uint24 level, uint48 day) external returns (address topStakeWinner);

    function addToBounty(uint256 amount) external;

    function normalizeActiveBurnQuests() external;

    function vault() external view returns (address);

    function coinflipTop(uint24 level) external view returns (address player, uint96 score);

    function rollDailyQuest(uint48 day, uint256 entropy) external;
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forceBurn) external;

    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external;

    function notifyQuestBong(address player, uint256 basePerBongWei) external;

    function notifyQuestBurn(address player, uint32 quantity) external;

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

    function bongPayment(uint256 amount) external;
}

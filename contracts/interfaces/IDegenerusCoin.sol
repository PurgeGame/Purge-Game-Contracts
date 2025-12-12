// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "./DegenerusGameModuleInterfaces.sol";
import {QuestInfo, PlayerQuestView} from "./IDegenerusQuestModule.sol";

interface IDegenerusCoin is IDegenerusCoinModule {
    function admin() external view returns (address);
    function jackpots() external view returns (address);
    function affiliateProgram() external view returns (address);

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

    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external;

    function notifyQuestBond(address player, uint256 basePerBondWei) external;

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
}

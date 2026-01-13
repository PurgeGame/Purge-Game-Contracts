// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "./DegenerusGameModuleInterfaces.sol";

interface IDegenerusCoin is IDegenerusCoinModule {
    function burnCoin(address target, uint256 amount) external;

    function processCoinflipPayouts(
        uint24 level,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch
    ) external returns (bool);

    function normalizeActiveBurnQuests() external;

    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external;

    function notifyQuestBurn(address player, uint32 quantity) external;

    function notifyQuestLootBox(address player, uint256 amountWei) external;

    function setDeployTime(uint48 timestamp) external;
}

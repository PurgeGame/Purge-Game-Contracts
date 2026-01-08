// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "./DegenerusGameModuleInterfaces.sol";

interface IDegenerusGameEndgameModule {
    function finalizeEndgame(uint24 lvl, uint256 rngWord) external;
}

interface IDegenerusGameJackpotModule {
    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord
    ) external;

    function payMapJackpot(
        uint24 lvl,
        uint256 randWord
    ) external;

    function payCarryoverExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord
    ) external returns (uint256 paidEth);

    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        uint256 ethPool
    ) external returns (uint256 paidEth);

    function payLevelJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei
    ) external;

    function calcPrizePoolForLevelJackpot(
        uint24 lvl,
        uint256 rngWord
    ) external returns (uint256 effectiveWei);

    function processMapBatch(uint32 writesBudget) external returns (bool finished);
}

interface IDegenerusGameBondModule {
    function bondUpkeep(uint256 rngWord) external;
    function stakeForTargetRatio(uint24 lvl) external;
    function drainToBonds() external;
}

interface IDegenerusGameMintModule {
    function recordMintData(
        address player,
        uint24 lvl,
        uint32 mintUnits
    ) external payable returns (uint256 coinReward);

    function calculateAirdropMultiplier(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount,
        uint24 lvl
    ) external pure returns (uint32);

    function purchaseTargetCountFromRaw(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount
    ) external view returns (uint32);

    function rebuildTraitCounts(
        uint32 tokenBudget,
        uint32 target,
        uint256 baseTokenId
    ) external returns (bool finished);
}

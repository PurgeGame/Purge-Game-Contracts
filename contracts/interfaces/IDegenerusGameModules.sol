// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "./DegenerusGameModuleInterfaces.sol";

interface IDegenerusGameEndgameModule {
    function finalizeEndgame(
        uint24 lvl,
        uint256 rngWord,
        address jackpots,
        address jackpotModule,
        IDegenerusCoinModule coinContract,
        address nftAddr
    ) external;
}

interface IDegenerusGameJackpotModule {
    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord,
        IDegenerusCoinModule coinContract
    ) external;

    function payMapJackpot(
        uint24 lvl,
        uint256 randWord
    ) external;

    function payCarryoverExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        IDegenerusCoinModule coinContract
    ) external returns (uint256 paidEth);

    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        uint256 ethPool,
        IDegenerusCoinModule coinContract
    ) external returns (uint256 paidEth);

    function payLevelJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IDegenerusCoinModule coinContract
    ) external;

    function calcPrizePoolForLevelJackpot(
        uint24 lvl,
        uint256 rngWord,
        address stethAddr
    ) external returns (uint256 effectiveWei);

    function processMapBatch(uint32 writesBudget) external returns (bool finished);
}

interface IDegenerusGameBondModule {
    function bondUpkeep(
        address bondsAddr,
        address stethAddr,
        address coinAddr,
        uint256 rngWord
    ) external;
    function stakeForTargetRatio(address bondsAddr, address stethAddr, uint24 lvl) external;
    function drainToBonds(address bondsAddr, address stethAddr) external;
}

interface IDegenerusGameMintModule {
    function recordMintData(
        address player,
        uint24 lvl,
        uint32 mintUnits
    ) external payable returns (uint256 coinReward);

    function calculateAirdropMultiplier(uint32 purchaseCount, uint24 lvl) external pure returns (uint32);

    function purchaseTargetCountFromRaw(uint32 rawCount) external view returns (uint32);

    function rebuildTraitCounts(
        uint32 tokenBudget,
        uint32 target,
        uint256 baseTokenId
    ) external returns (bool finished);
}

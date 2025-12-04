// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeCoinModule} from "./PurgeGameModuleInterfaces.sol";

interface IPurgeGameEndgameModule {
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint256 rngWord,
        address jackpots
    ) external returns (bool readyForPurchase);
}

interface IPurgeGameJackpotModule {
    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord,
        IPurgeCoinModule coinContract
    ) external;

    function payMapJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IPurgeCoinModule coinContract
    ) external;

    function calcPrizePoolForJackpot(
        uint24 lvl,
        uint256 rngWord,
        address stethAddr
    ) external returns (uint256 effectiveWei);

    function processMapBatch(uint32 writesBudget) external returns (bool finished);

    function processPendingJackpotBongs(
        uint256 maxMints
    ) external returns (bool finished, uint256 processed);
}

interface IPurgeGameBongModule {
    function bongMaintenanceForMap(
        address bongsAddr,
        address coinAddr,
        address stethAddr,
        uint48 day,
        uint256 totalWei,
        uint256 rngWord,
        uint32 cap
    ) external returns (bool worked);
    function stakeForTargetRatio(address bongsAddr, address stethAddr, uint24 lvl) external;
    function drainToBongs(address bongsAddr, address stethAddr, uint48 day) external;
}

interface IPurgeGameMintModule {
    function recordMintData(
        address player,
        uint24 lvl,
        bool coinMint,
        uint32 mintUnits
    ) external returns (uint256 coinReward);

    function calculateAirdropMultiplier(uint32 purchaseCount, uint24 lvl) external pure returns (uint32);

    function purchaseTargetCountFromRaw(uint32 rawCount) external view returns (uint32);

    function rebuildTraitCounts(
        uint32 tokenBudget,
        uint32 target,
        uint256 baseTokenId
    ) external returns (bool finished);
}

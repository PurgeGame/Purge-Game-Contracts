// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeCoinModule} from "./PurgeGameModuleInterfaces.sol";

interface IPurgeGameEndgameModule {
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint256 rngWord,
        address jackpots
    ) external;
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
}

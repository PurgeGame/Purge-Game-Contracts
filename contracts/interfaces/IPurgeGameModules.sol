// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeCoinModule, IPurgeGameTrophiesModule} from "../modules/PurgeGameModuleInterfaces.sol";

interface IPurgeGameEndgameModule {
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint256 rngWord,
        address jackpots,
        IPurgeGameTrophiesModule trophiesContract
    ) external;
}

interface IPurgeGameJackpotModule {
    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external;

    function payMapJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external;

    function runDecimatorHundredJackpot(
        uint24 lvl,
        uint32 cap,
        uint256 rngWord,
        IPurgeCoinModule coinContract
    ) external returns (bool finished);

    function calcPrizePoolForJackpot(
        uint24 lvl,
        uint256 rngWord,
        IPurgeCoinModule coinContract
    ) external returns (uint256 effectiveWei);
}

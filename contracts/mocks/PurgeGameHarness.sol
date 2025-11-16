// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGame} from "../PurgeGame.sol";
import {IPurgeCoin} from "../interfaces/IPurgeCoin.sol";
import {IPurgeRendererLike} from "../interfaces/IPurgeRendererLike.sol";
import {IPurgeGameNFT} from "../PurgeGameNFT.sol";
import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";
import {IPurgeGameEndgameModule, IPurgeGameJackpotModule} from "../interfaces/IPurgeGameModules.sol";

contract PurgeGameHarness is PurgeGame {
    constructor(
        address purgeCoinContract,
        address renderer_,
        address nftContract,
        address trophiesContract,
        address endgameModule_,
        address jackpotModule_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint256 vrfSubscriptionId_,
        address linkToken_
    ) PurgeGame(
        purgeCoinContract,
        renderer_,
        nftContract,
        trophiesContract,
        endgameModule_,
        jackpotModule_,
        vrfCoordinator_,
        vrfKeyHash_,
        vrfSubscriptionId_,
        linkToken_
    ) {}

    function harnessSetState(uint24 lvl, uint8 phase_, uint8 state_) external {
        level = lvl;
        phase = phase_;
        gameState = state_;
    }

    function harnessSeedPending(address exterminator, uint24 prevLevel, uint256 sidePool) external {
        pendingEndLevel.exterminator = exterminator;
        pendingEndLevel.level = prevLevel;
        pendingEndLevel.sidePool = sidePool;
    }

    function harnessSeedTickets(uint24 lvl, uint8 trait, address[] calldata players) external {
        address[][256] storage tickets = traitPurgeTicket[lvl];
        delete tickets[trait];
        for (uint256 i; i < players.length; i++) {
            tickets[trait].push(players[i]);
        }
    }

    function harnessSetPrize(uint256 unit) external {
        prizePool = unit;
    }

    function harnessSetLevelPrize(uint256 amount) external {
        levelPrizePool = amount;
    }

    function harnessGetNextPrizePool() external view returns (uint256) {
        return nextPrizePool;
    }

    function harnessSetCarry(uint256 amount) external {
        carryOver = amount;
    }

    function harnessSetLastTrait(uint16 trait) external {
        lastExterminatedTrait = trait;
    }

    function harnessSetRng(uint256 word, bool fulfilled, bool locked) external {
        rngWordCurrent = word;
        rngFulfilled = fulfilled;
        rngLockedFlag = locked;
    }

    function harnessRunEndgame(uint32 cap, uint48 day, uint256 rngWord) external {
        _runEndgameModule(level, cap, day, rngWord);
    }

    function harnessGetPendingEndLevel() external view returns (PendingEndLevel memory) {
        return pendingEndLevel;
    }

    function harnessGetLevelPrize() external view returns (uint256) {
        return levelPrizePool;
    }

    function harnessGetClaimable(address player) external view returns (uint256) {
        return claimableWinnings[player];
    }

    function harnessProcessMapBatch(uint32 writesBudget) external returns (bool) {
        return _processMapBatch(writesBudget);
    }

    function harnessCalcMapJackpot(uint24 lvl, uint256 rngWord) external returns (uint256) {
        return _calcPrizePoolForJackpot(lvl, rngWord);
    }

    function harnessRunMapJackpot(uint24 lvl, uint256 rngWord, uint256 effectiveWei) external returns (bool) {
        return payMapJackpot(lvl, rngWord, effectiveWei);
    }

    function harnessRunDailyJackpot(uint256 rngWord) external returns (bool) {
        payDailyJackpot(true, level, rngWord);
        return _handleJackpotLevelCap();
    }

    function harnessSetJackpotCounter(uint8 value) external {
        jackpotCounter = value;
    }
}

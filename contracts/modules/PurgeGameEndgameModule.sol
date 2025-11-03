// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeCoinModule, IPurgeGameTrophiesModule} from "./PurgeGameModuleInterfaces.sol";

/**
 * @title PurgeGameEndgameModule
 * @notice Delegate-called module that hosts the slow-path endgame settlement logic for `PurgeGame`.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract PurgeGameEndgameModule {
    // -----------------------
    // Custom Errors / Events
    // -----------------------
    error E();

    event PlayerCredited(address indexed player, uint256 amount);

    // -----------------------
    // Storage layout mirror
    // -----------------------
    // -----------------------
    // Game Constants (subset)
    // -----------------------
    uint32 private constant DEFAULT_PAYOUTS_PER_TX = 420;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;

    // -----------------------
    // Price
    // -----------------------
    uint256 private price;
    uint256 private priceCoin;

    // -----------------------
    // Prize Pools and RNG
    // -----------------------
    uint256 private lastPrizePool;
    uint256 private levelPrizePool;
    uint256 private prizePool;
    uint256 private nextPrizePool;
    uint256 private carryoverForNextLevel;

    // -----------------------
    // Time / Session Tracking
    // -----------------------
    uint48 private levelStartTime;
    uint48 private dailyIdx;

    // -----------------------
    // Game Progress
    // -----------------------
    uint24 public level;
    uint8 public gameState;
    uint8 private jackpotCounter;
    uint8 private earlyPurgeJackpotPaidMask;
    uint8 private phase;
    uint16 private lastExterminatedTrait;

    // -----------------------
    // Minting / Airdrops
    // -----------------------
    uint32 private airdropMapsProcessedCount;
    uint32 private airdropIndex;
    uint32 private traitRebuildCursor;
    bool private traitCountsSeedQueued;
    bool private traitCountsShouldOverwrite;

    address[] private pendingMapMints;
    mapping(address => uint32) private playerMapMintsOwed;

    // -----------------------
    // Token / Trait State
    // -----------------------
    mapping(address => uint256) private claimableWinnings;
    mapping(uint24 => address[][256]) private traitPurgeTicket;

    struct PendingEndLevel {
        address exterminator;
        uint24 level;
        uint256 sidePool;
    }
    PendingEndLevel private pendingEndLevel;

    // -----------------------
    // Daily / Trait Counters
    // -----------------------
    uint32[80] internal dailyPurgeCount;
    uint32[256] internal traitRemaining;
    mapping(address => uint256) private mintPacked_;

    constructor() {}

    /// @notice Entry point invoked via delegatecall from the core game contract.
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint48 /*day*/,
        uint256 rngWord,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external {
        PendingEndLevel storage pend = pendingEndLevel;

        uint8 _phase = phase;
        uint24 prevLevel = lvl - 1;
        uint8 prevMod10 = uint8(prevLevel % 10);
        uint8 prevMod100 = uint8(prevLevel % 100);

        if (_phase > 3) {
            if (lastExterminatedTrait != TRAIT_ID_TIMEOUT) {
                if (prizePool != 0) {
                    _payoutParticipants(cap, prevLevel);
                    return;
                }

                uint256 poolTotal = levelPrizePool;

                pend.level = prevLevel;
                pend.sidePool = poolTotal;

                levelPrizePool = 0;
            }

            if (pend.level != 0 && pend.exterminator == address(0)) {
                phase = 0;
                return;
            }
            bool coinflipFinalizeOk = true;
            if (_phase >= 3 || (lvl % 20) != 0) {
                coinflipFinalizeOk = coinContract.processCoinflipPayouts(lvl, cap, false, rngWord);
            }
            if (coinflipFinalizeOk) {
                phase = 0;
                return;
            }
        } else {
            bool decWindow = prevLevel >= 25 && prevMod10 == 5 && prevMod100 != 95;
            if (prevLevel != 0 && (prevLevel % 20) == 0) {
                uint256 bafPoolWei = (carryoverForNextLevel * 24) / 100;
                (bool bafFinished, ) = _progressExternal(0, bafPoolWei, cap, prevLevel, rngWord, coinContract);
                if (!bafFinished) return;
            }
            if (decWindow) {
                uint256 decPoolWei = (carryoverForNextLevel * 15) / 100;
                (bool decFinished, ) = _progressExternal(1, decPoolWei, cap, prevLevel, rngWord, coinContract);
                if (!decFinished) return;
            }

            if (lvl > 1) {
                _clearDailyPurgeCount();

                prizePool = 0;
                phase = 0;
            }
            uint256 pendingPool = nextPrizePool;
            if (pendingPool != 0) {
                prizePool = pendingPool;
                nextPrizePool = 0;
            }
            gameState = 2;
            traitRebuildCursor = 0;
        }

        if (pend.level == 0) {
            return;
        }

        bool traitWin = pend.exterminator != address(0);
        uint24 prevLevelPending = pend.level;
        uint256 poolValue = pend.sidePool;

        if (traitWin) {
            uint256 exterminatorShare = (prevLevelPending % 10 == 4 && prevLevelPending != 4)
                ? (poolValue * 40) / 100
                : (poolValue * 20) / 100;

            uint256 immediate = exterminatorShare >> 1;
            uint256 deferredWei = exterminatorShare - immediate;
            _addClaimableEth(pend.exterminator, immediate);

            uint256 sharedPool = poolValue / 20;
            uint256 base = sharedPool / 100;
            uint256 remainder = sharedPool - (base * 100);
            uint256 affiliateTrophyShare = base * 20 + remainder;
            uint256 legacyAffiliateShare = base * 10;
            uint256[6] memory affiliatePayouts = [
                base * 20,
                base * 20,
                base * 10,
                base * 8,
                base * 7,
                base * 5
            ];

            address[] memory affLeaders = coinContract.getLeaderboardAddresses(1);
            address affiliateTrophyRecipient = affLeaders.length != 0 ? affLeaders[0] : pend.exterminator;
            if (affiliateTrophyRecipient == address(0)) {
                affiliateTrophyRecipient = pend.exterminator;
            }

            (, address[6] memory affiliateRecipients) = trophiesContract.processEndLevel{
                value: deferredWei + affiliateTrophyShare + legacyAffiliateShare
            }(
                IPurgeGameTrophiesModule.EndLevelRequest({
                    exterminator: pend.exterminator,
                    traitId: lastExterminatedTrait,
                    level: prevLevelPending,
                    pool: poolValue
                })
            );
            for (uint8 i; i < 6; ) {
                address recipient = affiliateRecipients[i];
                if (recipient == address(0)) {
                    recipient = affiliateTrophyRecipient;
                }
                uint256 amount = affiliatePayouts[i];
                if (amount != 0) {
                    _addClaimableEth(recipient, amount);
                }
                unchecked {
                    ++i;
                }
            }
        } else {
            uint256 poolCarry = poolValue;
            uint256 mapUnit = poolCarry / 20;
            address[] memory affLeaders = coinContract.getLeaderboardAddresses(1);
            address topAffiliate = affLeaders.length != 0 ? affLeaders[0] : address(0);
            uint256 affiliateAward = topAffiliate == address(0) ? 0 : mapUnit;
            uint256 mapPayoutValue = mapUnit * 4 + affiliateAward;

            (address mapRecipient, address[6] memory mapAffiliates) = trophiesContract.processEndLevel{value: mapPayoutValue}(
                IPurgeGameTrophiesModule.EndLevelRequest({
                    exterminator: topAffiliate,
                    traitId: TRAIT_ID_TIMEOUT,
                    level: prevLevelPending,
                    pool: poolCarry
                })
            );
            mapAffiliates;
            _addClaimableEth(mapRecipient, mapUnit);
        }

        delete pendingEndLevel;

        coinContract.resetAffiliateLeaderboard(lvl);
    }

    function _payoutParticipants(uint32 capHint, uint24 prevLevel) private {
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        uint32 len = uint32(arr.length);
        if (len == 0) {
            prizePool = 0;
            return;
        }

        uint32 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint32 i = airdropIndex;
        uint32 end = i + cap;
        if (end > len) end = len;

        uint256 unitPayout = prizePool;
        if (end == len) {
            prizePool = 0;
        }

        while (i < end) {
            address w = arr[i];
            uint32 run = 1;
            unchecked {
                while (i + run < end && arr[i + run] == w) ++run;
            }
            _addClaimableEth(w, unitPayout * run);
            unchecked {
                i += run;
            }
        }

        airdropIndex = i;
        if (i == len) {
            airdropIndex = 0;
        }
    }

    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
        unchecked {
            claimableWinnings[beneficiary] += weiAmount;
        }
        emit PlayerCredited(beneficiary, weiAmount);
    }

    function _progressExternal(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord,
        IPurgeCoinModule coinContract
    ) private returns (bool finished, uint256 returnedWei) {
        (bool isFinished, address[] memory winnersArr, uint256[] memory amountsArr, uint256 returnWei) = coinContract
            .runExternalJackpot(kind, poolWei, cap, lvl, rngWord);

        for (uint256 i; i < winnersArr.length; ) {
            _addClaimableEth(winnersArr[i], amountsArr[i]);
            unchecked {
                ++i;
            }
        }

        if (isFinished) {
            carryoverForNextLevel -= (poolWei - returnWei);
            returnedWei = returnWei;
        }
        return (isFinished, returnedWei);
    }

    function _clearDailyPurgeCount() private {
        for (uint8 i; i < 80; ) {
            dailyPurgeCount[i] = 0;
            unchecked {
                ++i;
            }
        }
    }
}

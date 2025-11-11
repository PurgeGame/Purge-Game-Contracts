// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";
import {IPurgeCoinModule, IPurgeGameTrophiesModule} from "./PurgeGameModuleInterfaces.sol";
import {PurgeGameStorage} from "../storage/PurgeGameStorage.sol";

/**
 * @title PurgeGameEndgameModule
 * @notice Delegate-called module that hosts the slow-path endgame settlement logic for `PurgeGame`.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract PurgeGameEndgameModule is PurgeGameStorage {
    // -----------------------
    // Custom Errors / Events
    // -----------------------
    error E();

    event PlayerCredited(address indexed player, uint256 amount);

    uint32 private constant DEFAULT_PAYOUTS_PER_TX = 420;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;

    constructor() {}

    /// @notice Entry point invoked via delegatecall from the core game contract.
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint48 day,
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
            bool bafPending = prevLevel != 0 && (prevLevel % 20) == 0 && (prevLevel % 100) != 0;
            bool gateCoinflip = !bafPending && (_phase >= 3 || (lvl % 20) != 0);
            if (gateCoinflip && coinContract.coinflipWorkPending(lvl)) {
                coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day);
                return;
            }
            phase = 0;
            return;
        } else {
            bool decWindow = prevLevel >= 25 && prevMod10 == 5 && prevMod100 != 95;
            if (prevLevel != 0 && (prevLevel % 20) == 0 && (prevLevel % 100) != 0) {
                uint256 bafPoolWei = (carryOver * 24) / 100;
                (bool bafFinished, ) = _progressExternal(0, bafPoolWei, cap, prevLevel, rngWord, coinContract, true);
                if (!bafFinished) return;
            }
            bool bigDecWindow = decimatorHundredReady && prevLevel == 100;
            if (bigDecWindow) {
                uint256 bigPool = decimatorHundredPool;
                (bool decFinished, uint256 returnWei) = _progressExternal(
                    1,
                    bigPool,
                    cap,
                    prevLevel,
                    rngWord,
                    coinContract,
                    false
                );
                if (!decFinished) return;
                decimatorHundredPool = 0;
                decimatorHundredReady = false;
                if (returnWei != 0) {
                    carryOver += returnWei;
                }
            } else if (decWindow) {
                uint256 decPoolWei = (carryOver * 15) / 100;
                (bool decFinished, ) = _progressExternal(1, decPoolWei, cap, prevLevel, rngWord, coinContract, true);
                if (!decFinished) return;
            }

            if (lvl > 1) {
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
        address[] memory topAffiliates = coinContract.getLeaderboardAddresses(1);
        address topAffiliate = topAffiliates.length != 0 ? topAffiliates[0] : address(0);

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
            uint256 baseTimes20 = base * 20;
            uint256 affiliateTrophyShare = baseTimes20 + remainder;
            uint256 legacyAffiliateShare = base * 10;
            uint256[6] memory affiliatePayouts = [baseTimes20, baseTimes20, base * 10, base * 8, base * 7, base * 5];

            address affiliateTrophyRecipient = topAffiliate != address(0) ? topAffiliate : pend.exterminator;
            if (affiliateTrophyRecipient == address(0)) {
                affiliateTrophyRecipient = pend.exterminator;
            }

            (, address[6] memory affiliateRecipients) = trophiesContract.processEndLevel{
                value: deferredWei + affiliateTrophyShare + legacyAffiliateShare
            }(
                IPurgeGameTrophies.EndLevelRequest({
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
            uint256 affiliateAward = topAffiliate == address(0) ? 0 : mapUnit;
            uint256 mapPayoutValue = mapUnit * 4 + affiliateAward;

            (address mapRecipient, ) = trophiesContract.processEndLevel{value: mapPayoutValue}(
                IPurgeGameTrophies.EndLevelRequest({
                    exterminator: topAffiliate,
                    traitId: TRAIT_ID_TIMEOUT,
                    level: prevLevelPending,
                    pool: poolCarry
                })
            );
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
        IPurgeCoinModule coinContract,
        bool consumeCarry
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
            returnedWei = returnWei;
            if (consumeCarry && poolWei != 0) {
                carryOver -= (poolWei - returnWei);
            }
        }
        return (isFinished, returnedWei);
    }
}

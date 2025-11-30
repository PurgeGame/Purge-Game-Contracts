// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";
import {IPurgeGameTrophiesModule} from "./PurgeGameModuleInterfaces.sol";
import {IPurgeJackpots} from "../interfaces/IPurgeJackpots.sol";
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
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;

    /// @notice Entry point invoked via delegatecall from the core game contract.
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint256 rngWord,
        address jackpots,
        IPurgeGameTrophiesModule trophiesContract
    ) external {
        uint24 prevLevel = lvl - 1;
        bool traitWin = lastExterminatedTrait != TRAIT_ID_TIMEOUT;
        if (traitWin) {
            _primeTraitPayouts(prevLevel, rngWord, trophiesContract);
        }
        uint8 _phase = phase;
        if (_phase > 3) {
            if (traitWin && currentPrizePool != 0) {
                _payoutParticipants(cap, prevLevel);
                return;
            }
            if (prevLevel != 0 && (prevLevel % 10) == 0) {
                uint256 bafPoolWei;
                if ((prevLevel % 100) == 0 && bafHundredPool != 0) {
                    bafPoolWei = bafHundredPool;
                    bafHundredPool = 0;
                } else {
                    bafPoolWei = (rewardPool * _bafPercent(prevLevel)) / 100;
                }
                _progressExternal(0, bafPoolWei, cap, prevLevel, rngWord, jackpots, true);
            }
            bool decWindow = prevLevel % 10 == 5 && prevLevel >= 15 && prevLevel % 100 != 95;
            if (decWindow) {
                uint256 decPoolWei = (rewardPool * 15) / 100;
                _progressExternal(1, decPoolWei, cap, prevLevel, rngWord, jackpots, true);
            }

            phase = 0;
            return;
        }

        gameState = 2;
        if (lvl == 1) {
            return;
        }

        if (!traitWin) {
            IPurgeGameTrophies.EndLevelRequest memory req = IPurgeGameTrophies.EndLevelRequest({
                exterminator: address(0),
                traitId: lastExterminatedTrait,
                level: prevLevel,
                rngWord: rngWord,
                deferredWei: 0,
                invertTrophy: false
            });

            uint256 scale = _rewardBonusScaleBps(prevLevel);
            uint256 scaledPool = (rewardPool * scale) / 10_000;

            uint256 rewardsTotal = trophiesContract.processEndLevel(req, scaledPool);

            if (rewardsTotal != 0) {
                rewardPool -= rewardsTotal;
                trophyPool += rewardsTotal;
            }
        }
    }

    function _payoutParticipants(uint32 capHint, uint24 prevLevel) private {
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        uint32 len = uint32(arr.length);

        uint256 participantPool = currentPrizePool;
        uint256 unitPayout = participantPool / len;
        uint256 remainder = participantPool - (unitPayout * uint256(len));

        uint32 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint32 i = airdropIndex;
        uint32 end = i + cap;
        if (end > len) end = len;

        address lastPaid;
        while (i < end) {
            address w = arr[i];
            lastPaid = w;
            uint32 run = 1;
            unchecked {
                while (i + run < end && arr[i + run] == w) ++run;
            }
            _addClaimableEth(w, unitPayout * run);
            unchecked {
                i += run;
            }
        }

        if (end == len) {
            currentPrizePool = 0;
            if (remainder != 0) {
                if (lastPaid == address(0)) {
                    lastPaid = arr[end - 1];
                }
                _addClaimableEth(lastPaid, remainder);
            }
        }

        airdropIndex = i;
        if (i == len) {
            airdropIndex = 0;
        }
    }

    function _primeTraitPayouts(uint24 prevLevel, uint256 rngWord, IPurgeGameTrophiesModule trophiesContract) private {
        address ex = exterminator;
        if (ex == address(0)) return;

        uint256 poolValue = currentPrizePool;
        uint256 exterminatorShare = (prevLevel % 10 == 4 && prevLevel != 4)
            ? (poolValue * 40) / 100
            : (poolValue * 30) / 100;

        uint256 immediate = exterminatorShare >> 1;
        uint256 deferredWei = exterminatorShare - immediate;
        _addClaimableEth(ex, immediate);
        trophyPool += deferredWei;

        // Reassign the trophy slice from the prize pool to players: 10% split across three tickets
        // using their ETH mint streaks as weights (even split if all streaks are zero).
        uint256 ticketBonus = (poolValue * 10) / 100;
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        uint256 arrLen = arr.length;
        address[3] memory winners;
        uint256[3] memory streaks;
        uint256 seed = rngWord ^ (uint256(prevLevel) << 128);
        for (uint8 i; i < 3; ) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint256 idx = seed % arrLen;
            address w = arr[idx];
            winners[i] = w;
            streaks[i] = (mintPacked_[w] >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24;
            unchecked {
                ++i;
            }
        }

        uint256 totalWeight = streaks[0] + streaks[1] + streaks[2];
        uint256 remaining = ticketBonus;
        for (uint8 i; i < 3; ) {
            uint256 share;
            if (totalWeight == 0) {
                share = ticketBonus / 3;
            } else {
                share = (ticketBonus * streaks[i]) / totalWeight;
            }
            if (share != 0) {
                _addClaimableEth(winners[i], share);
                remaining -= share;
            }
            unchecked {
                ++i;
            }
        }
        if (remaining != 0) {
            _addClaimableEth(winners[0], remaining);
        }

        uint256 participantShare = ((poolValue * 90) / 100) - exterminatorShare;
        // Preserve the entire prize pool by rolling any rounding dust into the participant slice.
        uint256 poolDust = poolValue - (ticketBonus + exterminatorShare + participantShare);
        participantShare += poolDust;
        currentPrizePool = participantShare;
        airdropIndex = 0;

        IPurgeGameTrophies.EndLevelRequest memory req = IPurgeGameTrophies.EndLevelRequest({
            exterminator: ex,
            traitId: lastExterminatedTrait,
            level: prevLevel,
            rngWord: rngWord,
            deferredWei: deferredWei,
            invertTrophy: exterminationInvertFlag
        });

        uint256 scale = _rewardBonusScaleBps(prevLevel);
        uint256 scaledPool = (rewardPool * scale) / 10_000;

        uint256 rewardsTotal = trophiesContract.processEndLevel(req, scaledPool);

        if (rewardsTotal != 0) {
            rewardPool -= rewardsTotal;
            trophyPool += rewardsTotal;
        }

        exterminator = address(0);
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
        address jackpots,
        bool consumeCarry
    ) private returns (uint256 returnedWei) {
        address[] memory winnersArr;
        uint256[] memory amountsArr;
        uint256 trophyPoolDelta;
        uint256 returnWei;

        if (kind == 0) {
            (, winnersArr, amountsArr, trophyPoolDelta, returnWei) = IPurgeJackpots(jackpots).runBafJackpot(
                poolWei,
                cap,
                lvl,
                rngWord
            );
        } else if (kind == 1) {
            (, winnersArr, amountsArr, trophyPoolDelta, returnWei) = IPurgeJackpots(jackpots).runDecimatorJackpot(
                poolWei,
                cap,
                lvl,
                rngWord
            );
        } else {
            revert E();
        }

        for (uint256 i; i < winnersArr.length; ) {
            _addClaimableEth(winnersArr[i], amountsArr[i]);
            unchecked {
                ++i;
            }
        }

        if (trophyPoolDelta != 0) {
            trophyPool += trophyPoolDelta;
        }

        returnedWei = returnWei;
        if (consumeCarry && poolWei != 0) {
            rewardPool -= (poolWei - returnWei);
        }
        return returnedWei;
    }

    function _rewardBonusScaleBps(uint24 lvl) private pure returns (uint16) {
        // Linearly scale reward pool-funded slices from 100% at the start of a 100-level band
        // down to 50% on the last level of the band, then reset on the next band.
        uint256 cycle = ((uint256(lvl) - 1) % 100); // 0..99
        uint256 discount = (cycle * 5000) / 99; // up to 50% at cycle==99
        uint256 scale = 10_000 - discount;
        if (scale < 5000) scale = 5000;
        return uint16(scale);
    }

    function _bafPercent(uint24 lvl) private pure returns (uint256) {
        return lvl == 50 ? 25 : 10;
    }
}

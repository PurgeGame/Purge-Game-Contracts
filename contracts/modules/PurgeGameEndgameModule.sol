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

    /**
     * @notice Settles a completed level by paying trait-related slices, jackpots, and participant airdrops.
     * @dev Called by the core game contract via `delegatecall` so state mutations land on the parent.
     *      Trait payouts are primed up front on a trait win; `phase` then gates the participant payout vs jackpot/cleanup pass.
     * @param lvl Current level index (1-based) that just completed.
     * @param cap Optional cap for batched payouts; zero falls back to DEFAULT_PAYOUTS_PER_TX.
     * @param rngWord Randomness used for jackpot and ticket selection.
     * @param jackpots Address of the jackpots contract to invoke.
     * @param trophiesContract Delegate that handles trophy minting and reward distribution.
     */
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
                // Finalize the participant slice from `_primeTraitPayouts` in a gas-bounded manner.
                _payoutParticipants(cap, prevLevel);
                return;
            }
            if (prevLevel != 0 && (prevLevel % 10) == 0) {
                uint256 bafPoolWei;
                if ((prevLevel % 100) == 0 && bafHundredPool != 0) {
                    // Every 100 levels we may have a carry pool; otherwise take a fresh slice from rewardPool.
                    bafPoolWei = bafHundredPool;
                    bafHundredPool = 0;
                } else {
                    bafPoolWei = (rewardPool * (prevLevel == 50 ? 25 : 10)) / 100;
                }
                _rewardJackpot(0, bafPoolWei, cap, prevLevel, rngWord, jackpots, true);
            }
            bool decWindow = prevLevel % 10 == 5 && prevLevel >= 15 && prevLevel % 100 != 95;
            if (decWindow) {
                // Fire decimator jackpots midway through each decile except the 95th to avoid overlap with final bands.
                uint256 decPoolWei = (rewardPool * 15) / 100;
                _rewardJackpot(1, decPoolWei, cap, prevLevel, rngWord, jackpots, true);
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

    /**
     * @notice Pays the participant slice of the prize pool evenly across trait purge tickets for the level.
     * @dev Uses `airdropIndex` to batch work across transactions and coalesces consecutive identical winners.
     * @param capHint Optional per-call cap to keep gas bounded; zero uses DEFAULT_PAYOUTS_PER_TX.
     * @param prevLevel Level that just ended (level indexes are 1-based).
     */
    function _payoutParticipants(uint32 capHint, uint24 prevLevel) private {
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        uint256 len = arr.length;
        uint256 participantPool = currentPrizePool;
        uint256 unitPayout = participantPool / len;

        uint256 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint256 i = airdropIndex;
        uint256 end = i + cap;
        if (end > len) end = len;

        while (i < end) {
            address w = arr[i];
            uint256 run = 1;
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
        }

        airdropIndex = uint32(i);
        if (i == len) {
            airdropIndex = 0;
        }
    }

    /**
     * @notice Splits the current prize pool into exterminator, ticket, and participant slices for a trait win.
     * @dev Also triggers trophy processing for the exterminator and updates rewardPool/trophyPool balances.
     */
    function _primeTraitPayouts(uint24 prevLevel, uint256 rngWord, IPurgeGameTrophiesModule trophiesContract) private {
        address ex = exterminator;
        if (ex == address(0)) return;

        uint256 poolValue = currentPrizePool;
        uint256 exterminatorShare = (prevLevel % 10 == 4 && prevLevel != 4)
            ? (poolValue * 40) / 100
            : (poolValue * 30) / 100;

        // Pay half immediately; defer the rest through trophy processing.
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
        for (uint8 i; i < 3; ) {
            // Pick three winners with replacement using disjoint slices of the VRF word; weighting is applied later via streaks.
            address w = arr[(rngWord >> (uint256(i) * 64)) % arrLen];
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

        // Clear exterminator so a second call cannot double-claim the share.
        exterminator = address(0);
    }

    /// @notice Adds ETH winnings to a player, emitting the credit event.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
        unchecked {
            claimableWinnings[beneficiary] += weiAmount;
        }
        emit PlayerCredited(beneficiary, weiAmount);
    }

    /**
     * @notice Routes a jackpot slice to the jackpots contract and optionally burns from rewardPool.
     * @param kind 0 = BAF jackpot, 1 = Decimator jackpot.
     * @param poolWei Amount forwarded; if `consumeCarry` is true, rewardPool is debited by poolWei - returnWei.
     * @param cap Max winners processed in this call to bound gas.
     * @param lvl Level tied to the jackpot.
     * @param rngWord Randomness used by the jackpot contract.
     * @param jackpots Jackpots contract to call.
     * @param consumeCarry Whether to deduct the net spend from rewardPool.
     */
    function _rewardJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord,
        address jackpots,
        bool consumeCarry
    ) private {
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

        if (consumeCarry && poolWei != 0) {
            rewardPool -= (poolWei - returnWei);
        }
    }

    /// @notice Computes the rewardPool scaling factor (in bps) based on the level's position in its 100-level band.
    function _rewardBonusScaleBps(uint24 lvl) private pure returns (uint16) {
        // Linearly scale reward pool-funded slices from 100% at the start of a 100-level band
        // down to 50% on the last level of the band, then reset on the next band.
        uint256 cycle = ((uint256(lvl) - 1) % 100); // 0..99
        uint256 discount = (cycle * 5000) / 99; // up to 50% at cycle==99
        uint256 scale = 10_000 - discount;
        if (scale < 5000) scale = 5000;
        return uint16(scale);
    }
}

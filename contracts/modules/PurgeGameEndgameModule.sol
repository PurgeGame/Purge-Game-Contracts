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
    uint8 private constant PURGE_TROPHY_KIND_AFFILIATE = 2;
    uint8 private constant PURGE_TROPHY_KIND_STAKE = 3;
    uint16 private constant STAKED_RANDOM_BPS = 50; // 0.5% of the reward pool
    uint16 private constant AFFILIATE_CARRY_BPS = 100; // 1% of the reward pool
    uint16 private constant STAKE_CARRY_BPS = 50; // 0.5% of the reward pool
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;

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
            if (prevLevel != 0 && (prevLevel % 20) == 0 && (prevLevel % 100) != 0) {
                uint256 bafPoolWei = (rewardPool * 24) / 100;
                (bool bafFinished, ) = _progressExternal(0, bafPoolWei, cap, prevLevel, rngWord, coinContract, true);
                if (!bafFinished) return;
            }
            bool decWindow = prevLevel % 10 == 5 && prevLevel >= 25 && prevLevel % 100 != 95;
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
                    rewardPool += returnWei;
                }
            } else if (decWindow) {
                uint256 decPoolWei = (rewardPool * 15) / 100;
                (bool decFinished, ) = _progressExternal(1, decPoolWei, cap, prevLevel, rngWord, coinContract, true);
                if (!decFinished) return;
            }

            phase = 0;
            return;
        }
        gameState = 2;
        if (lvl == 1) {
            return;
        }
        if (coinContract.coinflipWorkPending(lvl)) {
            coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day, priceCoin);
            return;
        }

        if (!traitWin) {
            IPurgeGameTrophies.EndLevelRequest memory req = IPurgeGameTrophies.EndLevelRequest({
                exterminator: address(0),
                traitId: lastExterminatedTrait,
                level: prevLevel,
                rngWord: rngWord,
                deferredWei: 0
            });

            uint256 scale = _rewardBonusScaleBps(prevLevel);
            uint256 scaledPool = (rewardPool * scale) / 10_000;

            uint256 rewardsTotal = trophiesContract.processEndLevel(req, scaledPool);

            if (rewardsTotal != 0) {
                rewardPool -= rewardsTotal;
                trophyPool += rewardsTotal;
            }
        }

        coinContract.resetAffiliateLeaderboard(lvl);
    }

    function _payoutParticipants(uint32 capHint, uint24 prevLevel) private {
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        uint32 len = uint32(arr.length);

        uint256 participantPool = currentPrizePool;
        uint256 unitPayout = participantPool / len;

        uint32 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint32 i = airdropIndex;
        uint32 end = i + cap;
        if (end > len) end = len;

        if (end == len) {
            currentPrizePool = 0;
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

    function _primeTraitPayouts(
        uint24 prevLevel,
        uint256 rngWord,
        IPurgeGameTrophiesModule trophiesContract
    ) private {
        address ex = exterminator;
        if (ex == address(0)) return;

        uint256 poolValue = currentPrizePool;
        uint256 exterminatorShare = (prevLevel % 10 == 4 && prevLevel != 4)
            ? (poolValue * 40) / 100
            : (poolValue * 20) / 100;

        uint256 immediate = exterminatorShare >> 1;
        uint256 deferredWei = exterminatorShare - immediate;
        _addClaimableEth(ex, immediate);
        trophyPool += deferredWei;

        // Reassign the trophy slice from the prize pool to players: 10% split across three tickets
        // using their ETH mint streaks as weights (even split if all streaks are zero).
        uint256 ticketBonus = (poolValue * 10) / 100;
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        if (arr.length != 0 && ticketBonus != 0) {
            address[3] memory winners;
            uint256[3] memory streaks;
            uint256 seed = rngWord ^ (uint256(prevLevel) << 128);
            for (uint8 i; i < 3; ) {
                seed = uint256(keccak256(abi.encodePacked(seed, i)));
                uint256 idx = seed % arr.length;
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
        } else if (ticketBonus != 0) {
            // Defensive: if no tickets exist (unexpected), roll the bonus back into the reward pool.
            rewardPool += ticketBonus;
        }

        uint256 participantShare = ((poolValue * 90) / 100) - exterminatorShare;
        if (arr.length == 0) {
            currentPrizePool = 0;
        } else {
            currentPrizePool = participantShare;
            airdropIndex = 0;
        }

        IPurgeGameTrophies.EndLevelRequest memory req = IPurgeGameTrophies.EndLevelRequest({
            exterminator: ex,
            traitId: lastExterminatedTrait,
            level: prevLevel,
            rngWord: rngWord,
            deferredWei: deferredWei
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
        IPurgeCoinModule coinContract,
        bool consumeCarry
    ) private returns (bool finished, uint256 returnedWei) {
        (
            bool isFinished,
            address[] memory winnersArr,
            uint256[] memory amountsArr,
            uint256 trophyPoolDelta,
            uint256 returnWei
        ) = coinContract.runExternalJackpot(kind, poolWei, cap, lvl, rngWord);

        for (uint256 i; i < winnersArr.length; ) {
            _addClaimableEth(winnersArr[i], amountsArr[i]);
            unchecked {
                ++i;
            }
        }

        if (trophyPoolDelta != 0) {
            trophyPool += trophyPoolDelta;
        }

        if (isFinished) {
            returnedWei = returnWei;
            if (consumeCarry && poolWei != 0) {
                rewardPool -= (poolWei - returnWei);
            }
        }
        return (isFinished, returnedWei);
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
}

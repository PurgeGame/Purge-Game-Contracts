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
        PendingEndLevel storage pend = pendingEndLevel;

        uint8 _phase = phase;
        uint24 prevLevel = lvl - 1;
        uint8 prevMod10 = uint8(prevLevel % 10);
        uint8 prevMod100 = uint8(prevLevel % 100);

        if (_phase > 3) {
            if (lastExterminatedTrait != TRAIT_ID_TIMEOUT) {
                if (currentPrizePool != 0) {
                    _payoutParticipants(cap, prevLevel);
                    return;
                }
            }

            if (pend.level != 0 && pend.exterminator == address(0)) {
                phase = 0;
                return;
            }
            bool bafPending = prevLevel != 0 && (prevLevel % 20) == 0 && (prevLevel % 100) != 0;
            bool gateCoinflip = !bafPending && (_phase >= 3 || (lvl % 20) != 0);
            if (gateCoinflip && coinContract.coinflipWorkPending(lvl)) {
                coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day, priceCoin);
                return;
            }
            phase = 0;
            return;
        } else {
            bool decWindow = prevLevel >= 25 && prevMod10 == 5 && prevMod100 != 95;
            if (prevLevel != 0 && (prevLevel % 20) == 0 && (prevLevel % 100) != 0) {
                uint256 bafPoolWei = (rewardPool * 24) / 100;
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
                    rewardPool += returnWei;
                }
            } else if (decWindow) {
                uint256 decPoolWei = (rewardPool * 15) / 100;
                (bool decFinished, ) = _progressExternal(1, decPoolWei, cap, prevLevel, rngWord, coinContract, true);
                if (!decFinished) return;
            }

            if (lvl > 1) {
                currentPrizePool = 0;
                phase = 0;
            }
            // Next-level purchase phase starts with an empty currentPrizePool; new funds accumulate in nextPrizePool.
            gameState = 2;
            traitRebuildCursor = 0;
        }

        if (pend.level == 0) {
            return;
        }

        bool traitWin = pend.exterminator != address(0);
        uint24 prevLevelPending = pend.level;
        uint256 poolValue = pend.sidePool;
        IPurgeGameTrophies.EndLevelRequest memory req = IPurgeGameTrophies.EndLevelRequest({
            exterminator: pend.exterminator,
            traitId: lastExterminatedTrait,
            level: prevLevelPending,
            pool: poolValue,
            rngWord: rngWord,
            deferredWei: 0
        });

        if (traitWin) {
            uint256 exterminatorShare = (prevLevelPending % 10 == 4 && prevLevelPending != 4)
                ? (poolValue * 40) / 100
                : (poolValue * 20) / 100;

            uint256 immediate = exterminatorShare >> 1;
            uint256 deferredWei = exterminatorShare - immediate;
            _addClaimableEth(pend.exterminator, immediate);
            req.deferredWei = deferredWei;

            // Reassign the trophy slice from the prize pool to players: 10% split across three tickets
            // using their ETH mint streaks as weights (even split if all streaks are zero).
            uint256 ticketBonus = (poolValue * 10) / 100;
            address[] storage arr = traitPurgeTicket[prevLevelPending][uint8(lastExterminatedTrait)];
            if (arr.length != 0 && ticketBonus != 0) {
                address[3] memory winners;
                uint256[3] memory streaks;
                uint256 seed = rngWord ^ (uint256(prevLevelPending) << 128);
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
        } else {
            // Timeout path: the final daily jackpot already forwarded any leftovers; clear stale base and settle bonuses.
            dailyJackpotBase = 0;
        }

        uint256 trophyPoolDelta = req.deferredWei;
        if (req.traitId == TRAIT_ID_TIMEOUT && req.pool != 0) {
            trophyPoolDelta += req.pool;
        }
        if (trophyPoolDelta != 0) {
            trophyPool += trophyPoolDelta;
        }

        trophiesContract.processEndLevel(req);

        _payoutCarryBonuses(prevLevelPending, rngWord, trophiesContract);

        delete pendingEndLevel;

        coinContract.resetAffiliateLeaderboard(lvl);
    }

    function _payoutParticipants(uint32 capHint, uint24 prevLevel) private {
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        uint32 len = uint32(arr.length);
        if (len == 0) {
            currentPrizePool = 0;
            return;
        }

        uint32 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint32 i = airdropIndex;
        uint32 end = i + cap;
        if (end > len) end = len;

        uint256 unitPayout = currentPrizePool;
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

    function _payoutCarryBonuses(
        uint24 lvl,
        uint256 /*rngWord*/,
        IPurgeGameTrophiesModule trophiesContract
    ) private {
        uint256 rewardBudgetAffiliate = _scaledRewardSlice(rewardPool, AFFILIATE_CARRY_BPS, lvl);
        uint256 rewardBudgetStake = _scaledRewardSlice(rewardPool, STAKE_CARRY_BPS, lvl);
        if (rewardBudgetAffiliate == 0 && rewardBudgetStake == 0) return;

        uint256 rewardSpent;
        uint256 trophyDelta;

        (uint256 affiliateTokenId, address affiliateOwner) = trophiesContract.trophyToken(
            lvl,
            PURGE_TROPHY_KIND_AFFILIATE
        );
        if (affiliateTokenId != 0 && affiliateOwner != address(0) && rewardBudgetAffiliate != 0) {
            trophiesContract.rewardTrophyByToken(affiliateTokenId, rewardBudgetAffiliate, lvl);
            rewardSpent += rewardBudgetAffiliate;
            trophyDelta += rewardBudgetAffiliate;
        }

        (uint256 stakeTokenId, address stakeOwner) = trophiesContract.trophyToken(lvl, PURGE_TROPHY_KIND_STAKE);
        if (stakeTokenId != 0 && stakeOwner != address(0) && rewardBudgetStake != 0) {
            trophiesContract.rewardTrophyByToken(stakeTokenId, rewardBudgetStake, lvl);
            rewardSpent += rewardBudgetStake;
            trophyDelta += rewardBudgetStake;
        }

        if (rewardSpent != 0) {
            uint256 rewardBal = rewardPool;
            rewardPool = rewardSpent > rewardBal ? 0 : rewardBal - rewardSpent;
        }
        if (trophyDelta != 0) {
            trophyPool += trophyDelta;
        }
    }

    function _scaledRewardSlice(uint256 rewardBudget, uint16 sliceBps, uint24 lvl) private pure returns (uint256) {
        if (rewardBudget == 0 || sliceBps == 0) return 0;
        uint256 base = (rewardBudget * sliceBps) / 10_000;
        if (base == 0) return 0;
        return (base * _rewardBonusScaleBps(lvl)) / 10_000;
    }

    function _rewardBonusScaleBps(uint24 lvl) private pure returns (uint16) {
        // Linearly scale reward pool-funded slices from 100% at the start of a 100-level band
        // down to 50% on the last level of the band, then reset on the next band.
        uint256 cycle = (lvl == 0) ? 0 : ((uint256(lvl) - 1) % 100); // 0..99
        uint256 discount = (cycle * 5000) / 99; // up to 50% at cycle==99
        uint256 scale = 10_000 - discount;
        if (scale < 5000) scale = 5000;
        return uint16(scale);
    }
}

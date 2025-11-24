// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeCoinModule, IPurgeGameTrophiesModule} from "./PurgeGameModuleInterfaces.sol";
import {PurgeGameStorage} from "../storage/PurgeGameStorage.sol";

/**
 * @title PurgeGameJackpotModule
 * @notice Delegate-called module that hosts the jackpot distribution logic for `PurgeGame`.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract PurgeGameJackpotModule is PurgeGameStorage {
    event PlayerCredited(address indexed player, uint256 amount);
    event Jackpot(uint256 traits);

    uint48 private constant JACKPOT_RESET_TIME = 82620;
    uint8 private constant JACKPOT_LEVEL_CAP = 10;
    uint8 private constant EARLY_PURGE_COIN_ONLY_THRESHOLD = 50;
    uint8 private constant PURGE_TROPHY_KIND_MAP = 0;
    uint256 private constant DEGENERATE_ENTROPY_CHECK_VALUE = 420;
    uint64 private constant MAP_JACKPOT_SHARES_PACKED =
        (uint64(6000)) | (uint64(1333) << 16) | (uint64(1333) << 32) | (uint64(1334) << 48);
    uint64 private constant DAILY_JACKPOT_SHARES_PACKED = uint64(2000) * 0x0001000100010001;
    bytes32 private constant COIN_JACKPOT_TAG = keccak256("coin-jackpot");
    bytes32 private constant CARRYOVER_BONUS_TAG = keccak256("carryover_bonus");
    bytes32 private constant CARRYOVER_3D6_SALT = keccak256("carryover-3d6");
    bytes32 private constant CARRYOVER_3D4_SALT = keccak256("carryover-3d4");
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;

    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external {
        uint8 percentBefore = earlyPurgePercent;
        bool kickoffJackpot = !firstEarlyJackpotPaid;
        bool purchasePhaseActive = (gameState == 2 && phase <= 2 && !kickoffJackpot);
        bool purgePhaseActive = (gameState == 3);
        uint8 percentAfter = percentBefore;
        if (purchasePhaseActive) {
            percentAfter = _currentEarlyPurgePercent();
            earlyPurgePercent = percentAfter;
        }

        if (isDaily) {
            _handleDailyJackpot(lvl, randWord, coinContract, trophiesContract);
            return;
        }

        uint256 entropyWord = _scrambleJackpotEntropy(randWord, jackpotCounter);
        uint8[4] memory winningTraits = _getRandomTraits(entropyWord);
        uint32 winningTraitsPacked = _packWinningTraits(winningTraits);

        bool coinOnly = percentBefore >= EARLY_PURGE_COIN_ONLY_THRESHOLD;
        uint256 poolWei;
        if (!coinOnly && (purchasePhaseActive || purgePhaseActive || kickoffJackpot)) {
            uint256 carryBal = carryOver;
            uint256 poolBps = kickoffJackpot ? 300 : 50; // default 0.5% unless first jackpot
            bool initialTrigger = kickoffJackpot;
            bool thresholdTrigger = purchasePhaseActive &&
                percentBefore < EARLY_PURGE_COIN_ONLY_THRESHOLD &&
                percentAfter >= EARLY_PURGE_COIN_ONLY_THRESHOLD;
            uint256 boostedBps;

            if (initialTrigger) {
                boostedBps += 300;
            }
            if (thresholdTrigger) {
                boostedBps += 300;
            }
            if (boostedBps != 0) {
                poolBps = boostedBps;
            }

            poolWei = (carryBal * poolBps) / 10_000;
            if (kickoffJackpot) {
                firstEarlyJackpotPaid = true;
            }
        }

        uint256 coinPool;
        if (purchasePhaseActive) {
            (coinPool, ) = coinContract.prepareCoinJackpot();
        }
        uint256 paidWei;
        if (poolWei != 0 || coinPool != 0) {
            (paidWei, , ) = _runJackpot(
                lvl,
                poolWei,
                coinPool,
                false,
                entropyWord ^ (uint256(lvl) << 192),
                winningTraitsPacked,
                DAILY_JACKPOT_SHARES_PACKED,
                coinContract,
                trophiesContract,
                0,
                0
            );
        }

        coinContract.resetCoinflipLeaderboard();
        _rollQuestForJackpot(coinContract, entropyWord, lvl, false);

        uint48 currentDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        dailyIdx = currentDay;

        uint256 carry = carryOver;
        carryOver = paidWei > carry ? 0 : carry - paidWei;
    }

    function payMapJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external returns (bool finished) {
        uint8[4] memory winningTraits = _getRandomTraits(rngWord);
        uint32 winningTraitsPacked = _packWinningTraits(winningTraits);
        uint256 stakeTotal = (effectiveWei * 5) / 100;
        uint256 stakePer = stakeTotal / 2;
        uint256 stakePaid;
        uint256 mapTrophyFallback;
        uint256 stakeRemainder = stakeTotal - (stakePer * 2);

        for (uint256 s; s < 2; ) {
            if (stakePer != 0) {
                bytes32 stakeEntropy = keccak256(abi.encode(rngWord, lvl, s, "map-stake"));
                uint256 rngSeed = uint256(stakeEntropy);
                address staker = trophiesContract.stakedTrophySample(rngSeed);
                if (staker != address(0)) {
                    _addClaimableEth(staker, stakePer);
                    stakePaid += stakePer;
                } else {
                    mapTrophyFallback += stakePer;
                }
            }
            unchecked {
                ++s;
            }
        }
        mapTrophyFallback += stakeRemainder;

        uint256 paidWeiMap;
        (paidWeiMap, , ) = _runJackpot(
            lvl,
            effectiveWei,
            0,
            true,
            rngWord,
            winningTraitsPacked,
            MAP_JACKPOT_SHARES_PACKED,
            coinContract,
            trophiesContract,
            stakeTotal,
            mapTrophyFallback
        );

        uint256 distributedEth = paidWeiMap + stakePaid;
        if (distributedEth > effectiveWei) {
            distributedEth = effectiveWei;
        }
        uint256 remainingPool = effectiveWei - distributedEth;
        prizePool += remainingPool;
        levelPrizePool += remainingPool;

        _rollQuestForJackpot(coinContract, rngWord, lvl, true);

        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        coinContract.primeMintEthQuest(questDay + 1);

        return true;
    }

    function calcPrizePoolForJackpot(
        uint24 lvl,
        uint256 rngWord,
        IPurgeCoinModule coinContract
    ) external returns (uint256 effectiveWei) {
        uint256 totalWei = carryOver + prizePool;
        // Pay 10% PURGE using the current mint conversion (priceCoin / price) to Burnie.
        uint256 burnieAmount = (totalWei * priceCoin) / (10 * price);
        coinContract.burnie(burnieAmount);

        uint256 savePctTimes2 = _mapCarryoverPercent(lvl, rngWord);
        uint256 saveNextWei = (totalWei * savePctTimes2) / 200;
        carryOver = saveNextWei;

        uint256 jackpotBase = totalWei - saveNextWei;
        uint256 mapPct = _mapJackpotPercent(lvl);
        uint256 mapWei = (jackpotBase * mapPct) / 100;

        uint256 mainWei;
        unchecked {
            mainWei = jackpotBase - mapWei;
        }

        lastPrizePool = prizePool;
        prizePool = mainWei;
        levelPrizePool = mainWei;
        dailyJackpotBase = mainWei;
        dailyJackpotPaid = 0;

        effectiveWei = mapWei;
    }

    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
        claimableWinnings[beneficiary] += weiAmount;
        emit PlayerCredited(beneficiary, weiAmount);
    }

    function _traitBucketCounts(uint8 band, uint256 entropy) private pure returns (uint16[4] memory counts) {
        uint16[4] memory base;
        base[0] = uint16(25) * band;
        base[1] = uint16(15) * band;
        base[2] = uint16(10) * band;
        base[3] = 1;

        uint8 offset = uint8(entropy & 3);
        for (uint8 i; i < 4; ) {
            counts[i] = base[(i + offset) & 3];
            unchecked {
                ++i;
            }
        }
    }

    function _mapCarryoverPercent(uint24 lvl, uint256 rngWord) private pure returns (uint256) {
        if ((rngWord % 1_000_000_000) == DEGENERATE_ENTROPY_CHECK_VALUE) {
            return 20; // 10% fallback when trait entropy is degenerate (returned as times two).
        }
        if (lvl % 100 == 0) {
            uint256 pct = 3 + (uint256(lvl) / 50) + _rollSum(rngWord, CARRYOVER_3D6_SALT, 6, 3);
            return _clampPctTimes2(pct);
        }
        if (lvl >= 80 && lvl <= 98) {
            uint256 base = 75 + (uint256(lvl) - 80) + ((lvl % 10 == 9) ? 5 : 0);
            uint256 pct = base + _rollSum(rngWord, CARRYOVER_3D4_SALT, 4, 3);
            return _clampPctTimes2(pct);
        }
        if (lvl == 99) {
            return 196; // Hard cap at 98% for the pre-finale level (times two).
        }

        uint256 baseTimes2;
        if (lvl <= 4) {
            uint256 increments = lvl > 0 ? uint256(lvl) - 1 : 0;
            baseTimes2 = (8 + increments * 8) * 2;
        } else if (lvl <= 79) {
            baseTimes2 = 64 + (uint256(lvl) - 4);
        } else {
            baseTimes2 = _legacyCarryoverTimes2(lvl, rngWord);
        }

        baseTimes2 += _carryoverBonus(rngWord) * 2;
        if (baseTimes2 > 196) {
            baseTimes2 = 196;
        }

        uint256 jackpotPctTimes2 = 200 - baseTimes2;
        if (jackpotPctTimes2 < 34 && jackpotPctTimes2 != 60) {
            baseTimes2 = 166;
        }
        return baseTimes2;
    }

    function _carryoverBonus(uint256 rngWord) private pure returns (uint256) {
        uint256 seed = uint256(keccak256(abi.encodePacked(rngWord, CARRYOVER_BONUS_TAG)));
        uint256 d4a = (seed & 0xF) % 4;
        uint256 d4b = ((seed >> 8) & 0xF) % 4;
        uint256 d14 = ((seed >> 16) & 0xFF) % 14;
        return d4a + d4b + d14 + 3;
    }

    function _legacyCarryoverTimes2(uint24 lvl, uint256 rngWord) private pure returns (uint256) {
        uint256 base;
        uint256 lvlMod100 = lvl % 100;
        if (lvl < 10) base = uint256(lvl) * 5;
        else if (lvl < 20) base = 55 + (rngWord % 16);
        else if (lvl < 40) base = 55 + (rngWord % 21);
        else if (lvl < 60) base = 60 + (rngWord % 21);
        else if (lvl < 80) base = 60 + (rngWord % 26);
        else if (lvlMod100 == 99) base = 93;
        else base = 65 + (rngWord % 26);

        if ((lvl % 10) == 9) base += 5;
        base += lvl / 100;
        return base * 2;
    }

    function _clampPctTimes2(uint256 pct) private pure returns (uint256) {
        if (pct > 98) {
            pct = 98;
        }
        return pct * 2;
    }

    function _rollSum(uint256 rngWord, bytes32 salt, uint8 sides, uint8 dice) private pure returns (uint256) {
        uint256 seed = uint256(keccak256(abi.encodePacked(rngWord, salt)));
        uint256 result;
        unchecked {
            for (uint8 i; i < dice; ++i) {
                result += (seed % sides) + 1;
                seed >>= 16;
            }
        }
        return result;
    }

    function _mapJackpotPercent(uint24 lvl) private pure returns (uint256) {
        return (lvl % 20 == 16) ? 30 : 17;
    }

    function _runJackpot(
        uint24 lvl,
        uint256 ethPool,
        uint256 coinPool,
        bool mapTrophy,
        uint256 entropy,
        uint32 winningTraitsPacked,
        uint64 traitShareBpsPacked,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract,
        uint256 mapStakeSiphon,
        uint256 mapTrophyBonus
    ) private returns (uint256 totalPaidEth, uint256 totalPaidCoin, uint256 coinRemainder) {
        if (ethPool == 0 && coinPool == 0) {
            return (0, 0, 0);
        }

        uint8 band = uint8((lvl % 100) / 20) + 1;
        uint16[4] memory bucketCounts = _traitBucketCounts(band, entropy);
        uint8[4] memory traitIds = _unpackWinningTraits(winningTraitsPacked);
        uint16[4] memory shareBps = _shareBpsByBucket(traitShareBpsPacked, uint8(entropy & 3));

        if (ethPool != 0) {
            (totalPaidEth, , ) = _runJackpotEth(
                mapTrophy,
                lvl,
                ethPool,
                entropy,
                traitIds,
                shareBps,
                bucketCounts,
                coinContract,
                trophiesContract,
                mapStakeSiphon,
                mapTrophyBonus
            );
        }

        if (coinPool != 0) {
            totalPaidCoin = _runJackpotCoin(
                lvl,
                coinPool,
                entropy ^ uint256(COIN_JACKPOT_TAG),
                traitIds,
                shareBps,
                bucketCounts,
                coinContract
            );
        }

        coinRemainder = 0;
    }

    function _handleDailyJackpot(
        uint24 lvl,
        uint256 randWord,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) private {
        uint256 entropyWord = _scrambleJackpotEntropy(randWord, jackpotCounter);

        uint32 winningTraitsPacked = _packWinningTraits(_getWinningTraits(entropyWord, dailyPurgeCount));
        uint8 remainingJackpots = JACKPOT_LEVEL_CAP > jackpotCounter
            ? uint8(JACKPOT_LEVEL_CAP - jackpotCounter)
            : uint8(1);
        uint256 currentEntropy = entropyWord ^ (uint256(lvl) << 192);
        _payCurrentLevelDailyJackpot(
            lvl,
            currentEntropy,
            winningTraitsPacked,
            remainingJackpots,
            coinContract,
            trophiesContract
        );

        uint24 nextLevel = lvl + 1;
        (uint256 dailyCoinPool, ) = coinContract.prepareCoinJackpot();
        uint256 carryBal = carryOver;
        uint256 extraBps;
        bool purgeKickoff = !firstPurgeJackpotPaid;
        if (purgeKickoff) {
            extraBps += 300;
            firstPurgeJackpotPaid = true;
        }
        uint256 futureEthPool = (carryBal * (extraBps != 0 ? extraBps : 50)) / 10_000;
        if (futureEthPool > carryBal) futureEthPool = carryBal;

        uint256 dailyPaidEth = _payFutureDailyJackpot(
            nextLevel,
            entropyWord,
            winningTraitsPacked,
            futureEthPool,
            dailyCoinPool,
            coinContract,
            trophiesContract
        );

        coinContract.resetCoinflipLeaderboard();
        _rollQuestForJackpot(coinContract, entropyWord, nextLevel, false);

        if (dailyPaidEth != 0) {
            uint256 carryAfter = carryOver;
            carryOver = dailyPaidEth > carryAfter ? 0 : carryAfter - dailyPaidEth;
        }

        unchecked {
            ++jackpotCounter;
        }
        if (jackpotCounter < JACKPOT_LEVEL_CAP) {
            _clearDailyPurgeCount();
        }
    }

    function _payCurrentLevelDailyJackpot(
        uint24 lvl,
        uint256 entropy,
        uint32 winningTraitsPacked,
        uint8 remainingJackpots,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) private {
        if (remainingJackpots == 0) {
            remainingJackpots = 1;
        }
        uint8 executed = JACKPOT_LEVEL_CAP > remainingJackpots ? uint8(JACKPOT_LEVEL_CAP - remainingJackpots) : 0;
        uint8 jackpotIndex = executed + 1;
        uint256 paidSoFar = dailyJackpotPaid;
        uint256 budget;
        if (dailyJackpotBase != 0 && jackpotIndex <= JACKPOT_LEVEL_CAP) {
            uint256 targetPaid = _dailyJackpotTarget(jackpotIndex);
            if (targetPaid > paidSoFar) {
                budget = targetPaid - paidSoFar;
            }
        }
        if (budget == 0) {
            budget = prizePool / remainingJackpots;
        }
        if (budget == 0) return;
        if (budget > prizePool) {
            budget = prizePool;
        }
        (uint256 paid, , ) = _runJackpot(
            lvl,
            budget,
            0,
            false,
            entropy,
            winningTraitsPacked,
            DAILY_JACKPOT_SHARES_PACKED,
            coinContract,
            trophiesContract,
            0,
            0
        );
        if (paid == 0) return;
        uint256 poolBal = prizePool;
        prizePool = paid > poolBal ? 0 : poolBal - paid;
        dailyJackpotPaid = paidSoFar + paid;
        uint256 levelPool = levelPrizePool;
        levelPrizePool = paid > levelPool ? 0 : levelPool - paid;
    }

    function _dailyJackpotTarget(uint8 jackpotsExecuted) private view returns (uint256) {
        if (jackpotsExecuted == 0) {
            return 0;
        }
        uint256 base = dailyJackpotBase;
        if (base == 0) {
            return 0;
        }
        uint256 n = jackpotsExecuted;
        uint256 numerator = n * (n + 17);
        return (base * numerator) / 300;
    }

    function _payFutureDailyJackpot(
        uint24 nextLevel,
        uint256 entropyWord,
        uint32 winningTraitsPacked,
        uint256 futureEthPool,
        uint256 dailyCoinPool,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) private returns (uint256 paidEth) {
        if (futureEthPool == 0 && dailyCoinPool == 0) return 0;

        uint256 nextEntropy = _entropyStep(entropyWord) ^ (uint256(nextLevel) << 192);
        (paidEth, , ) = _runJackpot(
            nextLevel,
            futureEthPool,
            dailyCoinPool,
            false,
            nextEntropy,
            winningTraitsPacked,
            DAILY_JACKPOT_SHARES_PACKED,
            coinContract,
            trophiesContract,
            0,
            0
        );
    }

    function _runJackpotEth(
        bool mapTrophy,
        uint24 lvl,
        uint256 ethPool,
        uint256 entropy,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16[4] memory bucketCounts,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract,
        uint256 mapStakeSiphon,
        uint256 mapTrophyBonus
    ) private returns (uint256 totalPaidEth, uint256 entropyCursor, bool trophyGiven) {
        uint256 ethDistributed;
        entropyCursor = entropy;

        int8 trophyIndex = -1;
        if (mapTrophy) {
            for (uint8 i; i < 4; ) {
                if (bucketCounts[i] == 1) {
                    trophyIndex = int8(i);
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        }

        for (uint8 traitIdx; traitIdx < 4; ) {
            uint256 share = _sliceJackpotShare(ethPool, shareBps[traitIdx], traitIdx, ethDistributed);
            uint8 traitId = traitIds[traitIdx];
            uint16 bucketCount = bucketCounts[traitIdx];
            bool bucketGetsTrophy = mapTrophy && !trophyGiven && trophyIndex >= 0 && traitIdx == uint8(trophyIndex);
            if (bucketGetsTrophy) {
                if (mapStakeSiphon != 0) {
                    uint256 siphon = mapStakeSiphon > share ? share : mapStakeSiphon;
                    share -= siphon;
                    mapStakeSiphon -= siphon;
                }
                if (mapTrophyBonus != 0) {
                    share += mapTrophyBonus;
                    mapTrophyBonus = 0;
                }
            }
            if (traitIdx < 3) {
                unchecked {
                    ethDistributed += share;
                }
            }
            uint256 delta;
            (entropyCursor, trophyGiven, delta, ) = _runTraitJackpot(
                coinContract,
                trophiesContract,
                false,
                bucketGetsTrophy,
                lvl,
                traitId,
                traitIdx,
                share,
                entropyCursor,
                trophyGiven,
                bucketCount
            );
            totalPaidEth += delta;
            unchecked {
                ++traitIdx;
            }
        }
    }

    function _runJackpotCoin(
        uint24 lvl,
        uint256 coinPool,
        uint256 entropy,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16[4] memory bucketCounts,
        IPurgeCoinModule coinContract
    ) private returns (uint256 totalPaidCoin) {
        uint256 coinDistributed;
        for (uint8 traitIdx; traitIdx < 4; ) {
            uint256 share = _sliceJackpotShare(coinPool, shareBps[traitIdx], traitIdx, coinDistributed);
            uint8 traitId = traitIds[traitIdx];
            uint16 bucketCount = bucketCounts[traitIdx];
            if (traitIdx < 3) {
                unchecked {
                    coinDistributed += share;
                }
            }
            uint256 delta;
            (entropy, , , delta) = _runTraitJackpot(
                coinContract,
                IPurgeGameTrophiesModule(address(0)),
                true,
                false,
                lvl,
                traitId,
                traitIdx,
                share,
                entropy,
                false,
                bucketCount
            );
            totalPaidCoin += delta;
            unchecked {
                ++traitIdx;
            }
        }
    }

    function _rotatedShareBps(uint64 packed, uint8 offset, uint8 traitIdx) private pure returns (uint16) {
        uint8 baseIndex = uint8((uint256(traitIdx) + uint256(offset) + 1) & 3);
        return uint16(packed >> (baseIndex * 16));
    }

    function _sliceJackpotShare(
        uint256 pool,
        uint16 shareBps,
        uint8 traitIdx,
        uint256 distributed
    ) private pure returns (uint256 slice) {
        if (pool == 0) return 0;
        if (traitIdx == 3) return pool - distributed;
        if (shareBps == 0) return 0;
        slice = (pool * shareBps) / 10_000;
    }

    function _runTraitJackpot(
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract,
        bool payCoin,
        bool mapTrophy,
        uint24 lvl,
        uint8 traitId,
        uint8 traitIdx,
        uint256 traitShare,
        uint256 entropy,
        bool trophyGiven,
        uint16 winnerCount
    ) private returns (uint256 nextEntropy, bool trophyGivenOut, uint256 ethDelta, uint256 coinDelta) {
        nextEntropy = entropy;
        trophyGivenOut = trophyGiven;

        if (traitShare == 0) return (nextEntropy, trophyGivenOut, 0, 0);

        uint16 totalCount = winnerCount;
        if (totalCount == 0) return (nextEntropy, trophyGivenOut, 0, 0);

        uint8 requested = uint8(totalCount);
        nextEntropy = _entropyStep(nextEntropy ^ (uint256(traitIdx) << 64) ^ traitShare);
        address[] memory winners = _randTraitTicket(
            traitPurgeTicket[lvl],
            nextEntropy,
            traitId,
            requested,
            uint8(200 + traitIdx)
        );
        uint8 len = uint8(winners.length);
        if (len == 0) return (nextEntropy, trophyGivenOut, 0, 0);

        uint256 perWinner = traitShare / totalCount;
        if (perWinner == 0) return (nextEntropy, trophyGivenOut, 0, 0);

        bool needTrophy = mapTrophy && !trophyGivenOut;

        for (uint8 i; i < len; ) {
            address w = winners[i];

            if (needTrophy) {
                needTrophy = false;
                trophyGivenOut = true;
                uint256 half = perWinner / 2;
                if (half != 0) {
                    _addClaimableEth(w, half);
                    ethDelta += half;
                }
                uint256 deferred = perWinner - half;
                if (deferred != 0 && address(trophiesContract) != address(0)) {
                    uint256 trophyData = (uint256(traitId) << 152) | (uint256(lvl) << 128) | TROPHY_FLAG_MAP;
                    trophiesContract.awardTrophy{value: deferred}(w, lvl, PURGE_TROPHY_KIND_MAP, trophyData, deferred);
                    ethDelta += deferred;
                }
            } else if (_creditJackpot(coinContract, payCoin, w, perWinner)) {
                if (payCoin) coinDelta += perWinner;
                else ethDelta += perWinner;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _scrambleJackpotEntropy(uint256 entropy, uint256 salt) private pure returns (uint256) {
        unchecked {
            return ((entropy << 64) | (entropy >> 192)) ^ (salt << 128) ^ 0x05;
        }
    }

    function _entropyStep(uint256 state) private pure returns (uint256) {
        unchecked {
            state ^= state << 7;
            state ^= state >> 9;
            state ^= state << 8;
        }
        return state;
    }

    function _rollQuestForJackpot(
        IPurgeCoinModule coinContract,
        uint256 entropySource,
        uint24 questLevel,
        bool forceMintEthAndPurge
    ) private {
        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        uint256 questEntropy = uint256(keccak256(abi.encode(entropySource, questLevel, jackpotCounter, "daily-quest")));
        if (forceMintEthAndPurge) {
            coinContract.rollDailyQuestWithOverrides(questDay, questEntropy, true, true);
        } else {
            coinContract.rollDailyQuest(questDay, questEntropy);
        }
    }

    function _creditJackpot(
        IPurgeCoinModule coinContract,
        bool payInCoin,
        address beneficiary,
        uint256 amount
    ) private returns (bool) {
        if (beneficiary == address(0) || amount == 0) return false;
        if (payInCoin) {
            coinContract.bonusCoinflip(beneficiary, amount, true);
        } else {
            _addClaimableEth(beneficiary, amount);
        }
        return true;
    }

    function _packWinningTraits(uint8[4] memory traits) private pure returns (uint32 packed) {
        packed = uint32(traits[0]) | (uint32(traits[1]) << 8) | (uint32(traits[2]) << 16) | (uint32(traits[3]) << 24);
    }

    function _unpackWinningTraits(uint32 packed) private pure returns (uint8[4] memory traits) {
        traits[0] = uint8(packed);
        traits[1] = uint8(packed >> 8);
        traits[2] = uint8(packed >> 16);
        traits[3] = uint8(packed >> 24);
    }

    function _traitFromPacked(uint32 packed, uint8 idx) private pure returns (uint8) {
        return uint8(packed >> (uint32(idx) * 8));
    }

    function _shareBpsByBucket(uint64 packed, uint8 offset) private pure returns (uint16[4] memory shares) {
        unchecked {
            for (uint8 i; i < 4; ++i) {
                shares[i] = _rotatedShareBps(packed, offset, i);
            }
        }
    }

    function _getRandomTraits(uint256 rw) private pure returns (uint8[4] memory w) {
        w[0] = uint8(rw & 0x3F);
        w[1] = 64 + uint8((rw >> 6) & 0x3F);
        w[2] = 128 + uint8((rw >> 12) & 0x3F);
        w[3] = 192 + uint8((rw >> 18) & 0x3F);
    }

    function _getWinningTraits(
        uint256 randomWord,
        uint32[80] storage counters
    ) private view returns (uint8[4] memory w) {
        uint8 sym = _maxIdxInRange(counters, 0, 8);

        uint8 col0 = uint8(randomWord & 7);
        w[0] = (col0 << 3) | sym;

        uint8 maxColor = _maxIdxInRange(counters, 8, 8);
        uint8 randSym = uint8((randomWord >> 3) & 7);
        w[1] = 64 + ((maxColor << 3) | randSym);

        uint8 maxTrait = _maxIdxInRange(counters, 16, 64);
        w[2] = 128 + maxTrait;

        w[3] = 192 + uint8((randomWord >> 6) & 63);
    }

    function _maxIdxInRange(uint32[80] storage counters, uint8 base, uint8 len) private view returns (uint8) {
        if (len == 0 || base >= 80) return 0;

        uint256 end = uint256(base) + uint256(len);
        if (end > 80) end = 80;

        uint8 maxRel = 0;
        uint32 maxVal = counters[base];

        for (uint256 i = uint256(base) + 1; i < end; ) {
            uint32 v = counters[i];
            if (v > maxVal) {
                maxVal = v;
                maxRel = uint8(i) - base;
            }
            unchecked {
                ++i;
            }
        }
        return maxRel;
    }

    function _clearDailyPurgeCount() private {
        for (uint8 i; i < 80; ) {
            dailyPurgeCount[i] = 0;
            unchecked {
                ++i;
            }
        }
    }

    function _randTraitTicket(
        address[][256] storage traitPurgeTicket_,
        uint256 randomWord,
        uint8 trait,
        uint8 numWinners,
        uint8 salt
    ) private view returns (address[] memory winners) {
        address[] storage holders = traitPurgeTicket_[trait];
        uint256 len = holders.length;
        if (len == 0 || numWinners == 0) return new address[](0);

        winners = new address[](numWinners);
        uint256 slice = randomWord ^ (uint256(trait) << 128) ^ (uint256(salt) << 192);
        for (uint256 i; i < numWinners; ) {
            uint256 idx = slice % len;
            winners[i] = holders[idx];
            unchecked {
                ++i;
                slice = (slice >> 16) | (slice << 240);
            }
        }
    }

    function _currentEarlyPurgePercent() private view returns (uint8) {
        uint256 prevPoolWei = lastPrizePool;
        if (prevPoolWei == 0) return 0;
        uint256 pct = (prizePool * 100) / prevPoolWei;
        if (pct > type(uint8).max) return type(uint8).max;
        return uint8(pct);
    }
}

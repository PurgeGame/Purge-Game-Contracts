// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeCoinModule, IPurgeGameTrophiesModule} from "./PurgeGameModuleInterfaces.sol";

/**
 * @title PurgeGameJackpotModule
 * @notice Delegate-called module that hosts the jackpot distribution logic for `PurgeGame`.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract PurgeGameJackpotModule {
    event PlayerCredited(address indexed player, uint256 amount);
    event Jackpot(uint256 traits);

    uint48 private constant JACKPOT_RESET_TIME = 82620;
    uint8 private constant JACKPOT_KIND_DAILY = 4;
    uint8 private constant JACKPOT_KIND_MAP = 9;
    uint8 private constant EARLY_PURGE_COIN_ONLY_THRESHOLD = 50;
    uint8 private constant PURGE_TROPHY_KIND_MAP = 0;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint64 private constant MAP_JACKPOT_SHARES_PACKED =
        (uint64(6000)) | (uint64(1333) << 16) | (uint64(1333) << 32) | (uint64(1334) << 48);
    uint64 private constant DAILY_JACKPOT_SHARES_PACKED = uint64(2000) * 0x0001000100010001;
    bytes32 private constant COIN_JACKPOT_TAG = keccak256("coin-jackpot");
    bytes32 private constant CARRYOVER_BONUS_TAG = keccak256("carryover_bonus");
    bytes32 private constant CARRYOVER_3D6_SALT = keccak256("carryover-3d6");
    bytes32 private constant CARRYOVER_3D4_SALT = keccak256("carryover-3d4");
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant ETH_LAST_LEVEL_SHIFT = 0;

    // -----------------------
    // Storage layout mirror
    // -----------------------
    uint256 private price = 0.025 ether;
    uint256 private priceCoin = 1_000_000_000;

    uint256 private lastPrizePool = 125 ether;
    uint256 private levelPrizePool;
    uint256 private prizePool;
    uint256 private nextPrizePool;
    uint256 private carryoverForNextLevel;

    uint48 private levelStartTime = type(uint48).max;
    uint48 private dailyIdx;

    uint24 public level = 1;
    uint8 public gameState = 1;
    uint8 private jackpotCounter;
    uint8 private earlyPurgePercent;
    uint8 private phase;
    uint16 private lastExterminatedTrait = TRAIT_ID_TIMEOUT;
    bool private rngLockedFlag;
    bool private rngFulfilled = true;
    uint256 private rngWordCurrent;
    uint256 private vrfRequestId;

    uint32 private airdropMapsProcessedCount;
    uint32 private airdropIndex;
    uint32 private traitRebuildCursor;
    uint32 private airdropMultiplier;
    bool private traitCountsSeedQueued;
    bool private traitCountsShouldOverwrite;

    address[] private pendingMapMints;
    mapping(address => uint32) private playerMapMintsOwed;

    mapping(address => uint256) private claimableWinnings;
    mapping(uint24 => address[][256]) private traitPurgeTicket;

    struct PendingEndLevel {
        address exterminator;
        uint24 level;
        uint256 sidePool;
    }
    PendingEndLevel private pendingEndLevel;

    uint32[80] internal dailyPurgeCount;
    uint32[256] internal traitRemaining;
    mapping(address => uint256) private mintPacked_;

    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external {
        uint8 percentBefore = earlyPurgePercent;
        uint8 percentAfter = _currentEarlyPurgePercent();
        earlyPurgePercent = percentAfter;

        uint256 entropyWord = randWord;
        uint8[4] memory winningTraits;

        if (isDaily) {
            entropyWord = _scrambleJackpotEntropy(entropyWord, jackpotCounter);
            winningTraits = _getRandomTraits(entropyWord);

            uint24 targetLevel = lvl + 1;
            (uint256 dailyCoinPool, ) = coinContract.prepareCoinJackpot();
            uint256 carryBal = carryoverForNextLevel;
            uint256 ethPool = (carryBal * 50) / 10_000;
            if (ethPool > carryBal) ethPool = carryBal;

            uint256 dailyPaidEth;
            uint256 dailyCoinRemainder;
            (dailyPaidEth, , dailyCoinRemainder) = _runJackpot(
                targetLevel,
                ethPool,
                dailyCoinPool,
                false,
                entropyWord ^ (uint256(targetLevel) << 192),
                winningTraits,
                DAILY_JACKPOT_SHARES_PACKED,
                coinContract,
                trophiesContract,
                0,
                0
            );

            if (dailyCoinRemainder != 0) {
                bool distributedRemainder;
                for (uint8 traitIdx; traitIdx < 4 && !distributedRemainder; ) {
                    address[] memory fallbackWinners = _randTraitTicket(
                        traitPurgeTicket[targetLevel],
                        entropyWord,
                        winningTraits[traitIdx],
                        1,
                        uint8(240 + traitIdx)
                    );
                    if (fallbackWinners.length != 0) {
                        address candidate = fallbackWinners[0];
                        if (_creditJackpot(coinContract, true, candidate, dailyCoinRemainder)) {
                            distributedRemainder = true;
                        }
                    }
                    unchecked {
                        ++traitIdx;
                    }
                }
                if (!distributedRemainder) {
                    coinContract.addToBounty(dailyCoinRemainder);
                }
            }

            coinContract.resetCoinflipLeaderboard();

            uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
            uint256 questEntropy = uint256(keccak256(abi.encode(entropyWord, targetLevel, jackpotCounter, "daily-quest")));
            coinContract.rollDailyQuest(questDay, questEntropy);

            if (dailyPaidEth != 0) {
                uint256 carryAfter = carryoverForNextLevel;
                carryoverForNextLevel = dailyPaidEth > carryAfter ? 0 : carryAfter - dailyPaidEth;
            }

            unchecked {
                ++jackpotCounter;
            }
            if (jackpotCounter < 10) {
                _clearDailyPurgeCount();
            }
            return;
        }

        entropyWord = _scrambleJackpotEntropy(entropyWord, jackpotCounter);
        winningTraits = _getRandomTraits(entropyWord);

        bool coinOnly = percentBefore >= EARLY_PURGE_COIN_ONLY_THRESHOLD;
        uint256 poolWei;
        if (!coinOnly && gameState == 2 && phase <= 2) {
            uint256 carryBal = carryoverForNextLevel;
            uint256 poolBps = 50; // default 0.5%
            bool initialTrigger = percentBefore == 0;
            bool thresholdTrigger = percentBefore < EARLY_PURGE_COIN_ONLY_THRESHOLD &&
                percentAfter >= EARLY_PURGE_COIN_ONLY_THRESHOLD;

            if (percentBefore == 0) {
                poolBps = 400;
            } else if (
                percentBefore < EARLY_PURGE_COIN_ONLY_THRESHOLD && percentAfter >= EARLY_PURGE_COIN_ONLY_THRESHOLD
            ) {
                poolBps = 400;
            }
            if (initialTrigger && thresholdTrigger) {
                poolBps = 600;
            }
            poolWei = (carryBal * poolBps) / 10_000;
        }

        (uint256 coinPool, address biggestFlip) = coinContract.prepareCoinJackpot();
        address[] memory topBettors = coinContract.getLeaderboardAddresses(2);
        address thirdFlip = topBettors.length > 2 ? topBettors[2] : address(0);
        address fourthFlip = topBettors.length > 3 ? topBettors[3] : address(0);

        uint256 paidWei;
        uint256 coinRemainder;
        (paidWei, , coinRemainder) = _runJackpot(
            lvl,
            poolWei,
            coinPool,
            false,
            entropyWord ^ (uint256(lvl) << 192),
            winningTraits,
            DAILY_JACKPOT_SHARES_PACKED,
            coinContract,
            trophiesContract,
            0,
            0
        );

        if (coinRemainder != 0) {
            uint256 biggestShare = coinRemainder / 2;
            uint256 secondaryShare = coinRemainder / 4;
            uint256 bountyShare = coinRemainder - biggestShare - secondaryShare;
            uint256 bountyOverflow;

            if (biggestShare != 0) {
                if (biggestFlip != address(0)) {
                    coinContract.bonusCoinflip(biggestFlip, biggestShare, true, 0);
                } else {
                    bountyOverflow += biggestShare;
                }
            }

            if (secondaryShare != 0) {
                address candidate;
                if (thirdFlip != address(0) && fourthFlip != address(0)) {
                    uint256 selector = uint256(keccak256(abi.encode(entropyWord, lvl, jackpotCounter)));
                    candidate = (selector & 1) == 0 ? thirdFlip : fourthFlip;
                } else if (thirdFlip != address(0)) {
                    candidate = thirdFlip;
                } else if (fourthFlip != address(0)) {
                    candidate = fourthFlip;
                }

                if (candidate != address(0)) {
                    coinContract.bonusCoinflip(candidate, secondaryShare, true, 0);
                } else {
                    bountyOverflow += secondaryShare;
                }
            }

            bountyOverflow += bountyShare;
            if (bountyOverflow != 0) {
                coinContract.addToBounty(bountyOverflow);
            }
        }

        coinContract.resetCoinflipLeaderboard();

        earlyPurgePercent = percentAfter;

        uint48 currentDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        dailyIdx = currentDay;

        uint256 carry = carryoverForNextLevel;
        carryoverForNextLevel = paidWei > carry ? 0 : carry - paidWei;
    }

    function payMapJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external returns (bool finished) {
        uint8[4] memory winningTraits = _getRandomTraits(rngWord);
        uint256 stakeTotal = (effectiveWei * 5) / 100;
        uint256 stakePer = stakeTotal / 2;
        uint256 stakePaid;
        uint256 mapTrophyFallback;
        uint256 stakeRemainder = stakeTotal - (stakePer * 2);

        for (uint256 s; s < 2; ) {
            if (stakePer != 0) {
                bytes32 stakeEntropy = keccak256(abi.encode(rngWord, lvl, s, "map-stake"));
                uint64 salt = uint64(uint256(stakeEntropy));
                address staker = trophiesContract.stakedTrophySample(salt);
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
        uint256 coinRemainder;
        (paidWeiMap, , coinRemainder) = _runJackpot(
            lvl,
            effectiveWei,
            0,
            true,
            rngWord,
            winningTraits,
            MAP_JACKPOT_SHARES_PACKED,
            coinContract,
            trophiesContract,
            stakeTotal,
            mapTrophyFallback
        );

        if (coinRemainder != 0) {
            coinContract.addToBounty(coinRemainder);
        }

        uint256 distributedEth = paidWeiMap + stakePaid;
        if (distributedEth > effectiveWei) {
            distributedEth = effectiveWei;
        }
        uint256 remainingPool = effectiveWei - distributedEth;
        prizePool += remainingPool;
        levelPrizePool += remainingPool;

        earlyPurgePercent = 0;

        return true;
    }

    function calcPrizePoolForJackpot(
        uint24 lvl,
        uint256 rngWord,
        IPurgeCoinModule coinContract
    ) external returns (uint256 effectiveWei) {
        uint256 totalWei = carryoverForNextLevel + prizePool;
        uint256 burnieAmount = (totalWei * 5 * priceCoin) / 1 ether;
        coinContract.burnie(burnieAmount);

        uint256 savePctTimes2 = _mapCarryoverPercent(lvl, rngWord);
        uint256 saveNextWei = (totalWei * savePctTimes2) / 200;
        carryoverForNextLevel = saveNextWei;

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

        effectiveWei = mapWei;
    }

    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
        unchecked {
            claimableWinnings[beneficiary] += weiAmount;
        }
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
        if ((rngWord % 1_000_000_000) == TRAIT_ID_TIMEOUT) {
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
        uint8[4] memory winningTraits,
        uint64 traitShareBpsPacked,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract,
        uint256 mapStakeSiphon,
        uint256 mapTrophyBonus
    ) private returns (uint256 totalPaidEth, uint256 totalPaidCoin, uint256 coinRemainder) {
        uint8 band = uint8((lvl % 100) / 20) + 1;
        uint16[4] memory bucketCounts = _traitBucketCounts(band, entropy);

        (totalPaidEth, , ) = _runJackpotEth(
            mapTrophy,
            lvl,
            ethPool,
            entropy,
            winningTraits,
            traitShareBpsPacked,
            bucketCounts,
            coinContract,
            trophiesContract,
            mapStakeSiphon,
            mapTrophyBonus
        );

        if (coinPool != 0) {
            totalPaidCoin = _runJackpotCoin(
                lvl,
                coinPool,
                entropy ^ uint256(COIN_JACKPOT_TAG),
                winningTraits,
                traitShareBpsPacked,
                bucketCounts,
                coinContract
            );
        }

        coinRemainder = coinPool > totalPaidCoin ? coinPool - totalPaidCoin : 0;
    }

    function _runJackpotEth(
        bool mapTrophy,
        uint24 lvl,
        uint256 ethPool,
        uint256 entropy,
        uint8[4] memory winningTraits,
        uint64 traitShareBpsPacked,
        uint16[4] memory bucketCounts,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract,
        uint256 mapStakeSiphon,
        uint256 mapTrophyBonus
    ) private returns (uint256 totalPaidEth, uint256 entropyCursor, bool trophyGiven) {
        uint256 ethDistributed;
        entropyCursor = entropy;
        for (uint8 traitIdx; traitIdx < 4; ) {
            uint16 shareBps = uint16(traitShareBpsPacked >> (traitIdx * 16));
            uint256 share = _sliceJackpotShare(ethPool, shareBps, traitIdx, ethDistributed);
            uint8 traitId = winningTraits[traitIdx];
            uint16 bucketCount = bucketCounts[traitIdx];
            if (mapTrophy && traitIdx == 0) {
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
                mapTrophy,
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
        uint8[4] memory winningTraits,
        uint64 traitShareBpsPacked,
        uint16[4] memory bucketCounts,
        IPurgeCoinModule coinContract
    ) private returns (uint256 totalPaidCoin) {
        uint256 coinDistributed;
        for (uint8 traitIdx; traitIdx < 4; ) {
            uint16 shareBps = uint16(traitShareBpsPacked >> (traitIdx * 16));
            uint256 share = _sliceJackpotShare(coinPool, shareBps, traitIdx, coinDistributed);
            uint8 traitId = winningTraits[traitIdx];
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

        uint256 perWinner = traitShare / totalCount;
        if (perWinner == 0) return (nextEntropy, trophyGivenOut, 0, 0);

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
        if (len > requested) len = requested;

        bool needTrophy = mapTrophy && traitIdx == 0 && !trophyGivenOut;
        for (uint8 i; i < len; ) {
            address w = winners[i];
            if (_eligibleJackpotWinner(w, lvl)) {
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
                        trophiesContract.awardTrophy{value: deferred}(
                            w,
                            lvl,
                            PURGE_TROPHY_KIND_MAP,
                            trophyData,
                            deferred
                        );
                        ethDelta += deferred;
                    }
                } else if (_creditJackpot(coinContract, payCoin, w, perWinner)) {
                    if (payCoin) coinDelta += perWinner;
                    else ethDelta += perWinner;
                }
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

    function _creditJackpot(
        IPurgeCoinModule coinContract,
        bool payInCoin,
        address beneficiary,
        uint256 amount
    ) private returns (bool) {
        if (beneficiary == address(0) || amount == 0) return false;
        if (payInCoin) {
            coinContract.bonusCoinflip(beneficiary, amount, true, 0);
        } else {
            _addClaimableEth(beneficiary, amount);
        }
        return true;
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

    function _eligibleJackpotWinner(address player, uint24 lvl) private view returns (bool) {
        if (player == address(0)) return false;
        uint256 packed = mintPacked_[player];
        uint24 lastEthLevel = uint24((packed >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
        return (lastEthLevel + 2) >= lvl;
    }
}

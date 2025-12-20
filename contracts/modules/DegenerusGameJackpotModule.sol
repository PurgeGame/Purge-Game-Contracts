// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "../interfaces/DegenerusGameModuleInterfaces.sol";
import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";
import {DegenerusTraitUtils} from "../DegenerusTraitUtils.sol";

interface IStETHView {
    function balanceOf(address account) external view returns (uint256);
}

interface IDegenerusBondsJackpot {
    function purchasesEnabled() external view returns (bool);
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded);
    function depositFromGame(address beneficiary, uint256 amount) external payable returns (uint256 scoreAwarded);
}

/**
 * @title DegenerusGameJackpotModule
 * @notice Delegate-called module that hosts the jackpot distribution logic for `DegenerusGame`.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 *         Acts as the single routing layer for jackpot math: pool sizing, trait splits, coin vs ETH
 *         routing, and credit flow all originate here so auditors can focus on one surface.
 */
contract DegenerusGameJackpotModule is DegenerusGameStorage {
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);

    uint48 private constant JACKPOT_RESET_TIME = 82620;
    uint8 private constant JACKPOT_LEVEL_CAP = 10;
    uint8 private constant EARLY_BURN_COIN_ONLY_THRESHOLD = 50;
    uint8 private constant EARLY_BURN_BOOST_THRESHOLD = 60;
    uint256 private constant DEGENERATE_ENTROPY_CHECK_VALUE = 420;
    uint64 private constant MAP_JACKPOT_SHARES_PACKED =
        (uint64(6000)) | (uint64(1333) << 16) | (uint64(1333) << 32) | (uint64(1334) << 48);
    uint64 private constant DAILY_JACKPOT_SHARES_PACKED = uint64(2000) * 0x0001000100010001;
    bytes32 private constant COIN_JACKPOT_TAG = keccak256("coin-jackpot");
    bytes32 private constant CARRYOVER_BONUS_TAG = keccak256("carryover_bonus");
    bytes32 private constant CARRYOVER_3D4_SALT = keccak256("carryover-3d4");
    // Sums to 9156 bps (~91.56% of the post-MAP pool across 10 jackpots), roughly 2x growth from first to last.
    uint16 private constant DAILY_JACKPOT_BPS_0 = 610;
    uint16 private constant DAILY_JACKPOT_BPS_1 = 677;
    uint16 private constant DAILY_JACKPOT_BPS_2 = 746;
    uint16 private constant DAILY_JACKPOT_BPS_3 = 813;
    uint16 private constant DAILY_JACKPOT_BPS_4 = 881;
    uint16 private constant DAILY_JACKPOT_BPS_5 = 949;
    uint16 private constant DAILY_JACKPOT_BPS_6 = 1017;
    uint16 private constant DAILY_JACKPOT_BPS_7 = 1085;
    uint16 private constant DAILY_JACKPOT_BPS_8 = 1153;
    uint16 private constant DAILY_JACKPOT_BPS_9 = 1225;
    uint32 private constant WRITES_BUDGET_SAFE = 780;
    uint64 private constant MAP_LCG_MULT = 0x5851F42D4C957F2D;
    uint16 private constant JACKPOT_BOND_BPS_GRAND = 5000; // 50% skim for the top bucket
    uint16 private constant JACKPOT_BOND_BPS_OTHER = 1000; // 10% skim for other buckets
    uint256 private constant JACKPOT_BOND_MIN_BASE = 0.02 ether;
    uint16 private constant BOND_BPS_DAILY = 0; // bond buys from reward/early-burn daily jackpots disabled for now
    uint16 private constant MAIN_LARGE_BUCKET_SIZE = 25;
    uint16 private constant MAIN_LARGE_BUCKET_BOND_WINNERS = 12;
    uint16 private constant MAP_SOLO_BOND_BPS = 2500; // 25% bond buy for solo MAP winner
    uint16 private constant DAILY_SOLO_BOND_BPS = 5000; // 50% bond buy for solo daily winner
    uint32 private constant WRITES_BUDGET_MIN = 8; // Clamps low caps so we always clear base overhead and make progress

    struct JackpotEthCtx {
        uint256 ethDistributed;
        uint256 entropyState;
        uint256 liabilityDelta;
        uint256 totalPaidEth;
    }

    // Packed parameters for a single jackpot run to keep the call surface lean.
    struct JackpotParams {
        uint24 lvl;
        uint256 ethPool;
        uint256 coinPool;
        uint256 entropy;
        uint32 winningTraitsPacked;
        uint64 traitShareBpsPacked;
        IDegenerusCoinModule coinContract;
    }

    /// @notice Pays early-burn jackpots during purchase phase or the rolling daily jackpots at end of level.
    /// @dev Manages boost arming/consumption, coin-only fallback at max early-burn %, and quest rolls.
    function payDailyJackpot(bool isDaily, uint24 lvl, uint256 randWord, IDegenerusCoinModule coinContract) external {
        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        uint32 winningTraitsPacked;

        if (isDaily) {
            winningTraitsPacked = _packWinningTraits(_getWinningTraits(randWord, dailyBurnCount));
            bool lastDaily = (jackpotCounter + 1) >= JACKPOT_LEVEL_CAP;
            uint256 budget = (dailyJackpotBase * _dailyJackpotBps(jackpotCounter)) / 10_000;

            uint256 paidDailyEth = _runMainJackpotEthFlow(
                JackpotParams({
                    lvl: lvl,
                    ethPool: budget,
                    coinPool: 0,
                    entropy: randWord ^ (uint256(lvl) << 192),
                    winningTraitsPacked: winningTraitsPacked,
                    traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                    coinContract: coinContract
                }),
                DAILY_SOLO_BOND_BPS,
                MAIN_LARGE_BUCKET_SIZE,
                MAIN_LARGE_BUCKET_BOND_WINNERS
            );
            if (paidDailyEth != 0) {
                currentPrizePool -= paidDailyEth;
            }

            uint24 nextLevel = lvl + 1;
            uint256 futureEthPool;
            uint256 rewardSlice;

            // On the last daily, push all leftover prize pool plus the standard 1% reward slice to the next level.
            if (lastDaily) {
                uint256 leftoverPool = currentPrizePool;
                currentPrizePool = 0;
                uint256 futurePoolBps = 100; // 1% reward pool contribution
                rewardSlice = (rewardPool * futurePoolBps * _rewardJackpotScaleBps(nextLevel)) / 100_000_000;
                rewardPool -= rewardSlice;
                futureEthPool = rewardSlice + leftoverPool;
            } else {
                uint256 futurePoolBps = jackpotCounter == 0 ? 300 : 100; // 3% on first burn, else 1%
                if (jackpotCounter == 1) {
                    futurePoolBps += 100; // +1% boost on the second daily jackpot
                }
                futureEthPool = (rewardPool * futurePoolBps * _rewardJackpotScaleBps(nextLevel)) / 100_000_000;
            }

            _executeJackpot(
                JackpotParams({
                    lvl: nextLevel,
                    ethPool: futureEthPool,
                    coinPool: priceCoin * 10,
                    // Reuse the same entropy slice so the carryover jackpot shares traits/offsets with the level payout.
                    entropy: randWord ^ (uint256(nextLevel) << 192),
                    winningTraitsPacked: winningTraitsPacked,
                    traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                    coinContract: coinContract
                }),
                false,
                !lastDaily, // lastDaily reward slice already debited; carryover is prize pool
                BOND_BPS_DAILY
            );

            unchecked {
                ++jackpotCounter;
            }
            if (jackpotCounter < JACKPOT_LEVEL_CAP) {
                _clearDailyBurnCount();
            }

            _rollQuestForJackpot(coinContract, randWord, false, questDay);
            return;
        }

        // Non-daily (early-burn) path.
        uint8 percentBefore = earlyBurnPercent;
        bool boostArmedBefore = earlyBurnBoostArmed;
        uint8 percentAfter = _currentEarlyBurnPercent();
        if (percentAfter != percentBefore) {
            earlyBurnPercent = percentAfter;
            if (
                !boostArmedBefore &&
                percentBefore < EARLY_BURN_BOOST_THRESHOLD &&
                percentAfter >= EARLY_BURN_BOOST_THRESHOLD
            ) {
                earlyBurnBoostArmed = true; // arm boost for the next jackpot instead of the current one
            }
        }

        bool boostTrigger = boostArmedBefore;
        if (boostTrigger) {
            earlyBurnBoostArmed = false; // consume the armed boost
        }

        bool coinOnly = !boostTrigger && percentAfter >= EARLY_BURN_COIN_ONLY_THRESHOLD;

        winningTraitsPacked = _packWinningTraits(_getRandomTraits(randWord));

        uint256 rewardPoolSlice;
        if (!coinOnly) {
            uint256 poolBps = boostTrigger ? 200 : 50; // default 0.5%, boosted 2% when armed
            rewardPoolSlice = (rewardPool * poolBps) / 10_000;
            rewardPoolSlice = (rewardPoolSlice * _rewardJackpotScaleBps(lvl)) / 10_000;
        }

        uint256 ethPool = rewardPoolSlice;
        uint256 paidEth = _executeJackpot(
            JackpotParams({
                lvl: lvl,
                ethPool: ethPool,
                coinPool: priceCoin * 10,
                entropy: randWord ^ (uint256(lvl) << 192),
                winningTraitsPacked: winningTraitsPacked,
                traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                coinContract: coinContract
            }),
            false,
            false,
            BOND_BPS_DAILY
        );

        // Only the reward pool-funded slice should reduce reward pool accounting.
        rewardPool -= paidEth;
        _rollQuestForJackpot(coinContract, randWord, false, questDay);
    }

    /// @notice Pays a trait-restricted jackpot during extermination using daily jackpot sizing.
    /// @dev Uses daily jackpot share/bucket math but only draws tickets from the winning trait.
    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        uint256 ethPool,
        IDegenerusCoinModule coinContract
    ) external returns (uint256 paidEth) {
        uint32 packedTrait = uint32(traitId);
        packedTrait |= uint32(traitId) << 8;
        packedTrait |= uint32(traitId) << 16;
        packedTrait |= uint32(traitId) << 24;

        paidEth = _executeJackpot(
            JackpotParams({
                lvl: lvl,
                ethPool: ethPool,
                coinPool: 0,
                entropy: randWord ^ (uint256(lvl) << 192),
                winningTraitsPacked: packedTrait,
                traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                coinContract: coinContract
            }),
            false,
            false,
            BOND_BPS_DAILY
        );
    }

    /// @notice Pays a post-extermination carryover jackpot using the exterminated trait and the next level's tickets.
    /// @dev Funded from `rewardPool` (1% scaled) and distributed using daily jackpot share/bucket sizing.
    function payCarryoverExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        IDegenerusCoinModule coinContract
    ) external returns (uint256 paidEth) {
        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        uint256 ethPool = (rewardPool * 100 * _rewardJackpotScaleBps(lvl)) / 100_000_000;

        if (ethPool != 0) {
            uint32 packedTrait = uint32(traitId);
            packedTrait |= uint32(traitId) << 8;
            packedTrait |= uint32(traitId) << 16;
            packedTrait |= uint32(traitId) << 24;

            paidEth = _executeJackpot(
                JackpotParams({
                    lvl: lvl,
                    ethPool: ethPool,
                    coinPool: 0,
                    entropy: randWord ^ (uint256(lvl) << 192),
                    winningTraitsPacked: packedTrait,
                    traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                    coinContract: coinContract
                }),
                false,
                false,
                BOND_BPS_DAILY
            );

            if (paidEth != 0) {
                rewardPool -= paidEth;
            }
        }

        _rollQuestForJackpot(coinContract, randWord, false, questDay);
    }

    /// @notice Pays the MAP jackpot slice (trophies removed).
    function payMapJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IDegenerusCoinModule coinContract
    ) external {
        uint8[4] memory winningTraits = _getRandomTraits(rngWord);
        uint32 winningTraitsPacked = _packWinningTraits(winningTraits);
        uint256 paidEth = _runMainJackpotEthFlow(
            JackpotParams({
                lvl: lvl,
                ethPool: effectiveWei,
                coinPool: 0,
                entropy: rngWord,
                winningTraitsPacked: winningTraitsPacked,
                traitShareBpsPacked: MAP_JACKPOT_SHARES_PACKED,
                coinContract: coinContract
            }),
            MAP_SOLO_BOND_BPS,
            MAIN_LARGE_BUCKET_SIZE,
            MAIN_LARGE_BUCKET_BOND_WINNERS
        );
        currentPrizePool += (effectiveWei - paidEth);

        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        _rollQuestForJackpot(coinContract, rngWord, true, questDay);
    }

    /// @notice Computes prize pool splits for the next jackpot.
    function calcPrizePoolForJackpot(
        uint24 lvl,
        uint256 rngWord,
        address stethAddr
    ) external returns (uint256 effectiveWei) {
        currentPrizePool += nextPrizePool;
        nextPrizePool = 0;

        uint256 totalWei = rewardPool + currentPrizePool;
        uint256 mapPct;
        uint256 mapWei;
        uint256 mainWei;

        (uint256 savePctTimes2, uint256 level100RollTotal) = _mapRewardPoolPercent(lvl, rngWord);
        uint256 _rewardPool = (totalWei * savePctTimes2) / 200;
        rewardPool = _rewardPool;

        uint256 jackpotBase = totalWei - _rewardPool;
        mapPct = _mapJackpotPercent(lvl, rngWord);
        mapWei = (jackpotBase * mapPct) / 100;

        unchecked {
            mainWei = jackpotBase - mapWei;
        }

        lastPrizePool = currentPrizePool;
        currentPrizePool = mainWei;
        dailyJackpotBase = mainWei;

        effectiveWei = mapWei;

        if ((lvl % 100) == 0) {
            uint256 stBal = IStETHView(stethAddr).balanceOf(address(this));
            uint256 totalBal = address(this).balance + stBal;
            uint256 obligations = currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool;
            uint256 bafPool = bafHundredPool;
            if (bafPool != 0) {
                unchecked {
                    obligations += bafPool;
                }
            }
            if (totalBal > obligations && level100RollTotal < 5) {
                uint256 yieldPool = totalBal - obligations;
                uint256 bonus = yieldPool / 2;
                rewardPool += bonus;
            }
        }
    }

    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
        address recipient = beneficiary;
        claimableWinnings[recipient] += weiAmount;
        emit PlayerCredited(beneficiary, recipient, weiAmount);
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

    function _mapRewardPoolPercent(
        uint24 lvl,
        uint256 rngWord
    ) private pure returns (uint256 pctTimes2, uint256 level100Roll) {
        if ((lvl % 100) == 0) {
            level100Roll = _roll3d11(rngWord); // 0-30
            return (level100Roll * 2, level100Roll); // returned as times two
        }
        if ((rngWord % 1_000_000_000) == DEGENERATE_ENTROPY_CHECK_VALUE) {
            return (20, 0); // 10% fallback when trait entropy is degenerate (returned as times two).
        }
        if (lvl >= 80 && lvl <= 98) {
            uint256 base = 75 + (uint256(lvl) - 80) + ((lvl % 10 == 9) ? 5 : 0);
            uint256 pct = base + _rollSum(rngWord, CARRYOVER_3D4_SALT, 4, 3);
            return (_clampPctTimes2(pct), 0);
        }
        if (lvl == 99) {
            return (196, 0); // Hard cap at 98% for the pre-finale level (times two).
        }

        uint256 baseTimes2;
        if (lvl <= 4) {
            uint256 increments = lvl > 0 ? uint256(lvl) - 1 : 0;
            baseTimes2 = (8 + increments * 8) * 2;
        } else if (lvl <= 79) {
            baseTimes2 = 64 + (uint256(lvl) - 4);
        } else {
            baseTimes2 = _legacyRewardPoolTimes2(lvl, rngWord);
        }

        baseTimes2 += _rewardPoolBonus(rngWord) * 2;
        if (baseTimes2 > 196) {
            baseTimes2 = 196;
        }

        uint256 jackpotPctTimes2 = 200 - baseTimes2;
        if (jackpotPctTimes2 < 34 && jackpotPctTimes2 != 60) {
            baseTimes2 = 166;
        }
        return (baseTimes2, 0);
    }

    function _roll3d11(uint256 rngWord) private pure returns (uint256 total) {
        total = (rngWord % 11);
        total += ((rngWord >> 16) % 11);
        total += ((rngWord >> 32) % 11);
    }

    function _rewardPoolBonus(uint256 rngWord) private pure returns (uint256) {
        uint256 seed = uint256(keccak256(abi.encodePacked(rngWord, CARRYOVER_BONUS_TAG)));
        uint256 d4a = (seed & 0xF) % 4;
        uint256 d4b = ((seed >> 8) & 0xF) % 4;
        uint256 d14 = ((seed >> 16) & 0xFF) % 14;
        return d4a + d4b + d14 + 3;
    }

    function _legacyRewardPoolTimes2(uint24 lvl, uint256 rngWord) private pure returns (uint256) {
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

    function _mapJackpotPercent(uint24 lvl, uint256 rngWord) private pure returns (uint256) {
        if (lvl % 20 == 16) return 40; // keep the big MAP levels fixed
        return 20 + (rngWord % 21); // 20-40% otherwise
    }

    function _dailyJackpotBps(uint8 idx) private pure returns (uint16) {
        if (idx == 0) return DAILY_JACKPOT_BPS_0;
        if (idx == 1) return DAILY_JACKPOT_BPS_1;
        if (idx == 2) return DAILY_JACKPOT_BPS_2;
        if (idx == 3) return DAILY_JACKPOT_BPS_3;
        if (idx == 4) return DAILY_JACKPOT_BPS_4;
        if (idx == 5) return DAILY_JACKPOT_BPS_5;
        if (idx == 6) return DAILY_JACKPOT_BPS_6;
        if (idx == 7) return DAILY_JACKPOT_BPS_7;
        if (idx == 8) return DAILY_JACKPOT_BPS_8;
        return DAILY_JACKPOT_BPS_9;
    }

    function _executeJackpot(
        JackpotParams memory jp,
        bool fromPrizePool,
        bool fromRewardPool,
        uint16 bondBps
    ) private returns (uint256 paidEth) {
        // Runs jackpot and debits caller-selected pools; returns ETH paid for accounting.
        uint8[4] memory traitIds = _unpackWinningTraits(jp.winningTraitsPacked);
        uint16[4] memory shareBps = _shareBpsByBucket(jp.traitShareBpsPacked, uint8(jp.entropy & 3));

        if (jp.ethPool != 0) {
            paidEth = _runJackpotEthFlow(jp, traitIds, shareBps, bondBps);
        }

        if (jp.coinPool != 0) {
            _runJackpotCoinFlow(jp, traitIds, shareBps);
        }

        if (fromPrizePool) {
            currentPrizePool -= paidEth;
        }
        if (fromRewardPool) {
            rewardPool -= paidEth;
        }
    }

    function _runJackpotEthFlow(
        JackpotParams memory jp,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16 bondBps
    ) private returns (uint256 totalPaidEth) {
        uint8 band = uint8((jp.lvl % 100) / 20) + 1;
        uint16[4] memory bucketCounts = _traitBucketCounts(band, jp.entropy);
        address bondsAddr = bonds;
        return
            _distributeJackpotEth(
                jp.lvl,
                jp.ethPool,
                jp.entropy,
                traitIds,
                shareBps,
                bucketCounts,
                jp.coinContract,
                bondsAddr,
                bondBps
            );
    }

    function _runMainJackpotEthFlow(
        JackpotParams memory jp,
        uint16 soloBondBps,
        uint16 largeBucketSize,
        uint16 largeBucketBondWinners
    ) private returns (uint256 totalPaidEth) {
        uint8[4] memory traitIds = _unpackWinningTraits(jp.winningTraitsPacked);
        uint16[4] memory shareBps = _shareBpsByBucket(jp.traitShareBpsPacked, uint8(jp.entropy & 3));
        uint8 band = uint8((jp.lvl % 100) / 20) + 1;
        uint16[4] memory bucketCounts = _traitBucketCounts(band, jp.entropy);
        uint16 largeBucketCount;
        if (largeBucketSize != 0) {
            largeBucketCount = uint16(uint256(largeBucketSize) * band);
        }
        address bondsAddr = bonds;

        JackpotEthCtx memory ctx;
        ctx.entropyState = jp.entropy;

        for (uint8 traitIdx; traitIdx < 4; ) {
            uint256 share = _bucketShare(jp.ethPool, shareBps[traitIdx], traitIdx, ctx.ethDistributed);
            if (traitIdx < 3) {
                unchecked {
                    ctx.ethDistributed += share;
                }
            }

            uint16 bucketCount = bucketCounts[traitIdx];
            uint16 bucketBondBps;
            uint16 bondWinnerCount;

            if (bucketCount == 1) {
                bucketBondBps = soloBondBps;
            } else if (bucketCount == largeBucketCount && largeBucketSize != 0 && largeBucketBondWinners != 0) {
                bondWinnerCount = (bucketCount * largeBucketBondWinners) / largeBucketSize;
            }

            (uint256 newEntropyState, uint256 ethDelta, , uint256 bondSpent, uint256 bucketLiability) =
                _resolveTraitWinners(
                    jp.coinContract,
                    false,
                    jp.lvl,
                    traitIds[traitIdx],
                    traitIdx,
                    share,
                    ctx.entropyState,
                    bucketCount,
                    bondsAddr,
                    bucketBondBps,
                    bondWinnerCount
                );
            ctx.entropyState = newEntropyState;
            ctx.totalPaidEth += ethDelta + bondSpent;
            ctx.liabilityDelta += bucketLiability;
            unchecked {
                ++traitIdx;
            }
        }

        if (ctx.liabilityDelta != 0) {
            unchecked {
                claimablePool += ctx.liabilityDelta;
            }
        }

        return ctx.totalPaidEth;
    }

    function _runJackpotCoinFlow(JackpotParams memory jp, uint8[4] memory traitIds, uint16[4] memory shareBps) private {
        // Do not scale coin jackpots by level; use base bucket counts.
        uint16[4] memory bucketCounts = _traitBucketCounts(1, jp.entropy);
        _distributeJackpotCoin(
            jp.lvl,
            jp.coinPool,
            jp.entropy ^ uint256(COIN_JACKPOT_TAG),
            traitIds,
            shareBps,
            bucketCounts,
            jp.coinContract
        );
    }

    function _distributeJackpotEth(
        uint24 lvl,
        uint256 ethPool,
        uint256 entropy,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16[4] memory bucketCounts,
        IDegenerusCoinModule coinContract,
        address bondsAddr,
        uint16 bondBps
    ) private returns (uint256 totalPaidEth) {
        // Each trait bucket gets a slice; the last bucket absorbs remainder to avoid dust. totalPaidEth counts ETH plus bond spend.
        JackpotEthCtx memory ctx;
        ctx.entropyState = entropy;

        for (uint8 traitIdx; traitIdx < 4; ) {
            uint256 share = _bucketShare(ethPool, shareBps[traitIdx], traitIdx, ctx.ethDistributed);
            if (traitIdx < 3) {
                unchecked {
                    ctx.ethDistributed += share;
                }
            }
            uint16 bucketBondBps = bondBps;
            {
                (uint256 newEntropyState, uint256 ethDelta, , uint256 bondSpent, uint256 bucketLiability) =
                    _resolveTraitWinners(
                        coinContract,
                        false,
                        lvl,
                        traitIds[traitIdx],
                        traitIdx,
                        share,
                        ctx.entropyState,
                        bucketCounts[traitIdx],
                        bondsAddr,
                        bucketBondBps,
                        0
                );
                ctx.entropyState = newEntropyState;
                ctx.totalPaidEth += ethDelta + bondSpent;
                ctx.liabilityDelta += bucketLiability;
            }
            unchecked {
                ++traitIdx;
            }
        }

        if (ctx.liabilityDelta != 0) {
            unchecked {
                claimablePool += ctx.liabilityDelta;
            }
        }

        return ctx.totalPaidEth;
    }

    function _distributeJackpotCoin(
        uint24 lvl,
        uint256 coinPool,
        uint256 entropy,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16[4] memory bucketCounts,
        IDegenerusCoinModule coinContract
    ) private {
        uint256 coinDistributed;
        for (uint8 traitIdx; traitIdx < 4; ) {
            uint256 share = _bucketShare(coinPool, shareBps[traitIdx], traitIdx, coinDistributed);
            uint8 traitId = traitIds[traitIdx];
            uint16 bucketCount = bucketCounts[traitIdx];
            if (traitIdx < 3) {
                unchecked {
                    coinDistributed += share;
                }
            }
            (entropy, , , , ) = _resolveTraitWinners(
                coinContract,
                true,
                lvl,
                traitId,
                traitIdx,
                share,
                entropy,
                bucketCount,
                address(0),
                0,
                0
            );
            unchecked {
                ++traitIdx;
            }
        }
    }

    function _rotatedShareBps(uint64 packed, uint8 offset, uint8 traitIdx) private pure returns (uint16) {
        uint8 baseIndex = uint8((uint256(traitIdx) + uint256(offset) + 1) & 3);
        return uint16(packed >> (baseIndex * 16));
    }

    function _bucketShare(
        uint256 pool,
        uint16 shareBps,
        uint8 traitIdx,
        uint256 distributed
    ) private pure returns (uint256 slice) {
        if (traitIdx == 3) return pool - distributed;
        slice = (pool * shareBps) / 10_000;
    }

    /// @dev Resolves winners for a single trait bucket (trophies removed).
    function _resolveTraitWinners(
        IDegenerusCoinModule coinContract,
        bool payCoin,
        uint24 lvl,
        uint8 traitId,
        uint8 traitIdx,
        uint256 traitShare,
        uint256 entropy,
        uint16 winnerCount,
        address bondsAddr,
        uint16 bondBps,
        uint16 bondWinnerCount
    )
        private
        returns (uint256 entropyState, uint256 ethDelta, uint256 coinDelta, uint256 bondSpent, uint256 liabilityDelta)
    {
        entropyState = entropy;

        if (traitShare == 0) return (entropyState, 0, 0, 0, 0);

        uint16 totalCount = winnerCount;
        if (totalCount == 0) return (entropyState, 0, 0, 0, 0);

        entropyState = _entropyStep(entropyState ^ (uint256(traitIdx) << 64) ^ traitShare);
        address[] memory winners = _randTraitTicket(
            traitBurnTicket[lvl],
            entropyState,
            traitId,
            uint8(totalCount),
            uint8(200 + traitIdx)
        );
        if (winners.length == 0) return (entropyState, 0, 0, 0, 0);

        uint256 perWinner = traitShare / totalCount;
        if (perWinner == 0) return (entropyState, 0, 0, bondSpent, liabilityDelta);

        bool bondsEnabled;
        if (!payCoin && (bondBps != 0 || bondWinnerCount != 0)) {
            bondsEnabled = IDegenerusBondsJackpot(bondsAddr).purchasesEnabled();
        }

        if (!payCoin && bondBps != 0 && bondsEnabled && totalCount == 1) {
            address winner = winners[0];
            if (winner == address(0)) return (entropyState, 0, 0, 0, 0);
            (uint256 soloEthPaid, uint256 soloBondSpent, uint256 soloLiability) =
                _splitSoloBondPayout(winner, perWinner, bondBps, bondsAddr);
            return (entropyState, soloEthPaid, 0, soloBondSpent, soloLiability);
        }

        if (!payCoin && bondWinnerCount != 0 && bondsEnabled) {
            uint256 burnLiability;
            (bondSpent, burnLiability) = _jackpotBondSpendCount(
                bondsAddr,
                winners,
                perWinner,
                entropyState,
                bondWinnerCount
            );
            liabilityDelta += burnLiability;
        } else if (!payCoin && bondBps != 0 && bondsEnabled) {
            uint256 burnLiability;
            (bondSpent, burnLiability) = _jackpotBondSpend(
                bondsAddr,
                winners,
                perWinner,
                traitShare,
                entropyState,
                bondBps
            );
            liabilityDelta += burnLiability;
        }

        uint256 len = winners.length;
        if (payCoin) {
            for (uint256 i; i < len; ) {
                if (_creditJackpot(coinContract, true, winners[i], perWinner)) {
                    coinDelta += perWinner;
                }

                unchecked {
                    ++i;
                }
            }
            return (entropyState, 0, coinDelta, bondSpent, liabilityDelta);
        }

        uint256 totalPayout;
        for (uint256 i; i < len; ) {
            address w = winners[i];
            if (w != address(0)) {
                _addClaimableEth(w, perWinner);
                totalPayout += perWinner;
            }
            unchecked {
                ++i;
            }
        }
        if (totalPayout == 0) return (entropyState, 0, 0, bondSpent, liabilityDelta);

        liabilityDelta += totalPayout;
        ethDelta = totalPayout;

        return (entropyState, ethDelta, 0, bondSpent, liabilityDelta);
    }

    function _splitSoloBondPayout(
        address winner,
        uint256 amount,
        uint16 bondBps,
        address bondsAddr
    ) private returns (uint256 ethPaid, uint256 bondSpent, uint256 liabilityDelta) {
        uint256 bondBudget = (amount * bondBps) / 10_000;
        uint256 cashPortion = amount;

        if (bondBudget != 0) {
            try IDegenerusBondsJackpot(bondsAddr).depositFromGame{value: bondBudget}(winner, bondBudget) {
                cashPortion = amount - bondBudget;
                bondSpent = bondBudget;
            } catch {}
        }

        if (cashPortion != 0) {
            _addClaimableEth(winner, cashPortion);
            liabilityDelta += cashPortion;
        }

        ethPaid = liabilityDelta;
    }

    function _jackpotBondSpend(
        address bondsAddr,
        address[] memory winners,
        uint256 perWinner,
        uint256 traitShare,
        uint256 entropyState,
        uint16 bondBps
    ) private returns (uint256 bondSpent, uint256 liabilityDelta) {
        uint256 winnersLen = winners.length;

        // Immediately spend the bond skim on live bond purchases for the drawn winners.
        uint256 bondBudget = (traitShare * bondBps) / 10_000;
        if (bondBudget < perWinner) return (0, 0);

        uint256 targetBondWinners = bondBudget / perWinner;
        if (targetBondWinners > winnersLen) {
            targetBondWinners = winnersLen;
        }

        return _jackpotBondSpendCount(
            bondsAddr,
            winners,
            perWinner,
            entropyState,
            uint16(targetBondWinners)
        );
    }

    function _jackpotBondSpendCount(
        address bondsAddr,
        address[] memory winners,
        uint256 perWinner,
        uint256 entropyState,
        uint16 targetBondWinners
    ) private returns (uint256 bondSpent, uint256 liabilityDelta) {
        uint256 winnersLen = winners.length;
        if (targetBondWinners == 0 || winnersLen == 0) return (0, 0);
        if (targetBondWinners > winnersLen) {
            targetBondWinners = uint16(winnersLen);
        }

        IDegenerusBondsJackpot bondsContract = IDegenerusBondsJackpot(bondsAddr);
        uint16 offset = uint16(entropyState % winnersLen);

        for (uint256 i; i < targetBondWinners; ) {
            address recipient = winners[(uint256(offset) + i) % winnersLen];
            if (recipient == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }
            bool spent;
            try bondsContract.depositFromGame{value: perWinner}(recipient, perWinner) {
                spent = true;
            } catch {
                spent = false;
            }

            if (spent) {
                winners[(uint256(offset) + i) % winnersLen] = address(0);
                bondSpent += perWinner;
            }
            unchecked {
                ++i;
            }
        }

        return (bondSpent, liabilityDelta);
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
        IDegenerusCoinModule coinContract,
        uint256 entropySource,
        bool forceMintEthAndDegenerus,
        uint48 questDay
    ) private {
        if (forceMintEthAndDegenerus) {
            coinContract.rollDailyQuestWithOverrides(questDay, entropySource, true, true);
        } else {
            coinContract.rollDailyQuest(questDay, entropySource);
        }
    }

    function _creditJackpot(
        IDegenerusCoinModule coinContract,
        bool payInCoin,
        address beneficiary,
        uint256 amount
    ) private returns (bool) {
        if (beneficiary == address(0) || amount == 0) return false;
        if (payInCoin) {
            coinContract.creditFlip(beneficiary, amount);
        } else {
            // Liability is tracked by the caller to avoid per-winner SSTORE cost.
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

    function _rewardJackpotScaleBps(uint24 lvl) private pure returns (uint16) {
        // Linearly scale reward pool-funded jackpot slices from 100% at the start of a 100-level band
        // down to 50% on the last level of the band, then reset on the next band.
        uint256 cycle = (lvl == 0) ? 0 : ((uint256(lvl) - 1) % 100); // 0..99
        uint256 discount = (cycle * 5000) / 99; // up to 50% at cycle==99
        uint256 scale = 10_000 - discount;
        if (scale < 5000) scale = 5000;
        return uint16(scale);
    }

    /// @notice Process a batch of map mints using a caller-provided writes budget (0 = auto).
    /// @param writesBudget Count of SSTORE writes allowed this tx; hard-clamped to stay ≤15M-safe.
    /// @return finished True if all pending map mints have been fully processed.
    function processMapBatch(uint32 writesBudget) external returns (bool finished) {
        uint256 idx = airdropIndex;
        uint256 total = pendingMapMints.length;
        if (idx >= total) return true;
        uint32 processed = airdropMapsProcessedCount;

        if (writesBudget == 0) {
            writesBudget = WRITES_BUDGET_SAFE;
        } else if (writesBudget < WRITES_BUDGET_MIN) {
            writesBudget = WRITES_BUDGET_MIN;
        }
        uint24 lvl = level;
        if (gameState == 3) {
            unchecked {
                ++lvl;
            }
        }

        bool firstAirdropBatch = (idx == 0 && processed == 0);
        if (firstAirdropBatch) {
            writesBudget -= (writesBudget * 35) / 100; // 65% scaling
        }

        uint32 used = 0;
        uint256 entropy = rngWordCurrent;

        while (idx < total && used < writesBudget) {
            address player = pendingMapMints[idx];
            uint32 owed = playerMapMintsOwed[player];
            if (owed == 0) {
                unchecked {
                    ++idx;
                }
                processed = 0;
                continue;
            }

            uint32 room = writesBudget - used;

            uint32 baseOv = 2;
            if (processed == 0 && owed <= 2) {
                baseOv += 2;
            }
            if (room <= baseOv) break;
            room -= baseOv;

            uint32 maxT = (room <= 256) ? (room / 2) : (room - 256);
            uint32 take = owed > maxT ? maxT : owed;
            if (take == 0) break;

            uint256 baseKey = (uint256(lvl) << 224) | (idx << 192) | (uint256(uint160(player)) << 32);
            _raritySymbolBatch(player, baseKey, processed, take, entropy);

            uint32 writesThis = (take <= 256) ? (take * 2) : (take + 256);
            writesThis += baseOv;
            if (take == owed) {
                writesThis += 1;
            }

            uint32 remainingOwed;
            unchecked {
                remainingOwed = owed - take;
                playerMapMintsOwed[player] = remainingOwed;
                processed += take;
                used += writesThis;
            }
            if (remainingOwed == 0) {
                unchecked {
                    ++idx;
                }
                processed = 0;
            }
        }
        airdropIndex = uint32(idx);
        airdropMapsProcessedCount = processed;
        return idx >= total;
    }

    function _raritySymbolBatch(
        address player,
        uint256 baseKey,
        uint32 startIndex,
        uint32 count,
        uint256 entropyWord
    ) private {
        uint32[256] memory counts;
        uint8[256] memory touchedTraits;
        uint16 touchedLen;

        uint32 endIndex;
        unchecked {
            endIndex = startIndex + count;
        }
        uint32 i = startIndex;

        while (i < endIndex) {
            uint32 groupIdx = i >> 4; // per 16 symbols

            uint256 seed;
            unchecked {
                seed = (baseKey + groupIdx) ^ entropyWord;
            }
            uint64 s = uint64(seed) | 1;
            uint8 offset = uint8(i & 15);
            unchecked {
                s = s * (MAP_LCG_MULT + uint64(offset)) + uint64(offset);
            }

            for (uint8 j = offset; j < 16 && i < endIndex; ) {
                unchecked {
                    s = s * MAP_LCG_MULT + 1;

                    uint8 traitId = DegenerusTraitUtils.traitFromWord(s) + (uint8(i & 3) << 6);

                    if (counts[traitId]++ == 0) {
                        touchedTraits[touchedLen++] = traitId;
                    }
                    ++i;
                    ++j;
                }
            }
        }

        uint24 lvl = uint24(baseKey >> 224); // level is encoded into the base key

        uint256 levelSlot;
        assembly ("memory-safe") {
            mstore(0x00, lvl)
            mstore(0x20, traitBurnTicket.slot)
            levelSlot := keccak256(0x00, 0x40)
        }

        for (uint16 u; u < touchedLen; ) {
            uint8 traitId = touchedTraits[u];
            uint32 occurrences = counts[traitId];

            assembly ("memory-safe") {
                let elem := add(levelSlot, traitId)
                let len := sload(elem)
                let newLen := add(len, occurrences)
                sstore(elem, newLen)

                mstore(0x00, elem)
                let data := keccak256(0x00, 0x20)
                let dst := add(data, len)
                for {
                    let k := 0
                } lt(k, occurrences) {
                    k := add(k, 1)
                } {
                    sstore(dst, player)
                    dst := add(dst, 1)
                }
            }
            unchecked {
                ++u;
            }
        }
    }

    function _clearDailyBurnCount() private {
        for (uint8 i; i < 80; ) {
            dailyBurnCount[i] = 0;
            unchecked {
                ++i;
            }
        }
    }

    function _randTraitTicket(
        address[][256] storage traitBurnTicket_,
        uint256 randomWord,
        uint8 trait,
        uint8 numWinners,
        uint8 salt
    ) private view returns (address[] memory winners) {
        address[] storage holders = traitBurnTicket_[trait];
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

    function _currentEarlyBurnPercent() private view returns (uint8) {
        uint256 prevPoolWei = lastPrizePool;
        if (prevPoolWei == 0) return 0;
        uint256 pct = ((currentPrizePool + nextPrizePool) * 100) / prevPoolWei;
        if (pct > type(uint8).max) return type(uint8).max;
        return uint8(pct);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    IPurgeCoinModule,
    IPurgeGameNFTModule,
    IPurgeGameTrophiesModule
} from "./PurgeGameModuleInterfaces.sol";

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
    uint8 private constant EP_THIRTY_MASK = 4;
    uint8 private constant PURGE_TROPHY_KIND_MAP = 0;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint64 private constant MAP_JACKPOT_SHARES_PACKED =
        (uint64(6000)) |
        (uint64(1333) << 16) |
        (uint64(1333) << 32) |
        (uint64(1334) << 48);
    uint64 private constant DAILY_JACKPOT_SHARES_PACKED =
        (uint64(2000)) |
        (uint64(2000) << 16) |
        (uint64(2000) << 32) |
        (uint64(2000) << 48);
    bytes32 private constant COIN_JACKPOT_TAG = keccak256("coin-jackpot");
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;

    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant MINT_MASK_20 = (uint256(1) << 20) - 1;
    uint256 private constant MINT_MASK_32 = (uint256(1) << 32) - 1;
    uint256 private constant ETH_LAST_LEVEL_SHIFT = 0;
    uint256 private constant ETH_LEVEL_COUNT_SHIFT = 24;
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;
    uint256 private constant ETH_DAY_SHIFT = 72;
    uint256 private constant ETH_DAY_STREAK_SHIFT = 104;
    uint256 private constant COIN_DAY_SHIFT = 124;
    uint256 private constant COIN_DAY_STREAK_SHIFT = 156;
    uint256 private constant AGG_DAY_SHIFT = 176;
    uint256 private constant AGG_DAY_STREAK_SHIFT = 208;

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
    uint8 private earlyPurgeJackpotPaidMask;
    uint8 private phase;
    uint16 private lastExterminatedTrait = TRAIT_ID_TIMEOUT;

    uint32 private airdropMapsProcessedCount;
    uint32 private airdropIndex;
    uint32 private traitRebuildCursor;
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

    struct DailyJackpotBonus {
        address dailyBest;
        uint24 dailyStreak;
        uint24 dailyEthStreak;
        address levelBest;
        uint24 levelStreak;
        uint24 levelDailyStreak;
        uint24 levelDailyEthStreak;
    }

    struct DailyJackpotContext {
        uint256 poolWei;
        uint256 coinPool;
        address biggestFlip;
        address thirdFlip;
        address fourthFlip;
        uint8 extraTrait;
        uint256 baseEthShare;
        uint256 extraEthShare;
        uint256 dailyBonusPool;
        uint256 levelBonusPool;
        uint256 baseCoinShare;
        uint256 extraCoinShare;
        uint8 band;
        uint256 entropyCursor;
        uint256 paidEth;
        uint256 paidCoin;
        DailyJackpotBonus bonus;
    }

    constructor() {}

    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord,
        IPurgeCoinModule coinContract,
        IPurgeGameNFTModule nftContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external {
        uint256 entropyWord = randWord;
        uint8[4] memory winningTraits;

        if (isDaily) {
            winningTraits = _getWinningTraits(entropyWord, dailyPurgeCount);
            _distributeDailyJackpot(lvl, entropyWord, winningTraits, coinContract, nftContract);
            return;
        }

        entropyWord = _scrambleJackpotEntropy(entropyWord, jackpotCounter);
        winningTraits = _getRandomTraits(entropyWord);

        uint256 baseWei = carryoverForNextLevel;
        uint256 poolWei;
        if ((lvl % 20) == 0) poolWei = baseWei / 100;
        else if (lvl >= 21 && (lvl % 10) == 1) poolWei = (baseWei * 6) / 100;
        else poolWei = baseWei / 40;

        (uint256 coinPool, address biggestFlip) = coinContract.prepareCoinJackpot();
        address[] memory topBettors = coinContract.getLeaderboardAddresses(2);
        address thirdFlip = topBettors.length > 2 ? topBettors[2] : address(0);
        address fourthFlip = topBettors.length > 3 ? topBettors[3] : address(0);

        (uint256 paidWei, , uint256 coinRemainder) = _runJackpot(
            JACKPOT_KIND_DAILY,
            lvl,
            poolWei,
            coinPool,
            false,
            entropyWord ^ (uint256(lvl) << 192),
            winningTraits,
            DAILY_JACKPOT_SHARES_PACKED,
            coinContract,
            trophiesContract,
            false
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

        uint48 currentDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        dailyIdx = currentDay;
        nftContract.releaseRngLock();

        unchecked {
            --jackpotCounter;
        }
        uint256 carry = carryoverForNextLevel;
        carryoverForNextLevel = paidWei > carry ? 0 : carry - paidWei;
    }

    function payMapJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IPurgeCoinModule coinContract,
        IPurgeGameNFTModule /*nftContract*/,
        IPurgeGameTrophiesModule trophiesContract
    ) external returns (bool finished) {
        uint8[4] memory winningTraits = _getRandomTraits(rngWord);
        (uint256 paidWei, , ) = _runJackpot(
            JACKPOT_KIND_MAP,
            lvl,
            effectiveWei,
            0,
            true,
            rngWord,
            winningTraits,
            MAP_JACKPOT_SHARES_PACKED,
            coinContract,
            trophiesContract,
            false
        );

        uint256 remainingPool = effectiveWei - paidWei;
        prizePool += remainingPool;
        levelPrizePool += remainingPool;

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

        uint256 savePct = _mapCarryoverPercent(lvl, rngWord);
        uint256 saveNextWei = (totalWei * savePct) / 100;
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

    function updateEarlyPurgeJackpots(uint24 lvl) external {
        if (lvl == 99) return;

        uint256 prevPoolWei = lastPrizePool;
        uint256 pctOfLast = (prizePool * 100) / prevPoolWei;

        uint8 targetMask = (pctOfLast >= 10 ? uint8(1) : 0) |
            (pctOfLast >= 20 ? uint8(2) : 0) |
            (pctOfLast >= 30 ? uint8(4) : 0) |
            (pctOfLast >= 40 ? uint8(8) : 0) |
            (pctOfLast >= 50 ? uint8(16) : 0) |
            (pctOfLast >= 75 ? uint8(32) : 0);

        uint8 paidMask = earlyPurgeJackpotPaidMask;
        earlyPurgeJackpotPaidMask = targetMask;

        if (lvl < 10) return;

        uint8 addMask = targetMask & ~paidMask;
        if (addMask == 0) return;

        uint8 newCountBits = addMask;
        unchecked {
            newCountBits = newCountBits - ((newCountBits >> 1) & 0x55);
            newCountBits = (newCountBits & 0x33) + ((newCountBits >> 2) & 0x33);
            newCountBits = (newCountBits + (newCountBits >> 4)) & 0x0F;
        }

        jackpotCounter += newCountBits;
    }

    function _distributeDailyJackpot(
        uint24 lvl,
        uint256 entropyWord,
        uint8[4] memory winningTraits,
        IPurgeCoinModule coinContract,
        IPurgeGameNFTModule nftContract
    ) private {
        DailyJackpotContext memory ctx;
        ctx.poolWei = (levelPrizePool * (450 + uint256(jackpotCounter) * 100)) / 10_000;
        (ctx.coinPool, ctx.biggestFlip) = coinContract.prepareCoinJackpot();
        address[] memory topBettors = coinContract.getLeaderboardAddresses(2);
        ctx.thirdFlip = topBettors.length > 2 ? topBettors[2] : address(0);
        ctx.fourthFlip = topBettors.length > 3 ? topBettors[3] : address(0);
        ctx.extraTrait = uint8(entropyWord & 3);
        ctx.baseEthShare = (ctx.poolWei * 20) / 100;
        ctx.extraEthShare = (ctx.poolWei * 10) / 100;
        ctx.dailyBonusPool = (ctx.poolWei * 5) / 100;
        ctx.levelBonusPool = (ctx.poolWei * 5) / 100;
        uint256 plannedEth = (ctx.baseEthShare * 4) + ctx.extraEthShare + ctx.dailyBonusPool + ctx.levelBonusPool;
        if (ctx.poolWei > plannedEth) {
            ctx.extraEthShare += ctx.poolWei - plannedEth;
        }
        ctx.baseCoinShare = (ctx.coinPool * 20) / 100;
        ctx.extraCoinShare = (ctx.coinPool * 10) / 100;
        ctx.band = uint8((lvl % 100) / 20) + 1;
        ctx.entropyCursor = entropyWord ^ (uint256(lvl) << 192);
        uint16[4] memory bucketCounts = _traitBucketCounts(ctx.band, entropyWord >> 32);

        for (uint8 traitIdx; traitIdx < 4; ) {
            uint256 ethDelta;
            uint256 coinDelta;
            (ctx.entropyCursor, ethDelta, coinDelta, ctx.bonus) = _accumulateDailyTrait(
                lvl,
                winningTraits[traitIdx],
                traitIdx,
                bucketCounts[traitIdx],
                _dailyTraitShare(ctx.baseEthShare, ctx.extraEthShare, traitIdx, ctx.extraTrait),
                _dailyTraitShare(ctx.baseCoinShare, ctx.extraCoinShare, traitIdx, ctx.extraTrait),
                ctx.entropyCursor,
                ctx.bonus,
                coinContract
            );
            ctx.paidEth += ethDelta;
            ctx.paidCoin += coinDelta;
            unchecked {
                ++traitIdx;
            }
        }

        if (ctx.dailyBonusPool != 0 && ctx.bonus.dailyBest != address(0)) {
            _addClaimableEth(ctx.bonus.dailyBest, ctx.dailyBonusPool);
            ctx.paidEth += ctx.dailyBonusPool;
        }
        if (ctx.levelBonusPool != 0 && ctx.bonus.levelBest != address(0)) {
            _addClaimableEth(ctx.bonus.levelBest, ctx.levelBonusPool);
            ctx.paidEth += ctx.levelBonusPool;
        }

        uint256 coinRemainder = ctx.coinPool > ctx.paidCoin ? ctx.coinPool - ctx.paidCoin : 0;
        if (coinRemainder != 0) {
            uint256 biggestShare = coinRemainder / 2;
            uint256 secondaryShare = coinRemainder / 4;
            uint256 bountyShare = coinRemainder - biggestShare - secondaryShare;
            uint256 bountyOverflow;

            if (biggestShare != 0) {
                if (ctx.biggestFlip != address(0)) {
                    coinContract.bonusCoinflip(ctx.biggestFlip, biggestShare, true, 0);
                } else {
                    bountyOverflow += biggestShare;
                }
            }

            if (secondaryShare != 0) {
                address candidate;
                if (ctx.thirdFlip != address(0) && ctx.fourthFlip != address(0)) {
                    uint256 selector = uint256(keccak256(abi.encode(entropyWord, lvl, jackpotCounter)));
                    candidate = (selector & 1) == 0 ? ctx.thirdFlip : ctx.fourthFlip;
                } else if (ctx.thirdFlip != address(0)) {
                    candidate = ctx.thirdFlip;
                } else if (ctx.fourthFlip != address(0)) {
                    candidate = ctx.fourthFlip;
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

        uint48 currentDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        dailyIdx = currentDay;
        nftContract.releaseRngLock();

        unchecked {
            ++jackpotCounter;
        }
        uint256 currentPool = prizePool;
        prizePool = ctx.paidEth > currentPool ? 0 : currentPool - ctx.paidEth;

        emit Jackpot(
            (uint256(JACKPOT_KIND_DAILY) << 248) |
                uint256(winningTraits[0]) |
                (uint256(winningTraits[1]) << 8) |
                (uint256(winningTraits[2]) << 16) |
                (uint256(winningTraits[3]) << 24)
        );

        if (jackpotCounter < 10) {
            _clearDailyPurgeCount();
        }
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
        uint256 base;
        uint256 lvlMod100 = lvl % 100;

        if ((rngWord % 1_000_000_000) == TRAIT_ID_TIMEOUT) base = 10;
        else if (lvl < 10) base = uint256(lvl) * 5;
        else if (lvl < 20) base = 55 + (rngWord % 16);
        else if (lvl < 40) base = 55 + (rngWord % 21);
        else if (lvl < 60) base = 60 + (rngWord % 21);
        else if (lvl < 80) base = 60 + (rngWord % 26);
        else if (lvlMod100 == 99) base = 93;
        else base = 65 + (rngWord % 26);

        if ((lvl % 10) == 9) base += 5;
        base += lvl / 100;
        if (base > 99) {
            base = 99;
        }

        uint256 jackpotPct = 100 - base;
        if (jackpotPct < 17 && jackpotPct != 30) {
            base = 83;
        }
        return base;
    }

    function _mapJackpotPercent(uint24 lvl) private pure returns (uint256) {
        return (lvl % 20 == 16) ? 30 : 17;
    }

    function _runJackpot(
        uint8 eventKind,
        uint24 lvl,
        uint256 ethPool,
        uint256 coinPool,
        bool mapTrophy,
        uint256 entropy,
        uint8[4] memory winningTraits,
        uint64 traitShareBpsPacked,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract,
        bool redistributeEthRemainder
    ) private returns (uint256 totalPaidEth, uint256 totalPaidCoin, uint256 coinRemainder) {
        uint8 band = uint8((lvl % 100) / 20) + 1;
        uint16[4] memory bucketCounts = _traitBucketCounts(band, entropy);

        uint256 entropyCursorEth;
        bool trophyGiven;
        (totalPaidEth, entropyCursorEth, trophyGiven) = _runJackpotEth(
            mapTrophy,
            lvl,
            ethPool,
            entropy,
            winningTraits,
            traitShareBpsPacked,
            bucketCounts,
            coinContract,
            trophiesContract
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

        if (redistributeEthRemainder && !mapTrophy && ethPool > totalPaidEth) {
            (totalPaidEth, entropyCursorEth, trophyGiven) = _redistributeJackpotRemainder(
                ethPool,
                totalPaidEth,
                eventKind,
                lvl,
                winningTraits,
                entropyCursorEth,
                trophyGiven,
                bucketCounts,
                coinContract,
                trophiesContract
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
        IPurgeGameTrophiesModule trophiesContract
    ) private returns (uint256 totalPaidEth, uint256 entropyCursor, bool trophyGiven) {
        uint256 ethDistributed;
        entropyCursor = entropy;
        for (uint8 traitIdx; traitIdx < 4; ) {
            uint16 shareBps = uint16(traitShareBpsPacked >> (traitIdx * 16));
            uint256 share = _sliceJackpotShare(ethPool, shareBps, traitIdx, ethDistributed);
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
                winningTraits[traitIdx],
                traitIdx,
                share,
                entropyCursor,
                trophyGiven,
                bucketCounts[traitIdx]
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
                winningTraits[traitIdx],
                traitIdx,
                share,
                entropy,
                false,
                bucketCounts[traitIdx]
            );
            totalPaidCoin += delta;
            unchecked {
                ++traitIdx;
            }
        }
    }

    function _sliceJackpotShare(uint256 pool, uint16 shareBps, uint8 traitIdx, uint256 distributed)
        private
        pure
        returns (uint256 slice)
    {
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
                        trophiesContract.awardTrophy{value: deferred}(w, lvl, PURGE_TROPHY_KIND_MAP, trophyData, deferred);
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

    function _redistributeJackpotRemainder(
        uint256 ethPool,
        uint256 totalPaidEth,
        uint8 eventKind,
        uint24 lvl,
        uint8[4] memory winningTraits,
        uint256 entropyCursorEth,
        bool trophyGiven,
        uint16[4] memory bucketCounts,
        IPurgeCoinModule coinContract,
        IPurgeGameTrophiesModule trophiesContract
    ) private returns (uint256 newTotalPaidEth, uint256 newEntropyCursor, bool trophyGivenOut) {
        uint256 ethRemainder = ethPool - totalPaidEth;
        if (ethRemainder == 0) {
            return (totalPaidEth, entropyCursorEth, trophyGiven);
        }

        uint256 remainderEntropy = _entropyStep(
            entropyCursorEth ^ (uint256(eventKind) << 192) ^ ethRemainder
        );
        uint8 extraIdx = uint8(remainderEntropy & 3);
        uint256 nextEntropy;
        uint256 extraPaid;
        (nextEntropy, trophyGivenOut, extraPaid, ) = _runTraitJackpot(
            coinContract,
            trophiesContract,
            false,
            false,
            lvl,
            winningTraits[extraIdx],
            extraIdx,
            ethRemainder,
            remainderEntropy,
            trophyGiven,
            bucketCounts[extraIdx]
        );
        newTotalPaidEth = totalPaidEth;
        if (extraPaid != 0) {
            newTotalPaidEth += extraPaid;
        }
        newEntropyCursor = nextEntropy;
    }

    function _accumulateDailyTrait(
        uint24 lvl,
        uint8 traitId,
        uint8 traitIdx,
        uint16 winnerCount,
        uint256 ethShare,
        uint256 coinShare,
        uint256 entropyCursor,
        DailyJackpotBonus memory bonus,
        IPurgeCoinModule coinContract
    )
        private
        returns (
            uint256 nextEntropy,
            uint256 ethDelta,
            uint256 coinDelta,
            DailyJackpotBonus memory updatedBonus
        )
    {
        (nextEntropy, ethDelta, coinDelta, updatedBonus) = _runDailyTraitJackpot(
            lvl,
            traitId,
            traitIdx,
            winnerCount,
            ethShare,
            coinShare,
            entropyCursor,
            bonus,
            coinContract
        );
    }

    function _dailyTraitShare(
        uint256 baseShare,
        uint256 extraShare,
        uint8 traitIdx,
        uint8 extraTraitIdx
    ) private pure returns (uint256) {
        return traitIdx == extraTraitIdx ? baseShare + extraShare : baseShare;
    }

    function _runDailyTraitJackpot(
        uint24 lvl,
        uint8 traitId,
        uint8 traitIdx,
        uint16 winnerCount,
        uint256 ethShare,
        uint256 coinShare,
        uint256 entropy,
        DailyJackpotBonus memory bonus,
        IPurgeCoinModule coinContract
    )
        private
        returns (
            uint256 nextEntropy,
            uint256 ethDelta,
            uint256 coinDelta,
            DailyJackpotBonus memory updatedBonus
        )
    {
        nextEntropy = entropy;
        updatedBonus = bonus;
        if (ethShare == 0 && coinShare == 0) return (nextEntropy, 0, 0, updatedBonus);

        uint16 totalCount = winnerCount;
        if (totalCount == 0) return (nextEntropy, 0, 0, updatedBonus);

        uint256 perWinnerEth = ethShare / totalCount;
        uint256 perWinnerCoin = coinShare / totalCount;
        if (perWinnerEth == 0 && perWinnerCoin == 0) return (nextEntropy, 0, 0, updatedBonus);

        uint8 requested = uint8(totalCount);
        nextEntropy = _entropyStep(nextEntropy ^ (uint256(traitIdx) << 72) ^ ethShare ^ coinShare);
        address[] memory winners = _randTraitTicket(
            traitPurgeTicket[lvl],
            nextEntropy,
            traitId,
            requested,
            uint8(200 + traitIdx)
        );
        uint8 len = uint8(winners.length);
        if (len > requested) len = requested;

        for (uint8 i; i < len; ) {
            uint256 ethCredited;
            uint256 coinCredited;
            (updatedBonus, ethCredited, coinCredited) = _awardDailyWinner(
                updatedBonus,
                winners[i],
                perWinnerEth,
                perWinnerCoin,
                lvl,
                coinContract
            );
            ethDelta += ethCredited;
            coinDelta += coinCredited;
            unchecked {
                ++i;
            }
        }
    }

    function _awardDailyWinner(
        DailyJackpotBonus memory bonus,
        address player,
        uint256 perWinnerEth,
        uint256 perWinnerCoin,
        uint24 lvl,
        IPurgeCoinModule coinContract
    )
        private
        returns (
            DailyJackpotBonus memory updatedBonus,
            uint256 ethCredited,
            uint256 coinCredited
        )
    {
        updatedBonus = bonus;
        if (player == address(0)) return (updatedBonus, 0, 0);
        if (!_eligibleJackpotWinner(player, lvl)) return (updatedBonus, 0, 0);

        if (perWinnerEth != 0 && _creditJackpot(coinContract, false, player, perWinnerEth)) {
            ethCredited = perWinnerEth;
        }
        if (perWinnerCoin != 0 && _creditJackpot(coinContract, true, player, perWinnerCoin)) {
            coinCredited = perWinnerCoin;
        }
        if (ethCredited != 0 || coinCredited != 0) {
            updatedBonus = _updateDailyBonus(updatedBonus, player);
        }
    }

    function _updateDailyBonus(DailyJackpotBonus memory bonus, address player)
        private
        view
        returns (DailyJackpotBonus memory)
    {
        uint256 packed = mintPacked_[player];
        uint24 dailyStreak = uint24((packed >> AGG_DAY_STREAK_SHIFT) & MINT_MASK_20);
        uint24 dailyEthStreak = uint24((packed >> ETH_DAY_STREAK_SHIFT) & MINT_MASK_20);
        uint24 levelStreak = uint24((packed >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);

        if (
            bonus.dailyBest == address(0) ||
            dailyStreak > bonus.dailyStreak ||
            (dailyStreak == bonus.dailyStreak && dailyEthStreak > bonus.dailyEthStreak) ||
            (dailyStreak == bonus.dailyStreak &&
                dailyEthStreak == bonus.dailyEthStreak &&
                player < bonus.dailyBest)
        ) {
            bonus.dailyBest = player;
            bonus.dailyStreak = dailyStreak;
            bonus.dailyEthStreak = dailyEthStreak;
        }

        if (
            bonus.levelBest == address(0) ||
            levelStreak > bonus.levelStreak ||
            (levelStreak == bonus.levelStreak &&
                (dailyStreak > bonus.levelDailyStreak ||
                    (dailyStreak == bonus.levelDailyStreak &&
                        (dailyEthStreak > bonus.levelDailyEthStreak ||
                            (dailyEthStreak == bonus.levelDailyEthStreak && player < bonus.levelBest)))))
        ) {
            bonus.levelBest = player;
            bonus.levelStreak = levelStreak;
            bonus.levelDailyStreak = dailyStreak;
            bonus.levelDailyEthStreak = dailyEthStreak;
        }

        return bonus;
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

    function _epUnlocked(uint24 lvl) private view returns (bool) {
        return lvl < 10 || (earlyPurgeJackpotPaidMask & EP_THIRTY_MASK) != 0;
    }

    function _eligibleJackpotWinner(address player, uint24 lvl) private view returns (bool) {
        if (player == address(0)) return false;
        if (!_epUnlocked(lvl)) return true;
        return uint24((mintPacked_[player] >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24) == lvl;
    }
}

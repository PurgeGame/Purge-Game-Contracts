// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameNFT} from "../PurgeGameNFT.sol";
import {IPurgeGame} from "../interfaces/IPurgeGame.sol";
import {IPurgeQuestModule} from "../interfaces/IPurgeQuestModule.sol";
import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";

/**
 * @title PurgeCoinExternalJackpotModule
 * @notice Delegate-call module that hosts the BAF/Decimator external jackpot logic for Purgecoin.
 *         Storage layout mirrors the parent contract so writes land on the main contract via `delegatecall`.
 */
contract PurgeCoinExternalJackpotModule {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error InvalidKind();

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct PlayerScore {
        address player;
        uint96 score;
    }

    struct BAFState {
        uint128 totalPrizePoolWei;
        uint120 returnAmountWei;
        bool inProgress;
    }

    struct BAFScan {
        uint120 per;
        uint32 limit;
        uint8 offset;
    }

    struct DecEntry {
        uint192 burn;
        uint24 level;
        uint8 bucket;
        bool winner;
    }

    struct AffiliateCodeInfo {
        address owner;
        uint8 rakeback;
    }

    struct StakeTrophyCandidate {
        address player;
        uint72 principal;
        uint24 level;
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6;
    uint32 private constant BAF_BATCH = 5000;
    uint256 private constant BUCKET_SIZE = 1500;
    uint32 private constant SS_IDLE = type(uint32).max;
    uint32 private constant SS_DONE = type(uint32).max - 1;
    uint8 private constant PURGE_TROPHY_KIND_BAF = 4;
    uint8 private constant PURGE_TROPHY_KIND_DECIMATOR = 5;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;

    // ---------------------------------------------------------------------
    // Storage mirror (keep order identical to Purgecoin)
    // ---------------------------------------------------------------------
    IPurgeGame private purgeGame;
    PurgeGameNFT private purgeGameNFT;
    IPurgeGameTrophies private purgeGameTrophies;
    IPurgeQuestModule private questModule;
    address private externalJackpotModule; // storage slot alignment with Purgecoin

    bool private tbActive;
    bool private bonusActive;
    uint8 private extMode;

    uint8 private affiliateLen;
    uint8 private topLen;

    uint8 private tbMod;
    uint32 private tbRemain;
    uint256 private tbPrize;

    uint24 private stakeLevelComplete;
    uint32 private scanCursor = SS_IDLE;
    uint32 private payoutIndex;

    uint256 private currentTenthPlayerBonusPool;

    address[] private cfPlayers;
    uint128 private cfHead;
    uint128 private cfTail;

    mapping(address => uint256) public coinflipAmount;

    PlayerScore[8] public topBettors;

    mapping(bytes32 => AffiliateCodeInfo) private affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;
    mapping(address => bytes32) private playerReferralCode;
    mapping(address => uint256) public playerLuckbox;
    PlayerScore[8] public affiliateLeaderboard;

    mapping(uint24 => address[]) private stakeAddr;
    mapping(uint24 => mapping(address => uint256)) private stakeAmt;
    StakeTrophyCandidate private stakeTrophyCandidate;

    mapping(address => uint8) private affiliatePos;
    mapping(address => uint8) private topPos;
    mapping(address => uint32) private luckyFlipStreak;
    mapping(address => uint48) private lastLuckyStreakEpoch;
    uint48 private streakEpoch;

    uint128 public currentBounty;
    uint128 public biggestFlipEver;
    address private bountyOwedTo;
    uint96 public totalPresaleSold;

    uint256 private nukeStream;

    BAFState private bafState;
    BAFScan private bs;
    uint256 private extVar;

    mapping(address => DecEntry) private decBurn;
    mapping(uint24 => mapping(uint24 => address[])) private decBuckets;
    mapping(uint24 => uint32) private decPlayersCount;
    uint32[32] private decBucketAccumulator;

    // ---------------------------------------------------------------------
    // External jackpot logic
    // ---------------------------------------------------------------------
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    ) external returns (bool finished, address[] memory winners, uint256[] memory amounts, uint256 returnAmountWei) {
        uint32 batch = (cap == 0) ? BAF_BATCH : cap;
        uint256 executeWord = rngWord;

        if (!bafState.inProgress) {
            if (kind > 1) revert InvalidKind();

            bafState.inProgress = true;

            uint32 limit = (kind == 0) ? uint32(_coinflipCount()) : uint32(decPlayersCount[lvl]);

            bs.offset = uint8(executeWord % 10);
            bs.limit = limit;
            scanCursor = bs.offset;

            bafState.totalPrizePoolWei = uint128(poolWei);
            bafState.returnAmountWei = 0;

            extVar = 0;
            extMode = (kind == 0) ? uint8(1) : uint8(2);

            if (kind == 1) {
                _seedDecBucketState(rngWord);
            }

            if (kind == 0) {
                uint256 P = poolWei;
                address[6] memory tmpW;
                uint256[6] memory tmpA;
                uint256 n;
                uint256 credited;
                uint256 toReturn;
                bool coinflipWin = (rngWord & 1) == 1;
                address trophyRecipient;

                {
                    uint256 prize = (P * 20) / 100;
                    address w = topBettors[0].player;
                    if (_eligible(w)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                        trophyRecipient = w;
                    } else {
                        toReturn += prize;
                    }
                }

                {
                    uint256 prize = (P * 10) / 100;
                    address w = topBettors[2 + (uint256(keccak256(abi.encodePacked(executeWord, "p34"))) & 1)].player;
                    if (_eligible(w)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }

                {
                    uint256 prize = (P * 10) / 100;
                    address w = _randomEligible(uint256(keccak256(abi.encodePacked(executeWord, "re"))));
                    if (w != address(0)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }

                {
                    uint256[4] memory shares = [(P * 5) / 100, (P * 5) / 100, (P * 25) / 1000, (P * 25) / 1000];
                    for (uint256 s; s < 4; ) {
                        uint256 prize = shares[s];
                        address w = purgeGameTrophies.stakedTrophySample(
                            uint64(uint256(keccak256(abi.encodePacked(executeWord, s, "st"))))
                        );
                        if (w != address(0)) {
                            tmpW[n] = w;
                            tmpA[n] = prize;
                            unchecked {
                                ++n;
                            }
                            credited += prize;
                        } else {
                            toReturn += prize;
                        }
                        unchecked {
                            ++s;
                        }
                    }
                }

                uint256 scatter = (P * 40) / 100;
                uint256 unallocated = P - credited - toReturn - scatter;
                if (unallocated != 0) {
                    toReturn += unallocated;
                }
                if (limit >= 10 && bs.offset < limit) {
                    uint256 occurrences = 1 + (uint256(limit) - 1 - bs.offset) / 10;
                    uint256 perWei = scatter / occurrences;
                    bs.per = uint120(perWei);

                    uint256 rem = toReturn + (scatter - perWei * occurrences);
                    bafState.returnAmountWei = uint120(rem);
                } else {
                    bs.per = 0;
                    bafState.returnAmountWei = uint120(toReturn + scatter);
                }

                if (coinflipWin && trophyRecipient != address(0)) {
                    uint256 trophyData = (uint256(BAF_TRAIT_SENTINEL) << 152) |
                        (uint256(lvl) << TROPHY_BASE_LEVEL_SHIFT) |
                        TROPHY_FLAG_BAF;
                    purgeGameTrophies.awardTrophy(trophyRecipient, lvl, PURGE_TROPHY_KIND_BAF, trophyData, 0);
                } else {
                    purgeGameTrophies.burnBafPlaceholder(lvl);
                }

                winners = new address[](n);
                amounts = new uint256[](n);
                for (uint256 i; i < n; ) {
                    winners[i] = tmpW[i];
                    amounts[i] = tmpA[i];
                    unchecked {
                        ++i;
                    }
                }

                if (bs.per == 0 || limit < 10 || bs.offset >= limit) {
                    uint256 ret = uint256(bafState.returnAmountWei);
                    delete bafState;
                    delete bs;
                    extMode = 0;
                    extVar = 0;
                    scanCursor = SS_IDLE;
                    return (true, winners, amounts, ret);
                }
                return (false, winners, amounts, 0);
            }

            return (false, new address[](0), new uint256[](0), 0);
        }

        if (extMode == 1) {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            uint256 tmpCap = uint256(batch) / 10 + 2;
            address[] memory tmpWinners = new address[](tmpCap);
            uint256[] memory tmpAmounts = new uint256[](tmpCap);
            uint256 n2;
            uint256 per = uint256(bs.per);
            uint256 retWei = uint256(bafState.returnAmountWei);

            for (uint32 i = scanCursor; i < end; ) {
                address p = _playerAt(i);
                if (_eligible(p)) {
                    tmpWinners[n2] = p;
                    tmpAmounts[n2] = per;
                    unchecked {
                        ++n2;
                    }
                } else {
                    retWei += per;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;
            bafState.returnAmountWei = uint120(retWei);

            winners = new address[](n2);
            amounts = new uint256[](n2);
            for (uint256 k; k < n2; ) {
                winners[k] = tmpWinners[k];
                amounts[k] = tmpAmounts[k];
                unchecked {
                    ++k;
                }
            }

            if (end == bs.limit) {
                uint256 ret = uint256(bafState.returnAmountWei);
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                return (true, winners, amounts, ret);
            }
            return (false, winners, amounts, 0);
        }

        if (extMode == 2) {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            for (uint32 i = scanCursor; i < end; ) {
                address p = _srcPlayer(1, lvl, i);
                DecEntry storage e = decBurn[p];
                if (e.level == lvl && e.burn != 0) {
                    uint8 bucket = e.bucket;
                    if (bucket < 2) bucket = 2;
                    uint32 acc = decBucketAccumulator[bucket];
                    unchecked {
                        acc += 1;
                    }
                    if (acc >= bucket) {
                        acc -= bucket;
                        if (!e.winner) {
                            e.winner = true;
                            extVar += e.burn;
                        }
                    }
                    decBucketAccumulator[bucket] = acc;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;

            if (end < bs.limit) return (false, new address[](0), new uint256[](0), 0);

            if (extVar == 0) {
                uint256 refund = uint256(bafState.totalPrizePoolWei);
                if (_hasDecPlaceholder(lvl)) {
                    purgeGameTrophies.burnDecPlaceholder(lvl);
                }
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, new address[](0), new uint256[](0), refund);
            }

            extMode = 3;
            scanCursor = bs.offset;
            return (false, new address[](0), new uint256[](0), 0);
        }

        {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            uint256 tmpCap = uint256(batch) / 10 + 2;
            address[] memory tmpWinners = new address[](tmpCap);
            uint256[] memory tmpAmounts = new uint256[](tmpCap);
            uint256 n2;

            uint256 pool = uint256(bafState.totalPrizePoolWei);
            uint256 denom = extVar;
            uint256 paid = uint256(bafState.returnAmountWei);
            if (denom == 0) {
                if (_hasDecPlaceholder(lvl)) {
                    purgeGameTrophies.burnDecPlaceholder(lvl);
                }
                uint256 refundAll = pool;
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, new address[](0), new uint256[](0), refundAll);
            }

            for (uint32 i = scanCursor; i < end; ) {
                address p = _srcPlayer(1, lvl, i);
                DecEntry storage e = decBurn[p];
                if (e.level == lvl && e.burn != 0 && e.winner) {
                    uint256 amt = (pool * e.burn) / denom;
                    if (amt != 0) {
                        tmpWinners[n2] = p;
                        tmpAmounts[n2] = amt;
                        unchecked {
                            ++n2;
                            paid += amt;
                        }
                    }
                    e.winner = false;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;
            bafState.returnAmountWei = uint120(paid);

            winners = new address[](n2);
            amounts = new uint256[](n2);
            for (uint256 k; k < n2; ) {
                winners[k] = tmpWinners[k];
                amounts[k] = tmpAmounts[k];
                unchecked {
                    ++k;
                }
            }

            if (end == bs.limit) {
                bool hasPlaceholder = _hasDecPlaceholder(lvl);
                if (hasPlaceholder) {
                    address trophyOwner = topBettors[0].player;
                    if (denom != 0 && trophyOwner != address(0)) {
                        uint256 trophyData = (uint256(DECIMATOR_TRAIT_SENTINEL) << 152) |
                            (uint256(lvl) << TROPHY_BASE_LEVEL_SHIFT) |
                            TROPHY_FLAG_DECIMATOR;
                        purgeGameTrophies.awardTrophy(
                            trophyOwner,
                            lvl,
                            PURGE_TROPHY_KIND_DECIMATOR,
                            trophyData,
                            0
                        );
                    } else {
                        purgeGameTrophies.burnDecPlaceholder(lvl);
                    }
                }

                uint256 ret = pool > paid ? (pool - paid) : 0;
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, winners, amounts, ret);
            }
            return (false, winners, amounts, 0);
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _eligible(address player) internal view returns (bool) {
        if (coinflipAmount[player] < 5_000 * MILLION) return false;
        return purgeGame.ethMintStreakCount(player) >= 6;
    }

    function _randomEligible(uint256 seed) internal view returns (address) {
        uint256 total = _coinflipCount();
        if (total == 0) return address(0);

        uint256 idx = seed % total;
        uint256 stride = (total & 1) == 1 ? 2 : 1;
        uint256 maxChecks = total < 300 ? total : 300;

        for (uint256 tries; tries < maxChecks; ) {
            address p = _playerAt(idx);
            if (_eligible(p)) return p;
            unchecked {
                idx += stride;
                if (idx >= total) idx -= total;
                ++tries;
            }
        }
        return address(0);
    }

    function _coinflipCount() internal view returns (uint256) {
        return uint256(uint128(cfTail) - uint128(cfHead));
    }

    function _playerAt(uint256 idx) internal view returns (address) {
        return cfPlayers[cfHead + idx];
    }

    function _srcPlayer(uint8 kind, uint24 lvl, uint256 idx) internal view returns (address) {
        if (kind == 0) {
            return cfPlayers[cfHead + idx];
        }
        uint256 bucketIdx = idx / BUCKET_SIZE;
        uint256 offsetInBucket = idx - bucketIdx * BUCKET_SIZE;
        return decBuckets[lvl][uint24(bucketIdx)][offsetInBucket];
    }

    function _seedDecBucketState(uint256 entropy) internal {
        for (uint8 denom = 2; denom <= 20; ) {
            decBucketAccumulator[denom] = uint32(uint256(keccak256(abi.encodePacked(entropy, denom))) % denom);
            unchecked {
                ++denom;
            }
        }
    }

    function _resetDecBucketState() internal {
        for (uint8 denom = 2; denom <= 20; ) {
            decBucketAccumulator[denom] = 0;
            unchecked {
                ++denom;
            }
        }
    }

    function _hasDecPlaceholder(uint24 lvl) internal pure returns (bool) {
        if (lvl == DECIMATOR_SPECIAL_LEVEL) return true;
        if (lvl < 25) return false;
        if ((lvl % 10) != 5) return false;
        if ((lvl % 100) == 95) return false;
        return true;
    }
}

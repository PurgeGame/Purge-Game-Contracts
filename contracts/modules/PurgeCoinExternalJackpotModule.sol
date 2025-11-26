// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeCoinStorage} from "../storage/PurgeCoinStorage.sol";

/**
 * @title PurgeCoinExternalJackpotModule
 * @notice Delegate-call module that hosts the BAF/Decimator external jackpot logic for Purgecoin.
 *         Storage layout mirrors the parent contract so writes land on the main contract via `delegatecall`.
 */
contract PurgeCoinExternalJackpotModule is PurgeCoinStorage {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error InvalidKind();

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6;
    uint32 private constant BAF_BATCH = 5000;
    uint256 private constant BUCKET_SIZE = 1500;
    uint32 private constant SS_IDLE = type(uint32).max;
    uint8 private constant PURGE_TROPHY_KIND_BAF = 4;
    uint8 private constant PURGE_TROPHY_KIND_DECIMATOR = 5;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;
    uint32 private constant DEC_WINNER_BATCH = 250;

    // ---------------------------------------------------------------------
    // External jackpot logic
    // ---------------------------------------------------------------------
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    )
        external
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
    )
    {
        uint32 batch;
        if (cap == 0) {
            batch = (kind == 0) ? BAF_BATCH : DEC_WINNER_BATCH;
        } else {
            batch = cap;
        }

        if (!bafState.inProgress) {
            if (kind > 1) revert InvalidKind();

            bafState.inProgress = true;

            uint32 limit = (kind == 0) ? uint32(_coinflipCount()) : uint32(decPlayersCount[lvl]);
            if (kind == 0) {
                bs.offset = uint8(uint256(keccak256(abi.encode(rngWord, 1))) % 10);
                scanCursor = bs.offset;
            } else {
                bs.offset = 0;
                scanCursor = 0;
                decScanDenom = 2;
                decScanIndex = 0;
                delete decWinners;
            }
            bs.limit = limit;

            bafState.totalPrizePoolWei = uint128(poolWei);
            bafState.returnAmountWei = 0;

            extVar = 0;
            extMode = (kind == 0) ? uint8(1) : uint8(2);

            if (kind == 1) {
                _seedDecBucketState(rngWord);
            }

            if (kind == 0) {
                uint256 P = poolWei;
                address[] memory tmpW = new address[](8);
                uint256[] memory tmpA = new uint256[](8);
                uint256 n;
                uint256 credited;
                uint256 toReturn;
                bool coinflipWin = (rngWord & 1) == 1;
                address trophyRecipient;

                uint256 entropy = rngWord;
                uint256 salt;

                {
                    uint256 prize = P / 5;
                    address w = topBettors[0].player;
                    if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
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
                    unchecked {
                        ++salt;
                    }
                    entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                    uint256 prize = P / 10;
                    address w = topBettors[2 + (entropy & 1)].player;
                    if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }

                {
                    unchecked {
                        ++salt;
                    }
                    entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));

                    address[4] memory draws;
                    uint256 entryCount = _coinflipCount();
                    for (uint8 i; i < 4; ) {
                        draws[i] = entryCount == 0 ? address(0) : _playerAt(entropy % entryCount);
                        unchecked {
                            ++salt;
                            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                        }
                    }

                    // Sort by coinflipAmount descending (simple selection sort for up to 4 items)
                    for (uint8 i; i < 4; ) {
                        uint8 bestIdx = i;
                        uint256 best = coinflipAmount[draws[i]];
                        for (uint8 j = i + 1; j < 4; ) {
                            uint256 val = coinflipAmount[draws[j]];
                            if (val > best) {
                                best = val;
                                bestIdx = j;
                            }
                            unchecked {
                                ++j;
                            }
                        }
                        if (bestIdx != i) {
                            address tmp = draws[i];
                            draws[i] = draws[bestIdx];
                            draws[bestIdx] = tmp;
                        }
                        unchecked {
                            ++i;
                        }
                    }

                    uint256 prize9 = (P * 9) / 100;
                    uint256 prize6 = (P * 6) / 100;
                    uint256 prize3 = (P * 3) / 100;
                    uint256[4] memory prizes = [prize9, prize6, prize3, uint256(0)];

                    for (uint8 i; i < 4; ) {
                        uint256 prize = prizes[i];
                        address w = draws[i];
                        if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
                            unchecked {
                                ++n;
                            }
                            credited += prize;
                        } else if (prize != 0) {
                            toReturn += prize;
                        }
                        unchecked {
                            ++i;
                        }
                    }
                }

                {
                    uint256 trophyDelta;
                    uint256[4] memory trophyPrizes = [(P * 5) / 100, (P * 3) / 100, (P * 2) / 100, uint256(0)];
                    address[4] memory trophyOwners;
                    uint256[4] memory trophyIds;

                    for (uint8 s; s < 4; ) {
                        unchecked {
                            ++salt;
                        }
                        entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                        (uint256 tokenId, address owner) = purgeGameTrophies.stakedTrophySampleWithId(entropy);
                        trophyIds[s] = tokenId;
                        trophyOwners[s] = owner;
                        unchecked {
                            ++s;
                        }
                    }

                    // Sort trophies by owner coinflip size
                    for (uint8 i; i < 4; ) {
                        uint8 bestIdx = i;
                        uint256 best = coinflipAmount[trophyOwners[i]];
                        for (uint8 j = i + 1; j < 4; ) {
                            uint256 val = coinflipAmount[trophyOwners[j]];
                            if (val > best) {
                                best = val;
                                bestIdx = j;
                            }
                            unchecked {
                                ++j;
                            }
                        }
                        if (bestIdx != i) {
                            address ownerTmp = trophyOwners[i];
                            trophyOwners[i] = trophyOwners[bestIdx];
                            trophyOwners[bestIdx] = ownerTmp;

                            uint256 tokenTmp = trophyIds[i];
                            trophyIds[i] = trophyIds[bestIdx];
                            trophyIds[bestIdx] = tokenTmp;
                        }
                        unchecked {
                            ++i;
                        }
                    }

                    for (uint8 i; i < 4; ) {
                        uint256 prize = trophyPrizes[i];
                        uint256 tokenId = trophyIds[i];
                        address owner = trophyOwners[i];
                        bool eligibleOwner = tokenId != 0 && owner != address(0) && _eligible(owner);
                        if (eligibleOwner && prize != 0) {
                            purgeGameTrophies.rewardTrophyByToken(tokenId, prize, lvl);
                            trophyDelta += prize;
                            credited += prize;
                        } else if (prize != 0) {
                            toReturn += prize;
                        }
                        unchecked {
                            ++i;
                        }
                    }
                    extVar = trophyDelta;
                }

                {
                    uint256 prizeLuckbox = (P * 2) / 100;
                    PlayerScore memory luckboxRecord = biggestLuckbox;
                    address luckboxLeader = luckboxRecord.player;
                    if (luckboxLeader != address(0) && luckboxRecord.score != 0) {
                        if (_creditOrRefund(luckboxLeader, prizeLuckbox, tmpW, tmpA, n)) {
                            unchecked {
                                ++n;
                            }
                            credited += prizeLuckbox;
                        } else {
                            toReturn += prizeLuckbox;
                        }
                    } else {
                        toReturn += prizeLuckbox;
                    }
                }

                uint256 scatter = (P * 2) / 5;
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
                    trophyPoolDelta = extVar;
                    delete bafState;
                    delete bs;
                    extMode = 0;
                    extVar = 0;
                    scanCursor = SS_IDLE;
                    return (true, winners, amounts, trophyPoolDelta, ret);
                }
                return (false, winners, amounts, 0, 0);
            }

            return (false, new address[](0), new uint256[](0), 0, 0);
        }

        if (extMode == 1) {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            uint256 tmpCap = uint256(batch) / 10 + 2;
            address[] memory winnersBuf = new address[](tmpCap);
            uint256[] memory amountsBuf = new uint256[](tmpCap);
            uint256 n2;
            uint256 per = uint256(bs.per);
            uint256 retWei = uint256(bafState.returnAmountWei);

            for (uint32 i = scanCursor; i < end; ) {
                address p = _playerAt(i);
                if (_eligible(p)) {
                    winnersBuf[n2] = p;
                    amountsBuf[n2] = per;
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
            for (uint256 i; i < n2; ) {
                winners[i] = winnersBuf[i];
                amounts[i] = amountsBuf[i];
                unchecked {
                    ++i;
                }
            }

            if (end == bs.limit) {
                uint256 ret = uint256(bafState.returnAmountWei);
                trophyPoolDelta = extVar;
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                return (true, winners, amounts, trophyPoolDelta, ret);
            }
            return (false, winners, amounts, 0, 0);
        }

        if (extMode == 2) {
            uint32 winnersBudget = batch;

            for (; decScanDenom <= 20 && winnersBudget != 0; ) {
                uint8 denom = decScanDenom;
                uint32 acc = decBucketAccumulator[denom];
                address[] storage roster = decBucketRoster[lvl][denom];
                uint256 len = roster.length;
                uint32 idx = decScanIndex;

                if (idx >= len) {
                    uint256 advanced = len >= idx ? (len - idx) : 0;
                    decBucketAccumulator[denom] = uint32((uint256(acc) + advanced) % denom);
                    decScanDenom = denom + 1;
                    decScanIndex = 0;
                    continue;
                }

                bool exhaustedBucket;
                while (winnersBudget != 0) {
                    uint256 step = (denom - ((uint256(acc) + 1) % denom)) % denom;
                    uint256 winnerIdx = uint256(idx) + step;
                    if (winnerIdx >= len) {
                        decBucketAccumulator[denom] = uint32((uint256(acc) + (len - idx)) % denom);
                        exhaustedBucket = true;
                        break;
                    }

                    address p = roster[winnerIdx];
                    DecEntry storage e = decBurn[p];
                    if (e.level == lvl && e.bucket == denom && e.burn != 0) {
                        extVar += e.burn;
                        decWinners.push(p);
                        unchecked {
                            --winnersBudget;
                        }
                    }

                    acc = 0;
                    idx = uint32(winnerIdx + 1);
                    if (idx >= len) {
                        exhaustedBucket = true;
                        break;
                    }
                }

                decBucketAccumulator[denom] = acc;
                decScanIndex = idx;

                if (exhaustedBucket) {
                    decScanDenom = denom + 1;
                    decScanIndex = 0;
                }
            }

            if (decScanDenom > 20) {
                if (extVar == 0) {
                    uint256 refund = uint256(bafState.totalPrizePoolWei);
                    if (_hasDecPlaceholder(lvl)) {
                        purgeGameTrophies.burnDecPlaceholder(lvl);
                    }
                    delete decWinners;
                    delete bafState;
                    delete bs;
                    extMode = 0;
                    extVar = 0;
                    decScanDenom = 0;
                    decScanIndex = 0;
                    scanCursor = SS_IDLE;
                    _resetDecBucketState();
                    return (true, new address[](0), new uint256[](0), 0, refund);
                }

                extMode = 3;
                scanCursor = 0;
                return (false, new address[](0), new uint256[](0), 0, 0);
            }

            return (false, new address[](0), new uint256[](0), 0, 0);
        }

        {
            uint32 end = scanCursor + batch;
            uint256 totalWinners = decWinners.length;
            if (uint256(end) > totalWinners) end = uint32(totalWinners);

            uint256 span = uint256(end - scanCursor);
            address[] memory winnersBuf = new address[](span);
            uint256[] memory amountsBuf = new uint256[](span);
            uint256 n2;

            uint256 pool = uint256(bafState.totalPrizePoolWei);
            uint256 denom = extVar;
            uint256 paid = uint256(bafState.returnAmountWei);

            for (uint32 i = scanCursor; i < end; ) {
                address p = decWinners[i];
                DecEntry storage e = decBurn[p];
                if (e.level == lvl && e.burn != 0) {
                    uint256 amt = (pool * e.burn) / denom;
                    if (amt != 0) {
                        winnersBuf[n2] = p;
                        amountsBuf[n2] = amt;
                        unchecked {
                            ++n2;
                            paid += amt;
                        }
                    }
                }
                unchecked {
                    ++i;
                }
            }
            scanCursor = end;
            bafState.returnAmountWei = uint120(paid);

            winners = new address[](n2);
            amounts = new uint256[](n2);
            for (uint256 i; i < n2; ) {
                winners[i] = winnersBuf[i];
                amounts[i] = amountsBuf[i];
                unchecked {
                    ++i;
                }
            }

            if (uint256(end) == totalWinners) {
                bool hasPlaceholder = _hasDecPlaceholder(lvl);
                if (hasPlaceholder) {
                    address trophyOwner;
                    uint256 bestBurn;
                    uint256 lenW = decWinners.length;
                    for (uint256 i; i < lenW; ) {
                        address candidate = decWinners[i];
                        DecEntry storage e = decBurn[candidate];
                        if (e.level == lvl && e.burn > bestBurn) {
                            bestBurn = e.burn;
                            trophyOwner = candidate;
                        }
                        unchecked {
                            ++i;
                        }
                    }
                    if (trophyOwner != address(0)) {
                        uint256 trophyData = (uint256(DECIMATOR_TRAIT_SENTINEL) << 152) |
                            (uint256(lvl) << TROPHY_BASE_LEVEL_SHIFT) |
                            TROPHY_FLAG_DECIMATOR;
                        purgeGameTrophies.awardTrophy(trophyOwner, lvl, PURGE_TROPHY_KIND_DECIMATOR, trophyData, 0);
                    } else {
                        purgeGameTrophies.burnDecPlaceholder(lvl);
                    }
                }

                uint256 ret = pool > paid ? (pool - paid) : 0;
                delete decWinners;
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                decScanDenom = 0;
                decScanIndex = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, winners, amounts, 0, ret);
            }
            return (false, winners, amounts, 0, 0);
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _eligible(address player) internal view returns (bool) {
        if (coinflipAmount[player] < 5_000 * MILLION) return false;
        return purgeGame.ethMintStreakCount(player) >= 6;
    }

    function _creditOrRefund(
        address candidate,
        uint256 prize,
        address[] memory winnersBuf,
        uint256[] memory amountsBuf,
        uint256 idx
    ) private view returns (bool credited) {
        if (prize == 0) return false;
        if (candidate != address(0) && _eligible(candidate)) {
            winnersBuf[idx] = candidate;
            amountsBuf[idx] = prize;
            return true;
        }
        return false;
    }

    function _coinflipCount() internal view returns (uint256) {
        return uint256(uint128(cfTail) - uint128(cfHead));
    }

    function _playerAt(uint256 idx) internal view returns (address) {
        uint256 capacity = cfPlayers.length;
        if (capacity == 0) return address(0);
        uint256 physical = (uint256(cfHead) + idx) % capacity;
        return cfPlayers[physical];
    }

    function _srcPlayer(uint8 kind, uint24 lvl, uint256 idx) internal view returns (address) {
        if (kind == 0) {
            return _playerAt(idx);
        }
        uint256 bucketIdx = idx / BUCKET_SIZE;
        uint256 offsetInBucket = idx - bucketIdx * BUCKET_SIZE;
        return decBuckets[lvl][uint24(bucketIdx)][offsetInBucket];
    }

    function _seedDecBucketState(uint256 entropy) internal {
        for (uint8 denom = 2; denom <= 20; ) {
            entropy = uint256(keccak256(abi.encode(entropy, denom)));
            decBucketAccumulator[denom] = uint32(entropy % denom);
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

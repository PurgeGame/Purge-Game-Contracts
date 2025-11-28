// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGame} from "../interfaces/IPurgeGame.sol";
import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";
import {IPurgeJackpots} from "../interfaces/IPurgeJackpots.sol";
import {PurgeGameExternalOp} from "../interfaces/IPurgeGameExternal.sol";

interface IPurgeCoinJackpotView {
    function coinflipAmount(address player) external view returns (uint256);
    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score);
    function biggestLuckbox() external view returns (address player, uint96 score);
    function playerLuckbox(address player) external view returns (uint256);
}

/**
 * @title PurgeJackpots
 * @notice Standalone contract that owns BAF/Decimator jackpot state and claim logic.
 *         Purgecoin forwards flips/burns into this contract and calls it to resolve jackpots.
 */
contract PurgeJackpots is IPurgeJackpots {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error InvalidKind();
    error DecClaimInactive();
    error DecAlreadyClaimed();
    error DecNotWinner();
    error BafClaimInactive();
    error BafNotWinner();
    error AlreadyWired();
    error OnlyCoin();
    error OnlyGame();

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
    }

    struct DecClaimRound {
        uint256 poolWei;
        uint256 totalBurn;
        uint24 level;
        bool active;
    }

    struct BafClaimRound {
        uint256 perWei;
        uint24 level;
        bool active;
    }

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------
    IPurgeCoinJackpotView public coin;
    IPurgeGame public purgeGame;
    IPurgeGameTrophies public purgeGameTrophies;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6;
    uint32 private constant BAF_BATCH = 5000;
    uint32 private constant SS_IDLE = type(uint32).max;
    uint8 private constant PURGE_TROPHY_KIND_BAF = 4;
    uint8 private constant PURGE_TROPHY_KIND_DECIMATOR = 5;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;
    uint32 private constant DEC_WINNER_BATCH = 1900;

    // ---------------------------------------------------------------------
    // BAF / Decimator state (lives here; Purgecoin storage is unaffected)
    // ---------------------------------------------------------------------
    uint8 internal extMode;
    uint32 internal scanCursor = SS_IDLE;
    BAFState internal bafState;
    BAFScan internal bs;
    uint256 internal extVar;

    mapping(address => DecEntry) internal decBurn;
    mapping(uint24 => uint32) internal decPlayersCount;
    uint32[32] internal decBucketAccumulator;

    // Decimator bucketed rosters and scan state
    mapping(uint24 => mapping(uint8 => address[])) internal decBucketRoster;
    uint8 internal decScanDenom;
    uint32 internal decScanIndex;
    uint256 internal decTotalBurn;
    uint256 internal decBucketSeed;
    address internal decTopWinner;
    uint192 internal decTopBurn;

    // Active Decimator claim round by level.
    mapping(uint24 => DecClaimRound) internal decClaimRound;

    // Track whether a player has claimed their Decimator share for a level.
    mapping(uint24 => mapping(address => bool)) internal decClaimed;

    // Position of a player within the Decimator bucket roster for a given level.
    mapping(uint24 => mapping(address => uint32)) internal decBucketIndex;

    // Winning offset per denominator for a level (derived during selection).
    mapping(uint24 => mapping(uint8 => uint32)) internal decBucketOffset;

    // Active BAF scatter claim round by level.
    mapping(uint24 => BafClaimRound) internal bafScatterRound;

    // Snapshot of coinflip roster used for BAF scatter per level.
    mapping(uint24 => address[]) internal bafScatterRoster;
    mapping(uint24 => mapping(address => uint32)) internal bafScatterIndex;

    // BAF scatter winner flags per level.
    mapping(uint24 => mapping(address => bool)) internal bafScatterWinner;

    // Track whether a player has claimed their BAF scatter share for a level.
    mapping(uint24 => mapping(address => bool)) internal bafScatterClaimed;

    // Top-4 coinflip bettors for BAF per level.
    mapping(uint24 => PlayerScore[4]) internal bafTop;
    mapping(uint24 => uint8) internal bafTopLen;

    // ---------------------------------------------------------------------
    // Modifiers / wiring
    // ---------------------------------------------------------------------
    modifier onlyCoin() {
        if (msg.sender != address(coin)) revert OnlyCoin();
        _;
    }

    modifier onlyGame() {
        if (msg.sender != address(purgeGame)) revert OnlyGame();
        _;
    }

    modifier onlyGameOrCoin() {
        address sender = msg.sender;
        if (sender != address(purgeGame) && sender != address(coin)) revert OnlyGame();
        _;
    }

    function wire(address coin_, address purgeGame_, address trophies_) external override {
        if (address(coin) != address(0)) revert AlreadyWired();
        if (msg.sender != coin_) revert OnlyCoin();
        coin = IPurgeCoinJackpotView(coin_);
        purgeGame = IPurgeGame(purgeGame_);
        purgeGameTrophies = IPurgeGameTrophies(trophies_);
    }

    // ---------------------------------------------------------------------
    // Hooks from Purgecoin
    // ---------------------------------------------------------------------
    function recordBafFlip(address player, uint24 lvl) external override onlyCoin {
        if (bafScatterIndex[lvl][player] == 0) {
            uint32 idx = uint32(bafScatterRoster[lvl].length);
            bafScatterRoster[lvl].push(player);
            bafScatterIndex[lvl][player] = idx + 1; // store index+1 to distinguish unset
        }
        uint256 stake = coin.coinflipAmount(player);
        if (stake != 0) {
            _updateBafTop(lvl, player, stake);
        }
    }

    function recordDecBurn(
        address player,
        uint24 lvl,
        uint8 bucket,
        uint256 amount
    ) external override onlyCoin returns (uint8 bucketUsed) {
        DecEntry storage e = decBurn[player];

        if (e.level != lvl) {
            e.level = lvl;
            e.burn = 0;
            e.bucket = bucket;
            _decPush(lvl, bucket, player);
        } else if (e.bucket == 0) {
            e.bucket = bucket;
            _decPush(lvl, bucket, player);
        }

        uint256 updated = uint256(e.burn) + amount;
        if (updated > type(uint192).max) updated = type(uint192).max;
        e.burn = uint192(updated);

        return e.bucket;
    }

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
        override
        onlyGameOrCoin
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

            uint32 limit = (kind == 0) ? uint32(bafScatterRoster[lvl].length) : uint32(decPlayersCount[lvl]);
            if (kind == 0) {
                bs.offset = uint8(uint256(keccak256(abi.encode(rngWord, 1))) % 10);
                scanCursor = bs.offset;
            } else {
                bs.offset = 0;
                scanCursor = 0;
                decScanDenom = 2;
                decScanIndex = 0;
                decTotalBurn = 0;
                decBucketSeed = rngWord;
                decTopWinner = address(0);
                decTopBurn = 0;
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
                address[] memory tmpW = new address[](10);
                uint256[] memory tmpA = new uint256[](10);
                uint256 n;
                uint256 toReturn;
                address trophyRecipient;
                bool trophyAwarded;

                uint256 entropy = rngWord;
                uint256 salt;

                {
                    uint256 prize = P / 10;

                    (address w, ) = _bafTop(lvl, 0);
                    if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
                        unchecked {
                            ++n;
                        }
                        trophyRecipient = w;
                        uint256 trophyData = (uint256(BAF_TRAIT_SENTINEL) << 152) |
                            (uint256(lvl) << TROPHY_BASE_LEVEL_SHIFT) |
                            TROPHY_FLAG_BAF;
                        purgeGameTrophies.awardTrophy(trophyRecipient, lvl, PURGE_TROPHY_KIND_BAF, trophyData, prize);
                        trophyAwarded = true;
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
                    uint8 pick = uint8(entropy & 3);
                    (address w, ) = _bafTop(lvl, pick);
                    if (w == address(0) && pick != 0) {
                        (w, ) = _bafTop(lvl, 0);
                    }
                    if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
                        unchecked {
                            ++n;
                        }
                    } else {
                        toReturn += prize;
                    }
                }

                {
                    unchecked {
                        ++salt;
                    }
                    entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                    // Legacy coinflip-queue prizes removed; return this slice to the pool.
                    toReturn += (P * 18) / 100;
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
                        uint256 best = coin.coinflipAmount(trophyOwners[i]);
                        for (uint8 j = i + 1; j < 4; ) {
                            uint256 val = coin.coinflipAmount(trophyOwners[j]);
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
                    (address luckboxLeader, uint96 luckboxScore) = coin.biggestLuckbox();
                    if (luckboxLeader != address(0) && luckboxScore != 0) {
                        if (_creditOrRefund(luckboxLeader, prizeLuckbox, tmpW, tmpA, n)) {
                            unchecked {
                                ++n;
                            }
                        } else {
                            toReturn += prizeLuckbox;
                        }
                    } else {
                        toReturn += prizeLuckbox;
                    }
                }

                uint256 scatter = (P * 2) / 5;
                if (limit >= 10 && bs.offset < limit) {
                    uint256 occurrences = 1 + (uint256(limit) - 1 - bs.offset) / 10;
                    uint256 perWei = scatter / occurrences;
                    bs.per = uint120(perWei);

                    uint256 rem = scatter - perWei * occurrences;
                    bafState.returnAmountWei = uint120(toReturn + rem);
                } else {
                    bs.per = 0;
                    bafState.returnAmountWei = uint120(toReturn + scatter);
                }

                if (!trophyAwarded) {
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
                    _clearBafTop(lvl);
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

            uint256 per = uint256(bs.per);
            uint256 retWei = uint256(bafState.returnAmountWei);
            address[] storage roster = bafScatterRoster[lvl];
            BafClaimRound storage round = bafScatterRound[lvl];
            if (round.level != lvl) {
                delete bafScatterRound[lvl];
                delete bafScatterRoster[lvl];
                round = bafScatterRound[lvl];
                round.level = lvl;
                round.perWei = per;
                round.active = false;
            }

            bool anyWinner;
            for (uint32 i = scanCursor; i < end; ) {
                if (i >= roster.length) {
                    retWei += per;
                    unchecked {
                        i += 10;
                    }
                    continue;
                }
                address p = roster[i];
                if (_eligible(p)) {
                    if (!bafScatterWinner[lvl][p]) {
                        bafScatterWinner[lvl][p] = true;
                        anyWinner = true;
                    } else {
                        retWei += per;
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

            winners = new address[](0);
            amounts = new uint256[](0);
            if (end == bs.limit) {
                uint256 ret = uint256(bafState.returnAmountWei);
                if (!anyWinner) {
                    delete bafScatterRound[lvl];
                    delete bafScatterRoster[lvl];
                } else {
                    round.perWei = per;
                    round.active = true;
                    delete bafScatterRoster[lvl];
                }
                _clearBafTop(lvl);
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
            if (decScanDenom < 2) {
                decScanDenom = 2;
                decScanIndex = 0;
                _seedDecBucketState(decBucketSeed);
            }
            uint32 winnersBudget = batch;
            uint32 ops;
            uint32 opsLimit = batch * 4;
            if (opsLimit < 5000) opsLimit = 5000;

            for (; decScanDenom <= 20 && winnersBudget != 0 && ops < opsLimit; ) {
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
                while (winnersBudget != 0 && ops < opsLimit) {
                    unchecked {
                        ++ops;
                    }
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
                        uint256 burn = e.burn;
                        decTotalBurn += burn;
                        if (burn > uint256(decTopBurn)) {
                            decTopBurn = uint192(burn);
                            decTopWinner = p;
                        }
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
                if (decTotalBurn == 0) {
                    uint256 refund = uint256(bafState.totalPrizePoolWei);
                    if (_hasDecPlaceholder(lvl)) {
                        purgeGameTrophies.burnDecPlaceholder(lvl);
                    }
                    delete bafState;
                    delete bs;
                    extMode = 0;
                    extVar = 0;
                    decTotalBurn = 0;
                    decBucketSeed = 0;
                    decTopWinner = address(0);
                    decTopBurn = 0;
                    decScanDenom = 0;
                    decScanIndex = 0;
                    scanCursor = SS_IDLE;
                    _resetDecBucketState();
                    return (true, new address[](0), new uint256[](0), 0, refund);
                }

                uint256 totalPool = uint256(bafState.totalPrizePoolWei);

                DecClaimRound storage round = decClaimRound[lvl];
                round.poolWei = totalPool;
                round.totalBurn = decTotalBurn;
                round.level = lvl;
                round.active = true;

                // Derive winning offsets for each bucket for claim-time verification.
                for (uint8 denom = 2; denom <= 20; ) {
                    uint256 seed = uint256(keccak256(abi.encode(decBucketSeed, denom)));
                    decBucketOffset[lvl][denom] = uint32(seed % denom);
                    unchecked {
                        ++denom;
                    }
                }

                if (_hasDecPlaceholder(lvl)) {
                    if (decTopWinner != address(0)) {
                        uint256 trophyData = (uint256(DECIMATOR_TRAIT_SENTINEL) << 152) |
                            (uint256(lvl) << TROPHY_BASE_LEVEL_SHIFT) |
                            TROPHY_FLAG_DECIMATOR;
                        purgeGameTrophies.awardTrophy(decTopWinner, lvl, PURGE_TROPHY_KIND_DECIMATOR, trophyData, 0);
                    } else {
                        purgeGameTrophies.burnDecPlaceholder(lvl);
                    }
                }

                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                decTotalBurn = 0;
                decBucketSeed = 0;
                decTopWinner = address(0);
                decScanDenom = 0;
                decScanIndex = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, new address[](0), new uint256[](0), 0, 0);
            }

            return (false, new address[](0), new uint256[](0), 0, 0);
        }

        if (extMode == 3) {
            // Legacy Decimator streaming payouts removed; Decimator jackpots are now claim-based.
            revert InvalidKind();
        }
    }

    // ---------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------
    function _consumeDecClaim(address player, uint24 lvl) internal returns (uint256 amountWei) {
        DecClaimRound storage round = decClaimRound[lvl];
        if (!round.active) revert DecClaimInactive();
        if (decClaimed[lvl][player]) revert DecAlreadyClaimed();

        (amountWei, ) = _decClaimable(round, player, lvl);
        if (amountWei == 0) revert DecNotWinner();

        decClaimed[lvl][player] = true;
    }

    function consumeDecClaim(address player, uint24 lvl) external override onlyGame returns (uint256 amountWei) {
        return _consumeDecClaim(player, lvl);
    }

    function claimDecimatorJackpot(uint24 lvl) external {
        uint256 amountWei = _consumeDecClaim(msg.sender, lvl);
        purgeGame.applyExternalOp(PurgeGameExternalOp.DecJackpotClaim, msg.sender, amountWei, lvl);
    }

    function _consumeBafClaim(address player, uint24 lvl) internal returns (uint256 amountWei) {
        BafClaimRound storage round = bafScatterRound[lvl];
        if (!round.active || round.level != lvl) revert BafClaimInactive();
        if (bafScatterClaimed[lvl][player]) revert BafNotWinner();
        if (!bafScatterWinner[lvl][player]) revert BafNotWinner();

        amountWei = round.perWei;
        bafScatterClaimed[lvl][player] = true;
    }

    function consumeBafClaim(address player, uint24 lvl) external override onlyGame returns (uint256 amountWei) {
        return _consumeBafClaim(player, lvl);
    }

    function claimBafJackpot(uint24 lvl) external {
        uint256 amountWei = _consumeBafClaim(msg.sender, lvl);
        purgeGame.applyExternalOp(PurgeGameExternalOp.BafJackpotClaim, msg.sender, amountWei, lvl);
    }

    function decClaimable(address player, uint24 lvl) external view override returns (uint256 amountWei, bool winner) {
        DecClaimRound storage round = decClaimRound[lvl];
        return _decClaimable(round, player, lvl);
    }

    function bafClaimable(address player, uint24 lvl) external view override returns (uint256 amountWei, bool winner) {
        BafClaimRound storage round = bafScatterRound[lvl];
        if (!round.active || round.level != lvl) return (0, false);

        if (!bafScatterWinner[lvl][player] || bafScatterClaimed[lvl][player]) return (0, false);

        amountWei = round.perWei;
        winner = amountWei != 0;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _eligible(address player) internal view returns (bool) {
        if (coin.coinflipAmount(player) < 5_000 * MILLION) return false;
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
        if (lvl != 0 && (lvl % DECIMATOR_SPECIAL_LEVEL) == 0) return true;
        if (lvl < 25) return false;
        if ((lvl % 10) != 5) return false;
        if ((lvl % 100) == 95) return false;
        return true;
    }

    function _decClaimable(
        DecClaimRound storage round,
        address player,
        uint24 lvl
    ) internal view returns (uint256 amountWei, bool winner) {
        if (!round.active || round.totalBurn == 0 || round.level != lvl) return (0, false);
        if (decClaimed[lvl][player]) return (0, false);

        DecEntry storage e = decBurn[player];
        uint8 denom = e.bucket;
        if (e.level != lvl || denom == 0 || e.burn == 0) return (0, false);

        address[] storage roster = decBucketRoster[lvl][denom];
        uint256 idx = uint256(decBucketIndex[lvl][player]);
        if (idx >= roster.length || roster[idx] != player) return (0, false);

        uint32 offset = decBucketOffset[lvl][denom];
        uint256 start = (denom - ((uint256(offset) + 1) % denom)) % denom;
        if (idx < start || ((idx - start) % denom) != 0) return (0, false);

        amountWei = (round.poolWei * uint256(e.burn)) / round.totalBurn;
        winner = true;
    }

    function _decPush(uint24 lvl, uint8 bucket, address p) internal {
        decBucketIndex[lvl][p] = uint32(decBucketRoster[lvl][bucket].length);
        decBucketRoster[lvl][bucket].push(p);
        unchecked {
            decPlayersCount[lvl] = decPlayersCount[lvl] + 1;
        }
    }

    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    function _updateBafTop(uint24 lvl, address player, uint256 stake) private {
        uint96 score = _score96(stake);
        PlayerScore[4] storage board = bafTop[lvl];
        uint8 len = bafTopLen[lvl];

        uint8 existing = 4;
        for (uint8 i; i < len; ) {
            if (board[i].player == player) {
                existing = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (existing < 4) {
            if (score <= board[existing].score) return;
            board[existing].score = score;
            uint8 idx = existing;
            while (idx > 0 && board[idx].score > board[idx - 1].score) {
                PlayerScore memory tmp = board[idx - 1];
                board[idx - 1] = board[idx];
                board[idx] = tmp;
                unchecked {
                    --idx;
                }
            }
            return;
        }

        if (len < 4) {
            uint8 insert = len;
            while (insert > 0 && score > board[insert - 1].score) {
                board[insert] = board[insert - 1];
                unchecked {
                    --insert;
                }
            }
            board[insert] = PlayerScore({player: player, score: score});
            bafTopLen[lvl] = len + 1;
            return;
        }

        if (score <= board[3].score) return;
        uint8 idx2 = 3;
        while (idx2 > 0 && score > board[idx2 - 1].score) {
            board[idx2] = board[idx2 - 1];
            unchecked {
                --idx2;
            }
        }
        board[idx2] = PlayerScore({player: player, score: score});
    }

    function _bafTop(uint24 lvl, uint8 idx) private view returns (address player, uint96 score) {
        uint8 len = bafTopLen[lvl];
        if (idx >= len) return (address(0), 0);
        PlayerScore memory entry = bafTop[lvl][idx];
        return (entry.player, entry.score);
    }

    function _clearBafTop(uint24 lvl) private {
        uint8 len = bafTopLen[lvl];
        if (len != 0) {
            delete bafTopLen[lvl];
        }
        for (uint8 i; i < len; ) {
            delete bafTop[lvl][i];
            unchecked {
                ++i;
            }
        }
    }
}

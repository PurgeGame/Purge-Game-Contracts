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
        uint8 subBucket;
    }

    struct DecClaimRound {
        uint256 poolWei;
        uint256 totalBurn;
        uint24 level;
        bool active;
    }

    struct DecSubbucketTop {
        address player;
        uint192 burn;
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

    // Decimator bucketed rosters and aggregates
    mapping(uint24 => mapping(uint8 => mapping(uint8 => address[]))) internal decBucketRoster;
    mapping(uint24 => mapping(uint8 => mapping(uint8 => uint256))) internal decBucketBurnTotal;
    mapping(uint24 => mapping(uint8 => mapping(uint8 => DecSubbucketTop))) internal decBucketTop;
    mapping(uint24 => mapping(uint8 => uint32)) internal decBucketFillCount;
    uint256 internal decBucketSeed;
    address internal decTopWinner;
    uint192 internal decTopBurn;

    // Active Decimator claim round by level.
    mapping(uint24 => DecClaimRound) internal decClaimRound;

    // Track whether a player has claimed their Decimator share for a level.
    mapping(uint24 => mapping(address => bool)) internal decClaimed;

    // Position of a player within the Decimator bucket roster for a given level.
    mapping(uint24 => mapping(address => uint32)) internal decBucketIndex;

    // Winning subbucket index per denominator for a level (derived during selection).
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
        uint192 prevBurn = e.burn;

        if (e.level != lvl) {
            e.level = lvl;
            e.burn = 0;
            e.bucket = bucket;
            e.subBucket = 0;
            _decPush(lvl, bucket, player, e);
        } else if (e.bucket == 0) {
            e.bucket = bucket;
            e.subBucket = 0;
            _decPush(lvl, bucket, player, e);
        }

        bucketUsed = e.bucket;

        uint256 updated = uint256(e.burn) + amount;
        if (updated > type(uint192).max) updated = type(uint192).max;
        e.burn = uint192(updated);

        uint192 delta = e.burn - prevBurn;
        if (delta != 0 && bucketUsed != 0) {
            _decUpdateSubbucket(lvl, bucketUsed, e.subBucket, delta, player, e.burn);
        }

        return bucketUsed;
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
        if (kind == 0) {
            return _runBafJackpot(poolWei, cap, lvl, rngWord);
        }
        if (kind == 1) {
            return _runDecimatorJackpot(poolWei, cap, lvl, rngWord);
        }
        if (!bafState.inProgress) revert InvalidKind();
        if (extMode == 1) {
            return _runBafJackpot(poolWei, cap, lvl, rngWord);
        }
        if (extMode == 2) {
            return _runDecimatorJackpot(poolWei, cap, lvl, rngWord);
        }
        revert InvalidKind();
    }

    function runBafJackpot(
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
        return _runBafJackpot(poolWei, cap, lvl, rngWord);
    }

    function runDecimatorJackpot(
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
        return _runDecimatorJackpot(poolWei, cap, lvl, rngWord);
    }

    function _runBafJackpot(
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    )
        private
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
        )
    {
        if (bafState.inProgress && extMode != 1) revert InvalidKind();

        uint32 batch = cap == 0 ? BAF_BATCH : cap;

        if (!bafState.inProgress) {
            bafState.inProgress = true;

            uint32 limit = uint32(bafScatterRoster[lvl].length);
            bs.offset = uint8(uint256(keccak256(abi.encode(rngWord, 1))) % 10);
            scanCursor = bs.offset;
            bs.limit = limit;

            bafState.totalPrizePoolWei = uint128(poolWei);
            bafState.returnAmountWei = 0;

            extVar = 0;
            extMode = 1;

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

        if (extMode != 1) revert InvalidKind();

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

    function _runDecimatorJackpot(
        uint256 poolWei,
        uint32 /*cap*/,
        uint24 lvl,
        uint256 rngWord
    )
        private
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
        )
    {
        if (bafState.inProgress && extMode != 2) revert InvalidKind();

        if (!bafState.inProgress) {
            bafState.inProgress = true;

            bs.offset = 0;
            scanCursor = 0;
            decBucketSeed = rngWord;
            decTopWinner = address(0);
            decTopBurn = 0;
            bs.limit = uint32(decPlayersCount[lvl]);

            bafState.totalPrizePoolWei = uint128(poolWei);
            bafState.returnAmountWei = 0;

            extVar = 0;
            extMode = 2;

            return (false, new address[](0), new uint256[](0), 0, 0);
        }

        if (extMode != 2) revert InvalidKind();

        uint256 totalBurn;
        decTopWinner = address(0);
        decTopBurn = 0;

        for (uint8 denom = 2; denom <= 20; ) {
            uint8 winningSub = _decWinningSubbucket(decBucketSeed, denom);
            decBucketOffset[lvl][denom] = winningSub;

            uint256 subTotal = decBucketBurnTotal[lvl][denom][winningSub];
            if (subTotal != 0) {
                totalBurn += subTotal;

                DecSubbucketTop storage top = decBucketTop[lvl][denom][winningSub];
                if (top.burn > decTopBurn) {
                    decTopBurn = top.burn;
                    decTopWinner = top.player;
                }
            }

            unchecked {
                ++denom;
            }
        }

        if (totalBurn == 0) {
            uint256 refund = uint256(bafState.totalPrizePoolWei);
            if (_hasDecPlaceholder(lvl)) {
                purgeGameTrophies.burnDecPlaceholder(lvl);
            }
            delete bafState;
            delete bs;
            extMode = 0;
            extVar = 0;
            decBucketSeed = 0;
            decTopWinner = address(0);
            decTopBurn = 0;
            scanCursor = SS_IDLE;
            return (true, new address[](0), new uint256[](0), 0, refund);
        }

        uint256 totalPool = uint256(bafState.totalPrizePoolWei);

        DecClaimRound storage round = decClaimRound[lvl];
        round.poolWei = totalPool;
        round.totalBurn = totalBurn;
        round.level = lvl;
        round.active = true;

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
        decBucketSeed = 0;
        decTopWinner = address(0);
        decTopBurn = 0;
        scanCursor = SS_IDLE;
        return (true, new address[](0), new uint256[](0), 0, 0);
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

    function _decWinningSubbucket(uint256 entropy, uint8 denom) private pure returns (uint8) {
        if (denom == 0) return 0;
        return uint8(uint256(keccak256(abi.encode(entropy, denom))) % denom);
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
        uint8 sub = e.subBucket;
        if (e.level != lvl || denom == 0 || e.burn == 0) return (0, false);

        address[] storage roster = decBucketRoster[lvl][denom][sub];
        uint256 idx = uint256(decBucketIndex[lvl][player]);
        if (idx >= roster.length || roster[idx] != player) return (0, false);

        uint8 winningSub = uint8(decBucketOffset[lvl][denom]);
        if (sub != winningSub) return (0, false);

        if (decBucketBurnTotal[lvl][denom][winningSub] == 0) return (0, false);

        amountWei = (round.poolWei * uint256(e.burn)) / round.totalBurn;
        winner = true;
    }

    function _decPush(uint24 lvl, uint8 bucket, address p, DecEntry storage e) internal {
        if (bucket == 0) return;

        uint32 cursor = decBucketFillCount[lvl][bucket];
        uint8 sub = uint8(cursor % bucket);
        decBucketFillCount[lvl][bucket] = cursor + 1;

        address[] storage subRoster = decBucketRoster[lvl][bucket][sub];
        decBucketIndex[lvl][p] = uint32(subRoster.length);
        subRoster.push(p);
        e.subBucket = sub;

        unchecked {
            decPlayersCount[lvl] = decPlayersCount[lvl] + 1;
        }
    }

    function _decUpdateSubbucket(
        uint24 lvl,
        uint8 denom,
        uint8 sub,
        uint192 delta,
        address player,
        uint192 updatedBurn
    ) internal {
        if (delta == 0 || denom == 0) return;
        decBucketBurnTotal[lvl][denom][sub] += uint256(delta);
        DecSubbucketTop storage top = decBucketTop[lvl][denom][sub];
        if (updatedBurn > top.burn) {
            top.burn = updatedBurn;
            top.player = player;
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

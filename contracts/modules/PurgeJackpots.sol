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
    function bonds() external view returns (address);
}

interface IPurgeBonds {
    function sampleBondOwner(uint256 entropy) external view returns (uint256 tokenId, address owner);
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
    error AlreadyWired();
    error OnlyCoin();
    error OnlyGame();

    struct PlayerScore {
        address player;
        uint96 score;
    }

    function _recentLevel(uint24 lvl, uint256 entropy) private pure returns (uint24) {
        uint256 offset = (entropy % 20) + 1; // 1..20
        if (lvl > offset) {
            return lvl - uint24(offset);
        }
        return 0;
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
    mapping(address => DecEntry) internal decBurn;

    // Decimator bucketed rosters and aggregates
    mapping(uint24 => mapping(uint8 => mapping(uint8 => address[]))) internal decBucketRoster;
    mapping(uint24 => mapping(uint8 => mapping(uint8 => uint256))) internal decBucketBurnTotal;
    mapping(uint24 => mapping(uint8 => mapping(uint8 => DecSubbucketTop))) internal decBucketTop;
    mapping(uint24 => mapping(uint8 => uint32)) internal decBucketFillCount;
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
        if (kind == 0) return _runBafJackpot(poolWei, cap, lvl, rngWord);
        if (kind == 1) return _runDecimatorJackpot(poolWei, cap, lvl, rngWord);
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
        uint256 P = poolWei;
        address[] memory tmpW = new address[](140);
        uint256[] memory tmpA = new uint256[](140);
        uint256 n;
        uint256 toReturn;
        bool trophyAwarded;
        address bondsAddr = coin.bonds();

        uint256 entropy = rngWord;
        uint256 salt;

        {
            uint256 prize = P / 10;

            (address w, ) = _bafTop(lvl, 0);
            if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
                unchecked {
                    ++n;
                }
            } else {
                toReturn += prize;
            }

            uint256 trophyPrize = P / 10;
            if (w != address(0) && _eligible(w)) {
                uint256 trophyData = (uint256(BAF_TRAIT_SENTINEL) << 152) |
                    (uint256(lvl) << TROPHY_BASE_LEVEL_SHIFT) |
                    TROPHY_FLAG_BAF;
                purgeGameTrophies.awardTrophy(w, lvl, PURGE_TROPHY_KIND_BAF, trophyData, trophyPrize);
                trophyAwarded = true;
            } else {
                toReturn += trophyPrize;
            }
        }

        {
            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
            uint256 prize = P / 10;
            uint8 pick = 2 + uint8(entropy & 1);
            (address w, ) = _bafTop(lvl, pick);
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
                (uint256 idA, address ownerA) = purgeGameTrophies.stakedTrophySampleWithId(entropy);

                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                (uint256 idB, address ownerB) = purgeGameTrophies.stakedTrophySampleWithId(entropy);

                bool validA = idA != 0 && ownerA != address(0);
                bool validB = idB != 0 && ownerB != address(0);

                if (validA && validB) {
                    if (idA <= idB) {
                        trophyIds[s] = idA;
                        trophyOwners[s] = ownerA;
                    } else {
                        trophyIds[s] = idB;
                        trophyOwners[s] = ownerB;
                    }
                } else if (validA) {
                    trophyIds[s] = idA;
                    trophyOwners[s] = ownerA;
                } else if (validB) {
                    trophyIds[s] = idB;
                    trophyOwners[s] = ownerB;
                }
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
            trophyPoolDelta = trophyDelta;
        }

        {
            uint256 bondSlice = P / 10;
            uint256[4] memory bondPrizes = [(bondSlice * 5) / 10, (bondSlice * 3) / 10, (bondSlice * 2) / 10, uint256(0)];

            if (bondsAddr != address(0)) {
                IPurgeBonds bonds = IPurgeBonds(bondsAddr);
                for (uint8 s; s < 4; ) {
                    unchecked {
                        ++salt;
                    }
                    entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                    (uint256 idA, address ownerA) = bonds.sampleBondOwner(entropy);

                    unchecked {
                        ++salt;
                    }
                    entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                    (uint256 idB, address ownerB) = bonds.sampleBondOwner(entropy);

                    bool validA = idA != 0 && ownerA != address(0);
                    bool validB = idB != 0 && ownerB != address(0);
                    address chosenOwner;

                    if (validA && validB) {
                        chosenOwner = (idA <= idB) ? ownerA : ownerB;
                    } else if (validA) {
                        chosenOwner = ownerA;
                    } else if (validB) {
                        chosenOwner = ownerB;
                    }

                    uint256 prize = bondPrizes[s];
                    bool credited;
                    if (prize != 0 && chosenOwner != address(0) && _eligible(chosenOwner)) {
                        credited = _creditOrRefund(chosenOwner, prize, tmpW, tmpA, n);
                    }
                    if (credited) {
                        unchecked {
                            ++n;
                        }
                    } else if (prize != 0) {
                        toReturn += prize;
                    }
                    unchecked {
                        ++s;
                    }
                }
            } else {
                toReturn += bondSlice;
            }
        }

        {
            uint256 slice = P / 10;
            uint256[4] memory prizes = [(slice * 5) / 10, (slice * 3) / 10, (slice * 2) / 10, uint256(0)];

            for (uint8 s; s < 4; ) {
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint24 lvlA = _recentLevel(lvl, entropy);
                (address candA, ) = coin.coinflipTop(lvlA);

                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint24 lvlB = _recentLevel(lvl, entropy);
                (address candB, ) = coin.coinflipTop(lvlB);

                address chosen;
                bool validA = candA != address(0);
                bool validB = candB != address(0);
                if (validA && validB) {
                    chosen = (lvlA <= lvlB) ? candA : candB;
                } else if (validA) {
                    chosen = candA;
                } else if (validB) {
                    chosen = candB;
                }

                uint256 prize = prizes[s];
                bool credited;
                if (prize != 0 && chosen != address(0) && _eligible(chosen)) {
                    credited = _creditOrRefund(chosen, prize, tmpW, tmpA, n);
                }
                if (credited) {
                    unchecked {
                        ++n;
                    }
                } else if (prize != 0) {
                    toReturn += prize;
                }
                unchecked {
                    ++s;
                }
            }
        }

        // Scatter slice: pay up to 100 sampled trait tickets immediately (no batching/claims).
        {
            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
            uint256 scatter = (P * 2) / 5;
            (, , address[] memory tickets) = purgeGame.sampleTraitTickets(entropy);

            uint256 eligibleCount;
            uint256 tLen = tickets.length;
            for (uint256 i; i < tLen; ) {
                if (_eligible(tickets[i])) {
                    unchecked {
                        ++eligibleCount;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            if (eligibleCount == 0) {
                toReturn += scatter;
            } else {
                uint256 perWei = scatter / eligibleCount;
                uint256 rem = scatter - perWei * eligibleCount;
                toReturn += rem;
                for (uint256 i; i < tLen; ) {
                    address cand = tickets[i];
                    if (perWei != 0 && _eligible(cand)) {
                        if (_creditOrRefund(cand, perWei, tmpW, tmpA, n)) {
                            unchecked {
                                ++n;
                            }
                        } else {
                            toReturn += perWei;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
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

        _clearBafTop(lvl);
        return (true, winners, amounts, trophyPoolDelta, toReturn);
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
        uint256 totalBurn;
        decTopWinner = address(0);
        decTopBurn = 0;

        uint256 decSeed = rngWord;
        for (uint8 denom = 2; denom <= 20; ) {
            uint8 winningSub = _decWinningSubbucket(decSeed, denom);
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
            uint256 refund = poolWei;
            if (_hasDecPlaceholder(lvl)) {
                purgeGameTrophies.burnDecPlaceholder(lvl);
            }
            decTopWinner = address(0);
            decTopBurn = 0;
            return (true, new address[](0), new uint256[](0), 0, refund);
        }

        uint256 totalPool = poolWei;

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

        decTopWinner = address(0);
        decTopBurn = 0;
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

    function decClaimable(address player, uint24 lvl) external view override returns (uint256 amountWei, bool winner) {
        DecClaimRound storage round = decClaimRound[lvl];
        return _decClaimable(round, player, lvl);
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

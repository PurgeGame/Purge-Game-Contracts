// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeAffiliate} from "./interfaces/IPurgeAffiliate.sol";
import {IPurgeGameTrophies} from "./PurgeGameTrophies.sol";
import {IPurgeJackpots} from "./interfaces/IPurgeJackpots.sol";
import {PurgeGameExternalOp} from "./interfaces/IPurgeGameExternal.sol";

interface IPurgeCoinJackpotView {
    function coinflipAmount(address player) external view returns (uint256);
    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score);
    function affiliateProgram() external view returns (address);
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
    error OnlyBonds();
    error OnlyCoin();
    error OnlyGame();

    // Leaderboard entry for BAF coinflip stakes.
    struct PlayerScore {
        address player;
        uint96 score;
    }

    // Track per-player BAF totals within an active level (derived from manual flip deltas).
    struct BafEntry {
        uint256 total; // total manual flips this BAF level
        uint24 level;
    }

    // Sample a recent level (last 20) to bias retro prizes toward fresh play.
    function _recentLevel(uint24 lvl, uint256 entropy) private pure returns (uint24) {
        uint256 offset = (entropy % 20) + 1; // 1..20
        if (lvl > offset) {
            return lvl - uint24(offset);
        }
        return 0;
    }

    // Per-player Decimator burn tracking for the active level.
    struct DecEntry {
        uint192 burn;
        uint24 level;
        uint8 bucket;
        uint8 subBucket;
    }

    // Snapshot of a Decimator claim round for a level.
    struct DecClaimRound {
        uint256 poolWei;
        uint256 totalBurn;
        uint24 level;
        bool active;
    }

    // Leading contributor inside a subbucket (used to pick the trophy owner).
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
    mapping(address => BafEntry) internal bafTotals;
    // Track Decimator burns per level so earlier levels remain claimable after a player participates in later ones.
    mapping(uint24 => mapping(address => DecEntry)) internal decBurn;

    // Decimator aggregates
    mapping(uint24 => mapping(uint8 => mapping(uint8 => uint256))) internal decBucketBurnTotal;
    mapping(uint24 => mapping(uint8 => mapping(uint8 => DecSubbucketTop))) internal decBucketTop;

    // Active Decimator claim round by level.
    mapping(uint24 => DecClaimRound) internal decClaimRound;

    // Track whether a player has claimed their Decimator share for a level.
    mapping(uint24 => mapping(address => bool)) internal decClaimed;

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

    address public immutable bonds;

    constructor(address bonds_) {
        if (bonds_ == address(0)) revert OnlyBonds();
        bonds = bonds_;
    }

    /// @notice One-time wiring using address array ([coin, game, trophies]); callable only by bonds.
    function wire(address[] calldata addresses) external override {
        if (msg.sender != bonds) revert OnlyBonds();

        _setCoin(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setTrophies(addresses.length > 2 ? addresses[2] : address(0));
    }

    function _setCoin(address coinAddr) private {
        if (coinAddr == address(0)) return;
        address current = address(coin);
        if (current == address(0)) {
            coin = IPurgeCoinJackpotView(coinAddr);
        } else if (coinAddr != current) {
            revert AlreadyWired();
        }
    }

    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(purgeGame);
        if (current == address(0)) {
            purgeGame = IPurgeGame(gameAddr);
        } else if (gameAddr != current) {
            revert AlreadyWired();
        }
    }

    function _setTrophies(address trophiesAddr) private {
        if (trophiesAddr == address(0)) return;
        address current = address(purgeGameTrophies);
        if (current == address(0)) {
            purgeGameTrophies = IPurgeGameTrophies(trophiesAddr);
        } else if (trophiesAddr != current) {
            revert AlreadyWired();
        }
    }

    // ---------------------------------------------------------------------
    // Hooks from Purgecoin
    // ---------------------------------------------------------------------
    /// @dev Track leaderboard state for BAF using total manual flips during the BAF period.
    /// @param amount The newly added flip amount to credit for this level.
    function recordBafFlip(address player, uint24 lvl, uint256 amount) external override onlyCoin {
        BafEntry storage entry = bafTotals[player];
        if (entry.level != lvl) {
            entry.level = lvl;
            entry.total = 0;
        }
        if (amount == 0) return;
        unchecked {
            entry.total += amount;
        }
        _updateBafTop(lvl, player, entry.total);
    }

    /// @dev Register Decimator burns and bucket placement for a player in a level.
    function recordDecBurn(
        address player,
        uint24 lvl,
        uint8 bucket,
        uint256 amount
    ) external override onlyCoin returns (uint8 bucketUsed) {
        DecEntry storage e = decBurn[lvl][player];
        uint192 prevBurn = e.burn;

        if (e.level != lvl) {
            e.level = lvl;
            e.burn = 0;
            e.bucket = bucket;
            e.subBucket = _decSubbucketFor(player, lvl, bucket);
        } else if (e.bucket == 0) {
            e.bucket = bucket;
            e.subBucket = _decSubbucketFor(player, lvl, bucket);
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
    /**
     * @notice Resolve the BAF jackpot for a level.
     * @dev Pool split (percent of `poolWei`): 10% top bettor + 10% BAF trophy, 10% random pick
     *      between 3rd/4th leaderboard slots, 10% affiliate draw (top referrers from prior 20 levels),
     *      10% retro tops (recent levels), 7%/3% scatter buckets from trait tickets, 5/3/2% to
     *      staked trophy owners. Any unfilled shares are refunded to the caller via `returnAmountWei`.
     */
    function runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        override
        onlyGame
        returns (
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
    )
    {
        uint256 P = poolWei;
        // Max distinct winners: 1 (top) + 1 (pick) + 4 (affiliate draw) + 3 (retro) + 50 + 50 (scatter buckets) = 109.
        address[] memory tmpW = new address[](112);
        uint256[] memory tmpA = new uint256[](112);
        uint256 n;
        uint256 toReturn;
        bool trophyAwarded;

        uint256 entropy = rngWord;
        uint256 salt;

        {
            // Slice A: top bettor (10%) and BAF trophy (10%) follow the level's leading flip volume.
            uint256 prize = P / 10;

            (address w, ) = _bafTop(lvl, 0);
            // 10% to the top coinflip bettor (if eligible).
            uint256 s0 = _bafScore(w, lvl);
            if (_creditOrRefund(w, prize, tmpW, tmpA, n, s0, true)) {
                unchecked {
                    ++n;
                }
            } else {
                toReturn += prize;
            }

            uint256 trophyPrize = P / 10;
            if (w != address(0) && _eligible(w, s0, true)) {
                // Award BAF trophy + prize to the top bettor if they remain eligible.
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
            // Slice B: 10% to either the 3rd or 4th leaderboard slot (pseudo-random tie-break).
            uint256 sPick = _bafScore(w, lvl);
            if (_creditOrRefund(w, prize, tmpW, tmpA, n, sPick, true)) {
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
            // Staked trophy rewards: sample tickets twice per slot, pick the lower id, then sort
            // the candidates by coinflip size to prefer higher current bettors.
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

            // Sort trophies by owner BAF score
            for (uint8 i; i < 4; ) {
                uint8 bestIdx = i;
                uint256 best = _bafScore(trophyOwners[i], lvl);
                for (uint8 j = i + 1; j < 4; ) {
                    uint256 val = _bafScore(trophyOwners[j], lvl);
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
                bool eligibleOwner = tokenId != 0 && owner != address(0) && _eligible(owner, 0, false);
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
            // Slice C: affiliate achievers (past 20 levels) share 10% across four descending prizes.
            uint256[4] memory affiliatePrizes = [(P * 5) / 100, (P * 3) / 100, (P * 2) / 100, uint256(0)];
            uint256 affiliateSlice;
            unchecked {
                affiliateSlice = affiliatePrizes[0] + affiliatePrizes[1] + affiliatePrizes[2] + affiliatePrizes[3];
            }

            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));

            address affiliateAddr = coin.affiliateProgram();
            if (affiliateAddr == address(0)) {
                toReturn += affiliateSlice;
            } else {
                IPurgeAffiliate affiliate = IPurgeAffiliate(affiliateAddr);
                address[20] memory candidates;
                uint256[20] memory candidateScores;
                uint8 candidateCount;

                // Collect the top affiliate from each of the prior 20 levels (deduped).
                for (uint8 offset = 1; offset <= 20; ) {
                    if (lvl <= offset) break;
                    (address player, ) = affiliate.affiliateTop(uint24(lvl - offset));
                    if (player != address(0)) {
                        bool seen;
                        for (uint8 i; i < candidateCount; ) {
                            if (candidates[i] == player) {
                                seen = true;
                                break;
                            }
                            unchecked {
                                ++i;
                            }
                        }
                        if (!seen) {
                            candidates[candidateCount] = player;
                            candidateScores[candidateCount] = _bafScore(player, lvl);
                            unchecked {
                                ++candidateCount;
                            }
                        }
                    }
                    unchecked {
                        ++offset;
                    }
                }

                // Shuffle candidate order to randomize draws.
                for (uint8 i = candidateCount; i > 1; ) {
                    unchecked {
                        ++salt;
                    }
                    entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                    uint256 j = entropy % i;
                    uint8 idxA = i - 1;
                    address addrTmp = candidates[idxA];
                    candidates[idxA] = candidates[j];
                    candidates[j] = addrTmp;
                    uint256 scoreTmp = candidateScores[idxA];
                    candidateScores[idxA] = candidateScores[j];
                    candidateScores[j] = scoreTmp;
                    unchecked {
                        --i;
                    }
                }

                address[4] memory affiliateWinners;
                uint256[4] memory affiliateScores;
                uint8 winnerCount;

                for (uint8 i; i < candidateCount && winnerCount < 4; ) {
                    address cand = candidates[i];
                    uint256 scoreHint = candidateScores[i];
                    if (cand != address(0) && _eligible(cand, scoreHint, true)) {
                        affiliateWinners[winnerCount] = cand;
                        affiliateScores[winnerCount] = scoreHint;
                        unchecked {
                            ++winnerCount;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }

                if (winnerCount < 3) {
                    toReturn += affiliateSlice;
                } else {
                    // Sort by BAF score so higher scores take the larger cuts (5/3/2/0%).
                    for (uint8 i; i < winnerCount; ) {
                        uint8 bestIdx = i;
                        for (uint8 j = i + 1; j < winnerCount; ) {
                            if (affiliateScores[j] > affiliateScores[bestIdx]) {
                                bestIdx = j;
                            }
                            unchecked {
                                ++j;
                            }
                        }
                        if (bestIdx != i) {
                            address wTmp = affiliateWinners[i];
                            affiliateWinners[i] = affiliateWinners[bestIdx];
                            affiliateWinners[bestIdx] = wTmp;
                            uint256 sTmp = affiliateScores[i];
                            affiliateScores[i] = affiliateScores[bestIdx];
                            affiliateScores[bestIdx] = sTmp;
                        }
                        unchecked {
                            ++i;
                        }
                    }

                    uint256 paid;
                    uint8 maxWinners = winnerCount;
                    if (maxWinners > 4) {
                        maxWinners = 4;
                    }
                    for (uint8 i; i < maxWinners; ) {
                        uint256 prize = affiliatePrizes[i];
                        paid += prize;
                        if (prize != 0) {
                            tmpW[n] = affiliateWinners[i];
                            tmpA[n] = prize;
                            unchecked {
                                ++n;
                            }
                        }
                        unchecked {
                            ++i;
                        }
                    }
                    if (paid < affiliateSlice) {
                        toReturn += affiliateSlice - paid;
                    }
                }
            }
        }

        {
            uint256 slice = P / 10;
            uint256[4] memory prizes = [(slice * 5) / 10, (slice * 3) / 10, (slice * 2) / 10, uint256(0)];

            for (uint8 s; s < 4; ) {
                // Slice D: retro top bettors — sample recent levels to bias toward fresh play (10% total).
                // Retro top rewards: sample two recent levels (1..20 back) and pick the lower level.
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint24 lvlA = _recentLevel(lvl, entropy);
                (address candA, uint96 scoreA) = coin.coinflipTop(lvlA);

                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint24 lvlB = _recentLevel(lvl, entropy);
                (address candB, uint96 scoreB) = coin.coinflipTop(lvlB);

                address chosen;
                uint256 chosenScore;
                bool validA = candA != address(0);
                bool validB = candB != address(0);
                if (validA && validB) {
                    if (lvlA <= lvlB) {
                        chosen = candA;
                        chosenScore = uint256(scoreA) * MILLION;
                    } else {
                        chosen = candB;
                        chosenScore = uint256(scoreB) * MILLION;
                    }
                } else if (validA) {
                    chosen = candA;
                    chosenScore = uint256(scoreA) * MILLION;
                } else if (validB) {
                    chosen = candB;
                    chosenScore = uint256(scoreB) * MILLION;
                }

                uint256 prize = prizes[s];
                bool credited;
                if (prize != 0 && chosen != address(0) && _eligible(chosen, chosenScore, true)) {
                    credited = _creditOrRefund(chosen, prize, tmpW, tmpA, n, chosenScore, true);
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

        // Scatter slice: 200 total draws (4 tickets * 50 rounds). Per round, take top-2 by BAF score.
        // First bucket splits 7% evenly (max 50 winners); second bucket splits 3% evenly (max 50 winners).
        {
            // Slice E: scatter tickets from trait sampler so casual participants can land smaller cuts.
            uint256 scatterTop = (P * 7) / 100;
            uint256 scatterSecond = (P * 3) / 100;
            address[50] memory firstWinners;
            address[50] memory secondWinners;
            uint256 firstCount;
            uint256 secondCount;

            // 50 rounds of 4-ticket sampling (total 200 tickets).
            for (uint8 round; round < 50; ) {
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                (, , address[] memory tickets) = purgeGame.sampleTraitTickets(entropy);

                // Pick up to 4 tickets from the sampled set.
                uint256 limit = tickets.length;
                if (limit > 4) limit = 4;

                address best;
                uint256 bestScore;
                address second;
                uint256 secondScore;

                for (uint256 i; i < limit; ) {
                    address cand = tickets[i];
                    if (cand != address(0)) {
                        uint256 score = _bafScore(cand, lvl);
                        if (score > bestScore) {
                            second = best;
                            secondScore = bestScore;
                            best = cand;
                            bestScore = score;
                        } else if (score > secondScore && cand != best) {
                            second = cand;
                            secondScore = score;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }

                // Bucket winners if eligible and capacity not exceeded; otherwise refund their would-be share later.
                if (best != address(0) && firstCount < 50 && _eligible(best, bestScore, true)) {
                    firstWinners[firstCount] = best;
                    unchecked {
                        ++firstCount;
                    }
                }
                if (second != address(0) && secondCount < 50 && _eligible(second, secondScore, true)) {
                    secondWinners[secondCount] = second;
                    unchecked {
                        ++secondCount;
                    }
                }

                unchecked {
                    ++round;
                }
            }

            if (firstCount == 0) {
                toReturn += scatterTop;
            } else {
                uint256 per = scatterTop / firstCount;
                uint256 rem = scatterTop - per * firstCount;
                toReturn += rem;
                for (uint256 i; i < firstCount; ) {
                    uint256 scoreHint = _bafScore(firstWinners[i], lvl);
                    if (per != 0 && _creditOrRefund(firstWinners[i], per, tmpW, tmpA, n, scoreHint, true)) {
                        unchecked {
                            ++n;
                        }
                    } else {
                        toReturn += per;
                    }
                    unchecked {
                        ++i;
                    }
                }
            }

            if (secondCount == 0) {
                toReturn += scatterSecond;
            } else {
                uint256 per2 = scatterSecond / secondCount;
                uint256 rem2 = scatterSecond - per2 * secondCount;
                toReturn += rem2;
                for (uint256 i; i < secondCount; ) {
                    uint256 scoreHint = _bafScore(secondWinners[i], lvl);
                    if (per2 != 0 && _creditOrRefund(secondWinners[i], per2, tmpW, tmpA, n, scoreHint, true)) {
                        unchecked {
                            ++n;
                        }
                    } else {
                        toReturn += per2;
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
        }

        if (!trophyAwarded) {
            // Clear placeholder if no BAF trophy was minted.
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
        return (winners, amounts, trophyPoolDelta, toReturn);
    }

    function runDecimatorJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        override
        onlyGame
        returns (uint256 trophyPoolDelta, uint256 returnAmountWei)
    {
        // Decimator jackpots defer ETH distribution to per-player claims; this call snapshots winners.
        uint256 totalBurn;
        // Track provisional trophy winner among winning subbuckets across all denominators.
        address decTopWinner;
        uint192 decTopBurn;
        bool hasPlaceholder = _hasDecPlaceholder(lvl);

        uint256 decSeed = rngWord;
        for (uint8 denom = 2; denom <= 20; ) {
            // Pick a random winning subbucket for each denominator and accumulate its burn total.
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
            // No eligible burns: clear any placeholder and refund the whole pool.
            if (_hasDecPlaceholder(lvl)) {
                purgeGameTrophies.burnDecPlaceholder(lvl);
            }
            return (0, refund);
        }

        uint256 claimPool = poolWei;
        uint256 trophyPrize;
        if (hasPlaceholder && decTopWinner != address(0)) {
            trophyPrize = poolWei / 20; // 5% of Decimator pool reserved for the trophy owner
            claimPool = poolWei - trophyPrize;
        }

        DecClaimRound storage round = decClaimRound[lvl];
        round.poolWei = claimPool;
        round.totalBurn = totalBurn;
        round.level = lvl;
        round.active = true;

        if (hasPlaceholder) {
            if (decTopWinner != address(0)) {
                // Trophy follows the largest burn within the winning subbuckets.
                uint256 trophyData = (uint256(DECIMATOR_TRAIT_SENTINEL) << 152) |
                    (uint256(lvl) << TROPHY_BASE_LEVEL_SHIFT) |
                    TROPHY_FLAG_DECIMATOR;
                purgeGameTrophies.awardTrophy(decTopWinner, lvl, PURGE_TROPHY_KIND_DECIMATOR, trophyData, trophyPrize);
                trophyPoolDelta = trophyPrize;
            } else {
                purgeGameTrophies.burnDecPlaceholder(lvl);
            }
        }
        return (trophyPoolDelta, 0);
    }

    // ---------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------
    /// @dev Validate and mark a Decimator claim; returns the pro-rata payout.
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
    // Eligibility gate reused across jackpot slices; accepts optional coinflip score hint to save a read.
    function _eligible(address player, uint256 scoreHint, bool hasHint) internal view returns (bool) {
        uint256 score = hasHint ? scoreHint : coin.coinflipAmount(player);
        if (score < 5_000 * MILLION) return false;
        // Require at least a 6-level ETH mint streak to ensure winners are active players.
        return purgeGame.ethMintStreakCount(player) >= 6;
    }

    function _creditOrRefund(
        address candidate,
        uint256 prize,
        address[] memory winnersBuf,
        uint256[] memory amountsBuf,
        uint256 idx,
        uint256 scoreHint,
        bool hasHint
    ) private view returns (bool credited) {
        if (prize == 0) return false;
        // Writes into the preallocated buffers; caller controls idx and increments only on success.
        if (candidate != address(0) && _eligible(candidate, scoreHint, hasHint)) {
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

        DecEntry storage e = decBurn[lvl][player];
        uint8 denom = e.bucket;
        uint8 sub = e.subBucket;
        if (e.level != lvl || denom == 0 || e.burn == 0) return (0, false);

        uint8 winningSub = uint8(decBucketOffset[lvl][denom]);
        if (sub != winningSub) return (0, false);

        if (decBucketBurnTotal[lvl][denom][winningSub] == 0) return (0, false);

        // Pro-rata share of the Decimator pool based on the burn inside the winning subbucket.
        amountWei = (round.poolWei * uint256(e.burn)) / round.totalBurn;
        winner = true;
    }

    // Update aggregated burn totals for a subbucket and track the leading burner.
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

    function _decSubbucketFor(address player, uint24 lvl, uint8 bucket) private pure returns (uint8) {
        if (bucket == 0) return 0;
        return uint8(uint256(keccak256(abi.encodePacked(player, lvl, bucket))) % bucket);
    }

    function _bafScore(address player, uint24 lvl) private view returns (uint256) {
        BafEntry storage e = bafTotals[player];
        if (e.level != lvl) return 0;
        return e.total;
    }

    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    // Maintain the top-4 BAF leaderboard (largest coinflip stake first, stable length).
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

    // Clear leaderboard state for a level after jackpot resolution.
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

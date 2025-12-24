// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";
import {IDegenerusAffiliate} from "./interfaces/IDegenerusAffiliate.sol";
import {IDegenerusJackpots} from "./interfaces/IDegenerusJackpots.sol";
import {DegenerusGameExternalOp} from "./interfaces/IDegenerusGameExternal.sol";

interface IDegenerusCoinJackpotView {
    function coinflipAmountLastDay(address player) external view returns (uint256);
    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score);
    function coinflipTopLastDay() external view returns (address player, uint96 score);
}

/**
 * @title DegenerusJackpots
 * @notice Standalone contract that owns BAF/Decimator jackpot state and claim logic.
 *         DegenerusCoin forwards flips/burns into this contract and calls it to resolve jackpots.
 */
contract DegenerusJackpots is IDegenerusJackpots {
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

    // Leading contributor inside a subbucket (used to pick the subbucket winner).
    struct DecSubbucketTop {
        address player;
        uint192 burn;
    }

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------
    IDegenerusCoinJackpotView public coin;
    IDegenerusGame public degenerusGame;
    address private affiliate;
    address public immutable bondsAdmin;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6;
    uint256 private constant BAF_SCATTER_MASK_OFFSET = 128;
    uint8 private constant BAF_SCATTER_BOND_WINNERS = 40;
    uint8 private constant DECIMATOR_MAX_DENOM = 10;

    // ---------------------------------------------------------------------
    // BAF / Decimator state (lives here; DegenerusCoin storage is unaffected)
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
        if (msg.sender != address(degenerusGame)) revert OnlyGame();
        _;
    }

    address public immutable bonds;

    constructor(address bonds_, address bondsAdmin_) {
        if (bonds_ == address(0) || bondsAdmin_ == address(0)) revert OnlyBonds();
        bonds = bonds_;
        bondsAdmin = bondsAdmin_;
    }

    /// @notice One-time wiring using address array ([coin, game, affiliate]); callable only by bonds.
    function wire(address[] calldata addresses) external override {
        address admin = bondsAdmin;
        if (msg.sender != bonds && msg.sender != admin) revert OnlyBonds();

        _setCoin(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setAffiliate(addresses.length > 2 ? addresses[2] : address(0));
    }

    function _setCoin(address coinAddr) private {
        if (coinAddr == address(0)) return;
        address current = address(coin);
        if (current == address(0)) {
            coin = IDegenerusCoinJackpotView(coinAddr);
        } else if (coinAddr != current) {
            revert AlreadyWired();
        }
    }

    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(degenerusGame);
        if (current == address(0)) {
            degenerusGame = IDegenerusGame(gameAddr);
        } else if (gameAddr != current) {
            revert AlreadyWired();
        }
    }

    function _setAffiliate(address affiliateAddr) private {
        if (affiliateAddr == address(0)) return;
        address current = affiliate;
        if (current == address(0)) {
            affiliate = affiliateAddr;
        } else if (affiliateAddr != current) {
            revert AlreadyWired();
        }
    }

    // ---------------------------------------------------------------------
    // Hooks from DegenerusCoin
    // ---------------------------------------------------------------------
    /// @dev Track leaderboard state for BAF using multiplier-weighted flips during the BAF period.
    /// @param amount The newly added flip amount to credit for this level.
    function recordBafFlip(address player, uint24 lvl, uint256 amount) external override onlyCoin {
        BafEntry storage entry = bafTotals[player];
        if (entry.level != lvl) {
            entry.level = lvl;
            entry.total = 0;
        }
        uint256 multBps = degenerusGame.bondMultiplierBps(player);
        uint256 weighted = (amount * multBps) / 10000;
        unchecked {
            entry.total += weighted;
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
        if (delta != 0) {
            _decUpdateSubbucket(lvl, bucketUsed, e.subBucket, delta, player, e.burn);
        }

        return bucketUsed;
    }

    // ---------------------------------------------------------------------
    // External jackpot logic
    // ---------------------------------------------------------------------
    /**
     * @notice Resolve the BAF jackpot for a level.
     * @dev Pool split (percent of `poolWei`): 10% top BAF bettor, 10% top flip from the last day window,
     *      5% random pick between 3rd/4th BAF leaderboard slots, 10% exterminator draw (prior 20 levels),
     *      10% affiliate draw (top referrers from prior 20 levels), 10% retro tops (recent levels),
     *      20%/25% scatter buckets from trait tickets. `bondMask` encodes top-bond winners and the tail scatter winners
     *      that get special handling (map/bond split) in the game.
     *      Any unfilled shares are refunded to the caller via `returnAmountWei`.
     */
    function runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        override
        onlyGame
        returns (address[] memory winners, uint256[] memory amounts, uint256 bondMask, uint256 returnAmountWei)
    {
        uint256 P = poolWei;
        // Max distinct winners: 1 (top BAF) + 1 (top flip) + 1 (pick) + 4 (exterminator draw) + 4 (affiliate draw) + 3 (retro) + 50 + 50 (scatter buckets) = 114.
        address[] memory tmpW = new address[](120);
        uint256[] memory tmpA = new uint256[](120);
        uint256 n;
        uint256 toReturn;
        uint256 mask;

        uint256 entropy = rngWord;
        uint256 salt;

        {
            // Slice A: 10% to the top BAF bettor for the level.
            uint256 topPrize = P / 10;
            (address w, ) = _bafTop(lvl, 0);
            if (_creditOrRefund(w, topPrize, tmpW, tmpA, n)) {
                mask |= (uint256(1) << n);
                unchecked {
                    ++n;
                }
            } else {
                toReturn += topPrize;
            }
        }

        {
            // Slice A2: 10% to the top coinflip bettor from the last day window.
            uint256 topPrize = P / 10;
            (address w, ) = coin.coinflipTopLastDay();
            if (_creditOrRefund(w, topPrize, tmpW, tmpA, n)) {
                mask |= (uint256(1) << n);
                unchecked {
                    ++n;
                }
            } else {
                toReturn += topPrize;
            }
        }

        {
            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
            uint256 prize = P / 20;
            uint8 pick = 2 + uint8(entropy & 1);
            (address w, ) = _bafTop(lvl, pick);
            // Slice B: 5% to either the 3rd or 4th BAF leaderboard slot (pseudo-random tie-break).
            if (_creditOrRefund(w, prize, tmpW, tmpA, n)) {
                mask |= (uint256(1) << n);
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
            // Slice B2: exterminator achievers (past 20 levels) share 10% across four descending prizes (5/3/2/0%).
            uint256[4] memory exPrizes = [(P * 5) / 100, (P * 3) / 100, (P * 2) / 100, uint256(0)];
            uint256 exterminatorSlice;
            unchecked {
                exterminatorSlice = exPrizes[0] + exPrizes[1] + exPrizes[2];
            }

            unchecked {
                ++salt;
            }
            entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));

            address[20] memory exCandidates;
            uint256[20] memory exScores;
            uint8 exCount;

            // Collect exterminators from each of the prior 20 levels (deduped).
            for (uint8 offset = 1; offset <= 20; ) {
                if (lvl <= offset) break;
                address ex = degenerusGame.levelExterminator(uint24(lvl - offset));
                if (ex != address(0)) {
                    bool seen;
                    for (uint8 i; i < exCount; ) {
                        if (exCandidates[i] == ex) {
                            seen = true;
                            break;
                        }
                        unchecked {
                            ++i;
                        }
                    }
                    if (!seen) {
                        exCandidates[exCount] = ex;
                        exScores[exCount] = _bafScore(ex, lvl);
                        unchecked {
                            ++exCount;
                        }
                    }
                }
                unchecked {
                    ++offset;
                }
            }

            // Shuffle candidate order to randomize draws.
            for (uint8 i = exCount; i > 1; ) {
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                uint256 j = entropy % i;
                uint8 idxA = i - 1;
                address addrTmp = exCandidates[idxA];
                exCandidates[idxA] = exCandidates[j];
                exCandidates[j] = addrTmp;
                uint256 scoreTmp = exScores[idxA];
                exScores[idxA] = exScores[j];
                exScores[j] = scoreTmp;
                unchecked {
                    --i;
                }
            }

            address[4] memory exWinners;
            uint256[4] memory exWinnerScores;
            uint8 exWinCount;

            for (uint8 i; i < exCount && exWinCount < 4; ) {
                address cand = exCandidates[i];
                if (_eligible(cand)) {
                    exWinners[exWinCount] = cand;
                    exWinnerScores[exWinCount] = exScores[i];
                    unchecked {
                        ++exWinCount;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            if (exWinCount == 0) {
                toReturn += exterminatorSlice;
            } else {
                // Sort by BAF score so higher scores take the larger cuts (5/3/2/0%).
                for (uint8 i; i < exWinCount; ) {
                    uint8 bestIdx = i;
                    for (uint8 j = i + 1; j < exWinCount; ) {
                        if (exWinnerScores[j] > exWinnerScores[bestIdx]) {
                            bestIdx = j;
                        }
                        unchecked {
                            ++j;
                        }
                    }
                    if (bestIdx != i) {
                        address wTmp = exWinners[i];
                        exWinners[i] = exWinners[bestIdx];
                        exWinners[bestIdx] = wTmp;
                        uint256 sTmp = exWinnerScores[i];
                        exWinnerScores[i] = exWinnerScores[bestIdx];
                        exWinnerScores[bestIdx] = sTmp;
                    }
                    unchecked {
                        ++i;
                    }
                }

                uint256 paidEx;
                uint8 maxExWinners = exWinCount;
                if (maxExWinners > 4) {
                    maxExWinners = 4;
                }
                for (uint8 i; i < maxExWinners; ) {
                    uint256 prize = exPrizes[i];
                    paidEx += prize;
                    if (prize != 0) {
                        tmpW[n] = exWinners[i];
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }
                if (paidEx < exterminatorSlice) {
                    toReturn += exterminatorSlice - paidEx;
                }
            }
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

            address affiliateAddr = affiliate;
            if (affiliateAddr == address(0)) {
                toReturn += affiliateSlice;
            } else {
                IDegenerusAffiliate affiliateContract = IDegenerusAffiliate(affiliateAddr);
                address[20] memory candidates;
                uint256[20] memory candidateScores;
                uint8 candidateCount;

                // Collect the top affiliate from each of the prior 20 levels (deduped).
                for (uint8 offset = 1; offset <= 20; ) {
                    if (lvl <= offset) break;
                    (address player, ) = affiliateContract.affiliateTop(uint24(lvl - offset));
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
                    if (_eligible(cand)) {
                        affiliateWinners[winnerCount] = cand;
                        affiliateScores[winnerCount] = candidateScores[i];
                        unchecked {
                            ++winnerCount;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }

                if (winnerCount == 0) {
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
                    if (lvlA <= lvlB) {
                        chosen = candA;
                    } else {
                        chosen = candB;
                    }
                } else if (validA) {
                    chosen = candA;
                } else if (validB) {
                    chosen = candB;
                }

                uint256 prize = prizes[s];
                bool credited;
                if (prize != 0) {
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

        // Scatter slice: 200 total draws (4 tickets * 50 rounds). Per round, take top-2 by BAF score.
        // Game applies special map/bond handling for the last BAF_SCATTER_BOND_WINNERS scatter winners via `bondMask`.
        {
            // Slice E: scatter tickets from trait sampler so casual participants can land smaller cuts.
            uint256 scatterTop = (P * 20) / 100;
            uint256 scatterSecond = (P * 25) / 100;
            address[50] memory firstWinners;
            address[50] memory secondWinners;
            uint256 firstCount;
            uint256 secondCount;
            uint256 scatterStart = n;

            // 50 rounds of 4-ticket sampling (total 200 tickets).
            for (uint8 round; round < 50; ) {
                unchecked {
                    ++salt;
                }
                entropy = uint256(keccak256(abi.encodePacked(entropy, salt)));
                (, , address[] memory tickets) = degenerusGame.sampleTraitTickets(entropy);

                // Pick up to 4 tickets from the sampled set.
                uint256 limit = tickets.length;
                if (limit > 4) limit = 4;

                address best;
                uint256 bestScore;
                address second;
                uint256 secondScore;

                for (uint256 i; i < limit; ) {
                    address cand = tickets[i];
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
                    unchecked {
                        ++i;
                    }
                }

                // Bucket winners if eligible and capacity not exceeded; otherwise refund their would-be share later.
                if (firstCount < 50 && _eligible(best)) {
                    firstWinners[firstCount] = best;
                    unchecked {
                        ++firstCount;
                    }
                }
                if (secondCount < 50 && _eligible(second)) {
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
                    if (per != 0 && _creditOrRefund(firstWinners[i], per, tmpW, tmpA, n)) {
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
                    if (per2 != 0 && _creditOrRefund(secondWinners[i], per2, tmpW, tmpA, n)) {
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

            uint256 scatterCount = n - scatterStart;
            if (scatterCount != 0) {
                uint256 targetSpecialCount = scatterCount < BAF_SCATTER_BOND_WINNERS
                    ? scatterCount
                    : BAF_SCATTER_BOND_WINNERS;
                for (uint256 i; i < targetSpecialCount; ) {
                    uint256 idx = (scatterStart + scatterCount - 1) - i;
                    mask |= (uint256(1) << (BAF_SCATTER_MASK_OFFSET + idx));
                    unchecked {
                        ++i;
                    }
                }
            }
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

        bondMask = mask;

        _clearBafTop(lvl);
        return (winners, amounts, bondMask, toReturn);
    }

    function runDecimatorJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        override
        onlyGame
        returns (uint256 returnAmountWei)
    {
        // Decimator jackpots defer ETH distribution to per-player claims; this call snapshots winners.
        DecClaimRound storage round = decClaimRound[lvl];
        if (round.active) {
            // Already snapshotted; treat as no-op and refund the incoming pool.
            return poolWei;
        }

        uint256 totalBurn;

        uint256 decSeed = rngWord;
        for (uint8 denom = 2; denom <= DECIMATOR_MAX_DENOM; ) {
            // Pick a random winning subbucket for each denominator and accumulate its burn total.
            uint8 winningSub = _decWinningSubbucket(decSeed, denom);
            decBucketOffset[lvl][denom] = winningSub;

            uint256 subTotal = decBucketBurnTotal[lvl][denom][winningSub];
            if (subTotal != 0) {
                totalBurn += subTotal;
            }

            unchecked {
                ++denom;
            }
        }

        if (totalBurn == 0) {
            return poolWei;
        }

        round.poolWei = poolWei;
        round.totalBurn = totalBurn;
        round.level = lvl;
        round.active = true;

        return 0;
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

    function consumeDecClaim(address player, uint24 lvl) external onlyGame returns (uint256 amountWei) {
        return _consumeDecClaim(player, lvl);
    }

    function claimDecimatorJackpot(uint24 lvl) external {
        uint256 amountWei = _consumeDecClaim(msg.sender, lvl);
        degenerusGame.applyExternalOp(DegenerusGameExternalOp.DecJackpotClaim, msg.sender, amountWei);
    }

    function claimDecimatorJackpotBatch(address[] calldata players, uint24 lvl) external {
        uint256 len = players.length;
        if (len == 0) return;
        uint256[] memory amounts = new uint256[](len);
        for (uint256 i; i < len; ) {
            uint256 amountWei = _consumeDecClaim(players[i], lvl);
            amounts[i] = amountWei;
            unchecked {
                ++i;
            }
        }
        degenerusGame.applyExternalOpBatch(DegenerusGameExternalOp.DecJackpotClaim, players, amounts);
    }

    function decClaimable(address player, uint24 lvl) external view returns (uint256 amountWei, bool winner) {
        DecClaimRound storage round = decClaimRound[lvl];
        return _decClaimable(round, player, lvl);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    // Eligibility gate reused across jackpot slices.
    function _eligible(address player) internal view returns (bool) {
        if (coin.coinflipAmountLastDay(player) < 5_000 * MILLION) return false;
        return degenerusGame.ethMintStreakCount(player) >= 3;
    }

    function _creditOrRefund(
        address candidate,
        uint256 prize,
        address[] memory winnersBuf,
        uint256[] memory amountsBuf,
        uint256 idx
    ) private view returns (bool credited) {
        if (prize == 0) return false;
        // Writes into the preallocated buffers; caller controls idx and increments only on success.
        if (_eligible(candidate)) {
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
        uint192 entryBurn = e.burn;
        if (e.level != lvl || denom == 0 || entryBurn == 0) return (0, false);

        uint8 winningSub = uint8(decBucketOffset[lvl][denom]);
        if (sub != winningSub) return (0, false);

        if (decBucketBurnTotal[lvl][denom][winningSub] == 0) return (0, false);

        // Pro-rata share of the Decimator pool based on the burn inside the winning subbucket.
        amountWei = (round.poolWei * uint256(entryBurn)) / round.totalBurn;
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

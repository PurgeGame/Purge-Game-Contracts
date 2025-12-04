// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Minimal ERC20 surface (used for stETH pulls/payouts)
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Game hooks used for RNG and level gating.
interface IPurgeGameLike {
    function rngWordForDay(uint48 day) external view returns (uint256);
    function level() external view returns (uint24);
}

/**
 * @title PurgeBongs (bond pool)
 * @notice Level-based bond system with pull-claims and upfront solvency checks.
 *         - Funds (ETH + stETH) accrue in `bondObligations`.
 *         - Levels are staged via merkle roots; when the game level passes them and
 *           obligations >= worst-case payout, the level is resolved with a seed.
 *         - Holders claim individually via merkle proofs; payouts draw from the
 *           level's reserved budget. Any leftovers roll back into obligations
 *           once all claims are done.
 *
 * Bond logic:
 *  - "Small" (<0.5 ETH) entries sit in one of 8 buckets and get a single draw:
 *      win if their interval crosses a 1 ETH boundary after a bucket-specific offset.
 *      Prize: 1 ETH.
 *  - "Large" (>=0.5 ETH) entries are 50/50 double-or-zero. If paired, only one
 *    side of the pair can win; the coin-flip key is `pairId`.
 */
contract PurgeBongs {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error ZeroAddress();
    error InvalidLevel();
    error InvalidAmount();
    error InvalidProof();
    error AlreadyClaimed();
    error NotResolved();
    error InsufficientObligations();
    error PurchasesClosed();
    error TransfersLocked();
    error TransferFailed();
    error InvalidCoin();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event LevelStaged(uint24 indexed levelId, bytes32 root, uint256 maxPayout, uint256 leafCount);
    event LevelResolved(uint24 indexed levelId, uint256 seed, uint256 reserved, uint256 coinReserved);
    event Claim(address indexed player, uint24 indexed levelId, uint256 leafIndex, uint256 payoutEth, uint256 payoutCoin);
    event Funded(uint256 ethAmount, uint256 stEthAmount, uint256 coinAmount);
    event BondIssued(uint24 indexed levelId, address indexed player, uint256 amount, bool large);

    // ---------------------------------------------------------------------
    // Data Structures
    // ---------------------------------------------------------------------
    struct LevelConfig {
        bytes32 root;
        uint256 maxPayout; // worst-case required budget for the level
        uint256 remainingPayout; // reserved budget left for this level
        uint256 seed; // resolution seed (derived from RNG + level id)
        uint256 leafCount; // number of entries in the merkle tree
        uint256 claimedCount;
        uint256 paidOut;
        uint256[8] bucketTotals; // aggregate small bucket weights (for sanity bounds)
        uint256 coinPerBond; // PURGE amount per bond at resolution (floored)
        uint256 coinRemaining; // remaining PURGE reserved for this level
        bool resolved;
        bool staged;
    }

    struct ClaimLeaf {
        uint24 levelId;
        uint64 leafIndex;
        address player;
        uint256 amount; // principal
        uint8 bucketId; // 0-7 for small, 0 for large
        uint64 pairId; // >0 means paired; 0 means solo large (or small)
        bool pairSide; // side selector for paired large
        bool isLarge; // true for >=0.5 ETH entries
        uint256 bucketStart; // prefix sum within the bucket (for smalls)
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant SMALL_THRESHOLD = 0.5 ether;
    uint256 private constant ONE = 1 ether;
    uint256 private constant MAX_PRICE = 5 ether;
    uint16 public constant stakeRateBps = 10_000; // kept for interface compatibility

    // ---------------------------------------------------------------------
    // Wiring / Access
    // ---------------------------------------------------------------------
    address public owner;
    address public game;
    address public stEthToken;
    address public coinToken;
    address public vault;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------
    uint256 public bondObligations; // unreserved pool (ETH + stETH units)
    uint256 public coinUnreserved; // PURGE available to assign to future levels
    bool public gameOver;
    bool public transfersLocked;
    bool public purchasesEnabled = true;
    // Pricing memory (monotone upward per issuance, anchored to previous clearing)
    uint256 public lastClearingPrice;
    uint256 public lastSold;
    uint256 public initialPrice; // must be set before first issuance
    uint16 public discountBps = 500; // start 5% under last clearing
    uint16 public stepBps = 100; // 1% of last price scaled by volume band
    uint16 public minBand = 50; // min normalizer for slope

    // levelId => config
    mapping(uint24 => LevelConfig) public levels;
    // packed bitmaps to prevent double-claims (levelId => word => bits)
    mapping(uint24 => mapping(uint256 => uint256)) private claimedBitmap;

    // resolution order and cursor
    uint24[] private levelQueue;
    uint256 private resolveCursor;
    uint256 private cachedRngWord;

    // issuance helpers (book-keeping only)
    mapping(uint24 => uint256) public levelPrincipal;
    mapping(uint24 => uint256) public levelIssuedCount;

    // simple reentrancy guard
    uint256 private locked = 1;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyGame() {
        if (msg.sender != game) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Unauthorized();
        locked = 2;
        _;
        locked = 1;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address stEthToken_) {
        if (stEthToken_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        stEthToken = stEthToken_;
    }

    receive() external payable {
        if (msg.value != 0) {
            bondObligations += msg.value;
            emit Funded(msg.value, 0, 0);
        }
    }

    // ---------------------------------------------------------------------
    // Admin / Wiring
    // ---------------------------------------------------------------------
    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function wire(address game_) external onlyOwner {
        if (game_ == address(0)) revert ZeroAddress();
        game = game_;
    }

    function wire(address[] calldata addresses) external onlyOwner {
        if (addresses.length > 0 && addresses[0] != address(0)) {
            coinToken = addresses[0];
        }
        if (addresses.length > 1 && addresses[1] != address(0)) {
            game = addresses[1];
        }
        if (addresses.length > 2 && addresses[2] != address(0)) {
            vault = addresses[2];
        }
    }

    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    function setCoin(address coin_) external onlyOwner {
        if (coin_ == address(0)) revert ZeroAddress();
        coinToken = coin_;
    }

    function setInitialPrice(uint256 priceWei) external onlyOwner {
        initialPrice = priceWei;
    }

    function setPricingParams(uint16 discountBps_, uint16 stepBps_, uint16 minBand_) external onlyOwner {
        if (discountBps_ > 10_000) revert InvalidAmount();
        discountBps = discountBps_;
        stepBps = stepBps_;
        minBand = minBand_;
    }

    function setPurchasesEnabled(bool enabled) external onlyOwner {
        purchasesEnabled = enabled;
    }

    function setTransfersLocked(bool lockedFlag, uint48 /*rngDay*/) external onlyGame {
        transfersLocked = lockedFlag;
    }

    function notifyGameOver() external onlyGame {
        gameOver = true;
        transfersLocked = true;
    }

    // ---------------------------------------------------------------------
    // Level lifecycle
    // ---------------------------------------------------------------------
    /**
     * @notice Stage a level with its merkle root and worst-case payout.
     * @dev Root covers leaves shaped by `ClaimLeaf` (see `_leafHash`).
     * @param levelId Game level this snapshot belongs to.
     * @param root Merkle root of all bond entries for the level.
     * @param maxPayout Worst-case payout requirement for solvency gating.
     * @param leafCount Number of leaves in the tree (used for claim bitmaps / completion).
     * @param bucketTotals Aggregate bucket weights for small entries (sanity checks).
     */
    function stageLevel(
        uint24 levelId,
        bytes32 root,
        uint256 maxPayout,
        uint256 leafCount,
        uint256[8] calldata bucketTotals
    ) external onlyOwner {
        if (levelId == 0 || root == bytes32(0) || maxPayout == 0 || leafCount == 0) revert InvalidLevel();
        LevelConfig storage cfg = levels[levelId];
        if (cfg.staged) revert InvalidLevel();

        cfg.root = root;
        cfg.maxPayout = maxPayout;
        cfg.leafCount = leafCount;
        cfg.bucketTotals = bucketTotals;
        cfg.staged = true;
        levelQueue.push(levelId);

        emit LevelStaged(levelId, root, maxPayout, leafCount);
    }

    /**
     * @notice Returns true if there is any staged level that hasn't been resolved yet.
     */
    function resolvePending() external view returns (bool) {
        return resolveCursor < levelQueue.length;
    }

    /**
     * @notice Fund obligations and attempt to resolve the next eligible level.
     */
    function payBongs(
        uint256 coinAmount,
        uint256 stEthAmount,
        uint48 rngDay,
        uint256 rngWord,
        uint256 /*maxBongs*/
    ) external payable onlyGame {
        // ingest stETH
        if (stEthAmount != 0) {
            if (!IERC20Minimal(stEthToken).transferFrom(msg.sender, address(this), stEthAmount)) revert TransferFailed();
        }

        if (coinAmount != 0) {
            address coin = coinToken;
            if (coin == address(0)) revert InvalidCoin();
            if (!IERC20Minimal(coin).transferFrom(msg.sender, address(this), coinAmount)) revert TransferFailed();
            coinUnreserved += coinAmount;
        }

        uint256 inbound = msg.value + stEthAmount;
        if (inbound != 0) {
            bondObligations += inbound;
            emit Funded(msg.value, stEthAmount, coinAmount);
        } else if (coinAmount != 0) {
            emit Funded(0, 0, coinAmount);
        }

        // pull RNG if not provided
        uint256 seedWord = rngWord;
        if (seedWord == 0 && rngDay != 0 && game != address(0)) {
            seedWord = IPurgeGameLike(game).rngWordForDay(rngDay);
        }
        if (seedWord != 0) {
            cachedRngWord = seedWord;
        }

        _resolveReadyLevels(seedWord);
    }

    /**
     * @notice Attempt to resolve using cached RNG (or freshly available RNG via game day fetch).
     */
    function resolvePendingBongs(uint256 /*maxBongs*/) external {
        _resolveReadyLevels(0);
    }

    function _resolveReadyLevels(uint256 rngWord) private {
        uint256 seedWord = rngWord;
        if (seedWord == 0) {
            seedWord = cachedRngWord;
        }
        if (seedWord == 0 && game != address(0)) {
            // best-effort fetch current day's RNG if nothing cached
            seedWord = IPurgeGameLike(game).rngWordForDay(uint48(block.timestamp / 1 days));
            if (seedWord != 0) {
                cachedRngWord = seedWord;
            }
        }

        uint24 currentLevel = _currentLevel();
        while (resolveCursor < levelQueue.length) {
            uint24 levelId = levelQueue[resolveCursor];
            LevelConfig storage cfg = levels[levelId];

            if (!cfg.staged) {
                resolveCursor++;
                continue;
            }
            if (cfg.resolved) {
                resolveCursor++;
                continue;
            }
            if (!gameOver && currentLevel < levelId) {
                // level not yet passed in the main game
                break;
            }
            if (bondObligations < cfg.maxPayout) {
                // not enough funds reserved to safely resolve
                break;
            }
            if (seedWord == 0) {
                // need RNG to proceed
                break;
            }

            _resolveLevel(cfg, levelId, seedWord);
            resolveCursor++;
        }

        // If nothing else is currently resolvable (and no passed levels are waiting on funds/RNG), forward surplus to the vault.
        if (seedWord != 0 && !_hasResolvableLevel(currentLevel) && !_hasPassedPendingLevel(currentLevel)) {
            _drainSurplusToVault();
        }
    }

    function _resolveLevel(LevelConfig storage cfg, uint24 levelId, uint256 rngWord) private {
        uint256 seed = uint256(keccak256(abi.encode(rngWord, levelId)));
        uint256 liveBefore = _totalUnresolvedLeafs();
        cfg.resolved = true;
        cfg.seed = seed;
        cfg.remainingPayout = cfg.maxPayout;

        bondObligations -= cfg.maxPayout;

        // Snapshot coin share for this level (proportional to live unresolved bonds).
        uint256 coinReserved;
        if (coinToken != address(0) && coinUnreserved != 0) {
            if (liveBefore != 0) {
                uint256 coinForLevel = (coinUnreserved * cfg.leafCount) / liveBefore;
                uint256 perBond = coinForLevel / cfg.leafCount;
                if (perBond != 0) {
                    coinReserved = perBond * cfg.leafCount;
                    coinUnreserved -= coinReserved;
                    cfg.coinPerBond = perBond;
                    cfg.coinRemaining = coinReserved;
                }
            }
        }

        emit LevelResolved(levelId, seed, cfg.maxPayout, coinReserved);
    }

    function _hasResolvableLevel(uint24 currentLevel) private view returns (bool) {
        uint256 len = levelQueue.length;
        uint256 obligations = bondObligations;
        for (uint256 i = resolveCursor; i < len; ) {
            uint24 lvl = levelQueue[i];
            LevelConfig storage cfg = levels[lvl];
            if (cfg.staged && !cfg.resolved && (gameOver || currentLevel >= lvl) && obligations >= cfg.maxPayout) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _hasPassedPendingLevel(uint24 currentLevel) private view returns (bool) {
        uint256 len = levelQueue.length;
        for (uint256 i = resolveCursor; i < len; ) {
            uint24 lvl = levelQueue[i];
            LevelConfig storage cfg = levels[lvl];
            if (cfg.staged && !cfg.resolved && (gameOver || currentLevel >= lvl)) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _currentLevel() private view returns (uint24) {
        if (game == address(0)) return 0;
        try IPurgeGameLike(game).level() returns (uint24 lvl) {
            return lvl;
        } catch {
            return 0;
        }
    }

    // ---------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------
    function claim(ClaimLeaf calldata leaf, bytes32[] calldata proof) external nonReentrant {
        LevelConfig storage cfg = levels[leaf.levelId];
        if (!cfg.resolved) revert NotResolved();
        if (leaf.leafIndex >= cfg.leafCount) revert InvalidLevel();
        if (_isClaimed(leaf.levelId, leaf.leafIndex)) revert AlreadyClaimed();

        bytes32 leafHash = _leafHash(leaf);
        if (!_verify(proof, cfg.root, leafHash)) revert InvalidProof();

        uint256 payout = _payoutForLeaf(cfg, leaf);
        if (payout > cfg.remainingPayout) revert InsufficientObligations();

        _setClaimed(leaf.levelId, leaf.leafIndex);
        cfg.claimedCount += 1;
        cfg.paidOut += payout;
        cfg.remainingPayout -= payout;

        _payout(leaf.player, payout);
        uint256 coinOut;
        if (cfg.coinPerBond != 0 && cfg.coinRemaining != 0) {
            coinOut = cfg.coinPerBond;
            if (coinOut > cfg.coinRemaining) {
                coinOut = cfg.coinRemaining;
            }
            cfg.coinRemaining -= coinOut;
            _payoutCoin(leaf.player, coinOut);
        }

        emit Claim(leaf.player, leaf.levelId, leaf.leafIndex, payout, coinOut);

        // return surplus to the pool once every claim is done
        if (cfg.claimedCount == cfg.leafCount && cfg.remainingPayout != 0) {
            bondObligations += cfg.remainingPayout;
            cfg.remainingPayout = 0;
        }
        if (cfg.claimedCount == cfg.leafCount && cfg.coinRemaining != 0) {
            coinUnreserved += cfg.coinRemaining;
            cfg.coinRemaining = 0;
        }
    }

    function _payoutForLeaf(LevelConfig storage cfg, ClaimLeaf calldata leaf) private view returns (uint256) {
        if (leaf.isLarge) {
            if (leaf.amount < SMALL_THRESHOLD) revert InvalidAmount();
            uint256 flipKey = leaf.pairId == 0 ? leaf.leafIndex : leaf.pairId;
            bool win = (uint256(keccak256(abi.encode(cfg.seed, flipKey))) & 1) == (leaf.pairSide ? 1 : 0);
            return win ? leaf.amount * 2 : 0;
        }

        // small entry
        if (leaf.amount >= SMALL_THRESHOLD || leaf.bucketId > 7) revert InvalidAmount();
        uint256 bucketTotal = cfg.bucketTotals[leaf.bucketId];
        if (bucketTotal != 0 && leaf.bucketStart + leaf.amount > bucketTotal) revert InvalidAmount();

        uint256 offset = uint256(keccak256(abi.encode(cfg.seed, leaf.bucketId))) % ONE;
        uint256 start = leaf.bucketStart + offset;
        // wins if interval crosses a 1 ETH boundary after applying offset
        return (start / ONE != (start + leaf.amount) / ONE) ? ONE : 0;
    }

    function _leafHash(ClaimLeaf calldata leaf) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                leaf.levelId,
                leaf.leafIndex,
                leaf.player,
                leaf.amount,
                leaf.bucketId,
                leaf.bucketStart,
                leaf.pairId,
                leaf.pairSide,
                leaf.isLarge
            )
        );
    }

    // standard merkle proof verification (keccak256 hash pair, sorted)
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i; i < proof.length; ) {
            bytes32 proofElement = proof[i];
            computed = computed <= proofElement
                ? keccak256(abi.encodePacked(computed, proofElement))
                : keccak256(abi.encodePacked(proofElement, computed));
            unchecked {
                ++i;
            }
        }
        return computed == root;
    }

    function _isClaimed(uint24 levelId, uint256 index) private view returns (bool) {
        uint256 word = index >> 8; // /256
        uint256 mask = 1 << (index & 255);
        return claimedBitmap[levelId][word] & mask != 0;
    }

    function _setClaimed(uint24 levelId, uint256 index) private {
        uint256 word = index >> 8;
        uint256 mask = 1 << (index & 255);
        claimedBitmap[levelId][word] |= mask;
    }

    function _payout(address to, uint256 amount) private {
        if (amount == 0 || to == address(0)) return;

        uint256 ethBal = address(this).balance;
        uint256 payEth = amount <= ethBal ? amount : ethBal;
        if (payEth != 0) {
            (bool ok, ) = to.call{value: payEth}("");
            if (!ok) revert TransferFailed();
        }

        uint256 remaining = amount - payEth;
        if (remaining != 0) {
            IERC20Minimal token = IERC20Minimal(stEthToken);
            if (token.balanceOf(address(this)) < remaining) revert TransferFailed();
            if (!token.transfer(to, remaining)) revert TransferFailed();
        }
    }

    function _payoutCoin(address to, uint256 amount) private {
        if (amount == 0 || to == address(0)) return;
        address coin = coinToken;
        if (coin == address(0)) revert InvalidCoin();
        if (!IERC20Minimal(coin).transfer(to, amount)) revert TransferFailed();
    }

    function _totalUnresolvedLeafs() private view returns (uint256 total) {
        uint256 len = levelQueue.length;
        for (uint256 i = resolveCursor; i < len; ) {
            LevelConfig storage cfg = levels[levelQueue[i]];
            if (cfg.staged && !cfg.resolved) {
                total += cfg.leafCount;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _drainSurplusToVault() private {
        address vault_ = vault;
        if (vault_ == address(0)) return;

        uint256 obligations = bondObligations;
        if (obligations == 0) return;
        uint256 ethBal = address(this).balance;
        uint256 stBal = IERC20Minimal(stEthToken).balanceOf(address(this));
        uint256 available = ethBal + stBal;
        if (obligations > available) {
            obligations = available;
        }
        if (obligations == 0) return;

        uint256 sendEth = obligations <= ethBal ? obligations : ethBal;
        uint256 sendSt = obligations - sendEth;

        uint256 newObligations = bondObligations > obligations ? bondObligations - obligations : 0;
        bondObligations = newObligations;

        if (sendEth != 0) {
            (bool ok, ) = vault_.call{value: sendEth}("");
            if (!ok) revert TransferFailed();
        }
        if (sendSt != 0) {
            if (!IERC20Minimal(stEthToken).transfer(vault_, sendSt)) revert TransferFailed();
        }
    }

    // ---------------------------------------------------------------------
    // Issuance (book-keeping only, still fungible/transferable offchain)
    // ---------------------------------------------------------------------
    /**
     * @notice Record new bonds for the current game level. No assets are pulled here;
     *         the funding model relies on yield skims via `payBongs`.
     */
    function purchaseGameBongs(
        address[] calldata recipients,
        uint256 quantity,
        uint256 basePerBongWei,
        bool /*stake*/
    ) external onlyGame returns (uint256 startIndex) {
        if (!purchasesEnabled) revert PurchasesClosed();
        if (transfersLocked) revert TransfersLocked();

        uint256 len = recipients.length;
        if (len == 0) revert InvalidAmount();
        if (basePerBongWei == 0 || basePerBongWei > MAX_PRICE) revert InvalidAmount();

        uint256 mintCount = quantity;
        if (len == 1 && mintCount == 0) {
            mintCount = 1;
        } else if (len > 1) {
            if (mintCount == 0) {
                mintCount = len;
            } else if (mintCount != len) {
                revert InvalidAmount();
            }
        }

        uint24 lvl = _currentLevel();
        startIndex = levelIssuedCount[lvl];

        if (len == 1) {
            address to = recipients[0];
            if (to == address(0)) revert ZeroAddress();
            _issue(to, lvl, basePerBongWei, mintCount);
        } else {
            for (uint256 i; i < mintCount; ) {
                address to = recipients[i];
                if (to == address(0)) revert ZeroAddress();
                _issue(to, lvl, basePerBongWei, 1);
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _issue(address to, uint24 levelId, uint256 basePerBongWei, uint256 count) private {
        levelIssuedCount[levelId] += count;
        levelPrincipal[levelId] += basePerBongWei * count;
        bool large = basePerBongWei >= SMALL_THRESHOLD;

        for (uint256 i; i < count; ) {
            emit BondIssued(levelId, to, basePerBongWei, large);
            unchecked {
                ++i;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Pricing helpers (monotone upward per issuance)
    // ---------------------------------------------------------------------
    function quoteStartPrice() public view returns (uint256) {
        if (lastClearingPrice != 0) {
            return (lastClearingPrice * (10_000 - discountBps)) / 10_000;
        }
        return initialPrice;
    }

    function quotePrice(uint256 currentSold) external view returns (uint256) {
        uint256 startPrice = quoteStartPrice();
        // Choose a step so that after `lastSold` bonds, price reaches (or slightly exceeds) the last clearing price.
        uint256 step;
        if (lastClearingPrice > startPrice && lastSold != 0) {
            uint256 diff = lastClearingPrice - startPrice;
            // ceil(diff / lastSold) to guarantee reaching the target by lastSold.
            step = (diff + lastSold - 1) / lastSold;
        }

        uint256 price = startPrice + currentSold * step;
        if (price > MAX_PRICE) price = MAX_PRICE;
        return price;
    }

    function finalizeIssuance(uint256 clearingPrice, uint256 sold) external onlyGame {
        if (clearingPrice != 0) {
            lastClearingPrice = clearingPrice;
        }
        lastSold = sold;
    }

    // ---------------------------------------------------------------------
    // Shutdown placeholders (interface compatibility)
    // ---------------------------------------------------------------------
    function finalizeShutdown(uint256 /*maxIds*/) external pure returns (uint256 processedIds, uint256 burned, bool complete) {
        return (0, 0, true);
    }
}

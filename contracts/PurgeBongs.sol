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

interface IPurgeBong1155Renderer {
    function bongURI(
        uint256 id,
        uint256 supply,
        bool locked,
        uint256 principalSupply,
        bool funded
    ) external view returns (string memory);
}

interface IPurgeCoinBongMinter {
    function bongPayment(uint256 amount) external;
}

interface IPurgeCoinWire {
    function wire(address[] calldata addresses) external;
}

interface IPurgeAffiliateWire {
    function wire(address[] calldata addresses) external;
}

interface IPurgeJackpotsWire {
    function wire(address[] calldata addresses) external;
}

interface IRendererWire {
    function wire(address[] calldata addresses) external;
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
    error InsufficientBalance();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event LevelStaged(uint24 indexed levelId, bytes32 root, uint256 maxPayout, uint256 leafCount);
    event LevelStageMetadata(uint24 indexed levelId, uint256 matchedMaxPayout);
    event LevelResolved(uint24 indexed levelId, uint256 seed, uint256 reserved, uint256 coinReserved);
    event Claim(address indexed player, uint24 indexed levelId, uint256 leafIndex, uint256 payoutEth, uint256 payoutCoin);
    event EarlyLiquidation(address indexed player, uint24 indexed levelId, uint256 basePerBondWei, uint256 units, uint256 payoutEth);
    event Funded(uint256 ethAmount, uint256 stEthAmount, uint256 coinAmount);
    event BondIssued(uint24 indexed levelId, address indexed player, uint256 amount, bool large);
    event SystemWired(
        address coin,
        address game,
        address nft,
        address quest,
        address jackpots,
        address affiliate,
        address renderer,
        address trophyRenderer,
        address vault
    );
    event RenderersWired(
        address renderer,
        address trophyRenderer,
        address game,
        address nft,
        address extraToken1,
        address extraToken2
    );

    // ---------------------------------------------------------------------
    // Data Structures
    // ---------------------------------------------------------------------
    struct LevelConfig {
        bytes32 root;
        uint256 maxPayout; // worst-case required budget for the level
        uint256 matchedMaxPayout; // optional EV-style bound (<= maxPayout), informational only
        uint256 remainingPayout; // reserved budget left for this level
        uint256 payoutScale; // 1e18 = full payout, <1e18 = partial (shutdown), 0 = wiped
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
    uint256 private constant FULL_SCALE = 1e18;
    uint256 private constant MAX_PRICE = 5 ether;
    int256 private constant WAD_I = 1e18;
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
    bool public transfersLocked; // only used for shutdown
    bool public purchasesEnabled = true;
    // Pricing memory (monotone upward per issuance, anchored to previous clearing)
    uint256 public lastClearingPrice;
    uint256 public lastSold;
    uint256 public initialPrice; // must be set before first issuance
    uint16 public discountBps = 500; // start 5% under last clearing
    uint16 public stepBps = 100; // 1% of last price scaled by volume band
    uint16 public minBand = 50; // min normalizer for slope
    address public renderer;
    // Adaptive direct-sale pricing (fast up, slow down)
    uint256 public saleBasePrice; // wei
    uint256 public saleDecayUpWad; // 1e18-scaled exponent factor when ahead of schedule
    uint256 public saleDecayDownWad; // 1e18-scaled exponent factor when behind schedule
    uint256 public saleTargetRateWad; // bonds per second, 1e18-scaled
    uint256 public saleCooldownBuffer; // clamp negative deviation (units = bonds)
    uint256 public saleLaunchTime; // unix seconds; 0 disables adaptive pricing
    uint256 public saleSold; // cumulative bonds counted toward adaptive pricing

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
    mapping(uint24 => uint256) public levelSupply;
    mapping(uint256 => mapping(address => uint256)) private balances; // ERC1155 balances
    mapping(address => mapping(address => bool)) private operatorApproval;
    mapping(uint24 => bool) public levelLocked;
    mapping(uint24 => mapping(uint256 => uint256)) public levelDenomCount; // basePerBondWei => units outstanding
    mapping(uint24 => uint256) public levelMaxPayoutComputed; // rolling worst-case liability (updated on mint/liquidation)

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
        _wireCore(address(0), game_, address(0));
    }

    function wire(address[] calldata addresses) external onlyOwner {
        _wireCore(
            addresses.length > 0 ? addresses[0] : address(0),
            addresses.length > 1 ? addresses[1] : address(0),
            addresses.length > 2 ? addresses[2] : address(0)
        );
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

    function setRenderer(address renderer_) external onlyOwner {
        renderer = renderer_;
    }

    function setPurchasesEnabled(bool enabled) external onlyOwner {
        purchasesEnabled = enabled;
    }

    /// @notice Wire core contracts (coin, game, vault) and propagate wiring to downstream modules.
    /// @param coin_           Purgecoin address (or compatible implementation).
    /// @param game_           PurgeGame address.
    /// @param nft_            Game NFT address (forwarded to coin wire).
    /// @param questModule_    Quest module address (forwarded to coin wire).
    /// @param jackpots_       Jackpots module address.
    /// @param affiliate_      Affiliate module address.
    /// @param vault_          Vault for surplus drains.
    function wireCoreContracts(
        address coin_,
        address game_,
        address nft_,
        address questModule_,
        address jackpots_,
        address affiliate_,
        address vault_
    ) external onlyOwner {
        _wireCore(coin_, game_, vault_);

        if (coin_ != address(0)) {
            address[] memory coinAddrs = new address[](4);
            coinAddrs[0] = game_;
            coinAddrs[1] = nft_;
            coinAddrs[2] = questModule_;
            coinAddrs[3] = jackpots_;
            IPurgeCoinWire(coin_).wire(coinAddrs);
        }

        if (affiliate_ != address(0)) {
            address[] memory affiliateAddrs = new address[](2);
            affiliateAddrs[0] = coin_;
            affiliateAddrs[1] = game_;
            IPurgeAffiliateWire(affiliate_).wire(affiliateAddrs);
        }

        if (jackpots_ != address(0)) {
            address[] memory jackpotAddrs = new address[](2);
            jackpotAddrs[0] = coin_;
            jackpotAddrs[1] = game_;
            IPurgeJackpotsWire(jackpots_).wire(jackpotAddrs);
        }

        emit SystemWired(coin_, game_, nft_, questModule_, jackpots_, affiliate_, address(0), address(0), vault_);
    }

    /// @notice Wire renderer contracts that require bongs as the caller.
    /// @param renderer_       Primary game renderer (IconRendererRegular32).
    /// @param trophyRenderer_ Trophy renderer (IconRendererTrophy32).
    /// @param game_           Optional game override; falls back to stored game when zero.
    /// @param nft_            Game NFT address used by renderers.
    /// @param extraToken1     Optional allowed token for the renderer color registry.
    /// @param extraToken2     Optional allowed token for the renderer color registry.
    function wireRenderers(
        address renderer_,
        address trophyRenderer_,
        address game_,
        address nft_,
        address extraToken1,
        address extraToken2
    ) external onlyOwner {
        if (game_ != address(0)) {
            _wireCore(address(0), game_, address(0));
        }
        address gameAddr = game;

        if (renderer_ != address(0)) {
            address[] memory rendererAddrs = new address[](4);
            rendererAddrs[0] = gameAddr;
            rendererAddrs[1] = nft_;
            rendererAddrs[2] = extraToken1;
            rendererAddrs[3] = extraToken2;
            IRendererWire(renderer_).wire(rendererAddrs);
        }

        if (trophyRenderer_ != address(0)) {
            address[] memory trophyAddrs = new address[](1);
            trophyAddrs[0] = nft_;
            IRendererWire(trophyRenderer_).wire(trophyAddrs);
        }

        emit RenderersWired(renderer_, trophyRenderer_, gameAddr, nft_, extraToken1, extraToken2);
    }

    function _wireCore(address coin_, address game_, address vault_) private {
        if (coin_ != address(0)) {
            coinToken = coin_;
        }
        if (game_ != address(0)) {
            game = game_;
        }
        if (vault_ != address(0)) {
            vault = vault_;
        }
    }

    function setTransfersLocked(bool lockedFlag, uint48 /*rngDay*/) external onlyGame {
        // Global lock reserved for shutdown flows only.
        if (!gameOver && lockedFlag) revert TransfersLocked();
        transfersLocked = lockedFlag;
    }

    function _worstCase(uint256 basePerBondWei) private pure returns (uint256) {
        return basePerBondWei >= SMALL_THRESHOLD ? basePerBondWei * 2 : ONE;
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
        _stageLevel(levelId, root, maxPayout, 0, leafCount, bucketTotals);
    }

    /// @notice Stage a level with an optional EV-style matched payout cap (informational only).
    function stageLevelWithMatch(
        uint24 levelId,
        bytes32 root,
        uint256 maxPayout,
        uint256 matchedMaxPayout,
        uint256 leafCount,
        uint256[8] calldata bucketTotals
    ) external onlyOwner {
        _stageLevel(levelId, root, maxPayout, matchedMaxPayout, leafCount, bucketTotals);
    }

    function _stageLevel(
        uint24 levelId,
        bytes32 root,
        uint256 maxPayout,
        uint256 matchedMaxPayout,
        uint256 leafCount,
        uint256[8] calldata bucketTotals
    ) private {
        if ((levelId % 5 != 0) || root == bytes32(0) || leafCount == 0) revert InvalidLevel();
        LevelConfig storage cfg = levels[levelId];
        if (cfg.staged) revert InvalidLevel();
        if (matchedMaxPayout != 0 && matchedMaxPayout > maxPayout) revert InvalidLevel();

        uint256 computed = levelMaxPayoutComputed[levelId];
        if (maxPayout == 0) {
            maxPayout = computed;
        } else if (computed != 0 && maxPayout < computed) {
            revert InvalidLevel();
        }
        if (maxPayout == 0) revert InvalidLevel();

        cfg.root = root;
        cfg.maxPayout = maxPayout;
        cfg.matchedMaxPayout = matchedMaxPayout == 0 ? maxPayout : matchedMaxPayout;
        cfg.leafCount = leafCount;
        cfg.bucketTotals = bucketTotals;
        cfg.staged = true;
        levelLocked[levelId] = true; // freeze transfers for this level
        levelQueue.push(levelId);

        emit LevelStaged(levelId, root, maxPayout, leafCount);
        emit LevelStageMetadata(levelId, cfg.matchedMaxPayout);
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
            if (coinToken == address(0)) revert InvalidCoin();
            coinUnreserved += coinAmount; // treat as a bookkeeping credit; actual mint happens at claim time
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
        bool shortfall;
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
            if (currentLevel <= levelId) {
                // level not yet prior to the current game level
                break;
            }
            if (bondObligations < cfg.maxPayout) {
                // not enough funds reserved to safely resolve
                shortfall = true;
                break;
            }
            if (seedWord == 0) {
                // need RNG to proceed
                break;
            }

            _resolveLevel(cfg, levelId, seedWord);
            resolveCursor++;
        }

        if (gameOver && seedWord != 0) {
            _resolveShutdownWithBudget(seedWord, currentLevel);
            return;
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
        cfg.payoutScale = FULL_SCALE;

        bondObligations -= cfg.maxPayout;

        // Snapshot coin share for this level (proportional to live unresolved bonds).
        uint256 coinReserved = _reserveCoinForLevel(cfg, liveBefore);

        emit LevelResolved(levelId, seed, cfg.maxPayout, coinReserved);
    }

    function _resolvePartialLevel(
        LevelConfig storage cfg,
        uint24 levelId,
        uint256 rngWord,
        uint256 budget,
        uint256 liveBefore
    ) private {
        cfg.resolved = true;
        cfg.seed = uint256(keccak256(abi.encode(rngWord, levelId)));
        cfg.remainingPayout = budget;
        cfg.payoutScale = cfg.maxPayout == 0 ? 0 : (budget * FULL_SCALE) / cfg.maxPayout;

        uint256 obligations = bondObligations;
        bondObligations = obligations > budget ? obligations - budget : 0;

        uint256 coinReserved = _reserveCoinForLevel(cfg, liveBefore);
        emit LevelResolved(levelId, cfg.seed, budget, coinReserved);
    }

    function _reserveCoinForLevel(LevelConfig storage cfg, uint256 liveBefore) private returns (uint256 coinReserved) {
        if (coinToken == address(0) || coinUnreserved == 0 || liveBefore == 0) {
            return 0;
        }

        uint256 coinForLevel = (coinUnreserved * cfg.leafCount) / liveBefore;
        uint256 perBond = coinForLevel / cfg.leafCount;
        if (perBond == 0) {
            return 0;
        }

        coinReserved = perBond * cfg.leafCount;
        coinUnreserved -= coinReserved;
        cfg.coinPerBond = perBond;
        cfg.coinRemaining = coinReserved;
    }

    function _hasResolvableLevel(uint24 currentLevel) private view returns (bool) {
        uint256 len = levelQueue.length;
        uint256 obligations = bondObligations;
        for (uint256 i = resolveCursor; i < len; ) {
            uint24 lvl = levelQueue[i];
            LevelConfig storage cfg = levels[lvl];
            if (cfg.staged && !cfg.resolved && currentLevel > lvl && obligations >= cfg.maxPayout) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _totalUnresolvedLeafsFrom(uint256 start) private view returns (uint256 total) {
        uint256 len = levelQueue.length;
        for (uint256 i = start; i < len; ) {
            LevelConfig storage cfg = levels[levelQueue[i]];
            if (cfg.staged && !cfg.resolved) {
                total += cfg.leafCount;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _hasPassedPendingLevel(uint24 currentLevel) private view returns (bool) {
        uint256 len = levelQueue.length;
        for (uint256 i = resolveCursor; i < len; ) {
            uint24 lvl = levelQueue[i];
            LevelConfig storage cfg = levels[lvl];
            if (cfg.staged && !cfg.resolved && currentLevel > lvl) {
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

    function _levelTransfersLocked(uint24 levelId) private view returns (bool) {
        LevelConfig storage cfg = levels[levelId];
        if (cfg.resolved) return true; // freeze once resolved

        bool fullyFunded = cfg.staged && !cfg.resolved && bondObligations >= cfg.maxPayout;
        if (!fullyFunded) return false;

        uint24 curr = _currentLevel();
        if (curr == 0) return false;
        if (curr >= levelId) return true;
        uint24 delta = levelId - curr;
        return delta <= 3;
    }

    function _isFullyFunded(uint24 levelId) private view returns (bool) {
        LevelConfig storage cfg = levels[levelId];
        if (cfg.resolved) return true;
        if (!cfg.staged) return false;
        return bondObligations >= cfg.maxPayout;
    }

    function _fundedFlag(uint24 levelId) private view returns (bool) {
        if (_isFullyFunded(levelId)) return true;
        if (!gameOver) return false;

        LevelConfig storage cfg = levels[levelId];
        if (!cfg.staged) return false;

        uint256 need = cfg.resolved ? cfg.remainingPayout : cfg.maxPayout;
        return bondObligations >= need;
    }

    function _bondLevelFor(uint24 gameLevel) private pure returns (uint24) {
        if (gameLevel == 0) return 0;
        // Open sales 25 levels before resolution and keep them open until 21 levels before resolution.
        // Map to the resolution bucket that is 25-21 levels ahead (multiples of 5 only).
        uint24 ahead = gameLevel + 25;
        uint24 bucket = ahead / 5;
        return bucket * 5;
    }

    /**
     * @notice View helper: reports whether all staged, unresolved levels are fully covered by obligations.
     * @return pendingMaxPayout Sum of worst-case payouts for all pending levels.
     * @return obligations Current bondObligations balance.
     * @return shortfall Additional obligations needed to fully cover pending levels (0 if none).
     * @return fullyFunded True if obligations >= pendingMaxPayout.
     * @return rngReady True if a cached RNG word is already available for immediate resolution.
     */
    function coverageStatus()
        external
        view
        returns (uint256 pendingMaxPayout, uint256 obligations, uint256 shortfall, bool fullyFunded, bool rngReady)
    {
        pendingMaxPayout = _pendingMaxPayout();
        obligations = bondObligations;
        fullyFunded = obligations >= pendingMaxPayout;
        shortfall = fullyFunded ? 0 : pendingMaxPayout - obligations;
        rngReady = cachedRngWord != 0;
    }

    /// @notice Per-level funding metadata including EV-style matched cap (informational) and shutdown coverage.
    function fundingStatusFor(
        uint24 levelId
    )
        external
        view
        returns (bool fullyFunded, bool shutdownFunded, uint256 shortfall, uint256 matchedMaxPayout)
    {
        LevelConfig storage cfg = levels[levelId];
        if (!cfg.staged) revert InvalidLevel();

        fullyFunded = bondObligations >= cfg.maxPayout;
        uint256 need = cfg.resolved ? cfg.remainingPayout : cfg.maxPayout;
        matchedMaxPayout = cfg.matchedMaxPayout == 0 ? cfg.maxPayout : cfg.matchedMaxPayout;

        shutdownFunded = gameOver && bondObligations >= need;
        shortfall = bondObligations >= need ? 0 : need - bondObligations;
    }

    /// @notice View helper for display: returns both worst-case and matched (EV-style) max payouts for a level.
    function levelLiability(uint24 levelId) external view returns (uint256 maxPayout, uint256 matchedMaxPayout) {
        LevelConfig storage cfg = levels[levelId];
        if (!cfg.staged) revert InvalidLevel();
        maxPayout = cfg.maxPayout;
        matchedMaxPayout = cfg.matchedMaxPayout == 0 ? cfg.maxPayout : cfg.matchedMaxPayout;
    }

    function _pendingMaxPayout() private view returns (uint256 total) {
        uint256 len = levelQueue.length;
        for (uint256 i = resolveCursor; i < len; ) {
            LevelConfig storage cfg = levels[levelQueue[i]];
            if (cfg.staged && !cfg.resolved) {
                total += cfg.maxPayout;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _bufferForNextLevels(uint256 count) private view returns (uint256 total) {
        uint256 len = levelQueue.length;
        uint256 taken;
        for (uint256 i = resolveCursor; i < len && taken < count; ) {
            LevelConfig storage cfg = levels[levelQueue[i]];
            if (cfg.staged && !cfg.resolved) {
                total += cfg.maxPayout;
                unchecked {
                    ++taken;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _nextTwoBucketsFunded() private view returns (bool) {
        uint24 curr = _currentLevel();
        if (curr == 0) return false;
        uint24 firstBucket = _bondLevelFor(curr);
        uint24 secondBucket = firstBucket + 5;

        bool firstFound;
        bool secondFound;

        uint256 len = levelQueue.length;
        for (uint256 i = resolveCursor; i < len; ) {
            uint24 lvl = levelQueue[i];
            LevelConfig storage cfg = levels[lvl];
            if (cfg.staged && !cfg.resolved && bondObligations >= cfg.maxPayout) {
                if (lvl == firstBucket) firstFound = true;
                if (lvl == secondBucket) secondFound = true;
            }
            if (firstFound && secondFound) return true;
            if (lvl > secondBucket + 5) break;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _wipeRemainingLevels(uint256 start, uint256 seedWord) private {
        uint256 len = levelQueue.length;
        for (uint256 i = start; i < len; ) {
            uint24 levelId = levelQueue[i];
            LevelConfig storage cfg = levels[levelId];
            if (cfg.staged && !cfg.resolved) {
                cfg.resolved = true;
                cfg.seed = seedWord == 0 ? 0 : uint256(keccak256(abi.encode(seedWord, levelId, "wipe")));
                cfg.remainingPayout = 0;
                cfg.payoutScale = 0;
                cfg.coinPerBond = 0;
                cfg.coinRemaining = 0;
                emit LevelResolved(levelId, cfg.seed, 0, 0);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _resolveShutdownWithBudget(uint256 seedWord, uint24 currentLevel) private {
        if (seedWord == 0) return;

        uint256 len = levelQueue.length;
        uint256 cursor = resolveCursor;
        while (cursor < len) {
            resolveCursor = cursor;
            uint24 levelId = levelQueue[cursor];
            LevelConfig storage cfg = levels[levelId];

            if (!cfg.staged || cfg.resolved) {
                unchecked {
                    ++cursor;
                }
                continue;
            }

            if (currentLevel <= levelId) {
                _wipeRemainingLevels(cursor, seedWord);
                resolveCursor = len;
                return;
            }

            uint256 available = bondObligations;
            uint256 liveBefore = _totalUnresolvedLeafsFrom(cursor);
            if (available >= cfg.maxPayout) {
                _resolveLevel(cfg, levelId, seedWord);
                unchecked {
                    ++cursor;
                }
                continue;
            }

            _resolvePartialLevel(cfg, levelId, seedWord, available, liveBefore);
            unchecked {
                ++cursor;
            }
            _wipeRemainingLevels(cursor, seedWord);
            resolveCursor = len;
            return;
        }

        resolveCursor = cursor;
        uint24 currentLvlView = _currentLevel();
        if (!_hasResolvableLevel(currentLvlView) && !_hasPassedPendingLevel(currentLvlView)) {
            _drainSurplusToVault();
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
        uint256 scale = cfg.payoutScale;
        if (scale == 0) {
            payout = 0;
        } else if (scale != FULL_SCALE) {
            payout = (payout * scale) / FULL_SCALE;
        }
        if (payout > cfg.remainingPayout) revert InsufficientObligations();

        _setClaimed(leaf.levelId, leaf.leafIndex);
        cfg.claimedCount += 1;
        cfg.paidOut += payout;
        cfg.remainingPayout -= payout;

        _consumeBondUnits(leaf.player, leaf.levelId, leaf.amount, 1);

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

    /**
     * @notice Liquidate a fully funded, unresolved bond for a fixed percentage of principal (starts at 90%, -5% per bond-resolution step early).
     * @dev Only allowed for the next scheduled resolution bucket (ceil to next multiple of 5 from the current game level) when fully funded.
     */
    function liquidate(ClaimLeaf calldata leaf, bytes32[] calldata proof) external nonReentrant {
        LevelConfig storage cfg = levels[leaf.levelId];
        if (!cfg.staged || leaf.leafIndex >= cfg.leafCount) revert InvalidLevel();
        if (cfg.resolved) revert NotResolved();
        if (_isClaimed(leaf.levelId, leaf.leafIndex)) revert AlreadyClaimed();

        bytes32 leafHash = _leafHash(leaf);
        if (!_verify(proof, cfg.root, leafHash)) revert InvalidProof();

        uint24 currentLvl = _currentLevel();
        uint24 eligible = _bondLevelFor(currentLvl);
        if (leaf.levelId != eligible) revert InvalidLevel(); // only the next resolution bucket can be liquidated early

        if (bondObligations < cfg.maxPayout) revert InsufficientObligations(); // must be fully funded
        uint256 pendingMax = _pendingMaxPayout();
        if (bondObligations < pendingMax) revert InsufficientObligations(); // keep all staged levels covered

        uint256 bps = _liquidationBps(currentLvl, leaf.levelId);
        if (bps == 0) revert InsufficientObligations();

        uint256 payout = (leaf.amount * bps) / 10_000;
        if (payout == 0 || payout > bondObligations) revert InsufficientObligations();

        // Adjust max payout to reflect removal of this leaf's worst-case liability.
        if (leaf.isLarge && leaf.amount < SMALL_THRESHOLD) revert InvalidAmount();
        if (!leaf.isLarge && leaf.amount >= SMALL_THRESHOLD) revert InvalidAmount();
        uint256 worstCase = leaf.isLarge ? leaf.amount * 2 : ONE;
        if (cfg.maxPayout >= worstCase) {
            cfg.maxPayout -= worstCase;
        } else {
            cfg.maxPayout = 0;
        }
        uint256 comp = levelMaxPayoutComputed[leaf.levelId];
        levelMaxPayoutComputed[leaf.levelId] = comp >= worstCase ? comp - worstCase : 0;

        _setClaimed(leaf.levelId, leaf.leafIndex);
        cfg.claimedCount += 1;
        cfg.paidOut += payout;
        bondObligations -= payout;

        _consumeBondUnits(leaf.player, leaf.levelId, leaf.amount, 1);
        _payout(leaf.player, payout);

        emit Claim(leaf.player, leaf.levelId, leaf.leafIndex, payout, 0);
    }

    /// @notice Early liquidation without a merkle proof for unstaged, fully funded levels (next resolution bucket only).
    /// @param levelId Target level bucket (must be the current liquidation window).
    /// @param basePerBondWei Face value per bond (must match a minted denomination).
    /// @param units Number of bonds of this denomination to liquidate.
    function liquidateUnstaged(uint24 levelId, uint256 basePerBondWei, uint256 units) external nonReentrant {
        LevelConfig storage cfg = levels[levelId];
        if (cfg.staged || cfg.resolved) revert InvalidLevel();
        if (units == 0 || basePerBondWei == 0) revert InvalidAmount();

        uint24 currentLvl = _currentLevel();
        uint24 eligible = _bondLevelFor(currentLvl);
        if (levelId != eligible) revert InvalidLevel(); // only the next resolution bucket can be liquidated early

        uint256 maxPayout = levelMaxPayoutComputed[levelId];
        if (maxPayout == 0 || bondObligations < maxPayout) revert InsufficientObligations();

        uint256 availableUnits = levelDenomCount[levelId][basePerBondWei];
        if (availableUnits < units) revert InvalidAmount();

        uint256 worstPer = _worstCase(basePerBondWei);
        uint256 worstCase = worstPer * units;

        uint256 bps = _liquidationBps(currentLvl, levelId);
        if (bps == 0) revert InsufficientObligations();

        uint256 payout = (basePerBondWei * units * bps) / 10_000;
        if (payout == 0 || payout > bondObligations) revert InsufficientObligations();

        _consumeBondUnits(msg.sender, levelId, basePerBondWei, units);

        bondObligations -= payout;
        levelMaxPayoutComputed[levelId] = maxPayout >= worstCase ? maxPayout - worstCase : 0;

        _payout(msg.sender, payout);
        emit EarlyLiquidation(msg.sender, levelId, basePerBondWei, units, payout);
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

    function _consumeBondUnits(address owner, uint24 levelId, uint256 basePerBondWei, uint256 units) private {
        if (units == 0) revert InvalidAmount();
        if (basePerBondWei == 0) revert InvalidAmount();
        uint256 totalBurn = basePerBondWei * units;
        uint256 denomCount = levelDenomCount[levelId][basePerBondWei];
        if (denomCount < units) revert InvalidAmount();
        levelDenomCount[levelId][basePerBondWei] = denomCount - units;

        uint256 principal = levelPrincipal[levelId];
        if (principal < totalBurn) revert InvalidAmount();
        levelPrincipal[levelId] = principal - totalBurn;

        _burn(owner, levelId, totalBurn);
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

    function _liquidationBps(uint24 current, uint24 levelId) private pure returns (uint256) {
        if (levelId <= current) return 0;
        uint256 delta = uint256(levelId) - current;
        uint256 steps = delta / 5; // each bond resolution bucket is 5 levels
        if (steps >= 20) return 0; // safety cap
        // Starts at 90% and drops 5% per bucket early.
        uint256 bps = 9_000;
        uint256 discount = steps * 500;
        return bps > discount ? bps - discount : 0;
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
        uint256 bal = IERC20Minimal(coin).balanceOf(address(this));
        if (bal < amount) {
            IPurgeCoinBongMinter(coin).bongPayment(amount - bal);
        }
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

        // Require the next two resolution buckets (within 9 levels) to be fully funded.
        if (!_nextTwoBucketsFunded()) return;

        uint256 buffer = _bufferForNextLevels(5);
        uint256 obligations = bondObligations;
        if (obligations <= buffer) return;
        uint256 sendCap = obligations - buffer;

        uint256 ethBal = address(this).balance;
        uint256 stBal = IERC20Minimal(stEthToken).balanceOf(address(this));
        uint256 available = ethBal + stBal;
        if (sendCap > available) {
            sendCap = available;
        }
        if (sendCap == 0) return;

        uint256 sendEth = sendCap <= ethBal ? sendCap : ethBal;
        uint256 sendSt = sendCap - sendEth;

        uint256 newObligations = obligations > sendCap ? obligations - sendCap : 0;
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

        uint24 currentLvl = _currentLevel();
        uint24 lvl = _bondLevelFor(currentLvl);
        if (lvl == 0) {
            if (currentLvl != 0) revert PurchasesClosed(); // presale only when game level is 0
        } else {
            uint24 diff = lvl > currentLvl ? lvl - currentLvl : 0;
            if (diff < 21 || diff > 25) revert PurchasesClosed(); // sales open only 25→21 levels ahead of resolution
        }

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
        if (levelLocked[levelId]) revert TransfersLocked();
        levelIssuedCount[levelId] += count;
        levelPrincipal[levelId] += basePerBongWei * count;
        levelSupply[levelId] += basePerBongWei * count;
        levelDenomCount[levelId][basePerBongWei] += count;
        uint256 worst = _worstCase(basePerBongWei);
        levelMaxPayoutComputed[levelId] += worst * count;
        if (saleLaunchTime != 0) {
            saleSold += count;
        }
        bool large = basePerBongWei >= SMALL_THRESHOLD;

        for (uint256 i; i < count; ) {
            emit BondIssued(levelId, to, basePerBongWei, large);
            _mint(to, levelId, basePerBongWei);
            unchecked {
                ++i;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Pricing helpers (monotone upward per issuance + adaptive sale quoting)
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
        } else if (stepBps != 0) {
            uint256 denom = minBand == 0 ? 1 : minBand;
            step = (startPrice * stepBps) / (10_000 * denom);
        }

        uint256 price = startPrice + currentSold * step;
        if (price > MAX_PRICE) price = MAX_PRICE;
        return price;
    }

    /// @notice Configure adaptive direct-sale pricing (VRGDA-style).
    /// @param basePrice Starting price in wei.
    /// @param targetRateWad Bonds per second, 1e18-scaled (e.g., 0.05 bonds/sec => 5e16).
    /// @param decayUpWad Exponent multiplier when ahead of schedule (1e18-scaled).
    /// @param decayDownWad Exponent multiplier when behind schedule (1e18-scaled, usually smaller).
    /// @param cooldownBuffer Clamp on negative deviation (units = bonds) to prevent steep drops.
    /// @param launchTime Optional override for start time; 0 uses current block.timestamp.
    function configureAdaptiveSale(
        uint256 basePrice,
        uint256 targetRateWad,
        uint256 decayUpWad,
        uint256 decayDownWad,
        uint256 cooldownBuffer,
        uint256 launchTime
    ) external onlyOwner {
        saleBasePrice = basePrice;
        saleTargetRateWad = targetRateWad;
        saleDecayUpWad = decayUpWad;
        saleDecayDownWad = decayDownWad;
        saleCooldownBuffer = cooldownBuffer;
        saleLaunchTime = launchTime == 0 ? block.timestamp : launchTime;
    }

    /// @notice Quote adaptive price for `quantity` bonds using current sale state.
    /// @dev Small-loop integral; reverts for very large qty to prevent gas griefing.
    function quoteAdaptiveSale(uint256 quantity) external view returns (uint256 cost, uint256 nextPrice) {
        if (saleLaunchTime == 0 || saleTargetRateWad == 0 || saleBasePrice == 0) {
            return (0, 0);
        }
        if (quantity > 256) revert InvalidAmount();

        uint256 sold = saleSold;
        uint256 timeNow = block.timestamp;
        for (uint256 i; i < quantity; ) {
            int256 diff = int256(sold + i) - _targetSold(timeNow);
            cost += _adaptivePrice(diff);
            unchecked {
                ++i;
            }
        }

        int256 nextDiff = int256(sold + quantity) - _targetSold(timeNow);
        nextPrice = _adaptivePrice(nextDiff);
    }

    function _targetSold(uint256 t) private view returns (int256) {
        if (saleLaunchTime == 0 || saleTargetRateWad == 0 || t <= saleLaunchTime) return 0;
        uint256 elapsed = t - saleLaunchTime;
        return int256((saleTargetRateWad * elapsed) / FULL_SCALE);
    }

    function _adaptivePrice(int256 diff) private view returns (uint256) {
        if (saleBasePrice == 0) return 0;
        int256 clamped = diff;
        if (clamped < 0 && saleCooldownBuffer != 0) {
            int256 floor = -int256(saleCooldownBuffer);
            if (clamped < floor) clamped = floor;
        }
        int256 decay = clamped > 0 ? int256(saleDecayUpWad) : int256(saleDecayDownWad);
        int256 k = _wadMul(decay, clamped);
        int256 factor = _wadExp(k);
        return uint256(_wadMulSigned(int256(saleBasePrice), factor));
    }

    function _wadMul(int256 a, int256 b) private pure returns (int256) {
        return int256((int256(a) * int256(b)) / WAD_I);
    }

    function _wadMulSigned(int256 a, int256 b) private pure returns (int256) {
        return (a * b) / WAD_I;
    }

    // Taken from solmate PRB-math style expWad; 59x18 fixed-point exponent.
    function _wadExp(int256 x) private pure returns (int256 r) {
        unchecked {
            if (x <= -42139678854452767551) return 0;
            if (x >= 135305999368893231589) revert InvalidAmount();

            x = (x << 78) / 5 ** 18;
            int256 k = ((x << 96) / 54916777467707473351141471128 + (1 << 95)) >> 96;
            x = x - k * 54916777467707473351141471128;
            int256 y = x + 1346386616545796478920950773328;
            y = ((y * x) >> 96) + 57155421227552351082224309758464;
            int256 p = y + x - 94201549194550492254356042504812;
            p = (p * p + (int256(3273285459638523848632254066296) << 96)) >> 96;
            int256 q = y - 2855989394907223263936484059900;
            q = (q * x >> 96) + 50020603652535783019961831881945;
            q = (q * x >> 96) - 533845033583426703283633433725380;
            q = (q * x >> 96) + 3604857256930695427073651918091429;
            r = int256(p) * int256(1 << 96) / q;
            r = (r * 1677202110996718588342820967067443963516166) >> (int256(195) - k);
        }
    }

    function finalizeIssuance(uint256 clearingPrice, uint256 sold) external onlyGame {
        if (clearingPrice != 0) {
            lastClearingPrice = clearingPrice;
        }
        lastSold = sold;
    }

    // ERC1155 metadata
    function uri(uint256 id) external view returns (string memory) {
        address r = renderer;
        if (r == address(0)) return "";
        uint24 lvl = uint24(id);
        bool funded = _fundedFlag(lvl);
        return IPurgeBong1155Renderer(r).bongURI(id, levelSupply[lvl], levelLocked[lvl], levelPrincipal[lvl], funded);
    }

    // ---------------------------------------------------------------------
    // ERC1155 minimal
    // ---------------------------------------------------------------------
    function balanceOf(address account, uint256 id) public view returns (uint256) {
        return balances[id][account];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids) external view returns (uint256[] memory) {
        uint256 len = accounts.length;
        if (len != ids.length) revert InvalidAmount();
        uint256[] memory out = new uint256[](len);
        for (uint256 i; i < len; ) {
            out[i] = balanceOf(accounts[i], ids[i]);
            unchecked {
                ++i;
            }
        }
        return out;
    }

    function setApprovalForAll(address operator, bool approved) external {
        operatorApproval[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address account, address operator) public view returns (bool) {
        return operatorApproval[account][operator];
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        _safeTransferFrom(msg.sender, from, to, id, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        if (to == address(0)) revert ZeroAddress();
        if (ids.length != amounts.length) revert InvalidAmount();
        if (from != msg.sender) _requireApproval(from, msg.sender, ids);
        _beforeTransfer(ids);
        uint256 len = ids.length;
        for (uint256 i; i < len; ) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];
            uint256 bal = balances[id][from];
            if (amount == 0 || bal < amount) revert InsufficientBalance();
            unchecked {
                balances[id][from] = bal - amount;
                balances[id][to] += amount;
                ++i;
            }
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
        _doSafeBatchAcceptanceCheck(msg.sender, from, to, ids, amounts, data);
    }

    function _safeTransferFrom(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) private {
        if (to == address(0)) revert ZeroAddress();
        if (from != operator) _requireApproval(from, operator, _singleIdArray(id));
        _beforeTransfer(_singleIdArray(id));
        uint256 bal = balances[id][from];
        if (amount == 0 || bal < amount) revert InsufficientBalance();
        balances[id][from] = bal - amount;
        balances[id][to] += amount;
        emit TransferSingle(operator, from, to, id, amount);
        _doSafeTransferAcceptanceCheck(operator, from, to, id, amount, data);
    }

    function _singleIdArray(uint256 id) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = id;
        return arr;
    }

    function _beforeTransfer(uint256[] memory ids) private view {
        for (uint256 i; i < ids.length; ) {
            uint256 id = ids[i];
            if (_levelTransfersLocked(uint24(id))) revert TransfersLocked();
            unchecked {
                ++i;
            }
        }
    }

    function _requireApproval(address from, address operator, uint256[] memory ids) private view {
        for (uint256 i; i < ids.length; ) {
            if (_levelTransfersLocked(uint24(ids[i]))) revert Unauthorized();
            unchecked {
                ++i;
            }
        }
        if (!isApprovedForAll(from, operator)) revert Unauthorized();
    }

    function _mint(address to, uint256 id, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (transfersLocked || levelLocked[uint24(id)]) revert TransfersLocked();
        balances[id][to] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    function _burn(address from, uint256 id, uint256 amount) private {
        if (from == address(0)) revert ZeroAddress();
        uint256 bal = balances[id][from];
        if (amount == 0 || bal < amount) revert InsufficientBalance();
        balances[id][from] = bal - amount;
        levelSupply[uint24(id)] -= amount;
        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) private {
        if (to.code.length != 0) {
            try IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data) returns (bytes4 retval) {
                if (retval != IERC1155Receiver.onERC1155Received.selector) revert TransferFailed();
            } catch {
                revert TransferFailed();
            }
        }
    }

    function _doSafeBatchAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) private {
        if (to.code.length != 0) {
            try IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, amounts, data) returns (bytes4 retval) {
                if (retval != IERC1155Receiver.onERC1155BatchReceived.selector) revert TransferFailed();
            } catch {
                revert TransferFailed();
            }
        }
    }
    // Shutdown placeholders (interface compatibility)
    // ---------------------------------------------------------------------
    function finalizeShutdown(uint256 /*maxIds*/) external returns (uint256 processedIds, uint256 burned, bool complete) {
        uint256 seedWord = cachedRngWord;
        if (seedWord == 0 && game != address(0)) {
            seedWord = IPurgeGameLike(game).rngWordForDay(uint48(block.timestamp / 1 days));
            if (seedWord != 0) {
                cachedRngWord = seedWord;
            }
        }

        _resolveReadyLevels(seedWord);

        uint24 currentLevel = _currentLevel();
        processedIds = resolveCursor;
        burned = 0;
        complete = !_hasResolvableLevel(currentLevel) && !_hasPassedPendingLevel(currentLevel);
    }
}

interface IERC1155Receiver {
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data) external returns (bytes4);
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}

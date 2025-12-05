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

interface IPurgeGameMintStreakLike is IPurgeGameLike {
    function ethMintStreakCount(address player) external view returns (uint24);
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

interface IPurgeGameVRFSub {
    function wire(address game_) external;
    function shutdownAndRefund(address target) external;
}

/**
 * @title PurgeBondLiquidityToken
 * @notice Minimal ERC20 used as the transferable/liquid wrapper for bong positions.
 *         Minting/burning is restricted to the parent bongs contract.
 */
contract PurgeBondLiquidityToken {
    // Standard ERC20 surface
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable controller;
    uint24 public immutable levelId;

    error Unauthorized();
    error InvalidAmount();
    error InsufficientBalance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint24 levelId_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        controller = msg.sender;
        levelId = levelId_;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert Unauthorized();
        _;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientBalance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyController {
        if (to == address(0) || amount == 0) revert InvalidAmount();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyController {
        if (from == address(0) || amount == 0) revert InvalidAmount();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0) || from == address(0) || amount == 0) revert InvalidAmount();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
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
    error GateNotEligible();
    error GatePerWalletExceeded();
    error GateExhausted();
    error GateRequiresGame();
    error AlreadyWired();

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
    // payoutCoin kept for ABI compatibility; coin claims are disabled and emit 0.
    event Claim(address indexed player, uint24 indexed levelId, uint256 leafIndex, uint256 payoutEth, uint256 payoutCoin);
    event EarlyLiquidation(address indexed player, uint24 indexed levelId, uint256 basePerBondWei, uint256 units, uint256 payoutEth);
    event Funded(uint256 ethAmount, uint256 stEthAmount, uint256 coinAmount);
    event BondIssued(uint24 indexed levelId, address indexed player, uint256 amount, bool large);
    event BonusIssued(uint24 indexed levelId, address indexed player, uint256 amount, uint256 units, uint8 phase);
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
    event LeafRecorded(
        uint24 indexed levelId,
        uint64 indexed leafIndex,
        address indexed player,
        uint256 amount,
        uint8 bucketId,
        uint256 bucketStart,
        bool isLarge
    );
    event IssuanceGateConfigured(
        uint24 indexed levelId,
        uint24 minStreak,
        uint32 perAddressCap,
        uint256 totalCap,
        uint48 endTime,
        uint64 epoch
    );
    event IssuanceGateDisabled(uint64 epoch);
    event LiquidTokenCreated(uint24 indexed levelId, address token);
    event LiquidBondWrapped(uint24 indexed levelId, address indexed player, uint256 basePerBondWei, uint256 units, address token);
    event LiquidBondRedeemed(uint24 indexed levelId, address indexed player, uint256 basePerBondWei, uint256 units);

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

    struct GateMint {
        uint64 epoch;
        uint256 minted;
    }

    struct WireConfig {
        address coin;
        address game;
        address nft;
        address questModule;
        address jackpots;
        address affiliate;
        address renderer;
        address trophyRenderer;
        address vault;
        address extraToken1;
        address extraToken2;
    }

    struct Accumulator {
        uint256 leafCount;
        bytes32[32] frontier;
        uint256[8] bucketTotals; // running totals for small buckets (for proofs + liability)
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant SMALL_THRESHOLD = 0.5 ether;
    uint256 private constant ONE = 1 ether;
    uint256 private constant FULL_SCALE = 1e18;
    uint256 private constant MAX_PRICE = 5 ether;
    uint256 private constant DRIP_SCALE = 1e18;
    uint16 public constant stakeRateBps = 10_000; // kept for interface compatibility
    uint16 private constant BONUS_PHASE_TARGET_BPS_0 = 200; // 2%
    uint16 private constant BONUS_PHASE_TARGET_BPS_1 = 300; // 3%
    uint16 private constant BONUS_PHASE_TARGET_BPS_2 = 400; // 4%
    uint16 private constant BONUS_PHASE_TARGET_BPS_3 = 800; // 8%

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
    uint256 public coinUnreserved; // PURGE available to assign to future level jackpots
    bool public gameOver;
    bool public transfersLocked; // only used for shutdown
    bool public purchasesEnabled = true;
    bool public jackpotRewardsEnabled = true;
    address public renderer;
    address public vrfSub;
    bool public issuanceGateEnabled;
    uint24 public issuanceGateLevel;
    uint24 public issuanceGateMinStreak;
    uint32 public issuanceGatePerAddressCap;
    uint48 public issuanceGateEndTime;
    uint256 public issuanceGateTotalCap;
    uint256 public issuanceGateMinted;
    uint64 private issuanceGateEpoch;
    mapping(address => GateMint) private issuanceGateMints;

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
    mapping(uint24 => uint256) public levelCoinJackpot; // PURGE earmarked for per-level jackpots
    mapping(uint24 => mapping(uint256 => uint256)) private coinJackpotPrizeByLeaf; // levelId => leafIndex => PURGE prize
    mapping(uint256 => mapping(address => uint256)) private balances; // ERC1155 balances
    mapping(address => mapping(address => bool)) private operatorApproval;
    mapping(uint24 => bool) public levelLocked;
    mapping(uint24 => mapping(uint256 => uint256)) public levelDenomCount; // basePerBondWei => units outstanding
    mapping(uint24 => uint256) public levelSmallPrincipal; // running total principal for small entries (<0.5 ETH)
    mapping(uint24 => uint256) public levelLargePrincipal; // running total principal for large entries (>=0.5 ETH)
    mapping(uint24 => uint256) public levelMaxPayoutComputed; // rolling worst-case liability (updated on mint/liquidation)
    mapping(uint24 => Accumulator) private levelAccumulators; // on-chain merkle accumulator per level
    mapping(uint24 => bool) private levelQueued; // true once the level is in levelQueue for resolution ordering
    mapping(uint24 => uint24) public levelSaleStartLevel; // game level when this bucket first issued a bond
    mapping(uint24 => uint256) public bonusBasePrincipal; // snapshot principal after one level of sales (before bonuses)
    mapping(uint24 => uint256) public bonusMintedPrincipal; // total bonus principal minted (all phases)
    mapping(uint24 => uint256[4]) public bonusMintedByPhase; // bonus principal minted per phase (0-3)
    mapping(uint24 => uint256) public bonusJackpotMinted; // bonus principal minted to the phase-3 jackpot winner
    mapping(uint24 => address) public liquidToken; // ERC20 wrapper for transferable/liquid bonds per level
    mapping(uint24 => uint256) public liquidEscrowPrincipal; // principal currently wrapped into the ERC20 for a level
    mapping(uint24 => uint24) public dripStartLevel; // game level when drip schedule starts (first issuance level)
    mapping(uint24 => uint8) public dripStepCompleted; // how many drip steps executed (0-4)
    mapping(uint24 => uint256) public dripBaseline; // baseline principal captured after first level
    mapping(uint24 => bool) public dripBaselineCaptured;
    mapping(uint24 => uint256) public dripTokenCarry;
    mapping(uint24 => uint256) public dripAccTokenPerShare;
    mapping(uint24 => mapping(address => uint256)) public dripTokenDebt;
    mapping(uint24 => mapping(address => uint256)) public dripTokenOwed;
    uint24[] private dripQueue;
    mapping(uint24 => bool) private dripQueued;

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
    // Drip helpers (holder sets, reward tracking)
    // ---------------------------------------------------------------------
    function _syncTokenRewards(uint24 levelId, address account) private {
        uint256 acc = dripAccTokenPerShare[levelId];
        uint256 debt = dripTokenDebt[levelId][account];
        if (acc == 0) {
            return;
        }
        uint256 bal = _tokenRewardBalance(levelId, account);
        uint256 pending = (bal * acc) / DRIP_SCALE;
        if (pending > debt) {
            dripTokenOwed[levelId][account] += pending - debt;
        }
        dripTokenDebt[levelId][account] = (bal * acc) / DRIP_SCALE;
    }

    function _tokenRewardBalance(uint24 levelId, address account) private view returns (uint256) {
        if (account == address(this)) return 0;
        return balances[levelId][account];
    }

    function _tokenHolderSupply(uint24 levelId) private view returns (uint256) {
        uint256 supply = levelSupply[levelId];
        uint256 escrow = balances[levelId][address(this)];
        return supply > escrow ? supply - escrow : 0;
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
        WireConfig memory cfg;
        cfg.game = game_;
        _wireSystem(cfg);
    }

    function wire(address[] calldata addresses) external onlyOwner {
        WireConfig memory cfg;
        uint256 len = addresses.length;

        // Legacy 3-slot order: [coin, game, vault]
        if (len <= 3) {
            cfg.coin = len > 0 ? addresses[0] : address(0);
            cfg.game = len > 1 ? addresses[1] : address(0);
            cfg.vault = len > 2 ? addresses[2] : address(0);
        } else {
            // Standard order: [coin, game, nft, quest, jackpots, affiliate, renderer, trophyRenderer, vault, extraToken1, extraToken2]
            cfg.coin = addresses[0];
            cfg.game = addresses[1];
            cfg.nft = len > 2 ? addresses[2] : address(0);
            cfg.questModule = len > 3 ? addresses[3] : address(0);
            cfg.jackpots = len > 4 ? addresses[4] : address(0);
            cfg.affiliate = len > 5 ? addresses[5] : address(0);
            cfg.renderer = len > 6 ? addresses[6] : address(0);
            cfg.trophyRenderer = len > 7 ? addresses[7] : address(0);
            cfg.vault = len > 8 ? addresses[8] : address(0);
            cfg.extraToken1 = len > 9 ? addresses[9] : address(0);
            cfg.extraToken2 = len > 10 ? addresses[10] : address(0);
        }

        _wireSystem(cfg);
    }

    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        _setVault(vault_);
    }

    function setCoin(address coin_) external onlyOwner {
        if (coin_ == address(0)) revert ZeroAddress();
        _setCoin(coin_);
    }

    function setRenderer(address renderer_) external onlyOwner {
        if (renderer_ == address(0)) revert ZeroAddress();
        _setRenderer(renderer_);
    }

    function setVrfSub(address vrfSub_) external onlyOwner {
        if (vrfSub_ == address(0)) revert ZeroAddress();
        vrfSub = vrfSub_;
    }

    function setPurchasesEnabled(bool enabled) external onlyOwner {
        purchasesEnabled = enabled;
    }

    function setJackpotRewardsEnabled(bool enabled) external onlyOwner {
        jackpotRewardsEnabled = enabled;
    }

    /// @notice Configure a streak-gated early issuance window for a specific bond level.
    /// @param levelId        Bond level (bucket) the gate applies to.
    /// @param minStreak      Minimum ETH mint streak required to participate (0 disables streak check).
    /// @param perAddressCap  Max bonds per address during the gate (0 = no per-address cap).
    /// @param totalCap       Max bonds that can be issued during the gate (0 = no total cap).
    /// @param endTime        Optional timestamp cutoff for the gate (0 = no time limit).
    function configureIssuanceGate(
        uint24 levelId,
        uint24 minStreak,
        uint32 perAddressCap,
        uint256 totalCap,
        uint48 endTime
    ) external onlyOwner {
        if (levelId == 0 || (levelId % 5 != 0)) revert InvalidLevel();
        if (minStreak != 0 && game == address(0)) revert GateRequiresGame();

        issuanceGateEnabled = true;
        issuanceGateLevel = levelId;
        issuanceGateMinStreak = minStreak;
        issuanceGatePerAddressCap = perAddressCap;
        issuanceGateTotalCap = totalCap;
        issuanceGateEndTime = endTime;
        issuanceGateMinted = 0;
        unchecked {
            issuanceGateEpoch += 1;
        }

        emit IssuanceGateConfigured(levelId, minStreak, perAddressCap, totalCap, endTime, issuanceGateEpoch);
    }

    /// @notice Disable the streak-gated issuance window (public purchases remain subject to standard checks).
    function disableIssuanceGate() external onlyOwner {
        issuanceGateEnabled = false;
        emit IssuanceGateDisabled(issuanceGateEpoch);
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
        _wireSystem(
            WireConfig({
                coin: coin_,
                game: game_,
                nft: nft_,
                questModule: questModule_,
                jackpots: jackpots_,
                affiliate: affiliate_,
                renderer: address(0),
                trophyRenderer: address(0),
                vault: vault_,
                extraToken1: address(0),
                extraToken2: address(0)
            })
        );
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
        _wireSystem(
            WireConfig({
                coin: address(0),
                game: game_,
                nft: nft_,
                questModule: address(0),
                jackpots: address(0),
                affiliate: address(0),
                renderer: renderer_,
                trophyRenderer: trophyRenderer_,
                vault: address(0),
                extraToken1: extraToken1,
                extraToken2: extraToken2
            })
        );
    }

    function _setCoin(address coin_) private returns (address) {
        if (coin_ == address(0)) return coinToken;
        address current = coinToken;
        if (current == address(0)) {
            coinToken = coin_;
            return coin_;
        }
        if (current != coin_) revert AlreadyWired();
        return current;
    }

    function _setGame(address game_) private returns (address) {
        if (game_ == address(0)) return game;
        address current = game;
        if (current == address(0)) {
            game = game_;
            return game_;
        }
        if (current != game_) revert AlreadyWired();
        return current;
    }

    function _setVault(address vault_) private returns (address) {
        if (vault_ == address(0)) return vault;
        address current = vault;
        if (current == address(0)) {
            vault = vault_;
            return vault_;
        }
        if (current != vault_) revert AlreadyWired();
        return current;
    }

    function _setRenderer(address renderer_) private returns (address) {
        if (renderer_ == address(0)) return renderer;
        address current = renderer;
        if (current == address(0)) {
            renderer = renderer_;
            return renderer_;
        }
        if (current != renderer_) revert AlreadyWired();
        return current;
    }

    function _wireCore(address coin_, address game_, address vault_) private returns (address, address, address) {
        return (_setCoin(coin_), _setGame(game_), _setVault(vault_));
    }

    function _wireSystem(WireConfig memory cfg) private {
        (address coinAddr, address gameAddr, address vaultAddr) = _wireCore(cfg.coin, cfg.game, cfg.vault);
        address rendererAddr = _setRenderer(cfg.renderer);

        bool wireCoin = coinAddr != address(0) &&
            (gameAddr != address(0) || cfg.nft != address(0) || cfg.questModule != address(0) || cfg.jackpots != address(0));
        if (wireCoin) {
            address[] memory coinAddrs = new address[](4);
            coinAddrs[0] = gameAddr;
            coinAddrs[1] = cfg.nft;
            coinAddrs[2] = cfg.questModule;
            coinAddrs[3] = cfg.jackpots;
            IPurgeCoinWire(coinAddr).wire(coinAddrs);
        }

        if (cfg.affiliate != address(0) && coinAddr != address(0)) {
            address[] memory affiliateAddrs = new address[](2);
            affiliateAddrs[0] = coinAddr;
            affiliateAddrs[1] = gameAddr;
            IPurgeAffiliateWire(cfg.affiliate).wire(affiliateAddrs);
        }

        if (cfg.jackpots != address(0) && coinAddr != address(0)) {
            address[] memory jackpotAddrs = new address[](2);
            jackpotAddrs[0] = coinAddr;
            jackpotAddrs[1] = gameAddr;
            IPurgeJackpotsWire(cfg.jackpots).wire(jackpotAddrs);
        }

        bool wireRenderersFlag = rendererAddr != address(0) &&
            (cfg.renderer != address(0) || cfg.nft != address(0) || cfg.extraToken1 != address(0) || cfg.extraToken2 != address(0) || gameAddr != address(0));
        if (wireRenderersFlag) {
            address[] memory rendererAddrs = new address[](4);
            rendererAddrs[0] = gameAddr;
            rendererAddrs[1] = cfg.nft;
            rendererAddrs[2] = cfg.extraToken1;
            rendererAddrs[3] = cfg.extraToken2;
            IRendererWire(rendererAddr).wire(rendererAddrs);
        }

        bool wireTrophy = cfg.trophyRenderer != address(0) && cfg.nft != address(0);
        if (wireTrophy) {
            address[] memory trophyAddrs = new address[](1);
            trophyAddrs[0] = cfg.nft;
            IRendererWire(cfg.trophyRenderer).wire(trophyAddrs);
        }

        emit SystemWired(
            coinAddr,
            gameAddr,
            cfg.nft,
            cfg.questModule,
            cfg.jackpots,
            cfg.affiliate,
            rendererAddr,
            cfg.trophyRenderer,
            vaultAddr
        );
        if (wireRenderersFlag || wireTrophy) {
            emit RenderersWired(rendererAddr, cfg.trophyRenderer, gameAddr, cfg.nft, cfg.extraToken1, cfg.extraToken2);
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
    function _appendLeaf(
        uint24 levelId,
        bytes32 leafHash,
        uint8 bucketId,
        uint256 amount
    ) private returns (uint64 leafIndex, uint256 bucketStart) {
        Accumulator storage acc = levelAccumulators[levelId];
        uint256 count = acc.leafCount;
        if (count >= type(uint64).max) revert InvalidAmount();
        leafIndex = uint64(count);

        if (count == 0 && !levelQueued[levelId]) {
            levelQueued[levelId] = true;
            levelQueue.push(levelId);
        }

        if (bucketId < 8 && amount < SMALL_THRESHOLD) {
            bucketStart = acc.bucketTotals[bucketId];
            acc.bucketTotals[bucketId] = bucketStart + amount;
        }

        bytes32 hash = leafHash;
        uint256 idx = count;
        for (uint256 i; i < 32; ) {
            if ((idx & 1) == 0) {
                acc.frontier[i] = hash;
                break;
            } else {
                hash = _hashPair(acc.frontier[i], hash);
            }
            idx >>= 1;
            unchecked {
                ++i;
            }
        }

        acc.leafCount = count + 1;
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _merkleRoot(Accumulator storage acc) private view returns (bytes32 root) {
        uint256 count = acc.leafCount;
        if (count == 0) return bytes32(0);

        root = bytes32(0);
        for (uint256 i; i < 32; ) {
            bytes32 h = acc.frontier[i];
            if (h != bytes32(0)) {
                if (root == bytes32(0)) {
                    root = h;
                } else {
                    root = _hashPair(h, root);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _stageFromAccumulator(uint24 levelId) private {
        LevelConfig storage cfg = levels[levelId];
        if (cfg.staged) return;

        Accumulator storage acc = levelAccumulators[levelId];
        uint256 leafCount = acc.leafCount;
        if (leafCount == 0) return; // nothing to stage

        bytes32 root = _merkleRoot(acc);
        if (root == bytes32(0)) revert InvalidLevel();

        uint256 maxPayout = levelMaxPayoutComputed[levelId];
        if (maxPayout == 0) revert InvalidLevel();

        cfg.root = root;
        cfg.maxPayout = maxPayout;
        cfg.matchedMaxPayout = maxPayout;
        cfg.leafCount = leafCount;
        cfg.bucketTotals = acc.bucketTotals;
        cfg.staged = true;
        levelLocked[levelId] = true;
        if (!levelQueued[levelId]) {
            levelQueued[levelId] = true;
            levelQueue.push(levelId);
        }

        emit LevelStaged(levelId, root, maxPayout, leafCount);
        emit LevelStageMetadata(levelId, cfg.matchedMaxPayout);
    }

    function _autoStageDueLevels(uint24 currentLevel) private {
        uint256 len = levelQueue.length;
        for (uint256 i = resolveCursor; i < len; ) {
            uint24 lvl = levelQueue[i];
            if (levels[lvl].staged || currentLevel <= lvl) {
                unchecked {
                    ++i;
                }
                continue;
            }
            _stageFromAccumulator(lvl);
            unchecked {
                ++i;
            }
        }
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
        uint256 maxBongs
    ) external payable onlyGame {
        // ingest stETH
        if (stEthAmount != 0) {
            if (!IERC20Minimal(stEthToken).transferFrom(msg.sender, address(this), stEthAmount)) revert TransferFailed();
        }

        if (coinAmount != 0) {
            if (coinToken == address(0)) revert InvalidCoin();
            // Stash coin for per-level jackpots (no direct bond claims).
            coinUnreserved += coinAmount; // bookkeeping credit; minting deferred to future jackpot payouts
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

        uint24 currentLvlForDrip = _currentLevel();
        _processDrips(currentLvlForDrip, seedWord);
        _resolveReadyLevels(seedWord, maxBongs);
    }

    /**
     * @notice Attempt to resolve using cached RNG (or freshly available RNG via game day fetch).
     */
    function resolvePendingBongs(uint256 maxBongs) external {
        uint256 seedWord = cachedRngWord;
        uint24 currentLvlForDrip = _currentLevel();
        _processDrips(currentLvlForDrip, seedWord);
        _resolveReadyLevels(0, maxBongs);
    }

    function _resolveReadyLevels(uint256 rngWord, uint256 maxLevels) private {
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
        _autoStageDueLevels(currentLevel);
        bool shortfall;
        uint256 remaining = maxLevels == 0 ? type(uint256).max : maxLevels;
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
            if (--remaining == 0) {
                break;
            }
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

        // Snapshot coin stash for this level (proportional to live unresolved bonds) and fan it out to random bong holders.
        uint256 coinReserved = _allocateCoinJackpot(levelId, cfg.leafCount, liveBefore);
        uint256 coinPot = levelCoinJackpot[levelId];
        if (coinPot != 0) {
            _seedCoinJackpotWinners(levelId, cfg.leafCount, cfg.claimedCount, coinPot, seed);
            levelCoinJackpot[levelId] = 0;
        }

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

        uint256 coinReserved = _allocateCoinJackpot(levelId, cfg.leafCount, liveBefore);
        uint256 coinPot = levelCoinJackpot[levelId];
        if (coinPot != 0) {
            _seedCoinJackpotWinners(levelId, cfg.leafCount, cfg.claimedCount, coinPot, cfg.seed);
            levelCoinJackpot[levelId] = 0;
        }
        emit LevelResolved(levelId, cfg.seed, budget, coinReserved);
    }

    function _allocateCoinJackpot(
        uint24 levelId,
        uint256 leafCount,
        uint256 liveBefore
    ) private returns (uint256 coinReserved) {
        if (coinToken == address(0) || coinUnreserved == 0 || liveBefore == 0 || leafCount == 0) {
            return 0;
        }

        coinReserved = (coinUnreserved * leafCount) / liveBefore;
        if (coinReserved == 0) {
            return 0;
        }

        coinUnreserved -= coinReserved;
        levelCoinJackpot[levelId] += coinReserved;
    }

    function _seedCoinJackpotWinners(
        uint24 levelId,
        uint256 leafCount,
        uint256 claimedCount,
        uint256 coinPot,
        uint256 seed
    ) private {
        if (coinPot == 0 || leafCount == 0) return;
        if (leafCount <= claimedCount) return;

        uint256 available = leafCount - claimedCount;
        uint256 winnerCount = available < 100 ? available : 100;
        if (winnerCount == 0) return;

        uint256[100] memory picks;
        uint256 picked;
        uint256 entropy = seed;
        uint256 attempts;
        uint256 maxAttempts = leafCount * 5;
        if (maxAttempts < winnerCount * 2) {
            maxAttempts = winnerCount * 2;
        }

        while (picked < winnerCount && attempts < maxAttempts) {
            uint256 idx = uint256(keccak256(abi.encode(entropy, levelId, picked, attempts))) % leafCount;
            entropy = uint256(keccak256(abi.encode(entropy, idx)));
            unchecked {
                ++attempts;
            }

            if (_isClaimed(levelId, idx)) continue;

            bool dup;
            for (uint256 j; j < picked; ) {
                if (picks[j] == idx) {
                    dup = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (dup) continue;

            picks[picked] = idx;
            unchecked {
                ++picked;
            }
        }

        if (picked == 0) return;
        winnerCount = picked;

        uint256 firstShare = coinPot / 5; // 20%
        if (firstShare > coinPot) firstShare = coinPot;

        uint256 secondShare = winnerCount > 1 ? coinPot / 10 : 0; // 10% if a second winner exists
        if (firstShare + secondShare > coinPot) {
            secondShare = coinPot - firstShare;
        }

        uint256 remaining = coinPot - firstShare - secondShare;
        uint256 tailWinners = winnerCount > 2 ? winnerCount - 2 : 0;
        uint256 perTail = tailWinners == 0 ? 0 : remaining / tailWinners;
        uint256 dust = remaining - (perTail * tailWinners);

        mapping(uint256 => uint256) storage prizes = coinJackpotPrizeByLeaf[levelId];
        if (winnerCount >= 1) {
            prizes[picks[0]] = firstShare + dust; // dust to the largest slice
        }
        if (winnerCount >= 2) {
            prizes[picks[1]] = secondShare;
        }
        if (tailWinners != 0 && perTail != 0) {
            for (uint256 i = 2; i < winnerCount; ) {
                prizes[picks[i]] = perTail;
                unchecked {
                    ++i;
                }
            }
        }
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

    function _bonusPhaseTarget(uint24 levelId) private returns (uint8 phase, uint256 target, uint256 basePrincipal) {
        uint24 start = levelSaleStartLevel[levelId];
        if (start == 0) {
            phase = type(uint8).max;
            return (phase, 0, 0);
        }

        uint24 curr = _currentLevel();
        if (curr == 0 || curr <= start) {
            phase = type(uint8).max;
            return (phase, 0, 0);
        }

        uint24 offset = curr - start - 1;
        if (offset > 3) offset = 3;
        phase = uint8(offset);

        basePrincipal = bonusBasePrincipal[levelId];
        if (basePrincipal == 0) {
            basePrincipal = levelPrincipal[levelId];
            bonusBasePrincipal[levelId] = basePrincipal;
        }
        if (basePrincipal == 0) {
            target = 0;
            return (phase, target, basePrincipal);
        }

        uint256 bps = _bonusPhaseBps(phase);
        target = (basePrincipal * bps + stakeRateBps - 1) / stakeRateBps; // ceil to avoid shortfalls
    }

    function _bonusPrevTarget(uint256 basePrincipal, uint8 phase) private pure returns (uint256 prevTarget) {
        if (phase == 0) return 0;
        uint256 bps = _bonusPhaseBps(phase - 1);
        prevTarget = (basePrincipal * bps + stakeRateBps - 1) / stakeRateBps;
    }

    function _bonusPhaseBps(uint8 phase) private pure returns (uint256) {
        if (phase == 0) return BONUS_PHASE_TARGET_BPS_0;
        if (phase == 1) return BONUS_PHASE_TARGET_BPS_1;
        if (phase == 2) return BONUS_PHASE_TARGET_BPS_2;
        if (phase == 3) return BONUS_PHASE_TARGET_BPS_3;
        return 0;
    }

    function _levelTransfersLocked(uint24 levelId) private view returns (bool) {
        uint24 curr = _currentLevel();
        if (curr != 0 && _bondLevelFor(curr) == levelId) {
            return true; // lock during the active mint window for this bucket
        }
        LevelConfig storage cfg = levels[levelId];
        if (cfg.resolved) return true; // freeze once resolved

        bool fullyFunded = cfg.staged && !cfg.resolved && bondObligations >= cfg.maxPayout;
        if (!fullyFunded) return false;

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
        if (gameLevel == 0) return 5; // presale bonds point to level 5 bucket
        if (gameLevel <= 3) return 5;
        if (gameLevel <= 6) return 10;
        if (gameLevel <= 8) return 15;
        if (gameLevel <= 12) return 20;
        if (gameLevel <= 15) return 25;
        // Standard window: 25-21 levels ahead of resolution bucket (multiples of 5 only).
        uint24 ahead = gameLevel + 25;
        uint24 bucket = ahead / 5;
        return bucket * 5;
    }

    function _gateActiveFor(uint24 levelId) private view returns (bool) {
        if (!issuanceGateEnabled || levelId != issuanceGateLevel) return false;
        if (issuanceGateEndTime != 0 && block.timestamp > issuanceGateEndTime) return false;
        if (issuanceGateTotalCap != 0 && issuanceGateMinted >= issuanceGateTotalCap) return false;
        return true;
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

    /// @notice View helper for the streak-gated issuance window.
    function issuanceGateStatus()
        external
        view
        returns (
            bool active,
            uint24 levelId,
            uint24 minStreak,
            uint32 perAddressCap,
            uint256 totalCap,
            uint256 totalMinted,
            uint256 remainingCap,
            uint48 endTime
        )
    {
        levelId = issuanceGateLevel;
        minStreak = issuanceGateMinStreak;
        perAddressCap = issuanceGatePerAddressCap;
        totalCap = issuanceGateTotalCap;
        totalMinted = issuanceGateMinted;
        endTime = issuanceGateEndTime;

        active = _gateActiveFor(levelId);
        remainingCap = totalCap == 0 || totalMinted >= totalCap ? 0 : (totalCap - totalMinted);
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
            if (cfg.resolved) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (cfg.staged) {
                total += cfg.maxPayout;
            } else {
                uint256 computed = levelMaxPayoutComputed[levelQueue[i]];
                total += computed;
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
            if (!cfg.resolved) {
                if (cfg.staged) {
                    total += cfg.maxPayout;
                } else {
                    total += levelMaxPayoutComputed[levelQueue[i]];
                }
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
            if (!cfg.resolved) {
                uint256 need = cfg.staged ? cfg.maxPayout : levelMaxPayoutComputed[lvl];
                if (need != 0 && bondObligations >= need) {
                    if (lvl == firstBucket) firstFound = true;
                    if (lvl == secondBucket) secondFound = true;
                }
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
                emit LevelResolved(levelId, cfg.seed, 0, 0);
            }
            uint256 coinPot = levelCoinJackpot[levelId];
            if (coinPot != 0) {
                coinUnreserved += coinPot;
                levelCoinJackpot[levelId] = 0;
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
                _drainAllToVault();
                _shutdownVrfSub();
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
            _drainAllToVault();
            _shutdownVrfSub();
            return;
        }

        resolveCursor = cursor;
        uint24 currentLvlView = _currentLevel();
        if (!_hasResolvableLevel(currentLvlView) && !_hasPassedPendingLevel(currentLvlView)) {
            _drainAllToVault();
            _shutdownVrfSub();
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
        uint256 coinOut = _claimCoinJackpot(leaf.levelId, leaf.leafIndex, leaf.player);
        emit Claim(leaf.player, leaf.levelId, leaf.leafIndex, payout, coinOut);

        // return surplus to the pool once every claim is done
        if (cfg.claimedCount == cfg.leafCount && cfg.remainingPayout != 0) {
            bondObligations += cfg.remainingPayout;
            cfg.remainingPayout = 0;
        }
    }

    /// @notice Staged bonds must be claimed via the merkle tree; liquidation after staging is disabled.
    function liquidate(ClaimLeaf calldata /*leaf*/, bytes32[] calldata /*proof*/) external pure {
        revert InvalidLevel();
    }

    /// @notice Early liquidation without a merkle proof for unstaged levels (next resolution bucket only; requires at least half funding).
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
        uint256 halfMax = (maxPayout + 1) / 2;
        if (maxPayout == 0 || bondObligations < halfMax) revert InsufficientObligations();

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

    function _consumeBondUnits(address holder, uint24 levelId, uint256 basePerBondWei, uint256 units) private {
        if (units == 0) revert InvalidAmount();
        if (basePerBondWei == 0) revert InvalidAmount();
        uint256 totalBurn = basePerBondWei * units;
        uint256 denomCount = levelDenomCount[levelId][basePerBondWei];
        if (denomCount < units) revert InvalidAmount();
        levelDenomCount[levelId][basePerBondWei] = denomCount - units;

        uint256 principal = levelPrincipal[levelId];
        if (principal < totalBurn) revert InvalidAmount();
        levelPrincipal[levelId] = principal - totalBurn;
        if (basePerBondWei >= SMALL_THRESHOLD) {
            uint256 largePrincipal = levelLargePrincipal[levelId];
            levelLargePrincipal[levelId] = largePrincipal >= totalBurn ? largePrincipal - totalBurn : 0;
        } else {
            uint256 smallPrincipal = levelSmallPrincipal[levelId];
            levelSmallPrincipal[levelId] = smallPrincipal >= totalBurn ? smallPrincipal - totalBurn : 0;
        }

        _burn(holder, levelId, totalBurn);
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

    function _claimCoinJackpot(uint24 levelId, uint256 leafIndex, address to) private returns (uint256 coinOut) {
        coinOut = coinJackpotPrizeByLeaf[levelId][leafIndex];
        if (coinOut == 0 || to == address(0)) return 0;
        coinJackpotPrizeByLeaf[levelId][leafIndex] = 0;
        _payoutCoin(to, coinOut);
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

    function _drainAllToVault() private {
        address vault_ = vault;
        if (vault_ == address(0)) return;

        uint256 obligations = bondObligations;
        if (obligations == 0) return;

        uint256 ethBal = address(this).balance;
        uint256 stBal = IERC20Minimal(stEthToken).balanceOf(address(this));
        uint256 available = ethBal + stBal;
        if (available == 0) return;

        uint256 sendCap = obligations <= available ? obligations : available;
        if (sendCap == 0) return;

        uint256 sendEth = sendCap <= ethBal ? sendCap : ethBal;
        uint256 sendSt = sendCap - sendEth;

        bondObligations = obligations > sendCap ? obligations - sendCap : 0;

        if (sendEth != 0) {
            (bool ok, ) = vault_.call{value: sendEth}("");
            if (!ok) revert TransferFailed();
        }
        if (sendSt != 0) {
            if (!IERC20Minimal(stEthToken).transfer(vault_, sendSt)) revert TransferFailed();
        }
    }

    function _shutdownVrfSub() private {
        address sub = vrfSub;
        if (sub == address(0)) return;
        try IPurgeGameVRFSub(sub).shutdownAndRefund(address(this)) {} catch {}
    }

    function _bumpGateMint(address player, uint256 amount, uint32 perAddressCap, uint64 epoch) private {
        GateMint storage gm = issuanceGateMints[player];
        if (gm.epoch != epoch) {
            gm.epoch = epoch;
            gm.minted = 0;
        }
        uint256 newMinted = gm.minted + amount;
        if (perAddressCap != 0 && newMinted > perAddressCap) revert GatePerWalletExceeded();
        gm.minted = newMinted;
    }

    function _enforceIssuanceGate(uint24 lvl, address[] calldata recipients, uint256 mintCount) private {
        if (!_gateActiveFor(lvl)) return;

        uint256 newTotal = issuanceGateMinted + mintCount;
        uint256 totalCap = issuanceGateTotalCap;
        if (totalCap != 0 && newTotal > totalCap) revert GateExhausted();

        uint24 minStreak = issuanceGateMinStreak;
        uint32 perCap = issuanceGatePerAddressCap;
        uint64 epoch = issuanceGateEpoch;
        bool checkStreak = minStreak != 0;
        IPurgeGameMintStreakLike gameContract = IPurgeGameMintStreakLike(game);
        if (checkStreak && address(gameContract) == address(0)) revert GateRequiresGame();

        uint256 len = recipients.length;
        if (len == 1) {
            address to = recipients[0];
            if (checkStreak && gameContract.ethMintStreakCount(to) < minStreak) revert GateNotEligible();
            _bumpGateMint(to, mintCount, perCap, epoch);
        } else {
            for (uint256 i; i < len; ) {
                address to = recipients[i];
                if (checkStreak && gameContract.ethMintStreakCount(to) < minStreak) revert GateNotEligible();
                _bumpGateMint(to, 1, perCap, epoch);
                unchecked {
                    ++i;
                }
            }
        }

        issuanceGateMinted = newTotal;
    }

    // ---------------------------------------------------------------------
    // Drip schedule (per-level, 5-level window)
    // ---------------------------------------------------------------------
    function _processDrips(uint24 currentLevel, uint256 /*rngWord*/) private {
        uint256 len = dripQueue.length;
        for (uint256 i; i < len; ) {
            uint24 levelId = dripQueue[i];
            uint24 startLvl = dripStartLevel[levelId];
            if (startLvl == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            if (!dripBaselineCaptured[levelId]) {
                if (currentLevel > startLvl) {
                    dripBaseline[levelId] = levelPrincipal[levelId];
                    dripBaselineCaptured[levelId] = true;
                } else {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
            }

            uint8 step = dripStepCompleted[levelId];
            bool progressed;
            while (step < 4 && currentLevel > startLvl + step) {
                uint256 base = dripBaseline[levelId];
                if (base == 0) break;
                if (step == 0) {
                    _distributeTokenProRata(levelId, base / 100); // +1% to base holders
                } else if (step == 1) {
                    _distributeTokenProRata(levelId, (base * 2) / 100);
                } else if (step == 2) {
                    _distributeTokenProRata(levelId, base / 100);
                    _distributeTokenProRata(levelId, base / 100);
                } else if (step == 3) {
                    _distributeTokenProRata(levelId, (base * 3) / 100);
                }
                step += 1;
                progressed = true;
            }
            if (progressed) {
                dripStepCompleted[levelId] = step;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _distributeTokenProRata(uint24 levelId, uint256 amount) private {
        if (amount == 0) return;
        amount += dripTokenCarry[levelId];
        uint256 supply = _tokenHolderSupply(levelId);
        if (supply == 0) {
            dripTokenCarry[levelId] = amount;
            return;
        }
        uint256 acc = dripAccTokenPerShare[levelId];
        acc += (amount * DRIP_SCALE) / supply;
        dripAccTokenPerShare[levelId] = acc;
        dripTokenCarry[levelId] = 0;
    }
    function _mintTokenReward(uint24 levelId, address to, uint256 principal) private {
        if (principal == 0 || to == address(0)) return;
        _syncTokenRewards(levelId, to);
        _mintPrincipalSplit(levelId, to, principal);
        _syncTokenRewards(levelId, to);
    }

    function _mintPrincipalSplit(uint24 levelId, address to, uint256 principal) private {
        uint256 remaining = principal;
        while (remaining != 0) {
            uint256 base = remaining > MAX_PRICE ? MAX_PRICE : remaining;
            uint256 units = remaining / base;
            if (units > 128) {
                units = 128;
            }
            uint256 chunk = base * units;
            _issue(to, levelId, base, units);
            remaining -= chunk;
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
        if (lvl == 0 || currentLvl >= lvl) revert PurchasesClosed();

        uint24 diff = lvl - currentLvl;
        bool earlyWindow = (lvl == 5 && currentLvl <= 3) ||
            (lvl == 10 && currentLvl <= 6) ||
            (lvl == 15 && currentLvl <= 8) ||
            (lvl == 20 && currentLvl <= 12) ||
            (lvl == 25 && currentLvl <= 15);
        bool standardWindow = (diff >= 21 && diff <= 25);
        if (!earlyWindow && !standardWindow) revert PurchasesClosed(); // sales open only in configured windows

        startIndex = levelIssuedCount[lvl];

        _enforceIssuanceGate(lvl, recipients, mintCount);

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

    // ---------------------------------------------------------------------
    // Liquid wrapper (ERC20, must redeem back before resolution)
    // ---------------------------------------------------------------------
    function wrapToLiquidBond(
        uint24 levelId,
        uint256 basePerBondWei,
        uint256 units
    ) external nonReentrant returns (address token) {
        if (transfersLocked) revert TransfersLocked();
        if (units == 0 || basePerBondWei == 0) revert InvalidAmount();
        if (levelId == 0) revert InvalidLevel();

        LevelConfig storage cfg = levels[levelId];
        if (cfg.resolved) revert InvalidLevel();

        uint256 amount = basePerBondWei * units;
        uint256 bal = balances[levelId][msg.sender];
        if (bal < amount) revert InsufficientBalance();

        token = _ensureLiquidToken(levelId);

        // Move illiquid bonds into escrow on this contract.
        balances[levelId][msg.sender] = bal - amount;
        balances[levelId][address(this)] += amount;
        emit TransferSingle(msg.sender, msg.sender, address(this), levelId, amount);

        liquidEscrowPrincipal[levelId] += amount;
        PurgeBondLiquidityToken(token).mint(msg.sender, amount);
        emit LiquidBondWrapped(levelId, msg.sender, basePerBondWei, units, token);
    }

    function redeemLiquidBond(uint24 levelId, uint256 basePerBondWei, uint256 units) external nonReentrant {
        if (transfersLocked) revert TransfersLocked();
        if (units == 0 || basePerBondWei == 0) revert InvalidAmount();
        if (levelId == 0) revert InvalidLevel();

        LevelConfig storage cfg = levels[levelId];
        if (cfg.resolved) revert InvalidLevel();

        address token = liquidToken[levelId];
        if (token == address(0)) revert InvalidLevel();

        uint256 amount = basePerBondWei * units;
        uint256 escrow = liquidEscrowPrincipal[levelId];
        if (escrow < amount) revert InsufficientBalance();

        PurgeBondLiquidityToken(token).burn(msg.sender, amount);
        liquidEscrowPrincipal[levelId] = escrow - amount;

        uint256 contractBal = balances[levelId][address(this)];
        if (contractBal < amount) revert InsufficientBalance();
        balances[levelId][address(this)] = contractBal - amount;
        balances[levelId][msg.sender] += amount;
        emit TransferSingle(msg.sender, address(this), msg.sender, levelId, amount);
        emit LiquidBondRedeemed(levelId, msg.sender, basePerBondWei, units);
    }

    function liquidTokenFor(uint24 levelId) external view returns (address) {
        return liquidToken[levelId];
    }

    /// @notice Claim any owed drip mint allocations for the caller on a specific level.
    function claimDrip(uint24 levelId) external nonReentrant {
        _syncTokenRewards(levelId, msg.sender);
        _mintDripOwed(levelId, msg.sender);
    }

    function _ensureLiquidToken(uint24 levelId) private returns (address token) {
        token = liquidToken[levelId];
        if (token != address(0)) {
            return token;
        }

        string memory idStr = _toString(levelId);
        token = address(new PurgeBondLiquidityToken(
            string(abi.encodePacked("Purge Liquid Bond L", idStr)),
            string(abi.encodePacked("PLB", idStr)),
            18,
            levelId
        ));
        liquidToken[levelId] = token;
        emit LiquidTokenCreated(levelId, token);
    }

    function _mintDripOwed(uint24 levelId, address to) private {
        uint256 tokenOwed = dripTokenOwed[levelId][to];
        if (tokenOwed != 0) {
            dripTokenOwed[levelId][to] = 0;
            _mintTokenReward(levelId, to, tokenOwed);
            _syncTokenRewards(levelId, to);
        }
    }

    function _refreshTokenDebt(uint24 levelId, address account) private {
        dripTokenDebt[levelId][account] =
            (_tokenRewardBalance(levelId, account) * dripAccTokenPerShare[levelId]) /
            DRIP_SCALE;
    }

    /// @notice Admin bonus minting: add bonus bonds for a level within the capped bonus schedule.
    /// @dev Bonus window opens one game level after the first issuance for the bucket. Phases unlock sequentially (2%, 3%, 4%, 8% cumulative).
    ///      Selection of recipients is expected to be done offchain; this function only enforces the phase cap and integrates accounting.
    function distributeBonusBongs(
        uint24 levelId,
        address[] calldata recipients,
        uint256[] calldata basePerBongWei,
        uint256[] calldata counts
    ) external onlyOwner {
        uint256 len = recipients.length;
        if (len == 0 || len != basePerBongWei.length || len != counts.length) revert InvalidAmount();
        if (levelLocked[levelId]) revert TransfersLocked();

        (uint8 phase, uint256 target, uint256 basePrincipal) = _bonusPhaseTarget(levelId);
        if (phase == type(uint8).max || target == 0 || basePrincipal == 0) revert InvalidLevel();

        uint256 minted = bonusMintedPrincipal[levelId];
        if (minted >= target) revert InvalidAmount();

        uint256 available = target - minted;
        uint256 basePrincipalPrev = _bonusPrevTarget(basePrincipal, phase);

        if (phase == 3) {
            // Reserve 1/4 of the phase-3 incremental issuance for the jackpot winner.
            uint256 phaseCap = target > basePrincipalPrev ? target - basePrincipalPrev : 0;
            uint256 jackpotReserve = phaseCap / 4;
            uint256 mintedJackpot = bonusJackpotMinted[levelId];
            uint256 mintedPhaseTotal = bonusMintedByPhase[levelId][3];
            uint256 mintedPhaseNonJackpot = mintedPhaseTotal > mintedJackpot ? mintedPhaseTotal - mintedJackpot : 0;

            uint256 nonJackpotCap = phaseCap > jackpotReserve ? phaseCap - jackpotReserve : 0;
            uint256 remainingNonJackpot = nonJackpotCap > mintedPhaseNonJackpot ? nonJackpotCap - mintedPhaseNonJackpot : 0;

            uint256 earlierShortfall = basePrincipalPrev > minted ? basePrincipalPrev - minted : 0;
            available = remainingNonJackpot + earlierShortfall;
            if (available == 0) revert InvalidAmount();
        }

        for (uint256 i; i < len; ) {
            address to = recipients[i];
            if (to == address(0)) revert ZeroAddress();
            uint256 units = counts[i];
            uint256 base = basePerBongWei[i];
            if (units == 0 || base == 0 || base > MAX_PRICE) revert InvalidAmount();

            uint256 addPrincipal = base * units;
            if (addPrincipal > available || minted + addPrincipal > target) revert InsufficientObligations();
            _issue(to, levelId, base, units);
            minted += addPrincipal;
            available -= addPrincipal;
            bonusMintedByPhase[levelId][phase] += addPrincipal;
            emit BonusIssued(levelId, to, base, units, phase);
            unchecked {
                ++i;
            }
        }

        bonusMintedPrincipal[levelId] = minted;
    }

    /// @notice Phase-3 jackpot: mint up to 25% of the phase-3 allocation to a single class-A holder (weighted selection done offchain).
    function distributeBonusJackpot(
        uint24 levelId,
        address winner,
        uint256 basePerBongWei,
        uint256 units
    ) external onlyOwner {
        if (winner == address(0)) revert ZeroAddress();
        if (units == 0 || basePerBongWei == 0 || basePerBongWei > MAX_PRICE) revert InvalidAmount();
        if (levelLocked[levelId]) revert TransfersLocked();

        (uint8 phase, uint256 target, uint256 basePrincipal) = _bonusPhaseTarget(levelId);
        if (phase != 3 || target == 0 || basePrincipal == 0) revert InvalidLevel();

        uint256 prevTarget = _bonusPrevTarget(basePrincipal, phase);
        uint256 phaseCap = target > prevTarget ? target - prevTarget : 0;
        uint256 jackpotReserve = phaseCap / 4;
        if (jackpotReserve == 0) revert InvalidAmount();

        uint256 mintedJackpot = bonusJackpotMinted[levelId];
        if (mintedJackpot >= jackpotReserve) revert InvalidAmount();

        uint256 remainingJackpot = jackpotReserve - mintedJackpot;
        uint256 principal = basePerBongWei * units;
        if (principal == 0 || principal != remainingJackpot) revert InvalidAmount();

        // Require the winner to hold class-A supply to align with "weighted by holdings".
        uint256 classABalance = balances[uint256(levelId)][winner];
        if (classABalance == 0) revert GateNotEligible();

        _issue(winner, levelId, basePerBongWei, units);

        bonusJackpotMinted[levelId] = mintedJackpot + principal;
        bonusMintedByPhase[levelId][phase] += principal;
        bonusMintedPrincipal[levelId] += principal;

        emit BonusIssued(levelId, winner, basePerBongWei, units, phase);
    }

    function _issue(address to, uint24 levelId, uint256 basePerBongWei, uint256 count) private {
        if (levelLocked[levelId]) revert TransfersLocked();
        if (levelIssuedCount[levelId] == 0 && levelSaleStartLevel[levelId] == 0) {
            uint24 currLvl = _currentLevel();
            if (currLvl != 0) {
                levelSaleStartLevel[levelId] = currLvl;
                if (dripStartLevel[levelId] == 0) {
                    dripStartLevel[levelId] = currLvl;
                    if (!dripQueued[levelId]) {
                        dripQueued[levelId] = true;
                        dripQueue.push(levelId);
                    }
                }
            }
        }
        levelIssuedCount[levelId] += count;
        uint256 principalAdded = basePerBongWei * count;
        levelPrincipal[levelId] += principalAdded;
        bool large = basePerBongWei >= SMALL_THRESHOLD;
        if (large) {
            levelLargePrincipal[levelId] += principalAdded;
        } else {
            levelSmallPrincipal[levelId] += principalAdded;
        }
        levelSupply[levelId] += principalAdded;
        levelDenomCount[levelId][basePerBongWei] += count;
        uint256 worst = _worstCase(basePerBongWei);
        levelMaxPayoutComputed[levelId] += worst * count;

        Accumulator storage acc = levelAccumulators[levelId];
        for (uint256 i; i < count; ) {
            uint256 leafIdx = acc.leafCount;
            uint8 bucketId = large ? 0 : uint8(leafIdx & 7); // round-robin small buckets
            uint256 bucketStart = bucketId < 8 && !large ? acc.bucketTotals[bucketId] : 0;

            ClaimLeaf memory leaf = ClaimLeaf({
                levelId: levelId,
                leafIndex: uint64(leafIdx),
                player: to,
                amount: basePerBongWei,
                bucketId: bucketId,
                pairId: 0,
                pairSide: false,
                isLarge: large,
                bucketStart: bucketStart
            });

            bytes32 leafHash = keccak256(
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

            (uint64 storedIndex, uint256 start) = _appendLeaf(levelId, leafHash, bucketId, basePerBongWei);
            emit LeafRecorded(levelId, storedIndex, to, basePerBongWei, bucketId, start, large);
            emit BondIssued(levelId, to, basePerBongWei, large);
            _mint(to, levelId, basePerBongWei);
            unchecked {
                ++i;
            }
        }
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
            _syncTokenRewards(uint24(id), from);
            _syncTokenRewards(uint24(id), to);
            uint256 bal = balances[id][from];
            if (amount == 0 || bal < amount) revert InsufficientBalance();
            unchecked {
                balances[id][from] = bal - amount;
                balances[id][to] += amount;
                dripTokenDebt[uint24(id)][from] =
                    (_tokenRewardBalance(uint24(id), from) * dripAccTokenPerShare[uint24(id)]) /
                    DRIP_SCALE;
                dripTokenDebt[uint24(id)][to] =
                    (_tokenRewardBalance(uint24(id), to) * dripAccTokenPerShare[uint24(id)]) /
                    DRIP_SCALE;
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
        _syncTokenRewards(uint24(id), from);
        _syncTokenRewards(uint24(id), to);
        _beforeTransfer(_singleIdArray(id));
        uint256 bal = balances[id][from];
        if (amount == 0 || bal < amount) revert InsufficientBalance();
        balances[id][from] = bal - amount;
        balances[id][to] += amount;
        dripTokenDebt[uint24(id)][from] =
            (_tokenRewardBalance(uint24(id), from) * dripAccTokenPerShare[uint24(id)]) /
            DRIP_SCALE;
        dripTokenDebt[uint24(id)][to] =
            (_tokenRewardBalance(uint24(id), to) * dripAccTokenPerShare[uint24(id)]) /
            DRIP_SCALE;
        emit TransferSingle(operator, from, to, id, amount);
        _doSafeTransferAcceptanceCheck(operator, from, to, id, amount, data);
    }

    function _singleIdArray(uint256 id) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = id;
        return arr;
    }

    function _beforeTransfer(uint256[] memory /*ids*/) private view {
        // Keep transfers globally lockable; per-level locks removed for flexibility.
        if (transfersLocked) revert TransfersLocked();
    }

    function _requireApproval(address from, address operator, uint256[] memory /*ids*/) private view {
        if (transfersLocked) revert Unauthorized();
        if (!isApprovedForAll(from, operator)) revert Unauthorized();
    }

    function _mint(address to, uint256 id, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (transfersLocked || levelLocked[uint24(id)]) revert TransfersLocked();
        _syncTokenRewards(uint24(id), to);
        balances[id][to] += amount;
        dripTokenDebt[uint24(id)][to] =
            (_tokenRewardBalance(uint24(id), to) * dripAccTokenPerShare[uint24(id)]) /
            DRIP_SCALE;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    function _burn(address from, uint256 id, uint256 amount) private {
        if (from == address(0)) revert ZeroAddress();
        uint256 bal = balances[id][from];
        if (amount == 0 || bal < amount) revert InsufficientBalance();
        _syncTokenRewards(uint24(id), from);
        balances[id][from] = bal - amount;
        dripTokenDebt[uint24(id)][from] =
            (_tokenRewardBalance(uint24(id), from) * dripAccTokenPerShare[uint24(id)]) /
            DRIP_SCALE;
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

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits += 1;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
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

        _resolveReadyLevels(seedWord, 0);

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

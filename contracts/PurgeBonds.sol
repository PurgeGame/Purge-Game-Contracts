// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ===========================================================================
// Interfaces
// ===========================================================================

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC20Approve is IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

interface IPurgeBondRenderer {
    function bondTokenURI(
        uint256 tokenId,
        uint32 createdDistance,
        uint32 currentDistance,
        uint16 chanceBps,
        bool staked,
        uint256 sellCoinValue
    ) external view returns (string memory);
}

interface IPurgeGameLike {
    function rngWordForDay(uint48 day) external view returns (uint256);
    function emergencyUpdateVrfCoordinator(address newCoordinator) external;
}

interface IPurgeCoinBondMinter {
    function bondPayment(uint256 amount) external;
}

interface IPurgeAffiliateLike {
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external returns (uint256);
    function shutdownPresale() external;
}

interface IPurgeGamePrice {
    function mintPrice() external view returns (uint256);
    function coinPriceUnit() external view returns (uint256);
}

interface IStEthWithdrawalQueue {
    function requestWithdrawals(
        uint256[] calldata amounts,
        address owner
    ) external returns (uint256[] memory requestIds);

    function claimWithdrawals(
        uint256[] calldata requestIds,
        uint256[] calldata hints
    ) external returns (uint256[] memory amounts);
}

interface IPurgeGameBondWinnings {
    function creditBondWinnings(address player) external payable;
}

interface IPurgeGameBondSinks {
    function bondRewardDeposit() external payable;
    function bondYieldDeposit() external payable;
}

/**
 * @title PurgeBonds
 * @notice A lightweight ERC721 implementation for gamified "bonds".
 * @dev
 * Core Mechanics:
 * 1. Minting: Users pay ETH to mint bonds. Price is dynamic (decay + demand bumps).
 * 2. Betting: Users choose a `basePrice`. Win chance = `basePrice / 1 ETH`.
 * 3. Payouts:
 *    - Winners get topped up to 1 ETH (or 1 stETH).
 *    - Winners get a share of the PURGE token pool.
 *    - Staked bonds are non-transferable; all bonds share the same PURGE token weight.
 * 4. Accounting:
 *    - `totalCoinOwed` tracks the SUM of all potential liabilities (Weighted).
 *    - This ensures the contract is always solvent for the winning scenario.
 */
contract PurgeBonds {
    // ===========================================================================
    // Errors
    // ===========================================================================
    error Unauthorized(); // 0x82b42900
    error ZeroAddress(); // 0xd92e233d
    error InvalidToken(); // 0xc1ab6dc1
    error CallFailed(); // 0x3204506f
    error InvalidRisk(); // 0x99963255
    error WrongPrice(); // 0xcf16278b
    error NotClaimable(); // 0x203d82d8
    error AlreadyClaimed(); // 0x646cf558
    error PurchasesClosed(); // 0x827f9581
    error InsufficientCoinAvailable(); // 0xdec227d9
    error ResolvePendingAlready(); // 0x2f0d353d
    error ResolveNotReady(); // 0xc254d528
    error InsufficientEthForResolve(); // 0x6d552e2d
    error InvalidRng(); // 0x4b0b761f
    error InvalidQuantity(); // 0x9a23d870
    error InvalidBase(); // 0x55862059
    error InsufficientHeadroom(); // 0x19c42145
    error TransferBlocked(); // 0x30227e53
    error InvalidRate(); // 0x26650026
    error AlreadyConfigured(); // 0x2e68d627
    error GameOver(); // 0x0e647580
    error ShutdownPendingResolution(); // 0x2306321e
    error ExpiredSweepLocked(); // 0x44132333
    error InsufficientPayout(); // 0x8024d516
    error NotSellable(); // 0x762107fd
    error InvalidPrice(); // 0x3c7fd3c2

    // ===========================================================================
    // Events
    // ===========================================================================
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Purchased(address indexed buyer, uint256 indexed tokenId, uint256 basePrice, uint256 price);
    event ClaimEnabled(uint256 indexed tokenId);
    event Claimed(address indexed to, uint256 indexed tokenId, uint256 ethPaid, uint256 stEthPaid, uint256 bondPaid);
    event BondsPaid(uint256 ethAdded, uint256 stEthAdded, uint256 bondPoolAdded);
    event BondResolved(uint256 indexed tokenId, bool win, uint16 chanceBps, uint256 roll);
    event BondBurned(uint256 indexed tokenId);
    event GameShutdown(uint256 burnCursor);
    event ShutdownBurned(uint256 processed, uint256 burned, bool complete);
    event BondSold(address indexed seller, uint256 indexed tokenId, uint256 payoutWei);

    // ===========================================================================
    // Constants & Configuration
    // ===========================================================================

    // -- Bitmasks for ERC721A-style packing --
    // [0..63]: Balance | [64..127]: Minted Count | [128..191]: Burned Count
    uint256 private constant _BITMASK_ADDRESS_DATA_ENTRY = (1 << 64) - 1;
    uint256 private constant _BITPOS_NUMBER_MINTED = 64;
    uint256 private constant _BITPOS_NUMBER_BURNED = 128;

    // -- Bitmasks for Token Ownership Slots --
    // [0..159]: Address | [160..223]: Timestamp | [224]: Burned | [225]: Initialized | [232]: Staked | [233]: Claimable
    uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;
    uint256 private constant _BITPOS_START_TIMESTAMP = 160;
    uint256 private constant _BITMASK_BURNED = 1 << 224;
    uint256 private constant _BITMASK_NEXT_INITIALIZED = 1 << 225;
    uint256 private constant _BITPOS_STAKED = 232;
    uint256 private constant _BITMASK_STAKED = 1 << _BITPOS_STAKED;
    uint256 private constant _BITPOS_CLAIM_READY = 233;
    uint256 private constant _BITMASK_CLAIM_READY = 1 << _BITPOS_CLAIM_READY;

    // -- Game Config --
    uint256 private constant MULT_SCALE = 1e18;
    uint256 private constant DECAY_BPS = 9950; // 0.5% daily price decay
    uint256 private constant BPS_DENOM = 10_000;
    uint64 private constant DECAY_DELAY_DAYS = 7; // Bumps delay decay for 7 days
    uint256 private constant COIN_WEIGHT_UNMARKETABLE = 5; // Staked (non-transferable) weight
    uint256 private constant COIN_WEIGHT_MARKETABLE = 5; // Unstaked (transferable) weight (no penalty)
    uint256 private constant MIN_BASE_PRICE = 0.02 ether; // Minimum bond size
    uint256 private constant AUTO_RESOLVE_BATCH = 100;
    uint256 private constant GAS_LIMITED_RESOLVE_MAX = 150;
    uint256 private constant SALES_BUMP_NUMERATOR = 1005; // +0.5% price per threshold
    uint256 private constant SALES_BUMP_DENOMINATOR = 1000;
    uint256 private constant PRESALE_PRICE_PER_1000_DEFAULT = 0.01 ether;
    uint256 private constant FALLBACK_MINT_PRICE = 0.025 ether;

    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // ===========================================================================
    // State Variables
    // ===========================================================================

    // -- Metadata & Access --
    string public constant name = "Purge Bonds";
    string public constant symbol = "PBOND";
    address public owner;
    address public stEthToken; // The "Prime" asset for payouts
    address public coinToken; // The "Bonus" asset (PURGE)
    address public renderer;
    address public game; // The main PurgeGame contract
    address public affiliateProgram;
    address public stEthWithdrawalQueue;

    // -- Financial Accounting --
    // `pool` variables track actual assets held.
    // `Owed` variables track liabilities (if everyone won).
    uint256 public bondCoin; // PURGE owed for bond payouts (tracking pool)
    uint256 public totalEthOwed; // Aggregate ETH liability
    uint256 public payoutObligation; // Aggregate ETH + stETH reserved for bond payouts
    uint256 public totalCoinOwed; // Aggregate weighted PURGE liability
    uint256 public rewardSeedEth; // Accumulator for game rewards from unwired state
    uint256 public gameRefundDeficit; // ETH earmarked to offset coin minted for bond sellbacks (can be settled later)
    uint256 public gameRefundDeficitCoin; // PURGE minted via bond sellbacks (tracks coin amount tied to gameRefundDeficit)
    uint256 public presalePricePer1000Wei = PRESALE_PRICE_PER_1000_DEFAULT; // fallback coin pricing before the game is wired
    bool public prizePoolFunded; // flips after the first prize-pool transfer to the game (controls auto-staking on purchases)

    // -- Resolution State --
    bool public resolvePending;
    uint256 public pendingRngWord;
    uint256 public gameOverRngWord;
    uint48 public pendingRngDay;
    uint256 public pendingResolveBase;
    uint256 public pendingResolveMax;
    uint256 public pendingResolveBudget;
    uint256 public claimSweepCursor; // cursor for batch auto-claims

    // -- Dynamic Pricing --
    uint256 public priceMultiplier = 499e15; // Starts at 0.499x
    uint256 public salesAccumulator;
    uint64 public lastDecayDay;
    uint64 public decayDelayUntilDay;

    // -- Game Lifecycle --
    bool public purchasesEnabled = true;
    bool public decayPaused;
    bool public gameOver;
    uint256 public gameOverTimestamp;
    uint256 public shutdownBurnCursor;
    bool public allBondsBurned;

    // -- Token Data --
    uint256 private _currentIndex = 1;
    uint256 private nextClaimable = 1;
    uint256 private burnedCount;
    uint256 public lowestUnresolved = 1;
    uint256 public resolveBaseId;

    // ERC721A Packed Storage
    mapping(uint256 => uint256) private _packedOwnerships;
    mapping(address => uint256) private _packedAddressData;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // Bond Specific Data
    mapping(uint256 => uint256) public basePriceOf; // The "Principal" paid
    mapping(uint256 => uint32) public createdDistance; // Snapshot of queue depth at mint
    uint32 public lastPurchaseDistance; // Distance snapshot of the most recent purchase

    // -- Configuration --
    bool public transfersLocked;
    uint64 public transfersLockedAt;
    uint16 public stakeRateBps = 10_000; // 100%

    // ===========================================================================
    // Modifiers
    // ===========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyGame() {
        if (msg.sender != game) revert Unauthorized();
        _;
    }

    constructor(address stEthToken_) {
        if (stEthToken_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        stEthToken = stEthToken_;
        lastDecayDay = uint64(block.timestamp / 1 days);
    }

    // ===========================================================================
    // Funding & Resolution Ingest
    // ===========================================================================

    /**
     * @notice Main entry point to fund the contract and trigger bond resolution.
     * @dev Callable by the game only. Automatically batches resolution if budgets allow.
     *      Game profits (or shutdown drain) are expected to flow in here; bond purchases themselves are NOT reserved.
     *      Only ETH/stETH delivered via this function raises payoutObligation to back matured bonds.
     * @param coinAmount Amount of PURGE tokens being sent/credited.
     * @param stEthAmount Amount of stETH being credited by the caller.
     * @param rngDay The game day to fetch RNG for (if not provided via `rngWord`).
     * @param rngWord The random seed for resolution (overrides `rngDay` if non-zero).
     * @param maxBonds Resolution batch size limit.
     */
    function payBonds(
        uint256 coinAmount,
        uint256 stEthAmount,
        uint48 rngDay,
        uint256 rngWord,
        uint256 maxBonds
    ) external payable onlyGame {
        // 1. Ingest Coin (PURGE)
        bool pending = resolvePending;

        if (coinAmount != 0) {
            address coin = coinToken;

            IPurgeCoinBondMinter(coin).bondPayment(coinAmount);

            bondCoin += coinAmount;
        }

        // 2. Ingest stETH
        uint256 stAdded;
        if (stEthAmount != 0) {
            IERC20Minimal(stEthToken).transferFrom(msg.sender, address(this), stEthAmount);
            stAdded = stEthAmount;
        }

        uint256 budget = msg.value + stAdded;
        if (budget != 0) {
            payoutObligation += budget;
        }

        if (budget != 0 || coinAmount != 0) {
            emit BondsPaid(msg.value, stAdded, coinAmount);
        }

        // 3. Schedule Resolution
        if (!pending && budget != 0) {
            uint256 startId = _resolveStart();
            if (startId != 0) {
                uint256 wordToUse = rngWord;
                if (gameOver) {
                    uint256 locked = gameOverRngWord;
                    if (locked != 0) {
                        wordToUse = locked;
                    } else if (wordToUse != 0) {
                        gameOverRngWord = wordToUse;
                    }
                }
                _scheduleResolve(startId, rngDay, wordToUse, maxBonds, budget);
                pending = true;
            }
        }

        // 5. Execute Resolution Batch (if ready). Skip auto-run during game over; rely on manual calls instead.
        if (pending && !gameOver) {
            if (pendingRngWord == 0 && pendingRngDay != 0) {
                uint256 fetched = IPurgeGameLike(game).rngWordForDay(pendingRngDay);
                if (fetched != 0) {
                    pendingRngWord = fetched;
                }
            }
            if (pendingRngWord != 0) {
                _resolvePendingInternal(_resolveLimit(maxBonds), false);
            }
        }
    }

    /**
     * @notice Accept presale proceeds and forward 90% to the prize pool accumulator.
     * @dev Callable only by the affiliate contract during presale.
     */
    function ingestPresaleEth() external payable {
        if (msg.sender != affiliateProgram) revert Unauthorized();
        uint256 amount = msg.value;
        if (amount == 0) return;

        _routePurchaseProceeds(amount);
        // Remaining stays in the contract and is withdrawable via owner `sendAsset`.
    }

    /**
     * @notice Manual trigger to process pending bonds if auto-batching didn't finish.
     */
    function resolvePendingBonds(uint256 maxBonds) external {
        _resolvePendingInternal(_resolveLimit(maxBonds), true);
        // Auto-claim winners in live mode so players get swept to game credit without manual claims.
        if (!gameOver) {
            _autoClaimWinners(maxBonds);
        }
    }

    /**
     * @notice Permissionless helper to process pending bonds without reverting when nothing is queued.
     */
    function workPendingBonds(uint256 maxBonds) external {
        _resolvePendingInternal(_resolveLimit(maxBonds), false);
    }

    /**
     * @notice Emergency manual resolve if VRF fails significantly.
     */
    function forceResolveWithFallback(uint256 rngWord, uint256 maxBonds) external {
        if (!resolvePending) revert ResolveNotReady();
        if (rngWord == 0) revert InvalidRng();
        uint64 lockedAt = transfersLockedAt;
        // 2 day safety delay before admin can force RNG
        if (lockedAt == 0 || block.timestamp <= lockedAt + 2 days) revert ResolveNotReady();
        pendingRngWord = rngWord;
        _resolvePendingInternal(_resolveLimit(maxBonds), true);
    }

    // ===========================================================================
    // Minting (Buying)
    // ===========================================================================

    function _purchaseStakeFlag() private view returns (bool) {
        return prizePoolFunded;
    }

    function _routePurchaseProceeds(uint256 amount) private {
        if (amount == 0) return;
        address game_ = game;
        // Presale / unwired: park 20% for the game and keep the rest on the bond contract.
        if (game_ == address(0)) {
            uint256 toFund = amount / 5; // 20%
            if (toFund != 0) {
                rewardSeedEth += toFund;
            }
            return;
        }

        // Wired: send 50% to the game (20% reward pool + 30% yield pool), retain 50% locally.
        uint256 rewardCut = amount / 5; // 20%
        uint256 yieldCut = (amount * 3) / 10; // 30%
        if (rewardCut != 0) {
            _markPrizePoolFunded();
            IPurgeGameBondSinks(game_).bondRewardDeposit{value: rewardCut}();
        }
        if (yieldCut != 0) {
            IPurgeGameBondSinks(game_).bondYieldDeposit{value: yieldCut}();
        }
    }

    /**
     * @notice Purchase bonds.
     * @param baseWei The 'Principal' amount (affects win chance and payout).
     * @param quantity Number of bonds.
     * @param stake Deprecated stake toggle (auto-managed; kept for ABI compatibility).
     * @param affiliateCode Referral code.
     */
    function buy(uint256 baseWei, uint256 quantity, bool /*stake*/, bytes32 affiliateCode) external payable {
        if (!purchasesEnabled) revert PurchasesClosed();
        if (transfersLocked) revert TransferBlocked();
        if (quantity == 0) revert InvalidQuantity();
        if (baseWei == 0 || baseWei > 1 ether) revert InvalidBase();

        _syncMultiplier();

        // Cap base price at 0.5 ETH (50% win chance max)
        uint256 basePerBond = baseWei / quantity;
        if (basePerBond > 0.5 ether) {
            basePerBond = 0.5 ether;
        }
        if (basePerBond < MIN_BASE_PRICE) revert InvalidBase();

        // Handle Affiliate
        _applyAffiliateCode(msg.sender, affiliateCode, msg.value);

        // Verify Price
        uint256 price = (basePerBond * priceMultiplier) / MULT_SCALE;
        uint256 totalPrice = price * quantity;
        // Strict equality check protects against precision gaming
        if (price == 0 || totalPrice / quantity != price || msg.value != totalPrice) revert WrongPrice();

        // Purchases are revenue, not escrow: only `payBonds` funding backs payouts.
        _routePurchaseProceeds(msg.value);

        bool stakeFlag = _purchaseStakeFlag();
        if (stakeFlag && msg.sender.code.length != 0) revert Unauthorized();

        _mintBatch(msg.sender, quantity, basePerBond, price, stakeFlag);

        _bumpOnSales(msg.value);
    }

    /**
     * @notice Purchase bonds using PURGE at 2x the ETH price (converted using the current mint price oracle).
     * @dev Price source falls back to presale pricing before the game is wired. Prize pool routing is skipped.
     * @param stake Deprecated stake toggle (auto-managed; kept for ABI compatibility).
     */
    function buyWithCoin(uint256 baseWei, uint256 quantity, bool /*stake*/) external {
        if (!purchasesEnabled) revert PurchasesClosed();
        if (transfersLocked) revert TransferBlocked();
        if (quantity == 0) revert InvalidQuantity();
        if (baseWei == 0 || baseWei > 1 ether) revert InvalidBase();

        address coin = coinToken;
        if (coin == address(0)) revert ZeroAddress();

        _syncMultiplier();

        uint256 basePerBond = baseWei / quantity;
        if (basePerBond > 0.5 ether) {
            basePerBond = 0.5 ether;
        }
        if (basePerBond < MIN_BASE_PRICE) revert InvalidBase();

        uint256 priceWei = (basePerBond * priceMultiplier) / MULT_SCALE;
        uint256 totalWei = priceWei * quantity;
        if (priceWei == 0 || totalWei / quantity != priceWei) revert WrongPrice();

        (uint256 mintPriceWei, uint256 priceCoinUnit) = _currentMintPricing();
        if (mintPriceWei == 0 || priceCoinUnit == 0) revert WrongPrice();

        uint256 coinCost = (totalWei * priceCoinUnit * 2) / mintPriceWei;
        if (coinCost == 0) revert WrongPrice();

        IERC20Minimal(coin).transferFrom(msg.sender, address(this), coinCost);

        bool stakeFlag = _purchaseStakeFlag();
        if (stakeFlag && msg.sender.code.length != 0) revert Unauthorized();

        _mintBatch(msg.sender, quantity, basePerBond, 0, stakeFlag);

        _bumpOnSales(totalWei);
    }

    /**
     * @notice Purchase bonds at par (100% EV) using prize-pool funds routed by the game.
     * @dev Access: game only. Ignores price multiplier and affiliate flow; skips sales-based price bumps.
     * @param to Recipient of the bonds (typically the game contract for prize-pool recycling).
     * @param quantity Number of bonds.
     * @param stake Whether the bonds should be staked/soulbound.
     * @param baseWei Total base across the batch (capped to 0.5 ETH per bond).
     */
    function purchasePrizePoolBonds(
        address to,
        uint256 baseWei,
        uint256 quantity,
        bool stake
    ) external payable onlyGame returns (uint256 startTokenId) {
        _syncMultiplier();

        uint256 basePerBond = baseWei / quantity;
        if (basePerBond > 0.5 ether) {
            basePerBond = 0.5 ether;
        }
        if (basePerBond < MIN_BASE_PRICE) revert InvalidBase();

        uint256 totalPrice = basePerBond * quantity;
        if (totalPrice / quantity != basePerBond || msg.value != totalPrice) revert WrongPrice();

        _routePurchaseProceeds(msg.value);

        startTokenId = _mintBatch(to, quantity, basePerBond, msg.value, stake);
    }

    /**
     * @notice Purchase bonds for a set of recipients at par pricing using game-managed funds.
     * @dev Access: game only. Routes the standard prize cut and skips sales-based price bumps.
     * @param recipients Addresses that should each receive one bond.
     * @param basePerBondWei Base value per bond (win odds), capped at 0.5 ETH and floored to the minimum.
     * @param stake Whether the minted bonds should be staked/soulbound.
     */
    function purchaseJackpotBonds(
        address[] calldata recipients,
        uint256 basePerBondWei,
        bool stake
    ) external payable onlyGame returns (uint256 startTokenId) {
        uint256 quantity = recipients.length;
        if (quantity == 0) revert InvalidQuantity();
        if (basePerBondWei == 0 || basePerBondWei > 1 ether) revert InvalidBase();

        _syncMultiplier();

        uint256 basePerBond = basePerBondWei;
        if (basePerBond > 0.5 ether) {
            basePerBond = 0.5 ether;
        }
        if (basePerBond < MIN_BASE_PRICE) revert InvalidBase();

        uint256 totalPrice = basePerBond * quantity;
        if (totalPrice / quantity != basePerBond || msg.value != totalPrice) revert WrongPrice();

        _routePurchaseProceeds(msg.value);

        startTokenId = _currentIndex;
        for (uint256 i; i < quantity; ) {
            address to = recipients[i];
            if (to == address(0)) revert ZeroAddress();
            _mintBatch(to, 1, basePerBond, basePerBond, stake);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Mint free bonds for affiliates who earned reward tiers (no ETH required).
     * @dev Access: affiliate contract only.
     * @param to Recipient of the reward bonds.
     * @param quantity Number of bonds to mint.
     * @param basePerBondWei Base value per bond (win odds). Capped to 0.5 ETH.
     * @param stake Whether the bonds should be staked/soulbound.
     */
    function mintAffiliateReward(
        address to,
        uint256 quantity,
        uint256 basePerBondWei,
        bool stake
    ) external returns (uint256 startTokenId) {
        if (msg.sender != affiliateProgram) revert Unauthorized();

        uint256 basePerBond = basePerBondWei;
        if (basePerBond > 0.5 ether) {
            basePerBond = 0.5 ether;
        }
        if (basePerBond < MIN_BASE_PRICE) revert InvalidBase();

        startTokenId = _mintBatch(to, quantity, basePerBond, 0, stake);
    }

    /**
     * @notice Mint one bond per recipient using provided base values; callable only by the game.
     * @dev Base per bond is capped at 0.5 ETH; emits normal Purchase/Transfer events. No ETH is required.
     *      Stakes every other bond (starting staked) to target a 50/50 staked split.
     * @param recipients Addresses to receive bonds.
     * @param baseWei Base value per recipient (win chance), uncapped input (capped internally to 0.5 ETH).
     */
    function mintBondsForRecipients(address[] calldata recipients, uint256[] calldata baseWei) external onlyGame {
        uint256 len = recipients.length;
        if (len == 0 || len != baseWei.length) revert InvalidQuantity();

        for (uint256 i; i < len; ) {
            address to = recipients[i];
            if (to == address(0)) revert ZeroAddress();

            uint256 base = baseWei[i];
            if (base == 0 || base > 1 ether) revert InvalidBase();
            if (base > 0.5 ether) {
                base = 0.5 ether;
            }
            if (base < MIN_BASE_PRICE) revert InvalidBase();

            bool stake = (i & 1) == 0; // alternate staking to target ~50% staked
            _mintBatch(to, 1, base, 0, stake);

            unchecked {
                ++i;
            }
        }
    }

    function _mintBatch(
        address to,
        uint256 quantity,
        uint256 basePrice,
        uint256 paidWei,
        bool stake
    ) private returns (uint256 startTokenId) {
        if (to == address(0)) revert ZeroAddress();

        startTokenId = _currentIndex;
        _currentIndex = startTokenId + quantity;

        // ERC721A: Only initialize the first slot of the batch
        uint256 stakedFlag = stake ? _BITMASK_STAKED : 0;
        _packedOwnerships[startTokenId] = _packOwnershipData(
            to,
            (quantity == 1 ? _BITMASK_NEXT_INITIALIZED : 0) | stakedFlag
        );

        // Update Address Data (Balance + Mint Counts)
        uint256 packedData = _packedAddressData[to];
        uint256 balance = packedData & _BITMASK_ADDRESS_DATA_ENTRY;
        uint256 minted = (packedData >> _BITPOS_NUMBER_MINTED) & _BITMASK_ADDRESS_DATA_ENTRY;
        unchecked {
            balance += quantity;
            minted += quantity;
        }
        _packedAddressData[to] =
            (packedData & ~(_BITMASK_ADDRESS_DATA_ENTRY | (_BITMASK_ADDRESS_DATA_ENTRY << _BITPOS_NUMBER_MINTED))) |
            balance |
            (minted << _BITPOS_NUMBER_MINTED);

        // **CRITICAL ACCOUNTING**: Add weighted obligation to the global counter.
        // Staked/unstaked share the same coin weight; staking only affects transferability.
        uint256 weight = stake ? COIN_WEIGHT_UNMARKETABLE : COIN_WEIGHT_MARKETABLE;
        totalEthOwed += basePrice * quantity;
        totalCoinOwed += basePrice * weight * quantity;

        uint256 tokenId = startTokenId;
        uint256 end = startTokenId + quantity;
        uint256 toMasked = uint256(uint160(to)) & _BITMASK_ADDRESS;
        uint32 lastDistance;

        // Loop for per-token metadata setup (cannot be packed efficiently due to distinct Base Prices)
        do {
            basePriceOf[tokenId] = basePrice;
            uint32 distance = uint32(_currentDistance(tokenId));
            createdDistance[tokenId] = distance;
            lastDistance = distance;
            // Note: WinChance is no longer stored; derived from basePrice.

            emit Purchased(to, tokenId, basePrice, paidWei);

            assembly ("memory-safe") {
                log4(0, 0, _TRANSFER_EVENT_SIGNATURE, 0, toMasked, tokenId)
            }
            if (to.code.length != 0) {
                if (!_checkOnERC721Received(msg.sender, address(0), to, tokenId, "")) revert CallFailed();
            }
            unchecked {
                ++tokenId;
            }
        } while (tokenId != end);

        lastPurchaseDistance = lastDistance;
    }

    // ===========================================================================
    // Claiming
    // ===========================================================================

    /**
     * @notice Claim a winning bond.
     * @dev Burning happens BEFORE payout to prevent reentrancy.
     */
    function claim(uint256 tokenId, address to) external {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();

        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed & _BITMASK_BURNED != 0) revert AlreadyClaimed();
        if ((packed & _BITMASK_CLAIM_READY) == 0) revert NotClaimable();

        // 1. Burn Token (Reentrancy Guard Effect)
        address holder = address(uint160(packed)); // Extracts address from packed data
        _burnToken(tokenId, holder);

        // 2. Calculate Coin Share
        uint256 bondShare;
        // **CRITICAL**: Weighting determines share of the pot.
        uint256 coinWeight = _coinClaimWeight(packed);
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            // Formula: (TotalPot * MyWeightedShare) / TotalWeightedShares
            bondShare = (bondCoin * coinWeight) / coinOwed;
        }

        // 3. Payout (Prefer stETH, fallback to ETH)
        uint256 ethPaid;
        uint256 stEthPaid;
        address stToken = stEthToken;
        uint256 ethBal = address(this).balance;
        uint256 stBal = stToken == address(0) ? 0 : IERC20Minimal(stToken).balanceOf(address(this));

        if (ethBal >= 1 ether) {
            ethPaid = 1 ether;
            (bool ok, ) = payable(to).call{value: ethPaid}("");
            if (!ok) revert CallFailed();
        } else if (stBal >= 1 ether) {
            stEthPaid = 1 ether;
            IERC20Minimal(stToken).transfer(to, stEthPaid);
        } else {
            revert InsufficientPayout();
        }

        if (bondShare != 0) {
            if (bondCoin <= bondShare) {
                bondCoin = 0;
            } else {
                bondCoin -= bondShare;
            }
            IERC20Minimal(coinToken).transfer(to, bondShare);
        }

        uint256 paid = ethPaid + stEthPaid;
        if (paid != 0) {
            if (payoutObligation <= paid) {
                payoutObligation = 0;
            } else {
                payoutObligation -= paid;
            }
        }

        // 4. Update Global Obligations
        totalEthOwed -= 1 ether;
        _decreaseTotalCoinOwed(coinWeight); // Remove our weighted liability

        emit Claimed(to, tokenId, ethPaid, stEthPaid, bondShare);
    }

    /**
     * @notice Auto-claim matured winners in batches, paying coin directly and reporting winners for off-chain/game-side ETH credit.
     * @param maxClaims Max winners to process (0 => default batch size).
     * @return winners Addresses credited this batch.
     * @return morePending True if additional claim-ready winners remain for follow-up calls.
     */
    function _autoClaimWinners(uint256 maxClaims) private returns (address[] memory winners, bool morePending) {
        if (gameOver) revert GameOver(); // After GG, claims must be handled directly on the bond contract.

        uint256 cursor = claimSweepCursor;
        if (cursor == 0) cursor = 1;
        uint256 maxId = _currentIndex - 1;
        if (maxId == 0 || cursor > maxId) {
            claimSweepCursor = cursor;
            return (new address[](0), false);
        }

        uint256 limit = _resolveLimit(maxClaims);
        winners = new address[](limit);

        uint256 claimed;
        uint256 coinPool = bondCoin;

        while (claimed < limit && cursor <= maxId) {
            uint256 packed = _packedOwnershipAt(cursor);
            // Only handle claim-ready, non-burned tokens.
            if (packed != 0 && (packed & (_BITMASK_CLAIM_READY | _BITMASK_BURNED)) == _BITMASK_CLAIM_READY) {
                address holder = address(uint160(packed));
                if (holder != address(0)) {
                    uint256 coinWeight = _coinClaimWeight(packed);
                    uint256 bondShare;
                    uint256 coinOwed = totalCoinOwed;
                    if (coinOwed != 0 && coinPool != 0) {
                        bondShare = (coinPool * coinWeight) / coinOwed;
                        if (bondShare != 0) {
                            if (coinPool <= bondShare) {
                                coinPool = 0;
                            } else {
                                coinPool -= bondShare;
                            }
                            IERC20Minimal(coinToken).transfer(holder, bondShare);
                        }
                    }

                    _burnToken(cursor, holder);

                    uint256 paid = 1 ether;
                    // These winners are expected to be credited externally by the game; free up any reserved obligation locally.
                    if (payoutObligation <= paid) {
                        payoutObligation = 0;
                    } else {
                        payoutObligation -= paid;
                    }
                    totalEthOwed -= 1 ether;
                    _decreaseTotalCoinOwed(coinWeight);

                    winners[claimed] = holder;
                    emit Claimed(holder, cursor, paid, 0, bondShare);
                    unchecked {
                        ++claimed;
                    }
                }
            }
            unchecked {
                ++cursor;
            }
        }

        bondCoin = coinPool;
        claimSweepCursor = cursor;
        morePending = (cursor <= maxId);

        if (claimed != limit) {
            assembly ("memory-safe") {
                mstore(winners, claimed)
            }
        }
    }

    function autoClaimWinners(uint256 maxClaims) external returns (address[] memory winners, bool morePending) {
        return _autoClaimWinners(maxClaims);
    }

    // ===========================================================================
    // Selling
    // ===========================================================================

    /**
     * @notice Sell an active bond for PURGE (converted from the sellback’s ETH value at current mint pricing).
     * @param tokenId Bond id to sell.
     */
    function sell(uint256 tokenId) external {
        address holder = _requireActiveToken(tokenId);
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert Unauthorized();
        if (holder == address(this)) revert NotSellable();
        _sellBond(tokenId, holder);
    }

    function _sellBond(uint256 tokenId, address holder) private {
        uint256 packed = _packedOwnershipOf(tokenId);
        if ((packed & _BITMASK_CLAIM_READY) != 0) {
            _sellClaimReady(tokenId, holder, packed);
            return;
        }

        uint256 distance = _currentDistance(tokenId);
        if (distance == 0) revert NotSellable();

        uint256 refDistance = lastPurchaseDistance;
        if (refDistance < distance) {
            refDistance = distance;
        }
        uint256 basePrice = basePriceOf[tokenId];
        uint256 payout = _bondSalePayout(basePrice, distance, refDistance);
        if (payout == 0) revert NotSellable();

        _transferToVault(holder, tokenId, packed);

        address game_ = game;
        if (game_ == address(0)) revert ZeroAddress();
        uint256 priceWei = IPurgeGamePrice(game_).mintPrice();
        uint256 priceCoinUnit = IPurgeGamePrice(game_).coinPriceUnit();
        if (priceWei == 0 || priceCoinUnit == 0) revert NotSellable();

        // Convert the ETH-equivalent payout to PURGE using the live mint price ratio.
        uint256 coinOut = (payout * priceCoinUnit) / priceWei;
        if (coinOut == 0) revert NotSellable();

        // Track ETH that should eventually be forwarded to the game to mirror the minted coin value.
        unchecked {
            gameRefundDeficit += payout;
            gameRefundDeficitCoin += coinOut;
        }

        address coin = coinToken;
        IPurgeCoinBondMinter(coin).bondPayment(coinOut);
        IERC20Minimal(coin).transfer(holder, coinOut);
        emit BondSold(holder, tokenId, payout);
    }

    function _sellClaimReady(uint256 tokenId, address holder, uint256 packed) private {
        // Claim-ready winner: send full ETH to game as claimable winnings, pay coin share to holder.
        if (holder == address(0)) revert ZeroAddress();

        uint256 coinWeight = _coinClaimWeight(packed);
        uint256 bondShare;
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * coinWeight) / coinOwed;
            if (bondCoin <= bondShare) {
                bondCoin = 0;
            } else {
                bondCoin -= bondShare;
            }
        }

        uint256 amount = 1 ether;
        if (address(this).balance < amount) revert InsufficientPayout();

        address game_ = game;
        if (game_ == address(0)) revert ZeroAddress();
        payoutObligation = payoutObligation <= amount ? 0 : payoutObligation - amount;
        totalEthOwed -= 1 ether;
        _decreaseTotalCoinOwed(coinWeight);

        _burnToken(tokenId, holder);
        IPurgeGameBondWinnings(game_).creditBondWinnings{value: amount}(holder);

        if (bondShare != 0) {
            IERC20Minimal(coinToken).transfer(holder, bondShare);
        }

        emit BondSold(holder, tokenId, amount);
    }

    function _bondSalePayout(uint256 basePrice, uint256 distance, uint256 refDistance) private view returns (uint256) {
        if (refDistance == 0) return 0;
        if (distance > refDistance) distance = refDistance;
        // Start at 20% and scale linearly with progress, clamped to [20%, 90%].
        uint256 progress = refDistance - distance; // 0 when newest; increases as it matures
        uint256 scaleBps = (progress * 10_000) / refDistance;
        if (scaleBps < 2000) scaleBps = 2000;
        if (scaleBps > 9000) scaleBps = 9000;

        uint256 basePayout = (basePrice * scaleBps) / 10_000;
        uint256 mult = _saleMultiplier();
        return (basePayout * mult) / MULT_SCALE;
    }

    function _saleMultiplier() private view returns (uint256) {
        uint256 mult = _multiplierWithDecay();
        uint256 cap = 8e17; // 80%
        if (mult > cap) mult = cap;
        return mult;
    }

    // ===========================================================================
    // Admin / Config
    // ===========================================================================

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setStEthWithdrawalQueue(address queue) external onlyOwner {
        if (queue == address(0)) revert ZeroAddress();
        stEthWithdrawalQueue = queue;
        IERC20Approve(stEthToken).approve(queue, type(uint256).max);
    }

    /**
     * @notice Request withdrawal of stETH to receive ETH via the Lido withdrawal queue.
     * @dev Access: owner only. Amounts are burned in the queue and ETH becomes claimable there.
     * @param amounts stETH amounts per requestId to create.
     * @return requestIds IDs created in the queue.
     */
    function requestStEthWithdrawals(
        uint256[] calldata amounts
    ) external onlyOwner returns (uint256[] memory requestIds) {
        address queue = stEthWithdrawalQueue;
        if (queue == address(0)) revert ZeroAddress();
        uint256 len = amounts.length;
        if (len == 0) revert InvalidQuantity();
        uint256 total;
        for (uint256 i; i < len; ) {
            uint256 amt = amounts[i];
            if (amt == 0) revert InvalidQuantity();
            total += amt;
            unchecked {
                ++i;
            }
        }
        IERC20Minimal st = IERC20Minimal(stEthToken);
        if (st.balanceOf(address(this)) < total) revert InsufficientPayout();

        requestIds = IStEthWithdrawalQueue(queue).requestWithdrawals(amounts, address(this));
    }

    /**
     * @notice Claim ETH from previously requested stETH withdrawals.
     * @dev Access: owner only. Hints are queue-specific positioning helpers (pass empty if not needed).
     */
    function claimStEthWithdrawals(
        uint256[] calldata requestIds,
        uint256[] calldata hints
    ) external onlyOwner returns (uint256[] memory amounts) {
        address queue = stEthWithdrawalQueue;
        if (queue == address(0)) revert ZeroAddress();
        if (requestIds.length == 0) revert InvalidQuantity();
        amounts = IStEthWithdrawalQueue(queue).claimWithdrawals(requestIds, hints);
    }

    function setPresalePricePer1000(uint256 priceWeiPer1000) external onlyOwner {
        if (priceWeiPer1000 == 0) revert InvalidPrice();
        presalePricePer1000Wei = priceWeiPer1000;
    }

    function wire(address[] calldata addresses) external onlyOwner {
        _setCoinToken(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setAffiliate(addresses.length > 2 ? addresses[2] : address(0));
    }

    /**
     * @notice Triggers Game Over state (pausing purchases).
     */
    function notifyGameOver() external onlyGame {
        if (!gameOver) {
            gameOver = true;
            purchasesEnabled = false;
            decayPaused = true;
            transfersLocked = true;
            transfersLockedAt = uint64(block.timestamp);
            gameOverTimestamp = block.timestamp;
        } else if (gameOverTimestamp == 0) {
            gameOverTimestamp = block.timestamp;
        }

        if (shutdownBurnCursor == 0) {
            uint256 cursor = lowestUnresolved;
            if (cursor == 0) cursor = 1;
            shutdownBurnCursor = cursor;
        }
        emit GameShutdown(shutdownBurnCursor);
    }

    /**
     * @notice Withdraws funds NOT reserved for bond payouts.
     */
    function sendAsset(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        address stToken = stEthToken;
        uint256 stBal = stToken == address(0) ? 0 : IERC20Minimal(stToken).balanceOf(address(this));
        uint256 totalBal = address(this).balance + stBal;
        // Only funds explicitly flowed in via `payBonds` (plus any queued reward seed) are reserved for payouts.
        uint256 reserved = payoutObligation + rewardSeedEth;
        uint256 combinedHeadroom = totalBal > reserved ? totalBal - reserved : 0;

        if (token == address(0)) {
            uint256 requested = amount == 0 ? combinedHeadroom : amount;
            if (requested == 0 || requested > combinedHeadroom) revert InsufficientHeadroom();

            uint256 ethBal = address(this).balance;
            uint256 ethSend = requested <= ethBal ? requested : ethBal;
            uint256 remaining = requested - ethSend;

            if (ethSend != 0) {
                (bool ok, ) = payable(to).call{value: ethSend}("");
                if (!ok) revert CallFailed();
            }
            if (remaining != 0) {
                if (stToken == address(0) || remaining > stBal) revert InsufficientHeadroom();
                IERC20Minimal(stToken).transfer(to, remaining);
            }
            return;
        }
        if (token == stToken) {
            uint256 stAvailable = combinedHeadroom < stBal ? combinedHeadroom : stBal;
            uint256 sendAmount = amount == 0 ? stAvailable : amount;
            if (sendAmount == 0 || sendAmount > stAvailable) revert InsufficientHeadroom();
            IERC20Minimal(token).transfer(to, sendAmount);
            return;
        }
        if (token != coinToken) revert InvalidToken();
        // For coin, we only hold what's in `bondCoin`. Any excess is fair game.
        uint256 bal = IERC20Minimal(token).balanceOf(address(this));
        uint256 reservedCoin = bondCoin;
        uint256 available = bal > reservedCoin ? bal - reservedCoin : 0;
        if (amount == 0) amount = available;
        if (amount > available) revert InsufficientCoinAvailable();
        IERC20Minimal(token).transfer(to, amount);
    }

    function setRenderer(address renderer_) external onlyOwner {
        if (renderer_ == address(0)) revert ZeroAddress();
        renderer = renderer_;
    }

    function setPurchasesEnabled(bool enabled) external onlyOwner {
        if (gameOver && enabled) revert GameOver();
        purchasesEnabled = enabled;
        decayPaused = !enabled;
        if (enabled) {
            lastDecayDay = uint64(block.timestamp / 1 days);
        }
    }

    function setTransfersLocked(bool locked, uint48 rngDay) external onlyGame {
        transfersLocked = locked;
        if (locked) {
            transfersLockedAt = uint64(block.timestamp);
            if (rngDay != 0 && pendingRngDay == 0 && !resolvePending) {
                pendingRngDay = rngDay;
            }
        } else {
            transfersLockedAt = 0;
        }
    }

    function setStakeRateBps(uint16 rateBps) external onlyOwner {
        if (rateBps < 2500 || rateBps > 15_000) revert InvalidRate();
        stakeRateBps = rateBps;
    }

    /**
     * @notice Permanently stop presale purchases in the affiliate contract.
     */
    function shutdownPresale() external onlyOwner {
        address affiliate = affiliateProgram;
        if (affiliate == address(0)) revert ZeroAddress();
        IPurgeAffiliateLike(affiliate).shutdownPresale();
    }

    /**
     * @notice Triggers a VRF coordinator swap on the game if RNG has been stuck for >3 days.
     */
    function updateGameVrfCoordinator(address newCoordinator) external onlyOwner {
        if (newCoordinator == address(0)) revert ZeroAddress();
        address game_ = game;
        if (game_ == address(0)) revert ZeroAddress();
        IPurgeGameLike(game_).emergencyUpdateVrfCoordinator(newCoordinator);
    }

    /**
     * @notice Final cleanup 1 year after Game Over.
     */
    function sweepExpiredPools(
        address to
    ) external onlyOwner returns (uint256 ethOut, uint256 stEthOut, uint256 coinOut) {
        if (to == address(0)) revert ZeroAddress();
        uint256 endedAt = gameOverTimestamp;
        if (endedAt == 0 || block.timestamp <= endedAt + 365 days) revert ExpiredSweepLocked();

        ethOut = address(this).balance;
        if (ethOut != 0) {
            (bool ok, ) = payable(to).call{value: ethOut}("");
            if (!ok) revert CallFailed();
        }

        address stToken = stEthToken;
        if (stToken != address(0)) {
            stEthOut = IERC20Minimal(stToken).balanceOf(address(this));
            if (stEthOut != 0) {
                IERC20Minimal(stToken).transfer(to, stEthOut);
            }
        }

        address coin = coinToken;
        if (coin != address(0)) {
            coinOut = IERC20Minimal(coin).balanceOf(address(this));
            if (coinOut != 0) {
                bondCoin = 0;
                totalCoinOwed = 0;
                IERC20Minimal(coin).transfer(to, coinOut);
            }
        }
        payoutObligation = 0;
        _burnAllBonds();
    }

    /**
     * @notice Permissionless cleanup after shutdown.
     */
    function finalizeShutdown(
        uint256 maxIds
    ) external onlyGame returns (uint256 processedIds, uint256 burned, bool complete) {
        if (!gameOver) revert GameOver();
        if (resolvePending || pendingRngDay != 0 || pendingRngWord != 0) revert ShutdownPendingResolution();
        (processedIds, burned, complete) = _burnUnmaturedFromCursor(maxIds);
        emit ShutdownBurned(processedIds, burned, complete);
    }

    // ===========================================================================
    // Views
    // ===========================================================================

    function _exists(uint256 tokenId) private view returns (bool) {
        return _isActiveToken(tokenId);
    }

    function _requireActiveToken(uint256 tokenId) private view returns (address holder) {
        if (!_exists(tokenId)) revert InvalidToken();
        holder = address(uint160(_packedOwnershipOf(tokenId)));
    }

    function balanceOf(address account) public view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        if (allBondsBurned) return 0;
        return _packedAddressData[account] & _BITMASK_ADDRESS_DATA_ENTRY;
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _requireActiveToken(tokenId);
    }

    function totalSupply() external view returns (uint256) {
        if (allBondsBurned) return 0;
        uint256 minted = _currentIndex - 1;
        if (burnedCount > minted) return 0;
        return minted - burnedCount;
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        _requireActiveToken(tokenId);
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address holder, address operator) public view returns (bool) {
        return _operatorApprovals[holder][operator];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f || // ERC721Metadata
            interfaceId == 0x01ffc9a7; // ERC165
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        _requireActiveToken(tokenId);
        if (renderer == address(0)) revert ZeroAddress();

        uint32 created = createdDistance[tokenId];
        uint32 current = uint32(_currentDistance(tokenId));
        uint16 chance = getWinChance(tokenId);
        uint256 sellCoin = _bondCoinSaleQuote(tokenId);

        bool isStaked = (_packedOwnershipOf(tokenId) & _BITMASK_STAKED) != 0;
        return IPurgeBondRenderer(renderer).bondTokenURI(tokenId, created, current, chance, isStaked, sellCoin);
    }

    function getWinChance(uint256 tokenId) public view returns (uint16) {
        uint256 base = basePriceOf[tokenId];
        if (base == 0) return 0;

        uint256 c = (base * 1000) / 1 ether;
        if (c == 0) return 1;
        if (c > 1000) return 1000;
        return uint16(c);
    }

    function bondSellCoinQuote(uint256 tokenId) external view returns (uint256) {
        _requireActiveToken(tokenId);
        return _bondCoinSaleQuote(tokenId);
    }

    function currentPrice(uint256 baseWei) external view returns (uint256) {
        if (baseWei < MIN_BASE_PRICE) return 0;
        if (baseWei > 0.5 ether) baseWei = 0.5 ether;
        return (baseWei * _multiplierWithDecay()) / MULT_SCALE;
    }

    /**
     * @notice Estimate payouts if the bond were to win/claim right now.
     */
    function pendingShares() external view returns (uint256 ethShare, uint256 stEthShare, uint256 bondShare) {
        if (_currentIndex <= 1) return (0, 0, 0);
        uint256 ethBal = address(this).balance;
        address stToken = stEthToken;
        uint256 stBal = stToken == address(0) ? 0 : IERC20Minimal(stToken).balanceOf(address(this));
        if (ethBal >= 1 ether) {
            ethShare = 1 ether;
        } else if (stBal >= 1 ether) {
            stEthShare = 1 ether;
        }
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            // Displaying shares for a 'marketable' (unstaked) bond
            bondShare = (bondCoin * (COIN_WEIGHT_MARKETABLE * 1 ether)) / coinOwed;
        }
    }

    // ===========================================================================
    // Transfers
    // ===========================================================================

    function approve(address spender, uint256 tokenId) external {
        address holder = ownerOf(tokenId);
        if (_transfersBlocked(tokenId)) revert TransferBlocked();
        if (msg.sender != holder && !isApprovedForAll(holder, msg.sender)) revert Unauthorized();
        _tokenApprovals[tokenId] = spender;
        emit Approval(holder, spender, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        address holder = _requireActiveToken(tokenId);
        if (holder != from) revert Unauthorized();
        if (_transfersBlocked(tokenId)) revert TransferBlocked();
        if (to == address(0)) revert ZeroAddress();

        address approvedAddress = _tokenApprovals[tokenId];
        address sender = msg.sender;
        if (sender != holder && sender != approvedAddress && !isApprovedForAll(holder, sender)) revert Unauthorized();

        if (approvedAddress != address(0)) {
            delete _tokenApprovals[tokenId];
        }

        // ERC721A-style Transfer logic
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        uint256 fromData = _packedAddressData[from];
        uint256 toData = _packedAddressData[to];

        unchecked {
            _packedAddressData[from] =
                (fromData & ~_BITMASK_ADDRESS_DATA_ENTRY) |
                ((fromData & _BITMASK_ADDRESS_DATA_ENTRY) - 1);
            _packedAddressData[to] =
                (toData & ~_BITMASK_ADDRESS_DATA_ENTRY) |
                ((toData & _BITMASK_ADDRESS_DATA_ENTRY) + 1);

            _packedOwnerships[tokenId] = _packOwnershipData(to, _BITMASK_NEXT_INITIALIZED);

            // If the NEXT token slot is blank, we must carry over the old data to it
            // because ERC721A implies ownership extends until the next initialized slot.
            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextId = tokenId + 1;
                if (_packedOwnerships[nextId] == 0 && nextId != _currentIndex) {
                    _packedOwnerships[nextId] = prevOwnershipPacked;
                }
            }
        }

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            if (!_checkOnERC721Received(msg.sender, from, to, tokenId, data)) revert CallFailed();
        }
    }

    // ===========================================================================
    // Internals
    // ===========================================================================

    function _checkOnERC721Received(
        address operator,
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private returns (bool) {
        try IERC721Receiver(to).onERC721Received(operator, from, tokenId, data) returns (bytes4 retval) {
            return retval == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }

    function _packOwnershipData(address owner_, uint256 flags) private view returns (uint256 result) {
        assembly ("memory-safe") {
            owner_ := and(owner_, _BITMASK_ADDRESS)
            result := or(owner_, or(shl(_BITPOS_START_TIMESTAMP, timestamp()), flags))
        }
    }

    // Finds the initialized slot for a given ID (ERC721A core lookup)
    function _packedOwnershipAt(uint256 tokenId) private view returns (uint256 packed) {
        if (tokenId == 0 || tokenId >= _currentIndex) return 0;
        packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            unchecked {
                uint256 curr = tokenId;
                while (curr != 0) {
                    packed = _packedOwnerships[--curr];
                    if (packed != 0) break;
                }
            }
        }
    }

    function _packedOwnershipOf(uint256 tokenId) private view returns (uint256 packed) {
        if (tokenId == 0 || tokenId >= _currentIndex) revert InvalidToken();
        packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            unchecked {
                uint256 curr = tokenId;
                while (curr != 0) {
                    packed = _packedOwnerships[--curr];
                    if (packed != 0) break;
                }
            }
        }
        if ((packed & _BITMASK_BURNED) != 0 || (packed & _BITMASK_ADDRESS) == 0) revert InvalidToken();
        return packed;
    }

    function _isActiveToken(uint256 tokenId) private view returns (bool) {
        if (allBondsBurned) return false;
        if (tokenId == 0 || tokenId >= _currentIndex) return false;
        // Quick check for burned/claimable using the fast cursor
        if (_isInactive(tokenId)) return false;

        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed == 0 || (packed & _BITMASK_BURNED) != 0) return false;
        return address(uint160(packed)) != address(0);
    }

    function _isInactive(uint256 tokenId) private view returns (bool) {
        if (allBondsBurned) return true;
        uint256 floor = lowestUnresolved;
        if (floor == 0) floor = 1;

        // If token is behind the cursor, it MUST have been either burned or marked claimable.
        if (tokenId < floor) {
            uint256 packed = _packedOwnershipAt(tokenId);
            if (packed == 0) return true;
            if ((packed & _BITMASK_BURNED) != 0) return true;
            return (packed & _BITMASK_CLAIM_READY) == 0;
        }
        return false;
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) private view returns (bool) {
        address holder = _requireActiveToken(tokenId);
        return (spender == holder || _tokenApprovals[tokenId] == spender || _operatorApprovals[holder][spender]);
    }

    function _applyBurnAccounting(address owner_, uint256 burnCount) private {
        if (owner_ == address(0) || burnCount == 0) return;

        uint256 packedData = _packedAddressData[owner_];
        uint256 balance = packedData & _BITMASK_ADDRESS_DATA_ENTRY;
        uint256 minted = (packedData >> _BITPOS_NUMBER_MINTED) & _BITMASK_ADDRESS_DATA_ENTRY;
        uint256 burned = (packedData >> _BITPOS_NUMBER_BURNED) & _BITMASK_ADDRESS_DATA_ENTRY;

        uint256 newBalance = balance > burnCount ? balance - burnCount : 0;
        uint256 newBurned = burned + burnCount;

        _packedAddressData[owner_] =
            (packedData & ~(_BITMASK_ADDRESS_DATA_ENTRY | (_BITMASK_ADDRESS_DATA_ENTRY << _BITPOS_NUMBER_BURNED))) |
            newBalance |
            (minted << _BITPOS_NUMBER_MINTED) |
            (newBurned << _BITPOS_NUMBER_BURNED);
    }

    function _markBurned(uint256 tokenId, uint256 prevOwnershipPacked) private {
        address from = address(uint160(prevOwnershipPacked));
        _packedOwnerships[tokenId] = _packOwnershipData(from, _BITMASK_BURNED | _BITMASK_NEXT_INITIALIZED);

        if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
            uint256 nextId = tokenId + 1;
            if (_packedOwnerships[nextId] == 0 && nextId != _currentIndex) {
                _packedOwnerships[nextId] = prevOwnershipPacked;
            }
        }
    }

    function _coinWeightMultiplier(uint256 packed) private pure returns (uint256) {
        return (packed & _BITMASK_STAKED) != 0 ? COIN_WEIGHT_UNMARKETABLE : COIN_WEIGHT_MARKETABLE;
    }

    function _coinClaimWeight(uint256 packed) private pure returns (uint256) {
        return _coinWeightMultiplier(packed) * 1 ether;
    }

    function _resolveStart() private returns (uint256 startId) {
        uint256 floor = lowestUnresolved;
        if (floor == 0) floor = 1;

        startId = resolveBaseId;
        if (startId == 0 || startId < floor) {
            startId = nextClaimable;
            if (startId == 0 || startId < floor) {
                startId = floor;
            }
        }
        resolveBaseId = startId;
    }

    // The Engine: Resolves a batch of bonds.
    function _resolvePendingInternal(uint256 maxBonds, bool requirePending) private {
        if (!resolvePending) {
            if (requirePending) revert ResolveNotReady();
            return;
        }
        uint256 rngWord = pendingRngWord;
        if (rngWord == 0) {
            if (gameOver && gameOverRngWord != 0) {
                rngWord = gameOverRngWord;
            } else {
                uint48 rngDay = pendingRngDay;
                if (rngDay == 0) revert InvalidRng();
                address game_ = game;
                if (game_ == address(0)) revert ZeroAddress();
                rngWord = IPurgeGameLike(game_).rngWordForDay(rngDay);
                if (rngWord == 0) revert InvalidRng();
                if (gameOver && gameOverRngWord == 0) {
                    gameOverRngWord = rngWord;
                }
            }
            pendingRngWord = rngWord;
        }

        uint256 tid = pendingResolveBase;
        uint256 maxId = pendingResolveMax == 0 ? _currentIndex - 1 : pendingResolveMax;
        uint256 limit = maxBonds == 0 ? AUTO_RESOLVE_BATCH : maxBonds;
        uint256 budget = pendingResolveBudget;
        // budget is set by `payBonds`; we only advance matured bonds when funding has been explicitly supplied.
        if (budget == 0) revert InsufficientEthForResolve();

        if (tid == 0) tid = 1;

        uint256 rangeEnd = tid + limit - 1;
        if (rangeEnd > maxId) rangeEnd = maxId;
        if (tid > rangeEnd) {
            resolvePending = false;
            pendingRngWord = 0;
            pendingResolveBase = 0;
            pendingResolveMax = 0;
            pendingResolveBudget = 0;
            pendingRngDay = 0;
            transfersLocked = false;
            return;
        }

        uint256 totalSlots = rangeEnd - tid + 1;
        uint256 randomCount = (totalSlots * 20) / 100;
        if (randomCount == 0 && totalSlots != 0) {
            randomCount = 1;
        }
        if (randomCount > totalSlots) {
            randomCount = totalSlots;
        }

        uint256[] memory randomIds = new uint256[](randomCount);
        uint256 randomFilled;
        uint256 seed = rngWord;
        while (randomFilled < randomCount) {
            uint256 candidate = tid + (seed % totalSlots);
            bool dup = false;
            unchecked {
                for (uint256 j; j < randomFilled; ++j) {
                    if (randomIds[j] == candidate) {
                        dup = true;
                        break;
                    }
                }
            }
            if (!dup) {
                randomIds[randomFilled] = candidate;
                unchecked {
                    ++randomFilled;
                }
            }
            seed = uint256(keccak256(abi.encode(seed, randomFilled, tid)));
        }

        bool halted;
        uint256 heldCoinTotal;
        uint256 heldEthTotal;
        for (uint256 i; i < randomFilled; ) {
            (budget, halted, heldCoinTotal, heldEthTotal) = _resolveSingle(
                randomIds[i],
                rngWord,
                budget,
                heldCoinTotal,
                heldEthTotal
            );
            if (halted) {
                break;
            }
            unchecked {
                ++i;
            }
        }

        uint256 processed;
        uint256 cursor = tid;
        while (!halted && processed < totalSlots && cursor <= maxId) {
            bool skip;
            unchecked {
                for (uint256 k; k < randomFilled; ++k) {
                    if (randomIds[k] == cursor) {
                        skip = true;
                        break;
                    }
                }
            }
            if (!skip) {
                (budget, halted, heldCoinTotal, heldEthTotal) = _resolveSingle(
                    cursor,
                    rngWord,
                    budget,
                    heldCoinTotal,
                    heldEthTotal
                );
                if (halted) {
                    tid = cursor;
                    break;
                }
            }
            unchecked {
                ++cursor;
                ++processed;
            }
        }
        if (processed == totalSlots) {
            tid = rangeEnd + 1;
        } else if (cursor > tid) {
            tid = cursor;
        }

        if (heldEthTotal != 0 || heldCoinTotal != 0) {
            _distributeHeldWins(heldEthTotal, heldCoinTotal);
        }

        resolveBaseId = tid;
        if (nextClaimable < tid) {
            nextClaimable = tid;
        }
        if (tid > lowestUnresolved) {
            _burnInactiveUpTo(tid - 1);
        }

        // Reset state for next batch
        resolvePending = false;
        pendingRngWord = 0;
        pendingResolveBase = 0;
        pendingResolveMax = 0;
        pendingResolveBudget = 0;
        pendingRngDay = 0;
        transfersLocked = false;
    }

    function _markClaimable(uint256 tokenId, uint256 basePrice) private {
        uint256 packed = _packedOwnershipOf(tokenId);
        if ((packed & _BITMASK_CLAIM_READY) != 0) return;
        _packedOwnerships[tokenId] = packed | _BITMASK_CLAIM_READY;
        _clearApproval(tokenId);

        // Top up obligations to full 1 ETH value
        if (basePrice < 1 ether) {
            uint256 delta = 1 ether - basePrice;
            totalEthOwed += delta;
            totalCoinOwed += delta * _coinWeightMultiplier(packed);
        }
        emit ClaimEnabled(tokenId);
    }

    function _clearApproval(uint256 tokenId) private {
        address approved = _tokenApprovals[tokenId];
        if (approved != address(0)) {
            _tokenApprovals[tokenId] = address(0);
            uint256 packed = _packedOwnershipAt(tokenId);
            address holder = address(uint160(packed));
            if (holder != address(0)) emit Approval(holder, address(0), tokenId);
        }
    }

    function _resolveLimit(uint256 requested) private pure returns (uint256) {
        uint256 limit = requested == 0 ? AUTO_RESOLVE_BATCH : requested;
        if (limit > GAS_LIMITED_RESOLVE_MAX) limit = GAS_LIMITED_RESOLVE_MAX;
        return limit;
    }

    function _scheduleResolve(
        uint256 startId,
        uint48 rngDay,
        uint256 rngWord,
        uint256 maxBonds,
        uint256 budgetWei
    ) private {
        if (resolvePending) revert ResolvePendingAlready();
        if (rngWord == 0 && rngDay == 0) revert InvalidRng();
        // Resolves run only when the game has injected ETH/stETH via `payBonds`.
        if (budgetWei == 0) revert InsufficientEthForResolve();

        uint256 maxId = _currentIndex - 1;
        if (maxId == 0 || startId == 0 || startId > maxId) revert InvalidToken();

        uint256 plannedMax = maxBonds == 0 ? maxId : startId + maxBonds - 1;
        if (plannedMax > maxId) plannedMax = maxId;

        pendingResolveBase = startId;
        pendingResolveMax = plannedMax;
        pendingRngWord = rngWord;
        pendingRngDay = rngDay;
        resolveBaseId = startId;
        pendingResolveBudget = budgetWei;
        resolvePending = true;
        transfersLocked = true;
    }

    function _syncMultiplier() private {
        if (decayPaused) return;
        uint64 day = uint64(block.timestamp / 1 days);
        uint64 last = lastDecayDay;
        if (day <= last) return;

        uint64 delayUntil = decayDelayUntilDay;
        uint64 anchor = last;
        if (delayUntil != 0) {
            uint64 barrier = delayUntil - 1;
            if (day <= barrier) return;
            if (barrier > anchor) {
                anchor = barrier;
            }
        }
        priceMultiplier = _applyDecay(priceMultiplier, uint256(day - anchor));
        lastDecayDay = day;
    }

    function _multiplierWithDecay() private view returns (uint256) {
        if (decayPaused) return priceMultiplier;
        uint64 day = uint64(block.timestamp / 1 days);
        uint64 last = lastDecayDay;
        if (day <= last) return priceMultiplier;

        uint64 delayUntil = decayDelayUntilDay;
        uint64 anchor = last;
        if (delayUntil != 0) {
            uint64 barrier = delayUntil - 1;
            if (day <= barrier) return priceMultiplier;
            if (barrier > anchor) {
                anchor = barrier;
            }
        }
        return _applyDecay(priceMultiplier, uint256(day - anchor));
    }

    function _applyDecay(uint256 mult, uint256 deltaDays) private pure returns (uint256) {
        if (deltaDays == 0) return mult;
        if (deltaDays > 3650) deltaDays = 3650;

        for (uint256 i; i < deltaDays; ) {
            mult = (mult * DECAY_BPS) / BPS_DENOM;
            unchecked {
                ++i;
            }
        }
        if (mult < 99e17) return 99e17; // Floor at 9.9x
        return mult;
    }

    function _bumpOnSales(uint256 saleAmount) private {
        if (saleAmount == 0) return;
        uint256 acc = salesAccumulator + saleAmount;
        uint256 increments = acc / 1 ether;
        salesAccumulator = acc % 1 ether;
        if (increments == 0) return;

        uint256 mult = priceMultiplier;
        for (uint256 i; i < increments; ) {
            mult = (mult * SALES_BUMP_NUMERATOR) / SALES_BUMP_DENOMINATOR;
            unchecked {
                ++i;
            }
        }
        priceMultiplier = mult;

        uint64 day = uint64(block.timestamp / 1 days);
        uint64 newDelay = day + DECAY_DELAY_DAYS;
        if (newDelay > decayDelayUntilDay) {
            decayDelayUntilDay = newDelay;
        }
        lastDecayDay = day;
    }

    function _currentMintPricing() private view returns (uint256 priceWei, uint256 priceCoinUnit) {
        address game_ = game;
        if (game_ != address(0)) {
            priceWei = IPurgeGamePrice(game_).mintPrice();
            priceCoinUnit = IPurgeGamePrice(game_).coinPriceUnit();
            if (priceWei != 0 && priceCoinUnit != 0) {
                return (priceWei, priceCoinUnit);
            }
        }

        priceWei = _fallbackMintPrice();
        priceCoinUnit = _presaleCoinPriceUnit(priceWei);
    }

    function _presaleCoinPriceUnit(uint256 mintPriceWei) private view returns (uint256) {
        uint256 pricePer1000 = presalePricePer1000Wei;
        if (pricePer1000 == 0) {
            pricePer1000 = PRESALE_PRICE_PER_1000_DEFAULT;
        }
        // coinPriceUnit = (mintPrice / pricePerCoin) scaled by coin decimals (1e6).
        return (mintPriceWei * 1e9) / pricePer1000;
    }

    function _fallbackMintPrice() private pure returns (uint256) {
        return FALLBACK_MINT_PRICE;
    }

    function _bondCoinSaleQuote(uint256 tokenId) private view returns (uint256 coinOut) {
        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed == 0 || (packed & _BITMASK_BURNED) != 0) return 0;

        uint256 basePrice = basePriceOf[tokenId];
        uint256 distance = _currentDistance(tokenId);
        if (distance == 0) return 0;

        uint256 refDistance = lastPurchaseDistance;
        if (refDistance < distance) {
            refDistance = distance;
        }

        uint256 payoutWei = _bondSalePayout(basePrice, distance, refDistance);
        if (payoutWei == 0) return 0;

        address game_ = game;
        if (game_ == address(0)) return 0;
        uint256 priceWei = IPurgeGamePrice(game_).mintPrice();
        uint256 priceCoinUnit = IPurgeGamePrice(game_).coinPriceUnit();
        if (priceWei == 0 || priceCoinUnit == 0) return 0;

        coinOut = (payoutWei * priceCoinUnit) / priceWei;
    }

    function _decreaseTotalCoinOwed(uint256 amount) private {
        if (amount == 0) return;
        uint256 owed = totalCoinOwed;
        if (owed <= amount) {
            totalCoinOwed = 0;
        } else {
            totalCoinOwed = owed - amount;
        }
    }

    function _burnAllBonds() private {
        if (allBondsBurned) return;
        allBondsBurned = true;
        uint256 minted = _currentIndex - 1;
        burnedCount = minted;
        totalEthOwed = 0;
        totalCoinOwed = 0;
        bondCoin = 0;
        payoutObligation = 0;
        resolvePending = false;
        pendingRngWord = 0;
        pendingRngDay = 0;
        pendingResolveBase = 0;
        pendingResolveMax = 0;
        pendingResolveBudget = 0;
        uint256 end = _currentIndex;
        lowestUnresolved = end;
        shutdownBurnCursor = end;
        nextClaimable = end;
        transfersLocked = true;
        purchasesEnabled = false;
    }

    function _applyAffiliateCode(address buyer, bytes32 affiliateCode, uint256 weiSpent) private {
        address affiliate = affiliateProgram;
        if (affiliate == address(0) || affiliateCode == bytes32(0) || weiSpent == 0) return;

        uint256 coinBase;
        bool usedFallbackPrice;
        address game_ = game;
        if (game_ != address(0)) {
            uint256 priceWei = IPurgeGamePrice(game_).mintPrice();
            uint256 priceCoinUnit = IPurgeGamePrice(game_).coinPriceUnit();
            if (priceWei != 0 && priceCoinUnit != 0) {
                coinBase = (weiSpent * priceCoinUnit) / priceWei;
            }
        }
        // Fallback pricing if Game is not reporting correctly
        if (coinBase == 0) {
            usedFallbackPrice = true;
            uint256 pricePer1000 = FALLBACK_MINT_PRICE;
            coinBase = (weiSpent * 1000 * 1e6) / pricePer1000;
        }

        uint256 pct = usedFallbackPrice ? 10 : 3;
        uint256 affiliateAmount = (coinBase * pct) / 100;
        if (affiliateAmount == 0) return;

        IPurgeAffiliateLike(affiliate).payAffiliate(affiliateAmount, affiliateCode, buyer, 0);
    }

    function _setCoinToken(address token) private {
        if (token == address(0)) return;
        address current = coinToken;
        if (current != address(0)) {
            if (current != token) revert AlreadyConfigured();
            return;
        }
        coinToken = token;
    }

    function _markPrizePoolFunded() private {
        if (!prizePoolFunded) {
            prizePoolFunded = true;
        }
    }

    function _setGame(address game_) private {
        if (game_ == address(0)) return;
        address current = game;
        if (current != address(0)) {
            if (current != game_) revert AlreadyConfigured();
            return;
        }
        game = game_;
        uint256 seed = rewardSeedEth;
        if (seed != 0) {
            rewardSeedEth = 0;
            _markPrizePoolFunded();
            (bool ok, ) = payable(game_).call{value: seed}("");
            if (!ok) revert CallFailed();
        }
    }

    function _setAffiliate(address affiliate_) private {
        if (affiliate_ == address(0)) return;
        address current = affiliateProgram;
        if (current != address(0)) {
            if (current != affiliate_) revert AlreadyConfigured();
            return;
        }
        affiliateProgram = affiliate_;
    }

    function _advanceClaimableCursor() private {
        uint256 cursor = nextClaimable;
        if (cursor == 0) cursor = 1;
        uint256 maxId = _currentIndex - 1;
        while (cursor <= maxId) {
            uint256 packed = _packedOwnershipAt(cursor);
            if (packed == 0) break;
            if ((packed & (_BITMASK_BURNED | _BITMASK_CLAIM_READY)) == 0) {
                break;
            }
            unchecked {
                ++cursor;
            }
        }
        nextClaimable = cursor;
        if (lowestUnresolved < cursor) {
            lowestUnresolved = cursor;
        }
        if (resolveBaseId < cursor) {
            resolveBaseId = cursor;
        }
    }

    function _transferToVault(address from, uint256 tokenId, uint256 prevOwnershipPacked) private {
        address approvedAddress = _tokenApprovals[tokenId];
        if (approvedAddress != address(0)) {
            _tokenApprovals[tokenId] = address(0);
            emit Approval(from, address(0), tokenId);
        }

        uint256 fromData = _packedAddressData[from];
        uint256 toData = _packedAddressData[address(this)];

        unchecked {
            _packedAddressData[from] =
                (fromData & ~_BITMASK_ADDRESS_DATA_ENTRY) |
                ((fromData & _BITMASK_ADDRESS_DATA_ENTRY) - 1);
            _packedAddressData[address(this)] =
                (toData & ~_BITMASK_ADDRESS_DATA_ENTRY) |
                ((toData & _BITMASK_ADDRESS_DATA_ENTRY) + 1);

            uint256 flags = _BITMASK_NEXT_INITIALIZED | (prevOwnershipPacked & _BITMASK_STAKED);
            _packedOwnerships[tokenId] = _packOwnershipData(address(this), flags);

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextId = tokenId + 1;
                if (_packedOwnerships[nextId] == 0 && nextId != _currentIndex) {
                    _packedOwnerships[nextId] = prevOwnershipPacked;
                }
            }
        }

        emit Transfer(from, address(this), tokenId);
    }

    function _inPendingWindow(uint256 tokenId) private view returns (bool) {
        if (allBondsBurned) return false;
        if (!resolvePending) return false;
        uint256 start = pendingResolveBase;
        uint256 end = pendingResolveMax;
        if (start == 0) return false;
        if (end == 0) end = _currentIndex - 1;
        return tokenId >= start && tokenId <= end;
    }

    function _transfersBlocked(uint256 tokenId) private view returns (bool) {
        uint256 packed = _packedOwnershipAt(tokenId);
        return transfersLocked || (packed & _BITMASK_STAKED) != 0 || _isResolved(tokenId) || _inPendingWindow(tokenId);
    }

    function bondOutcome(
        uint256 tokenId,
        uint256 rngWord
    ) public view returns (bool win, uint16 chanceBps, uint256 roll) {
        _requireActiveToken(tokenId);
        chanceBps = getWinChance(tokenId);
        // Hash(Seed + TokenID) % 1000
        roll = uint256(keccak256(abi.encodePacked(rngWord, tokenId))) % 1000;
        win = roll < chanceBps;
    }

    function _resolveBond(uint256 tokenId, uint256 rngWord) private returns (uint8 outcome, uint256 heldCoin, uint256 heldEth) {
        uint256 basePrice = basePriceOf[tokenId];
        uint256 packed = _packedOwnershipOf(tokenId);
        uint256 weight = _coinWeightMultiplier(packed);
        address owner_ = address(uint160(packed));
        uint16 chance;
        uint256 roll;

        bool win;
        (win, chance, roll) = bondOutcome(tokenId, rngWord);
        if (win) {
            if (owner_ == address(this)) {
                uint256 coinShare;
                uint256 coinOwed = totalCoinOwed;
                if (coinOwed != 0 && bondCoin != 0) {
                    coinShare = (bondCoin * weight) / coinOwed;
                }
                _burnToken(tokenId, owner_);
                payoutObligation = payoutObligation <= 1 ether ? 0 : payoutObligation - 1 ether;
                totalEthOwed -= 1 ether;
                _decreaseTotalCoinOwed(weight);
                heldCoin = coinShare;
                heldEth = 1 ether;
                outcome = 2;
            } else if (gameOver) {
                // Game over: keep claimable flow.
                if ((packed & _BITMASK_CLAIM_READY) == 0) {
                    packed = packed | _BITMASK_CLAIM_READY;
                    _packedOwnerships[tokenId] = packed;
                    _clearApproval(tokenId);
                    emit ClaimEnabled(tokenId);
                    // Add missing obligation if we weren't fully funded
                    if (basePrice < 1 ether) {
                        uint256 delta = 1 ether - basePrice;
                        totalEthOwed += delta;
                        totalCoinOwed += delta * weight;
                    }
                }
                outcome = 1; // claimable (GG)
            } else {
                _payoutLiveWinner(tokenId, packed, owner_);
                outcome = 2; // paid directly to game credit
            }
        }
        // Losing bonds are handled in _burnInactiveUpTo
        emit BondResolved(tokenId, win, chance, roll);
    }

    function _distributeHeldWins(uint256 ethAmount, uint256 coinAmount) private {
        address game_ = game;
        if (game_ == address(0)) return;

        // Handle ETH portion
        if (ethAmount != 0) {
            uint256 payDeficit = ethAmount;
            uint256 deficit = gameRefundDeficit;
            if (deficit < payDeficit) payDeficit = deficit;

            uint256 remaining = ethAmount;
            if (payDeficit != 0) {
                gameRefundDeficit = deficit - payDeficit;
                remaining -= payDeficit;
                (bool ok, ) = payable(game_).call{value: payDeficit}("");
                if (!ok) revert CallFailed();
            }

            if (remaining != 0) {
                uint256 toGame = (remaining * 40) / 100;
                uint256 toFund = (remaining * 40) / 100;
                uint256 toSlush = remaining - toGame - toFund;

                if (toGame != 0) {
                    (bool okGame, ) = payable(game_).call{value: toGame}("");
                    if (!okGame) revert CallFailed();
                }
                if (toFund != 0) {
                    payoutObligation += toFund;
                }
                // toSlush is intentionally left in contract balance
                toSlush;
            }
        }

        // Handle coin portion
        if (coinAmount != 0) {
            uint256 available = bondCoin < coinAmount ? bondCoin : coinAmount;
            if (available != 0) {
                bondCoin -= available;
                uint256 toFund = available / 2;
                uint256 toSlush = available - toFund;
                if (toFund != 0) {
                    bondCoin += toFund;
                }
                // toSlush remains as surplus coin balance on the contract
                toSlush;
            }
        }
    }

    function _resolveSingle(
        uint256 tokenId,
        uint256 rngWord,
        uint256 budget,
        uint256 heldCoinAcc,
        uint256 heldEthAcc
    ) private returns (uint256 newBudget, bool stop, uint256 heldCoin, uint256 heldEth) {
        newBudget = budget;
        heldCoin = heldCoinAcc;
        heldEth = heldEthAcc;
        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed == 0 || (packed & _BITMASK_BURNED) != 0) {
            return (newBudget, false, heldCoin, heldEth);
        }

        uint256 basePrice = basePriceOf[tokenId];
        uint256 delta = basePrice >= 1 ether ? 0 : (1 ether - basePrice);
        if (newBudget < delta) return (newBudget, true, heldCoin, heldEth);

        (uint8 outcome, uint256 heldCoinWin, uint256 heldEthWin) = _resolveBond(tokenId, rngWord);
        if (outcome == 1) {
            if (delta != 0) newBudget -= delta;
            _markClaimable(tokenId, basePrice);
        } else if (outcome == 2) {
            if (delta != 0) newBudget -= delta;
        } else {
            newBudget += basePrice;
        }
        if (heldCoinWin != 0) heldCoin += heldCoinWin;
        if (heldEthWin != 0) heldEth += heldEthWin;
        return (newBudget, false, heldCoin, heldEth);
    }

    function _payoutLiveWinner(uint256 tokenId, uint256 packed, address owner_) private {
        if (owner_ == address(0)) return;

        uint256 coinWeight = _coinClaimWeight(packed);
        uint256 bondShare;
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * coinWeight) / coinOwed;
            if (bondShare != 0) {
                if (bondCoin <= bondShare) {
                    bondCoin = 0;
                } else {
                    bondCoin -= bondShare;
                }
                IERC20Minimal(coinToken).transfer(owner_, bondShare);
            }
        }

        _burnToken(tokenId, owner_);

        uint256 amount = 1 ether;
        if (address(this).balance < amount) revert InsufficientPayout();

        address game_ = game;
        if (game_ == address(0)) revert ZeroAddress();

        payoutObligation = payoutObligation <= amount ? 0 : payoutObligation - amount;
        totalEthOwed -= 1 ether;
        _decreaseTotalCoinOwed(coinWeight);

        IPurgeGameBondWinnings(game_).creditBondWinnings{value: amount}(owner_);

        emit Claimed(owner_, tokenId, amount, 0, bondShare);
    }

    function _burnUnmaturedFromCursor(
        uint256 maxIds
    ) private returns (uint256 processed, uint256 burned, bool complete) {
        uint256 tid = shutdownBurnCursor;
        if (tid == 0) tid = lowestUnresolved;
        if (tid == 0) tid = 1;

        uint256 maxId = _currentIndex - 1;
        if (maxId == 0 || tid > maxId) {
            shutdownBurnCursor = tid;
            return (0, 0, true);
        }

        uint256 limit = maxIds == 0 ? 500 : maxIds;
        address ownerCursor;
        uint256 ownerBurns;

        while (processed < limit && tid <= maxId) {
            uint256 prevOwnershipPacked = _packedOwnershipAt(tid);
            if (prevOwnershipPacked == 0) {
                unchecked {
                    ++processed;
                    ++tid;
                }
                continue;
            }
            // Only burn if not claimed/burned already
            if ((prevOwnershipPacked & (_BITMASK_CLAIM_READY | _BITMASK_BURNED)) == 0) {
                address holder = address(uint160(prevOwnershipPacked));
                if (holder != address(0)) {
                    // Decrement Liabilities
                    uint256 basePrice = basePriceOf[tid];
                    totalEthOwed -= basePrice;
                    _decreaseTotalCoinOwed(basePrice * _coinWeightMultiplier(prevOwnershipPacked));

                    _markBurned(tid, prevOwnershipPacked);

                    if (_tokenApprovals[tid] != address(0)) {
                        _tokenApprovals[tid] = address(0);
                    }

                    // Batch accounting updates for owners
                    if (ownerCursor != holder) {
                        if (ownerCursor != address(0) && ownerBurns != 0) {
                            _applyBurnAccounting(ownerCursor, ownerBurns);
                        }
                        ownerCursor = holder;
                        ownerBurns = 1;
                    } else {
                        unchecked {
                            ++ownerBurns;
                        }
                    }

                    emit BondBurned(tid);
                    emit Transfer(holder, address(0), tid);
                    unchecked {
                        ++burned;
                    }
                }
            }

            unchecked {
                ++processed;
                ++tid;
            }
        }

        if (ownerCursor != address(0) && ownerBurns != 0) {
            _applyBurnAccounting(ownerCursor, ownerBurns);
        }
        if (burned != 0) {
            burnedCount += burned;
        }

        shutdownBurnCursor = tid;
        if (nextClaimable < tid) nextClaimable = tid;
        if (tid > lowestUnresolved) lowestUnresolved = tid;

        complete = tid > maxId;
    }

    // Cleans up losers behind the resolution cursor
    function _burnInactiveUpTo(uint256 targetId) private {
        uint256 tid = lowestUnresolved;
        if (tid == 0) tid = 1;
        if (targetId < tid) return;

        uint256 burned;
        address ownerCursor;
        uint256 ownerBurns;

        while (tid <= targetId) {
            uint256 prevOwnershipPacked = _packedOwnershipAt(tid);
            if (prevOwnershipPacked == 0) {
                unchecked {
                    ++tid;
                }
                continue;
            }
            bool resolvedWinner = (prevOwnershipPacked & (_BITMASK_CLAIM_READY | _BITMASK_BURNED)) != 0;
            if (resolvedWinner) {
                unchecked {
                    ++tid;
                }
                continue;
            }

            address holder = address(uint160(prevOwnershipPacked));
            if (holder != address(0)) {
                uint256 basePrice = basePriceOf[tid];
                totalEthOwed -= basePrice;
                _decreaseTotalCoinOwed(basePrice * _coinWeightMultiplier(prevOwnershipPacked));

                if (_tokenApprovals[tid] != address(0)) {
                    _tokenApprovals[tid] = address(0);
                }

                _markBurned(tid, prevOwnershipPacked);

                if (ownerCursor != holder) {
                    if (ownerCursor != address(0) && ownerBurns != 0) {
                        _applyBurnAccounting(ownerCursor, ownerBurns);
                    }
                    ownerCursor = holder;
                    ownerBurns = 1;
                } else {
                    unchecked {
                        ++ownerBurns;
                    }
                }

                emit BondBurned(tid);
                emit Transfer(holder, address(0), tid);
                unchecked {
                    ++burned;
                }
            }
            unchecked {
                ++tid;
            }
        }

        if (ownerCursor != address(0) && ownerBurns != 0) {
            _applyBurnAccounting(ownerCursor, ownerBurns);
        }
        if (burned != 0) {
            burnedCount += burned;
        }
        lowestUnresolved = tid;
    }

    function _burnToken(uint256 tokenId, address holder) private {
        if (holder == address(0)) return;
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        address ownerOfToken = address(uint160(prevOwnershipPacked));
        if (ownerOfToken != holder) {
            holder = ownerOfToken;
        }

        _applyBurnAccounting(holder, 1);
        unchecked {
            ++burnedCount;
        }

        if (_tokenApprovals[tokenId] != address(0)) {
            _tokenApprovals[tokenId] = address(0);
        }
        _markBurned(tokenId, prevOwnershipPacked);
        emit Transfer(holder, address(0), tokenId);
    }

    function _claimHeldBond(uint256 tokenId) private {
        uint256 packed = _packedOwnershipOf(tokenId);
        if (address(uint160(packed)) != address(this)) return;
        if ((packed & _BITMASK_CLAIM_READY) == 0) return;

        _burnToken(tokenId, address(this));

        uint256 bondShare;
        uint256 coinWeight = _coinClaimWeight(packed);
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * coinWeight) / coinOwed;
            uint256 recycleCoin;
            uint256 payOutCoin = bondShare;
            if (bondShare != 0) {
                recycleCoin = bondShare / 2;
                payOutCoin = bondShare - recycleCoin;
                if (recycleCoin != 0) {
                    bondCoin += recycleCoin; // recycle half back into the pool
                }
            }
            if (bondCoin <= payOutCoin) {
                bondCoin = 0;
            } else {
                bondCoin -= payOutCoin;
            }
        }

        uint256 ethPaid;
        uint256 stEthPaid;
        uint256 ethBal = address(this).balance;
        address stToken = stEthToken;
        uint256 stBal = stToken == address(0) ? 0 : IERC20Minimal(stToken).balanceOf(address(this));
        uint256 amount = 1 ether;
        bool payEth = ethBal >= amount;
        if (!payEth && stBal < amount) revert InsufficientPayout();

        uint256 toGame = amount / 5; // 20%
        uint256 toPayout = (amount * 7) / 10; // 70%
        uint256 retained = amount - toGame - toPayout; // 10%

        address game_ = game;
        if (game_ == address(0)) revert ZeroAddress();

        if (payEth) {
            ethPaid = amount;
            if (toGame != 0) {
                (bool ok, ) = payable(game_).call{value: toGame}("");
                if (!ok) revert CallFailed();
            }
        } else {
            stEthPaid = amount;
            if (toGame != 0) {
                IERC20Minimal(stToken).transfer(game_, toGame);
            }
        }

        // Adjust payout obligations: this bond is settled, 70% is re-reserved, 10% stays as free balance.
        if (payoutObligation <= amount) {
            payoutObligation = 0;
        } else {
            payoutObligation -= amount;
        }
        payoutObligation += toPayout;
        // retained remains in contract balance by design

        totalEthOwed -= 1 ether;
        _decreaseTotalCoinOwed(coinWeight);

        emit Claimed(address(this), tokenId, ethPaid, stEthPaid, bondShare);
    }

    function _isResolved(uint256 tokenId) private view returns (bool) {
        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed == 0) return false;
        if ((packed & _BITMASK_BURNED) != 0) return true;
        return (packed & _BITMASK_CLAIM_READY) != 0 || _isInactive(tokenId);
    }

    function _currentDistance(uint256 tokenId) private view returns (uint256) {
        if (_isResolved(tokenId)) return 0;
        uint256 cursor = nextClaimable;
        if (tokenId < cursor) return 0;
        return (tokenId - cursor) + 1;
    }
}

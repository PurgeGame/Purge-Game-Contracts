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
        bool staked
    ) external view returns (string memory);
}

interface IPurgeGameLike {
    function rngWordForDay(uint48 day) external view returns (uint256);
}

interface IPurgeCoinBondMinter {
    function bondPayment(address to, uint256 amount) external;
}

interface IPurgeAffiliateLike {
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external returns (uint256);
}

interface IPurgeGamePrice {
    function mintPrice() external view returns (uint256);
    function coinPriceUnit() external view returns (uint256);
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
 *    - Staked bonds (non-transferable) get 5x the PURGE token weight.
 * 4. Accounting:
 *    - `totalCoinOwed` tracks the SUM of all potential liabilities (Weighted).
 *    - This ensures the contract is always solvent for the winning scenario.
 */
contract PurgeBonds {
    // ===========================================================================
    // Errors
    // ===========================================================================
    error Unauthorized();                 // 0x82b42900
    error ZeroAddress();                  // 0xd92e233d
    error InvalidToken();                 // 0xc1ab6dc1
    error CallFailed();                   // 0x3204506f
    error InvalidRisk();                  // 0x99963255
    error WrongPrice();                   // 0xcf16278b
    error NotClaimable();                 // 0x203d82d8
    error AlreadyClaimed();               // 0x646cf558
    error PurchasesClosed();              // 0x827f9581
    error InsufficientCoinAvailable();    // 0xdec227d9
    error ResolvePendingAlready();        // 0x2f0d353d
    error ResolveNotReady();              // 0xc254d528
    error InsufficientEthForResolve();    // 0x6d552e2d
    error InvalidRng();                   // 0x4b0b761f
    error InvalidQuantity();              // 0x9a23d870
    error InvalidBase();                  // 0x55862059
    error InsufficientHeadroom();         // 0x19c42145
    error TransferBlocked();              // 0x30227e53
    error InvalidRate();                  // 0x26650026
    error AlreadyConfigured();            // 0x2e68d627
    error GameOver();                     // 0x0e647580
    error ShutdownPendingResolution();    // 0x2306321e
    error ExpiredSweepLocked();           // 0x44132333
    error InsufficientPayout();           // 0x8024d516

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
    uint256 private constant DECAY_BPS = 9950;          // 0.5% daily price decay
    uint256 private constant BPS_DENOM = 10_000;
    uint64 private constant DECAY_DELAY_DAYS = 7;       // Bumps delay decay for 7 days
    uint256 private constant COIN_WEIGHT_UNMARKETABLE = 5; // Staked (non-transferable) weight
    uint256 private constant COIN_WEIGHT_MARKETABLE = 1;   // Unstaked (transferable) weight
    uint256 private constant MIN_BASE_PRICE = 0.02 ether;  // Minimum bond size
    uint256 private constant AUTO_RESOLVE_BATCH = 50;
    uint256 private constant GAS_LIMITED_RESOLVE_MAX = 600;
    uint256 private constant SALES_BUMP_NUMERATOR = 1005;   // +0.5% price per threshold
    uint256 private constant SALES_BUMP_DENOMINATOR = 1000;

    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // ===========================================================================
    // State Variables
    // ===========================================================================

    // -- Metadata & Access --
    string public name;
    string public symbol;
    address public owner;
    address public fundRecipient; // Receives sales proceeds
    address public stEthToken;    // The "Prime" asset for payouts
    address public coinToken;     // The "Bonus" asset (PURGE)
    address public renderer;
    address public game;          // The main PurgeGame contract
    address public affiliateProgram;

    // -- Financial Accounting --
    // `pool` variables track actual assets held.
    // `Owed` variables track liabilities (if everyone won).
    uint256 public ethPool;
    uint256 public stEthPool;
    uint256 public bondPool;      // Tracks PURGE available for claims
    uint256 public bondCoin;      // Redundant tracker for bond payouts logic
    uint256 public totalEthOwed;  // Aggregate ETH liability
    uint256 public totalCoinOwed; // Aggregate weighted PURGE liability
    uint256 public rewardSeedEth; // Accumulator for game rewards from unwired state
    uint256 private stEthAccounted; // Internal accounting to prevent donation attacks

    // -- Resolution State --
    bool public resolvePending;
    uint256 public pendingRngWord;
    uint48 public pendingRngDay;
    uint256 public pendingResolveBase;
    uint256 public pendingResolveMax;
    uint256 public pendingResolveBudget;

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
    mapping(uint256 => uint256) public basePriceOf;   // The "Principal" paid
    mapping(uint256 => uint32) public createdDistance; // Snapshot of queue depth at mint

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

    modifier onlyOwnerOrGame() {
        address sender = msg.sender;
        if (sender != owner && sender != game) revert Unauthorized();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address fundRecipient_,
        address stEthToken_
    ) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (fundRecipient_ == address(0)) revert ZeroAddress();
        if (stEthToken_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        owner = owner_;
        fundRecipient = fundRecipient_;
        stEthToken = stEthToken_;
        uint64 day = uint64(block.timestamp / 1 days);
        lastDecayDay = day;
        decayDelayUntilDay = day;
    }

    // ===========================================================================
    // Funding & Resolution Ingest
    // ===========================================================================

    /**
     * @notice Main entry point to fund the contract and trigger bond resolution.
     * @dev Callable by owner or game. Automatically batches resolution if budgets allow.
     * @param coinAmount Amount of PURGE tokens being sent/credited.
     * @param stEthAddress Address check for safety.
     * @param rngDay The game day to fetch RNG for (if not provided via `rngWord`).
     * @param rngWord The random seed for resolution (overrides `rngDay` if non-zero).
     * @param baseId Explicit start ID for resolution (0 = auto).
     * @param maxBonds Resolution batch size limit.
     */
    function payBonds(
        uint256 coinAmount,
        address stEthAddress,
        uint48 rngDay,
        uint256 rngWord,
        uint256 baseId,
        uint256 maxBonds
    ) external payable onlyOwnerOrGame {
        // 1. Ingest ETH
        ethPool += msg.value;

        // 2. Ingest Coin (PURGE)
        uint256 bondAdded;
        if (coinAmount != 0) {
            address coin = coinToken;
            if (coin == address(0)) revert ZeroAddress();
            
            // Game mints directly; Users transfer.
            // Note: Users taking a 75% haircut on "donation" is a specific game mechanic.
            if (msg.sender == game) {
                IPurgeCoinBondMinter(coin).bondPayment(address(this), coinAmount);
                bondAdded = coinAmount; 
            } else {
                IERC20Minimal(coin).transferFrom(msg.sender, address(this), coinAmount);
                bondAdded = coinAmount / 4; // 25% credited to pool
                bondPool += bondAdded;
                bondCoin += bondAdded;
            }
        }

        // 3. Ingest stETH (Rebase/Donation check)
        uint256 stAdded;
        if (stEthAddress != address(0)) {
            if (stEthToken == address(0)) {
                stEthToken = stEthAddress;
            } else if (stEthToken != stEthAddress) {
                revert InvalidToken();
            }
            uint256 bal = IERC20Minimal(stEthToken).balanceOf(address(this));
            if (bal > stEthAccounted) {
                stAdded = bal - stEthAccounted;
                stEthPool += stAdded;
                stEthAccounted = bal;
            }
        }

        emit BondsPaid(msg.value, stAdded, bondAdded);

        // 4. Schedule Resolution
        uint256 budget = msg.value + stAdded;
        if ((rngWord != 0 || rngDay != 0) && ethPool > 1 ether && !resolvePending && budget != 0) {
            uint256 startId = _resolveStart(baseId);
            if (startId != 0) {
                _scheduleResolve(startId, rngDay, rngWord, maxBonds, budget);
            }
        }

        // 5. Execute Resolution Batch (if ready)
        if (resolvePending) {
            bool ready;
            if (pendingRngWord != 0) {
                ready = true;
            } else if (pendingRngDay != 0 && game != address(0)) {
                uint256 fetched = IPurgeGameLike(game).rngWordForDay(pendingRngDay);
                if (fetched != 0) {
                    pendingRngWord = fetched;
                    ready = true;
                }
            }
            if (ready) {
                _resolvePendingInternal(AUTO_RESOLVE_BATCH, false);
            }
        }
    }

    /**
     * @notice Manual trigger to process pending bonds if auto-batching didn't finish.
     */
    function resolvePendingBonds(uint256 maxBonds) external {
        _resolvePendingInternal(_resolveLimit(maxBonds), true);
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

    /**
     * @notice Purchase bonds.
     * @param baseWei The 'Principal' amount (affects win chance and payout).
     * @param quantity Number of bonds.
     * @param stake If true, bonds are Soulbound but get 5x weight in coin payouts.
     * @param affiliateCode Referral code.
     */
    function buy(uint256 baseWei, uint256 quantity, bool stake, bytes32 affiliateCode) external payable {
        address recipient = fundRecipient;
        if (recipient == address(0)) revert ZeroAddress();
        if (!purchasesEnabled) revert PurchasesClosed();
        if (resolvePending) revert ResolvePendingAlready();
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

        _mintBatch(msg.sender, quantity, basePerBond, price, stake);

        // Distribute ETH
        _processPayment(msg.value, recipient);
        _bumpOnSales(msg.value);
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
            (packedData &
                ~(_BITMASK_ADDRESS_DATA_ENTRY | (_BITMASK_ADDRESS_DATA_ENTRY << _BITPOS_NUMBER_MINTED))) |
            balance |
            (minted << _BITPOS_NUMBER_MINTED);

        // **CRITICAL ACCOUNTING**: Add weighted obligation to the global counter.
        // Staked bonds = 5x weight. Unstaked = 1x weight.
        uint256 weight = stake ? COIN_WEIGHT_UNMARKETABLE : COIN_WEIGHT_MARKETABLE;
        totalEthOwed += basePrice * quantity;
        totalCoinOwed += basePrice * weight * quantity;

        uint256 tokenId = startTokenId;
        uint256 end = startTokenId + quantity;
        uint256 toMasked = uint256(uint160(to)) & _BITMASK_ADDRESS;
        
        // Loop for per-token metadata setup (cannot be packed efficiently due to distinct Base Prices)
        do {
            basePriceOf[tokenId] = basePrice;
            createdDistance[tokenId] = uint32(_currentDistance(tokenId));
            // Note: WinChance is no longer stored; derived from basePrice.

            emit Purchased(to, tokenId, basePrice, paidWei);

            assembly {
                log4(0, 0, _TRANSFER_EVENT_SIGNATURE, 0, toMasked, tokenId)
            }
            if (to.code.length != 0) {
                if (!_checkOnERC721Received(msg.sender, address(0), to, tokenId, "")) revert CallFailed();
            }
            unchecked {
                ++tokenId;
            }
        } while (tokenId != end);
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
        
        if (stEthPool >= 1 ether) {
            stEthPool -= 1 ether;
            stEthPaid = 1 ether;
            IERC20Minimal(stToken).transfer(to, stEthPaid);
            if (stEthAccounted >= stEthPaid) {
                stEthAccounted -= stEthPaid;
            } else {
                stEthAccounted = 0;
            }
        } else if (ethPool >= 1 ether) {
            ethPool -= 1 ether;
            ethPaid = 1 ether;
            (bool ok, ) = payable(to).call{value: ethPaid}("");
            if (!ok) revert CallFailed();
        } else {
            revert InsufficientPayout();
        }

        if (bondShare != 0) {
            if (bondPool >= bondShare) {
                bondPool -= bondShare;
            } else {
                bondPool = 0;
            }
            bondCoin -= bondShare;
            IERC20Minimal(coinToken).transfer(to, bondShare);
        }

        // 4. Update Global Obligations
        totalEthOwed -= 1 ether;
        _decreaseTotalCoinOwed(coinWeight); // Remove our weighted liability
        
        emit Claimed(to, tokenId, ethPaid, stEthPaid, bondShare);
    }

    // ===========================================================================
    // Admin / Config
    // ===========================================================================

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setFundRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        fundRecipient = newRecipient;
    }

    function wire(address[] calldata addresses) external onlyOwner {
        _setCoinToken(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setAffiliate(addresses.length > 2 ? addresses[2] : address(0));
    }

    /**
     * @notice Triggers Game Over state (pausing purchases).
     */
    function notifyGameOver() external onlyOwnerOrGame {
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
        if (token == address(0)) {
            uint256 headroom = _ethHeadroom();
            if (amount == 0) amount = headroom;
            if (amount == 0 || amount > headroom) revert InsufficientHeadroom();
            ethPool -= amount;
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert CallFailed();
            return;
        }
        if (token == stEthToken) {
            uint256 headroom = _stEthHeadroom();
            if (amount == 0) amount = headroom;
            if (amount == 0 || amount > headroom) revert InsufficientHeadroom();
            stEthAccounted -= amount;
            IERC20Minimal(token).transfer(to, amount);
            return;
        }
        if (token != coinToken) revert InvalidToken();
        // For coin, we only hold what's in `bondCoin`. Any excess is fair game.
        uint256 bal = IERC20Minimal(token).balanceOf(address(this));
        uint256 reserved = bondCoin;
        uint256 available = bal > reserved ? bal - reserved : 0;
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

    function setTransfersLocked(bool locked, uint48 rngDay) external onlyOwnerOrGame {
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
     * @notice Final cleanup 1 year after Game Over.
     */
    function sweepExpiredPools(address to) external onlyOwner returns (uint256 ethOut, uint256 stEthOut, uint256 coinOut) {
        if (to == address(0)) revert ZeroAddress();
        uint256 endedAt = gameOverTimestamp;
        if (endedAt == 0 || block.timestamp <= endedAt + 365 days) revert ExpiredSweepLocked();

        ethOut = address(this).balance;
        if (ethOut != 0) {
            ethPool = 0;
            (bool ok, ) = payable(to).call{value: ethOut}("");
            if (!ok) revert CallFailed();
        }

        address stToken = stEthToken;
        if (stToken != address(0)) {
            stEthOut = IERC20Minimal(stToken).balanceOf(address(this));
            if (stEthOut != 0) {
                stEthPool = 0;
                stEthAccounted = 0;
                IERC20Minimal(stToken).transfer(to, stEthOut);
            }
        }

        address coin = coinToken;
        if (coin != address(0)) {
            coinOut = IERC20Minimal(coin).balanceOf(address(this));
            if (coinOut != 0) {
                bondCoin = 0;
                bondPool = 0;
                totalCoinOwed = 0;
                IERC20Minimal(coin).transfer(to, coinOut);
            }
        }
        _burnAllBonds();
    }

    /**
     * @notice Permissionless cleanup after shutdown.
     */
    function finalizeShutdown(
        uint256 maxIds
    ) external onlyOwnerOrGame returns (uint256 processedIds, uint256 burned, bool complete) {
        if (!gameOver) revert GameOver();
        if (resolvePending || pendingRngDay != 0 || pendingRngWord != 0) revert ShutdownPendingResolution();
        (processedIds, burned, complete) = _burnUnmaturedFromCursor(maxIds);
        emit ShutdownBurned(processedIds, burned, complete);
    }

    function onBondMint(uint256 amount) external {
        if (msg.sender != coinToken) revert Unauthorized();
        if (amount == 0) return;
        bondCoin += amount;
        bondPool += amount;
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
        
        bool isStaked = (_packedOwnershipOf(tokenId) & _BITMASK_STAKED) != 0;
        return IPurgeBondRenderer(renderer).bondTokenURI(tokenId, created, current, chance, isStaked);
    }

    function getWinChance(uint256 tokenId) public view returns (uint16) {
        uint256 base = basePriceOf[tokenId];
        if (base == 0) return 0;
        
        uint256 c = (base * 1000) / 1 ether;
        if (c == 0) return 1;
        if (c > 1000) return 1000;
        return uint16(c);
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
        if (stEthPool >= 1 ether) {
            stEthShare = 1 ether;
        } else if (ethPool >= 1 ether) {
            ethShare = 1 ether;
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
            _packedAddressData[from] = (fromData & ~_BITMASK_ADDRESS_DATA_ENTRY) | ((fromData & _BITMASK_ADDRESS_DATA_ENTRY) - 1);
            _packedAddressData[to] = (toData & ~_BITMASK_ADDRESS_DATA_ENTRY) | ((toData & _BITMASK_ADDRESS_DATA_ENTRY) + 1);

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
        assembly {
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
            (packedData &
                ~(_BITMASK_ADDRESS_DATA_ENTRY | (_BITMASK_ADDRESS_DATA_ENTRY << _BITPOS_NUMBER_BURNED))) |
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

    function _resolveStart(uint256 baseId) private returns (uint256 startId) {
        uint256 floor = lowestUnresolved;
        if (floor == 0) floor = 1;
        
        if (baseId != 0) {
            if (baseId < floor) baseId = floor;
            resolveBaseId = baseId;
            return baseId;
        }
        startId = resolveBaseId;
        if (startId == 0 || startId < floor) {
            startId = nextClaimable;
            if (startId == 0 || startId < floor) {
                startId = floor;
            }
            resolveBaseId = startId;
        }
    }

    // The Engine: Resolves a batch of bonds.
    function _resolvePendingInternal(uint256 maxBonds, bool requirePending) private {
        if (!resolvePending) {
            if (requirePending) revert ResolveNotReady();
            return;
        }
        uint256 rngWord = pendingRngWord;
        if (rngWord == 0) {
            uint48 rngDay = pendingRngDay;
            if (rngDay == 0) revert InvalidRng();
            address game_ = game;
            if (game_ == address(0)) revert ZeroAddress();
            rngWord = IPurgeGameLike(game_).rngWordForDay(rngDay);
            if (rngWord == 0) revert InvalidRng();
            pendingRngWord = rngWord;
        }

        uint256 tid = pendingResolveBase;
        uint256 maxId = pendingResolveMax == 0 ? _currentIndex - 1 : pendingResolveMax;
        uint256 limit = maxBonds == 0 ? AUTO_RESOLVE_BATCH : maxBonds;
        uint256 budget = pendingResolveBudget;
        if (budget == 0) revert InsufficientEthForResolve();

        uint256 processed;
        while (processed < limit && tid <= maxId) {
            uint256 packed = _packedOwnershipAt(tid);
            if (packed != 0 && (packed & _BITMASK_BURNED) == 0) {
                uint256 basePrice = basePriceOf[tid];
                uint256 delta = basePrice >= 1 ether ? 0 : (1 ether - basePrice);
                
                // Budget check: Do we have funds to pay if this bond wins?
                if (budget < delta) break;
                
                bool win = _resolveBond(tid, rngWord);
                if (win) {
                    if (delta != 0) budget -= delta;
                    _markClaimable(tid, basePrice);
                } else {
                    budget += basePrice; // Losers return funds to the budget
                }
            }
            unchecked {
                ++tid;
                ++processed;
            }
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
        if (budgetWei == 0) revert InsufficientEthForResolve();
        if (ethPool <= 1 ether) revert InsufficientEthForResolve();

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
            unchecked { ++i; }
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
            unchecked { ++i; }
        }
        priceMultiplier = mult;

        uint64 day = uint64(block.timestamp / 1 days);
        uint64 newDelay = day + DECAY_DELAY_DAYS;
        if (newDelay > decayDelayUntilDay) {
            decayDelayUntilDay = newDelay;
        }
        lastDecayDay = day;
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
        ethPool = 0;
        stEthPool = 0;
        stEthAccounted = 0;
        bondPool = 0;
        bondCoin = 0;
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

    function _processPayment(uint256 amount, address recipient) private {
        uint256 gameCut = amount / 5; // 20% to game
        address gameAddr = game;
        if (gameAddr == address(0)) {
            rewardSeedEth += gameCut;
        } else {
            (bool gameOk, ) = payable(gameAddr).call{value: gameCut}("");
            if (!gameOk) revert CallFailed();
        }

        uint256 toCreator = amount - gameCut;
        (bool ok, ) = payable(recipient).call{value: toCreator}("");
        if (!ok) revert CallFailed();
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
            uint256 pricePer1000 = 0.025 ether;
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
        return
            transfersLocked ||
            (packed & _BITMASK_STAKED) != 0 ||
            _isResolved(tokenId) ||
            _inPendingWindow(tokenId);
    }

    function _ethHeadroom() private view returns (uint256) {
        uint256 owed = totalEthOwed;
        uint256 pool = ethPool;
        if (pool <= owed) return 0;
        return pool - owed;
    }

    function _stEthHeadroom() private view returns (uint256) {
        uint256 accounted = stEthAccounted;
        if (accounted <= stEthPool) return 0;
        return accounted - stEthPool;
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

    function _resolveBond(uint256 tokenId, uint256 rngWord) private returns (bool win) {
        uint256 basePrice = basePriceOf[tokenId];
        uint256 packed = _packedOwnershipOf(tokenId);
        uint256 weight = _coinWeightMultiplier(packed);
        uint16 chance;
        uint256 roll;
        
        (win, chance, roll) = bondOutcome(tokenId, rngWord);
        if (win) {
            // If not already claimed...
            if ((packed & _BITMASK_CLAIM_READY) == 0) {
                _packedOwnerships[tokenId] = packed | _BITMASK_CLAIM_READY;
                _clearApproval(tokenId);
                emit ClaimEnabled(tokenId);
                // Add missing obligation if we weren't fully funded
                if (basePrice < 1 ether) {
                    uint256 delta = 1 ether - basePrice;
                    totalEthOwed += delta;
                    totalCoinOwed += delta * weight;
                }
            }
        }
        // Losing bonds are handled in _burnInactiveUpTo
        emit BondResolved(tokenId, win, chance, roll);
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
                unchecked { ++processed; ++tid; }
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
                        unchecked { ++ownerBurns; }
                    }

                    emit BondBurned(tid);
                    emit Transfer(holder, address(0), tid);
                    unchecked { ++burned; }
                }
            }

            unchecked { ++processed; ++tid; }
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
        if (complete && burnedCount >= (_currentIndex - 1)) {
            stEthPool = 0; // Cleanup dust if supply is 0
        }
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
                unchecked { ++tid; }
                continue;
            }
            bool resolvedWinner = (prevOwnershipPacked & (_BITMASK_CLAIM_READY | _BITMASK_BURNED)) != 0;
            if (resolvedWinner) {
                unchecked { ++tid; }
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
                    unchecked { ++ownerBurns; }
                }

                emit BondBurned(tid);
                emit Transfer(holder, address(0), tid);
                unchecked { ++burned; }
            }
            unchecked { ++tid; }
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
        unchecked { ++burnedCount; }
        
        if (_tokenApprovals[tokenId] != address(0)) {
            _tokenApprovals[tokenId] = address(0);
        }
        _markBurned(tokenId, prevOwnershipPacked);
        emit Transfer(holder, address(0), tokenId);
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
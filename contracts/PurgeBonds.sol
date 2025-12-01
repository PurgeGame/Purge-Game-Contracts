// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

/// @notice PurgeBonds — a lightweight ERC721 used to beta test bond-like payouts for the game flows.
///         Supports public purchases with a caller-specified base, dynamic pricing, sequential claim gating,
///         and proportional ETH/stETH/coin bond pool distribution on claim.
contract PurgeBonds {
    /*
     * Contract overview (succinct lifecycle + accounting model)
     * - Minting: users buy ERC721 bonds with a chosen base (affects base price owed). Purchase price is
     *   derived from a dynamic multiplier; win odds are proportional to ETH paid (capped at 100%). Staked
     *   mints are non-transferable. Each mint tracks `createdDistance` for renderer context.
     * - Resolution: the owner/game feeds ETH/stETH/coin via `payBonds`, optionally scheduling RNG. Bonds
     *   resolve in id order; winners become claimable and their owed ETH/coin is topped to 1 ether equivalent.
     *   Losers are batch-burned when the resolve cursor advances, releasing obligations.
     * - Claiming: claimable bonds pay a fixed 1 stETH (or 1 ETH if no stETH is available) plus weighted PURGE
     *   from the bond pool; coin weights favor staked (unmarketable) bonds. Sequential gating prevents enabling
     *   later IDs before earlier ones, but any matured bond can be claimed in any order.
     * - Shutdown: `notifyGameOver` locks purchases/transfers; `finalizeShutdown` burns remaining unmatured
     *   bonds, and `sweepExpiredPools` clears any leftover assets after a long timeout.
     *
     * Key accounting invariants:
     * - `ethPool`/`stEthPool`/`bondPool` hold actual assets; `_ethHeadroom` and `_stEthHeadroom` expose
     *   withdrawable surplus (`pool - totalOwed`).
     * - `totalEthOwed` and `totalCoinOwed` mirror liabilities: base price added on mint, topped to 1 ether
     *   when a bond wins, and decremented when bonds burn or are claimed.
     * - `burnedCount` + `_currentIndex - 1` capture live supply; ERC721 state mirrors the ERC721A-style layout
     *   used by the main NFT contract.
     */
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error ZeroAddress();
    error InvalidToken();
    error CallFailed();
    error InvalidRisk();
    error WrongPrice();
    error NotClaimable();
    error AlreadyClaimed();
    error PurchasesClosed();
    error InsufficientCoinAvailable();
    error ResolvePendingAlready();
    error ResolveNotReady();
    error InsufficientEthForResolve();
    error InvalidRng();
    error InvalidQuantity();
    error InvalidBase();
    error InsufficientHeadroom();
    error TransferBlocked();
    error InvalidRate();
    error AlreadyConfigured();
    error GameOver();
    error ShutdownPendingResolution();
    error ExpiredSweepLocked();
    error InsufficientPayout();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
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

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------
    string public name;
    string public symbol;
    address public owner; // admin
    address public fundRecipient;
    address public stEthToken;
    address public coinToken;
    address public renderer;
    address public game;
    address public affiliateProgram;
    bool public decayPaused;
    // Pool balances vs obligations; headroom is `pool - total*Owed`.
    uint256 public bondCoin; // PURGE reserved for bond payouts
    uint256 public totalEthOwed; // Sum of ETH owed across all bonds
    uint256 public totalCoinOwed; // Weighted coin obligations (marketable bonds count at reduced weight)
    uint256 public rewardSeedEth; // Held ETH from unwired purchases to seed game reward pool
    bool public resolvePending;
    uint256 public pendingRngWord;
    uint48 public pendingRngDay;
    uint256 public pendingResolveBase;
    uint256 public pendingResolveMax;
    uint256 public pendingResolveBudget; // Amount of ETH/stETH-equivalent allocated for the pending resolve

    uint256 public priceMultiplier = 499e15; // dynamic price multiplier (1e18 = 1.0x), default 0.499x
    uint256 public salesAccumulator; // Tracks ETH priced volume toward the next multiplier bump
    uint64 public lastDecayDay;
    uint64 public decayDelayUntilDay;
    uint256 public ethPool;
    uint256 public stEthPool;
    uint256 public bondPool;
    bool public purchasesEnabled = true;
    bool public gameOver;
    uint256 public shutdownBurnCursor;
    uint256 public gameOverTimestamp;
    bool public allBondsBurned;

    uint256 private _currentIndex = 1;
    uint256 private nextClaimable = 1;
    uint256 private burnedCount;

    // ERC721A-style storage (aligned with PurgeGameNFT)
    mapping(uint256 => uint256) private _packedOwnerships;
    mapping(address => uint256) private _packedAddressData;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => uint256) public basePriceOf;
    mapping(uint256 => uint16) public winChanceBps; // per-thousand chance; capped at 1000
    mapping(uint256 => uint32) public createdDistance;

    // Resolution cursors and transfer controls.
    uint256 public lowestUnresolved;
    uint256 public resolveBaseId;
    bool public transfersLocked;
    uint64 public transfersLockedAt;
    uint16 public stakeRateBps = 10_000; // percent of reward+trophy pool to stake as stETH

    // ERC721A bit layout (mirrors PurgeGameNFT)
    uint256 private constant _BITMASK_ADDRESS_DATA_ENTRY = (1 << 64) - 1;
    uint256 private constant _BITPOS_NUMBER_MINTED = 64;
    uint256 private constant _BITPOS_NUMBER_BURNED = 128;
    uint256 private constant _BITPOS_START_TIMESTAMP = 160;
    uint256 private constant _BITMASK_BURNED = 1 << 224;
    uint256 private constant _BITMASK_NEXT_INITIALIZED = 1 << 225;
    uint256 private constant _BITPOS_STAKED = 232;
    uint256 private constant _BITMASK_STAKED = uint256(1) << _BITPOS_STAKED;
    uint256 private constant _BITPOS_CLAIM_READY = 233;
    uint256 private constant _BITMASK_CLAIM_READY = uint256(1) << _BITPOS_CLAIM_READY;
    uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;
    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint256 private constant _BURN_COUNT_INCREMENT_UNIT = uint256(1) << _BITPOS_NUMBER_BURNED;

    uint256 private stEthAccounted;

    uint256 private constant MULT_SCALE = 1e18;
    uint256 private constant DECAY_BPS = 9950; // 0.5% down daily
    uint256 private constant BPS_DENOM = 10_000;
    uint64 private constant DECAY_DELAY_DAYS = 7;
    uint256 private constant COIN_WEIGHT_UNMARKETABLE = 5; // Unmarketable (staked) bonds get full weight
    uint256 private constant COIN_WEIGHT_MARKETABLE = 1; // Marketable bonds get 20% of the coin payout
    uint256 private constant AFFILIATE_PRESALE_PRICE_PER_1000_WEI = 0.025 ether; // price per 1,000 coin during presale
    uint256 private constant MIN_BASE_PRICE = 0.02 ether; // Floor for base price and win chance
    uint256 private constant AUTO_RESOLVE_BATCH = 50; // bonds processed automatically per payBonds call
    uint256 private constant GAS_LIMITED_RESOLVE_MAX = 600; // ~15M gas cap at ~25k per bond
    uint256 private constant SALES_BUMP_NUMERATOR = 1005; // +0.5% per threshold
    uint256 private constant SALES_BUMP_DENOMINATOR = 1000;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrGame() {
        address sender = msg.sender;
        if (sender != owner && sender != game) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------------
    // Bond funding (replacement for burnie-style flows)
    // ---------------------------------------------------------------------

    /// @notice Accept ETH/stETH/coin inflows and resolve/burn bonds for the day using RNG.
    /// @param coinAmount Amount of coin credited alongside this call; 25% is added to the bondPool.
    /// @param stEthAddress Address of the stETH token used for accounting (must match configured stEthToken).
    /// @param rngDay Epoch day used to fetch RNG from the game contract during resolution (0 to skip scheduling).
    /// @param rngWord Randomness for this resolution window; takes precedence over rngDay when non-zero.
    /// @param baseId Optional starting token id for this resolution pass (0 = continue from prior cursor).
    /// @param maxBonds Max bonds to include in the pending window (0 = full window). Execution batches are capped separately.
    function payBonds(
        uint256 coinAmount,
        address stEthAddress,
        uint48 rngDay,
        uint256 rngWord,
        uint256 baseId,
        uint256 maxBonds
    ) external payable onlyOwnerOrGame {
        ethPool += msg.value;

        uint256 bondAdded;
        if (coinAmount != 0) {
            address coin = coinToken;
            if (coin == address(0)) revert ZeroAddress();
            if (msg.sender == game) {
                IPurgeCoinBondMinter(coin).bondPayment(address(this), coinAmount);
                bondAdded = coinAmount; // full credit when minted directly; onBondMint accounts it
            } else {
                IERC20Minimal(coin).transferFrom(msg.sender, address(this), coinAmount);
                bondAdded = coinAmount / 4; // 25%
                bondPool += bondAdded;
                bondCoin += bondAdded;
            }
        }

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

        uint256 budget = msg.value + stAdded;
        if ((rngWord != 0 || rngDay != 0) && ethPool > 1 ether && !resolvePending && budget != 0) {
            uint256 startId = _resolveStart(baseId);
            if (startId != 0) {
                _scheduleResolve(startId, rngDay, rngWord, maxBonds, budget);
            }
        }

        emit BondsPaid(msg.value, stAdded, bondAdded);

        if (resolvePending) {
            bool ready;
            uint256 word = pendingRngWord;
            uint48 day = pendingRngDay;
            if (word != 0) {
                ready = true;
            } else if (day != 0 && game != address(0)) {
                uint256 fetched = IPurgeGameLike(game).rngWordForDay(day);
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

    /// @notice Force resolution using a provided RNG word after a timeout when VRF is unavailable.
    function forceResolveWithFallback(uint256 rngWord, uint256 maxBonds) external {
        if (!resolvePending) revert ResolveNotReady();
        if (rngWord == 0) revert InvalidRng();
        uint64 lockedAt = transfersLockedAt;
        if (lockedAt == 0 || block.timestamp <= lockedAt + 2 days) revert ResolveNotReady();
        pendingRngWord = rngWord;
        _resolvePendingInternal(_resolveLimit(maxBonds), true);
    }

    /// @notice Resolve pending bonds using the stored RNG; callable by anyone when pending.
    function resolvePendingBonds(uint256 maxBonds) external {
        _resolvePendingInternal(_resolveLimit(maxBonds), true);
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
        lowestUnresolved = 1;
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    /// @notice Purchase bonds using a desired base pool amount (<= 1 ETH) and quantity; stake=true mints non-transferable.
    /// @dev Caller must send the exact aggregate price for the derived base across all mints.
    function buy(uint256 baseWei, uint256 quantity, bool stake, bytes32 affiliateCode) external payable {
        address recipient = fundRecipient;
        if (recipient == address(0)) revert ZeroAddress();
        if (!purchasesEnabled) revert PurchasesClosed();
        if (resolvePending) revert ResolvePendingAlready();
        if (quantity == 0) revert InvalidQuantity();
        if (baseWei == 0 || baseWei > 1 ether) revert InvalidBase();

        _syncMultiplier();

        uint256 basePerBond = baseWei / quantity;
        if (basePerBond > 0.5 ether) {
            basePerBond = 0.5 ether;
        }
        if (basePerBond < MIN_BASE_PRICE) revert InvalidBase();

        _applyAffiliateCode(msg.sender, affiliateCode, msg.value);
        uint256 price = (basePerBond * priceMultiplier) / MULT_SCALE;
        uint256 totalPrice = price * quantity;
        if (price == 0 || totalPrice / quantity != price || msg.value != totalPrice) revert WrongPrice();

        _mintBatch(msg.sender, quantity, basePerBond, price, stake);

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
        if (quantity == 0) revert InvalidQuantity();

        startTokenId = _currentIndex;
        _currentIndex = startTokenId + quantity;

        // Initialize ownership slot and per-address packed data (ERC721A-style).
        uint256 stakedFlag = stake ? _BITMASK_STAKED : 0;
        _packedOwnerships[startTokenId] = _packOwnershipData(
            to,
            (quantity == 1 ? _BITMASK_NEXT_INITIALIZED : 0) | stakedFlag
        );

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

        uint256 weight = stake ? COIN_WEIGHT_UNMARKETABLE : COIN_WEIGHT_MARKETABLE;
        totalEthOwed += basePrice * quantity;
        totalCoinOwed += basePrice * weight * quantity;
        uint16 chance = uint16((basePrice * 1000) / 1 ether);
        if (chance == 0) chance = 1;
        if (chance > 1000) chance = 1000;

        uint256 tokenId = startTokenId;
        uint256 end = startTokenId + quantity;
        uint256 toMasked = uint256(uint160(to)) & _BITMASK_ADDRESS;
        do {
            basePriceOf[tokenId] = basePrice;
            createdDistance[tokenId] = uint32(_currentDistance(tokenId));
            winChanceBps[tokenId] = chance;

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

    // ---------------------------------------------------------------------
    // Admin config
    // ---------------------------------------------------------------------

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setFundRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        fundRecipient = newRecipient;
    }

    /// @notice Wire coin/game/affiliate using a single entrypoint.
    /// @dev Order: [coin token, game, affiliate]; each slot may be set once (subsequent different values revert).
    function wire(address[] calldata addresses) external onlyOwner {
        _setCoinToken(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setAffiliate(addresses.length > 2 ? addresses[2] : address(0));
    }

    /// @notice Permanently enter shutdown mode after the game triggers its liveness drain.
    function notifyGameOver() external onlyOwnerOrGame {
        if (!gameOver) {
            gameOver = true;
            purchasesEnabled = false;
            decayPaused = true;
            transfersLocked = true;
            transfersLockedAt = uint64(block.timestamp);
            gameOverTimestamp = block.timestamp;
        } else if (gameOverTimestamp == 0) {
            // Backfill timestamp if it was missing for some reason.
            gameOverTimestamp = block.timestamp;
        }

        if (shutdownBurnCursor == 0) {
            uint256 cursor = lowestUnresolved;
            if (cursor == 0) {
                cursor = 1;
            }
            shutdownBurnCursor = cursor;
        }

        emit GameShutdown(shutdownBurnCursor);
    }

    /// @notice Send ETH, stETH, or PURGE to `to`, only from balances not earmarked for bonds.
    /// @param token Pass address(0) for ETH, stEthToken for stETH, or coinToken for PURGE.
    /// @param to Recipient address.
    /// @param amount Amount to send (0 = sweep available headroom for ETH/stETH, full available for coin).
    function sendAsset(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            uint256 headroom = _ethHeadroom();
            if (amount == 0) {
                amount = headroom;
            }
            if (amount == 0 || amount > headroom) revert InsufficientHeadroom();
            ethPool -= amount;
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert CallFailed();
            return;
        }
        if (token == stEthToken) {
            uint256 headroom = _stEthHeadroom();
            if (amount == 0) {
                amount = headroom;
            }
            if (amount == 0 || amount > headroom) revert InsufficientHeadroom();
            stEthAccounted -= amount;
            IERC20Minimal(token).transfer(to, amount);
            return;
        }
        if (token != coinToken) revert InvalidToken();
        uint256 bal = IERC20Minimal(token).balanceOf(address(this));
        uint256 reserved = bondCoin;
        uint256 available = bal > reserved ? bal - reserved : 0;
        if (amount == 0) {
            amount = available;
        }
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
        if (rateBps < 2500 || rateBps > 15_000) revert InvalidRate(); // 25% - 150%
        stakeRateBps = rateBps;
    }

    /// @notice One year after game end, sweep all ETH/stETH/coin held by the bond contract and delete remaining bonds.
    /// @dev Coin sweep zeroes bondCoin/bondPool/totalCoinOwed so subsequent claims no longer expect coin.
    function sweepExpiredPools(
        address to
    ) external onlyOwner returns (uint256 ethOut, uint256 stEthOut, uint256 coinOut) {
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

        // After funds are swept, permanently delete all bonds.
        _burnAllBonds();
    }

    /// @notice After shutdown, burn remaining unmatured bonds to release excess ETH/stETH.
    /// @param maxIds Max token ids to scan in this call (0 = default chunk).
    /// @return processedIds Count of token ids processed.
    /// @return burned Count of bonds burned.
    /// @return complete True if no ids remain to scan.
    function finalizeShutdown(
        uint256 maxIds
    ) external onlyOwnerOrGame returns (uint256 processedIds, uint256 burned, bool complete) {
        if (!gameOver) revert GameOver();
        if (resolvePending || pendingRngDay != 0 || pendingRngWord != 0) revert ShutdownPendingResolution();
        (processedIds, burned, complete) = _burnUnmaturedFromCursor(maxIds);
        emit ShutdownBurned(processedIds, burned, complete);
    }

    /// @notice Hook from the PURGE token to credit freshly minted bond payouts.
    function onBondMint(uint256 amount) external {
        if (msg.sender != coinToken) revert Unauthorized();
        if (amount == 0) return;
        uint256 newBondCoin = bondCoin + amount;
        bondCoin = newBondCoin;
        bondPool += amount;
    }

    // ---------------------------------------------------------------------
    // Claim flow
    // ---------------------------------------------------------------------

    /// @notice Claim bond proceeds for a ready token. Callable by owner or approved address.
    function claim(uint256 tokenId, address to) external {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed & _BITMASK_BURNED != 0) revert AlreadyClaimed();
        if ((packed & _BITMASK_CLAIM_READY) == 0) revert NotClaimable();

        if (_currentIndex <= 1) revert InvalidToken();

        address holder = _requireActiveToken(tokenId);
        _burnToken(tokenId, holder);

        uint256 bondShare;
        uint256 coinWeight = _coinClaimWeight(packed);
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * coinWeight) / coinOwed;
        }

        uint256 ethPaid;
        uint256 stEthPaid;
        address stToken = stEthToken;
        // Prefer paying 1 stETH; fall back to 1 ETH when stETH is unavailable.
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

        totalEthOwed -= 1 ether;
        _decreaseTotalCoinOwed(coinWeight);
        emit Claimed(to, tokenId, ethPaid, stEthPaid, bondShare);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function _isInactive(uint256 tokenId) private view returns (bool) {
        if (allBondsBurned) return true;
        uint256 floor = lowestUnresolved;
        if (floor == 0) {
            floor = 1;
        }
        if (tokenId < floor) {
            uint256 packed = _packedOwnershipAt(tokenId);
            if (packed == 0) return true;
            if ((packed & _BITMASK_BURNED) != 0) return true;
            return (packed & _BITMASK_CLAIM_READY) == 0;
        }
        return false;
    }

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

    /// @notice View a single-claim payout snapshot given current pools (marketable weight for coin share).
    /// @dev stETH is preferred; ETH is shown only when stETH is unavailable.
    function pendingShares() external view returns (uint256 ethShare, uint256 stEthShare, uint256 bondShare) {
        if (_currentIndex <= 1) return (0, 0, 0);
        if (stEthPool >= 1 ether) {
            stEthShare = 1 ether;
        } else if (ethPool >= 1 ether) {
            ethShare = 1 ether;
        }
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * (COIN_WEIGHT_MARKETABLE * 1 ether)) / coinOwed;
        }
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
        address renderer_ = renderer;
        if (renderer_ == address(0)) revert ZeroAddress();
        uint32 created = createdDistance[tokenId];
        uint32 current = uint32(_currentDistance(tokenId));
        uint16 chance = winChanceBps[tokenId];
        if (chance == 0) {
            chance = 1;
        }
        bool isStaked = (_packedOwnershipOf(tokenId) & _BITMASK_STAKED) != 0;
        return IPurgeBondRenderer(renderer_).bondTokenURI(tokenId, created, current, chance, isStaked);
    }

    function currentPrice(uint256 baseWei) external view returns (uint256) {
        if (baseWei < MIN_BASE_PRICE) return 0;
        if (baseWei > 0.5 ether) baseWei = 0.5 ether;
        return (baseWei * _multiplierWithDecay()) / MULT_SCALE;
    }

    // ---------------------------------------------------------------------
    // Approvals
    // ---------------------------------------------------------------------

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

    // ---------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------

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

        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        uint256 fromData = _packedAddressData[from];
        uint256 toData = _packedAddressData[to];

        unchecked {
            _packedAddressData[from] = (fromData & ~_BITMASK_ADDRESS_DATA_ENTRY) | ((fromData & _BITMASK_ADDRESS_DATA_ENTRY) - 1);
            _packedAddressData[to] = (toData & ~_BITMASK_ADDRESS_DATA_ENTRY) | ((toData & _BITMASK_ADDRESS_DATA_ENTRY) + 1);

            _packedOwnerships[tokenId] = _packOwnershipData(to, _BITMASK_NEXT_INITIALIZED);

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

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

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
        if (_isInactive(tokenId)) return false;
        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed == 0 || (packed & _BITMASK_BURNED) != 0) return false;
        return address(uint160(packed)) != address(0);
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
        if (floor == 0) {
            floor = 1;
        }
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
        // Walk the pending range, marking winners claimable and accruing any extra ETH/coin owed to them.
        // The `budget` guard is purely to cap how many wins we can fund in this pass; it is not persisted
        // after resolution and does not move `ethPool` directly.
        uint256 processed;
        while (processed < limit && tid <= maxId) {
            uint256 packed = _packedOwnershipAt(tid);
            if (packed != 0 && (packed & _BITMASK_BURNED) == 0) {
                uint256 basePrice = basePriceOf[tid];
                uint256 delta = basePrice >= 1 ether ? 0 : (1 ether - basePrice);
                if (budget < delta) {
                    break;
                }
                bool win = _resolveBond(tid, rngWord);
                if (win) {
                    if (delta != 0) budget -= delta;
                    _markClaimable(tid, basePrice);
                } else {
                    budget += basePrice;
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
        if (limit > GAS_LIMITED_RESOLVE_MAX) {
            limit = GAS_LIMITED_RESOLVE_MAX;
        }
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
        if (deltaDays > 3650) {
            deltaDays = 3650; // safety cap to keep loops bounded
        }
        for (uint256 i; i < deltaDays; ) {
            mult = (mult * DECAY_BPS) / BPS_DENOM;
            unchecked {
                ++i;
            }
        }
        // Floor at 9.9x (9.9e18).
        if (mult < 99e17) return 99e17;
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
        uint256 gameCut = amount / 5; // 20% to game fund
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
        if (coinBase == 0) {
            usedFallbackPrice = true;
            uint256 pricePer1000 = AFFILIATE_PRESALE_PRICE_PER_1000_WEI;
            coinBase = (weiSpent * 1000 * 1e6) / pricePer1000; // convert to 6-decimal coin base units
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

    /// @notice Purely algorithmic bond outcome using RNG + token data; no state writes.
    function bondOutcome(
        uint256 tokenId,
        uint256 rngWord
    ) public view returns (bool win, uint16 chanceBps, uint256 roll) {
        _requireActiveToken(tokenId);
        chanceBps = winChanceBps[tokenId];
        if (chanceBps == 0) {
            chanceBps = 1; // minimal non-zero chance if none recorded
        }
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
            if ((packed & _BITMASK_CLAIM_READY) == 0) {
                _packedOwnerships[tokenId] = packed | _BITMASK_CLAIM_READY;
                _clearApproval(tokenId);
                emit ClaimEnabled(tokenId);
                if (basePrice < 1 ether) {
                    uint256 delta = 1 ether - basePrice;
                    totalEthOwed += delta;
                    totalCoinOwed += delta * weight;
                }
            }
        } else {
            // Losing bonds are accounted and burned in batch when the resolve cursor advances.
        }
        emit BondResolved(tokenId, win, chance, roll);
    }

    function _burnUnmaturedFromCursor(
        uint256 maxIds
    ) private returns (uint256 processed, uint256 burned, bool complete) {
        uint256 tid = shutdownBurnCursor;
        if (tid == 0) {
            tid = lowestUnresolved;
            if (tid == 0) {
                tid = 1;
            }
        }

        uint256 maxId = _currentIndex - 1;
        if (maxId == 0 || tid > maxId) {
            shutdownBurnCursor = tid;
            return (0, 0, true);
        }

        uint256 limit = maxIds == 0 ? 500 : maxIds;
        address ownerCursor;
        uint256 ownerBurns;

        // Sweep forward from the shutdown cursor, retiring any bonds that never matured.
        while (processed < limit && tid <= maxId) {
            uint256 prevOwnershipPacked = _packedOwnershipAt(tid);
            if (prevOwnershipPacked == 0) {
                unchecked {
                    ++processed;
                    ++tid;
                }
                continue;
            }
            if ((prevOwnershipPacked & (_BITMASK_CLAIM_READY | _BITMASK_BURNED)) == 0) {
                address holder = address(uint160(prevOwnershipPacked));
                if (holder != address(0)) {
                    uint256 basePrice = basePriceOf[tid];
                    totalEthOwed -= basePrice;
                    _decreaseTotalCoinOwed(basePrice * _coinWeightMultiplier(prevOwnershipPacked));

                    _markBurned(tid, prevOwnershipPacked);

                    address approved = _tokenApprovals[tid];
                    if (approved != address(0)) {
                        _tokenApprovals[tid] = address(0);
                    }

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
        if (nextClaimable < tid) {
            nextClaimable = tid;
        }
        if (tid > lowestUnresolved) {
            lowestUnresolved = tid;
        }
        complete = tid > maxId;
        if (complete) {
            uint256 minted = _currentIndex - 1;
            if (burnedCount >= minted) {
                stEthPool = 0;
            }
        }
    }

    function _burnInactiveUpTo(uint256 targetId) private {
        uint256 tid = lowestUnresolved;
        if (tid == 0) {
            tid = 1;
        }
        if (targetId < tid) return;

        uint256 burned;
        address ownerCursor;
        uint256 ownerBurns;

        // Retire losing/unresolved bonds behind the active cursor once a resolution window has passed them.
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

                address approved = _tokenApprovals[tid];
                if (approved != address(0)) {
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
        address approved = _tokenApprovals[tokenId];
        if (approved != address(0)) {
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

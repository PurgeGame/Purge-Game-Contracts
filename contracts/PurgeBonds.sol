// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
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

/// @notice PurgeBonds — a lightweight ERC721 used to beta test bond-like payouts for the creator flows.
///         Supports public purchases with a user-supplied risk, dynamic pricing, sequential claim gating,
///         and proportional ETH/stETH/coin bond pool distribution on claim.
contract PurgeBonds {
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
    error Reentrancy();
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

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Purchased(address indexed buyer, uint256 indexed tokenId, uint8 risk, uint256 price);
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
    address public owner; // creator contract / admin
    address public fundRecipient;
    address public stEthToken;
    address public coinToken;
    address public renderer;
    address public game;
    bool public decayPaused;
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

    uint256 public priceMultiplier = 49_9e16; // dynamic price multiplier (1e18 = 1.0x), default 49.9x
    uint64 public lastDecayDay;
    uint64 public decayDelayUntilDay;
    uint256 public ethPool;
    uint256 public stEthPool;
    uint256 public bondPool;
    bool public purchasesEnabled = true;
    bool public gameOver;
    uint256 public shutdownBurnCursor;

    uint256 private nextId = 1;
    uint256 private nextClaimable = 1;
    uint256 private burnedCount;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(address => uint256) private _burnedBalance;
    mapping(uint256 => address) private _tokenApproval;
    mapping(address => mapping(address => bool)) private _operatorApproval;
    mapping(uint256 => uint8) public riskOf;
    mapping(uint256 => bool) public claimReady;
    mapping(uint256 => bool) public claimed;
    mapping(uint256 => uint16) public winChanceBps; // basis points; capped at 10000
    mapping(uint256 => bool) public staked;
    mapping(uint256 => uint32) public createdDistance;

    uint256 public lowestUnresolved;
    uint256 public resolveBaseId;
    bool public transfersLocked;
    uint64 public transfersLockedAt;
    uint16 public stakeRateBps = 10_000; // percent of reward+trophy pool to stake as stETH

    bool private entered;
    uint256 private stEthAccounted;

    uint256 private constant MULT_SCALE = 1e18;
    uint256 private constant DECAY_BPS = 9950; // 0.5% down daily
    uint256 private constant BPS_DENOM = 10_000;
    uint64 private constant DECAY_DELAY_DAYS = 7;
    uint8 private constant MAX_RISK = 59; // Keeps 1 ether >> risk non-zero
    uint256 private constant COIN_WEIGHT_UNMARKETABLE = 5; // Unmarketable (staked) bonds get full weight
    uint256 private constant COIN_WEIGHT_MARKETABLE = 1; // Marketable bonds get 20% of the coin payout

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
    /// @param maxBonds Max bonds to resolve in this call (0 = default 25).
    function payBonds(
        uint256 coinAmount,
        address stEthAddress,
        uint48 rngDay,
        uint256 rngWord,
        uint256 baseId,
        uint256 maxBonds
    ) external payable onlyOwnerOrGame nonReentrant {
        ethPool += msg.value;

        uint256 bondAdded;
        if (coinAmount != 0) {
            address coin = coinToken;
            if (coin == address(0)) revert ZeroAddress();
            if (msg.sender == game) {
                IPurgeCoinBondMinter(coin).bondPayment(address(this), coinAmount);
                bondAdded = coinAmount; // full credit when minted directly; onBondMint accounts it
            } else {
                if (!IERC20Minimal(coin).transferFrom(msg.sender, address(this), coinAmount)) revert CallFailed();
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
                _resolvePendingInternal(maxBonds, false);
            }
        }
    }

    /// @notice Schedule bond resolution using a provided RNG word without executing it.
    function scheduleResolve(
        uint48 rngDay,
        uint256 rngWord,
        uint256 baseId,
        uint256 maxBonds,
        uint256 budgetWei
    ) external {
        address sender = msg.sender;
        if (sender != owner && sender != game) revert Unauthorized();
        uint256 startId = _resolveStart(baseId);
        _scheduleResolve(startId, rngDay, rngWord, maxBonds, budgetWei);
    }

    /// @notice Force resolution using a provided RNG word after a timeout when VRF is unavailable.
    function forceResolveWithFallback(uint256 rngWord, uint256 maxBonds) external onlyOwnerOrGame {
        if (!resolvePending) revert ResolveNotReady();
        if (rngWord == 0) revert InvalidRng();
        uint64 lockedAt = transfersLockedAt;
        if (lockedAt == 0 || block.timestamp <= lockedAt + 2 days) revert ResolveNotReady();
        pendingRngWord = rngWord;
        _resolvePendingInternal(maxBonds, true);
    }

    /// @notice Resolve pending bonds using the stored RNG; callable by anyone when pending.
    function resolvePendingBonds(uint256 maxBonds) external nonReentrant {
        _resolvePendingInternal(maxBonds, true);
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
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

    function buy(uint8 risk) external payable nonReentrant returns (uint256 tokenId) {
        tokenId = _buy(risk, false);
    }

    /// @notice Purchase a bond and permanently stake it (non-transferable).
    function buyStaked(uint8 risk) external payable nonReentrant returns (uint256 tokenId) {
        tokenId = _buy(risk, true);
    }

    /// @notice Purchase multiple bonds using a desired base pool amount (<= 1 ETH) and quantity.
    /// @dev Base-per-bond is `min(baseWei / quantity, 0.5 ether)`; risk is derived from that base.
    ///      Caller must send the exact aggregate price for the derived risk across all mints.
    function buyWithBase(
        uint256 baseWei,
        uint256 quantity
    ) external payable nonReentrant returns (uint256 firstTokenId) {
        firstTokenId = _buyWithBase(baseWei, quantity, false);
    }

    /// @notice Same as buyWithBase but permanently stakes the minted bonds (non-transferable).
    function buyStakedWithBase(
        uint256 baseWei,
        uint256 quantity
    ) external payable nonReentrant returns (uint256 firstTokenId) {
        firstTokenId = _buyWithBase(baseWei, quantity, true);
    }

    function _buy(uint8 risk, bool stake) private returns (uint256 tokenId) {
        address recipient = fundRecipient;
        if (recipient == address(0)) revert ZeroAddress();
        if (!purchasesEnabled) revert PurchasesClosed();
        _guardPurchases();

        _syncMultiplier();
        uint256 price = _priceForRisk(risk);
        if (msg.value != price) revert WrongPrice();

        _processPayment(msg.value, recipient);

        tokenId = _mint(msg.sender, risk, price, stake);
        emit Purchased(msg.sender, tokenId, risk, price);

        _bumpMultiplier(msg.value);
    }

    function _buyWithBase(uint256 baseWei, uint256 quantity, bool stake) private returns (uint256 firstTokenId) {
        address recipient = fundRecipient;
        if (recipient == address(0)) revert ZeroAddress();
        if (!purchasesEnabled) revert PurchasesClosed();
        _guardPurchases();
        if (quantity == 0) revert InvalidQuantity();
        if (baseWei == 0 || baseWei > 1 ether) revert InvalidBase();

        _syncMultiplier();

        uint256 basePerBond = baseWei / quantity;
        if (basePerBond == 0) revert InvalidBase();
        if (basePerBond > 0.5 ether) {
            basePerBond = 0.5 ether;
        }
        uint8 risk = _riskForBase(basePerBond);

        uint256 remaining = msg.value;
        for (uint256 i; i < quantity; ) {
            uint256 price = _priceForRisk(risk);
            if (price == 0 || remaining < price) revert WrongPrice();
            remaining -= price;

            uint256 mintedId = _mint(msg.sender, risk, price, stake);
            if (firstTokenId == 0) {
                firstTokenId = mintedId;
            }
            emit Purchased(msg.sender, mintedId, risk, price);

            _bumpMultiplier(price);
            unchecked {
                ++i;
            }
        }
        if (remaining != 0) revert WrongPrice();

        _processPayment(msg.value, recipient);
    }

    /// @notice Backdoor mint for the owner (creator contract) to manually mint without payment if needed.
    function mintTo(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = _mint(to, 0, 0, false);
    }

    function _mint(address to, uint8 risk, uint256 paidWei, bool stake) private returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (risk > MAX_RISK) revert InvalidRisk();

        tokenId = nextId++;
        _ownerOf[tokenId] = to;
        _balanceOf[to] += 1;
        riskOf[tokenId] = risk;
        if (stake) {
            staked[tokenId] = true;
        }
        createdDistance[tokenId] = uint32(_currentDistance(tokenId));
        uint256 basePrice = _basePrice(risk);
        totalEthOwed += basePrice;
        totalCoinOwed += basePrice * _coinWeightMultiplier(tokenId);

        // Store win chance based on payment size (capped at 100%).
        if (paidWei != 0) {
            uint256 chance = (paidWei * 10_000) / 1 ether;
            if (chance > 10_000) chance = 10_000;
            winChanceBps[tokenId] = uint16(chance);
        }

        emit Transfer(address(0), to, tokenId);

        if (to.code.length != 0) {
            if (!_checkOnERC721Received(msg.sender, address(0), to, tokenId, "")) revert CallFailed();
        }
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

    function setStEthToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        stEthToken = token;
    }

    function setCoinToken(address token) external onlyOwner {
        _setCoinToken(token);
    }

    function setGame(address game_) external onlyOwner {
        _setGame(game_);
    }

    /// @notice Wire the coin and game contracts once post-deploy.
    function wireContracts(address coinToken_, address game_) external onlyOwner {
        _setCoinToken(coinToken_);
        _setGame(game_);
    }

    /// @notice Permanently enter shutdown mode after the game triggers its liveness drain.
    function notifyGameOver() external onlyOwnerOrGame {
        if (!gameOver) {
            gameOver = true;
            purchasesEnabled = false;
            decayPaused = true;
            transfersLocked = true;
            transfersLockedAt = uint64(block.timestamp);
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

    /// @notice Send PURGE held by this contract, excluding the reserved bondCoin balance.
    function sendCoin(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        address coin = coinToken;
        if (coin == address(0)) revert ZeroAddress();

        uint256 bal = IERC20Minimal(coin).balanceOf(address(this));
        uint256 reserved = bondCoin;
        uint256 available = bal > reserved ? bal - reserved : 0;
        if (amount > available) revert InsufficientCoinAvailable();

        if (!IERC20Minimal(coin).transfer(to, amount)) revert CallFailed();
    }

    /// @notice Withdraw ETH that exceeds total outstanding obligations.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw (0 = sweep all headroom).
    function sweepExcessEth(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 headroom = _ethHeadroom();
        if (amount == 0) {
            amount = headroom;
        }
        if (amount == 0 || amount > headroom) revert InsufficientHeadroom();
        ethPool -= amount;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert CallFailed();
    }

    /// @notice Withdraw stETH that exceeds the accounted pool for bond obligations.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw (0 = sweep all headroom).
    function sweepExcessStEth(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 headroom = _stEthHeadroom();
        if (amount == 0) {
            amount = headroom;
        }
        if (amount == 0 || amount > headroom) revert InsufficientHeadroom();
        stEthAccounted -= amount;
        address stToken = stEthToken;
        if (stToken == address(0)) revert ZeroAddress();
        if (!IERC20Minimal(stToken).transfer(to, amount)) revert CallFailed();
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
        if (IERC20Minimal(coinToken).balanceOf(address(this)) < newBondCoin) revert InsufficientCoinAvailable();
        bondCoin = newBondCoin;
        bondPool += amount;
    }

    // ---------------------------------------------------------------------
    // Claim flow
    // ---------------------------------------------------------------------

    /// @notice Mark the next `count` tokens (in purchase order) claimable.
    /// @dev Claims are strictly sequential; attempting to enable past minted supply is ignored.
    function enableClaims(uint256 count) external onlyOwner returns (uint256 enabled) {
        uint256 tid = nextClaimable;
        uint256 maxId = nextId - 1;
        while (enabled < count && tid <= maxId) {
            if (claimed[tid]) {
                unchecked {
                    ++tid;
                }
                continue;
            }
            if (!claimReady[tid]) {
                claimReady[tid] = true;
                _clearApproval(tid);
                uint256 basePrice = _basePrice(riskOf[tid]);
                if (basePrice < 1 ether) {
                    uint256 delta = 1 ether - basePrice;
                    totalEthOwed += delta;
                    totalCoinOwed += delta * _coinWeightMultiplier(tid);
                }
                emit ClaimEnabled(tid);
                ++enabled;
            }
            unchecked {
                ++tid;
            }
        }
        nextClaimable = tid;
    }

    /// @notice Claim bond proceeds for a ready token. Callable by owner or approved address.
    function claim(uint256 tokenId, address to) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        if (!claimReady[tokenId]) revert NotClaimable();
        if (claimed[tokenId]) revert AlreadyClaimed();
        claimed[tokenId] = true;

        uint256 supply = nextId - 1;
        if (supply == 0) revert InvalidToken();

        address holder = _ownerOf[tokenId];
        _burnToken(tokenId, holder);

        uint256 ethShare = ethPool / supply;
        uint256 stShare = stEthPool / supply;
        uint256 bondShare;
        uint256 coinWeight = _coinClaimWeight(tokenId);
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * coinWeight) / coinOwed;
        }

        if (ethShare != 0) {
            ethPool -= ethShare;
            (bool ok, ) = payable(to).call{value: ethShare}("");
            if (!ok) revert CallFailed();
        }

        if (stShare != 0) {
            address stToken = stEthToken;
            if (stToken == address(0)) revert ZeroAddress();
            stEthPool -= stShare;
            if (!IERC20Minimal(stToken).transfer(to, stShare)) revert CallFailed();
            if (stEthAccounted >= stShare) {
                stEthAccounted -= stShare;
            } else {
                stEthAccounted = 0;
            }
        }

        if (bondShare != 0) {
            if (bondPool >= bondShare) {
                bondPool -= bondShare;
            } else {
                bondPool = 0;
            }
            bondCoin -= bondShare;
            if (coinToken == address(0)) revert ZeroAddress();
            if (!IERC20Minimal(coinToken).transfer(to, bondShare)) revert CallFailed();
        }

        totalEthOwed -= 1 ether;
        totalCoinOwed -= coinWeight;
        emit Claimed(to, tokenId, ethShare, stShare, bondShare);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function _isInactive(uint256 tokenId) private view returns (bool) {
        uint256 floor = lowestUnresolved;
        if (floor == 0) {
            floor = 1;
        }
        return tokenId < floor && !claimReady[tokenId];
    }

    function _exists(uint256 tokenId) private view returns (bool) {
        if (tokenId == 0 || tokenId >= nextId) return false;
        if (claimed[tokenId]) return false;
        if (_isInactive(tokenId)) return false;
        return _ownerOf[tokenId] != address(0);
    }

    function _requireActiveToken(uint256 tokenId) private view returns (address holder) {
        if (!_exists(tokenId)) revert InvalidToken();
        holder = _ownerOf[tokenId];
    }

    function balanceOf(address account) public view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        uint256 owned = _balanceOf[account];
        uint256 burned = _burnedBalance[account];
        if (burned >= owned) return 0;
        unchecked {
            return owned - burned;
        }
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _requireActiveToken(tokenId);
    }

    function totalSupply() external view returns (uint256) {
        uint256 minted = nextId - 1;
        if (burnedCount > minted) return 0;
        return minted - burnedCount;
    }

    function pendingShares() external view returns (uint256 ethShare, uint256 stEthShare, uint256 bondShare) {
        uint256 supply = nextId - 1;
        if (burnedCount < supply) {
            unchecked {
                supply -= burnedCount;
            }
        } else {
            supply = 0;
        }
        if (supply == 0) return (0, 0, 0);
        ethShare = ethPool / supply;
        stEthShare = stEthPool / supply;
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * (COIN_WEIGHT_MARKETABLE * 1 ether)) / coinOwed;
        }
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        _requireActiveToken(tokenId);
        return _tokenApproval[tokenId];
    }

    function isApprovedForAll(address holder, address operator) public view returns (bool) {
        return _operatorApproval[holder][operator];
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
        bool isStaked = staked[tokenId];
        return IPurgeBondRenderer(renderer_).bondTokenURI(tokenId, created, current, chance, isStaked);
    }

    function currentPrice(uint8 risk) external view returns (uint256) {
        return _priceForRiskWithMultiplier(risk, _multiplierWithDecay());
    }

    // ---------------------------------------------------------------------
    // Approvals
    // ---------------------------------------------------------------------

    function approve(address spender, uint256 tokenId) external {
        address holder = ownerOf(tokenId);
        if (_transfersBlocked(tokenId)) revert TransferBlocked();
        if (msg.sender != holder && !isApprovedForAll(holder, msg.sender)) revert Unauthorized();
        _tokenApproval[tokenId] = spender;
        emit Approval(holder, spender, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApproval[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    // ---------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------

    function transferFrom(address from, address to, uint256 tokenId) public {
        address holder = ownerOf(tokenId);
        if (holder != from) revert Unauthorized();
        if (_transfersBlocked(tokenId)) revert TransferBlocked();
        if (msg.sender != holder && msg.sender != _tokenApproval[tokenId] && !isApprovedForAll(holder, msg.sender))
            revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();

        _tokenApproval[tokenId] = address(0);
        _ownerOf[tokenId] = to;
        unchecked {
            _balanceOf[from] -= 1;
            _balanceOf[to] += 1;
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

    function _isApprovedOrOwner(address spender, uint256 tokenId) private view returns (bool) {
        address holder = _requireActiveToken(tokenId);
        return (spender == holder || _tokenApproval[tokenId] == spender || _operatorApproval[holder][spender]);
    }

    function _coinWeightMultiplier(uint256 tokenId) private view returns (uint256) {
        return staked[tokenId] ? COIN_WEIGHT_UNMARKETABLE : COIN_WEIGHT_MARKETABLE;
    }

    function _coinClaimWeight(uint256 tokenId) private view returns (uint256) {
        return _coinWeightMultiplier(tokenId) * 1 ether;
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
        uint256 maxId = pendingResolveMax == 0 ? nextId - 1 : pendingResolveMax;
        uint256 limit = maxBonds == 0 ? 25 : maxBonds;
        uint256 budget = pendingResolveBudget;
        if (budget == 0) revert InsufficientEthForResolve();
        uint256 processed;
        while (processed < limit && tid <= maxId) {
            if (!claimed[tid]) {
                uint256 basePrice = _basePrice(riskOf[tid]);
                uint256 delta = basePrice >= 1 ether ? 0 : (1 ether - basePrice);
                if (budget < delta) {
                    break;
                }
                bool win = _resolveBond(tid, rngWord);
                if (win) {
                    if (delta != 0) budget -= delta;
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

    function _clearApproval(uint256 tokenId) private {
        address approved = _tokenApproval[tokenId];
        if (approved != address(0)) {
            _tokenApproval[tokenId] = address(0);
            address holder = _ownerOf[tokenId];
            if (holder != address(0)) {
                emit Approval(holder, address(0), tokenId);
            }
        }
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

        uint256 maxId = nextId - 1;
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

    function _bumpMultiplier(uint256 paidWei) private {
        if (paidWei == 0) return;
        // +1% per ETH of purchases (pro-rata for partial ETH).
        // delta = multiplier * paidWei / (100 * 1e18)
        uint256 delta = (priceMultiplier * paidWei) / (100 * 1 ether);
        priceMultiplier += delta;

        uint64 day = uint64(block.timestamp / 1 days);
        uint64 newDelay = day + DECAY_DELAY_DAYS;
        // Enforce a one-week holding period before the new rate begins decaying again.
        if (newDelay > decayDelayUntilDay) {
            decayDelayUntilDay = newDelay;
        }
    }

    function _priceForRisk(uint8 risk) private view returns (uint256) {
        return _priceForRiskWithMultiplier(risk, priceMultiplier);
    }

    function _basePrice(uint8 risk) private pure returns (uint256) {
        return _priceForRiskWithMultiplier(risk, MULT_SCALE);
    }

    function _priceForRiskWithMultiplier(uint8 risk, uint256 multiplier) private pure returns (uint256) {
        if (risk > MAX_RISK) revert InvalidRisk();
        uint256 base = uint256(1 ether) >> risk;
        if (base == 0) revert InvalidRisk();
        return (base * multiplier) / MULT_SCALE;
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

    function _guardPurchases() private view {
        if (resolvePending) revert ResolvePendingAlready();
        if (transfersLocked) revert TransferBlocked();
    }

    function _processPayment(uint256 amount, address recipient) private {
        uint256 seed;
        if (game == address(0)) {
            seed = amount / 2;
            rewardSeedEth += seed;
        }
        uint256 toSend = amount - seed;
        (bool ok, ) = payable(recipient).call{value: toSend}("");
        if (!ok) revert CallFailed();
    }

    function _setCoinToken(address token) private {
        if (token == address(0)) revert ZeroAddress();
        address current = coinToken;
        if (current != address(0)) {
            if (current != token) revert AlreadyConfigured();
            return;
        }
        coinToken = token;
    }

    function _setGame(address game_) private {
        if (game_ == address(0)) revert ZeroAddress();
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

    function _riskForBase(uint256 baseWei) private pure returns (uint8 risk) {
        if (baseWei == 0 || baseWei > 1 ether) revert InvalidBase();
        uint256 base = 1 ether;
        while (base > baseWei && risk < MAX_RISK) {
            unchecked {
                ++risk;
            }
            base >>= 1;
        }
    }

    function _inPendingWindow(uint256 tokenId) private view returns (bool) {
        if (!resolvePending) return false;
        uint256 start = pendingResolveBase;
        uint256 end = pendingResolveMax;
        if (start == 0) return false;
        if (end == 0) end = nextId - 1;
        return tokenId >= start && tokenId <= end;
    }

    function _transfersBlocked(uint256 tokenId) private view returns (bool) {
        return transfersLocked || staked[tokenId] || _isResolved(tokenId) || _inPendingWindow(tokenId);
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
        roll = uint256(keccak256(abi.encodePacked(rngWord, tokenId))) % 10_000;
        win = roll < chanceBps;
    }

    function _resolveBond(uint256 tokenId, uint256 rngWord) private returns (bool win) {
        uint256 basePrice = _basePrice(riskOf[tokenId]);
        uint256 weight = _coinWeightMultiplier(tokenId);
        uint16 chance;
        uint256 roll;
        (win, chance, roll) = bondOutcome(tokenId, rngWord);
        if (win) {
            if (!claimReady[tokenId]) {
                claimReady[tokenId] = true;
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

        uint256 maxId = nextId - 1;
        if (maxId == 0 || tid > maxId) {
            shutdownBurnCursor = tid;
            return (0, 0, true);
        }

        uint256 limit = maxIds == 0 ? 500 : maxIds;
        address ownerCursor;
        uint256 ownerBurns;

        while (processed < limit && tid <= maxId) {
            if (!claimReady[tid] && !claimed[tid]) {
                address holder = _ownerOf[tid];
                if (holder != address(0)) {
                    uint256 basePrice = _basePrice(riskOf[tid]);
                    totalEthOwed -= basePrice;
                    totalCoinOwed -= basePrice * _coinWeightMultiplier(tid);

                    claimed[tid] = true;

                    if (ownerCursor != holder) {
                        if (ownerCursor != address(0) && ownerBurns != 0) {
                            _burnedBalance[ownerCursor] += ownerBurns;
                        }
                        ownerCursor = holder;
                        ownerBurns = 1;
                    } else {
                        unchecked {
                            ++ownerBurns;
                        }
                    }

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
            _burnedBalance[ownerCursor] += ownerBurns;
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
            uint256 minted = nextId - 1;
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

        while (tid <= targetId) {
            bool resolvedWinner = claimReady[tid] || claimed[tid];
            if (resolvedWinner) {
                unchecked {
                    ++tid;
                }
                continue;
            }

            address holder = _ownerOf[tid];
            if (holder != address(0)) {
                uint256 basePrice = _basePrice(riskOf[tid]);
                totalEthOwed -= basePrice;
                totalCoinOwed -= basePrice * _coinWeightMultiplier(tid);

                claimed[tid] = true;
                address approved = _tokenApproval[tid];
                if (approved != address(0)) {
                    _tokenApproval[tid] = address(0);
                }

                if (ownerCursor != holder) {
                    if (ownerCursor != address(0) && ownerBurns != 0) {
                        _burnedBalance[ownerCursor] += ownerBurns;
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
            _burnedBalance[ownerCursor] += ownerBurns;
        }
        if (burned != 0) {
            burnedCount += burned;
        }
        lowestUnresolved = tid;
    }

    function _burnToken(uint256 tokenId, address holder) private {
        if (holder == address(0)) return;
        unchecked {
            _burnedBalance[holder] += 1;
        }
        unchecked {
            ++burnedCount;
        }
        address approved = _tokenApproval[tokenId];
        if (approved != address(0)) {
            _tokenApproval[tokenId] = address(0);
        }
        emit Transfer(holder, address(0), tokenId);
    }

    function _isResolved(uint256 tokenId) private view returns (bool) {
        return claimReady[tokenId] || claimed[tokenId] || _isInactive(tokenId);
    }

    function _currentDistance(uint256 tokenId) private view returns (uint256) {
        if (_isResolved(tokenId)) return 0;
        uint256 cursor = nextClaimable;
        if (tokenId < cursor) return 0;
        return (tokenId - cursor) + 1;
    }
}

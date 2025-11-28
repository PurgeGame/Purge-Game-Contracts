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
    function bondTokenURI(uint256 tokenId) external view returns (string memory);
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
    error TransferBlocked();

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
    bool public decayPaused;
    uint256 public bondCoin; // PURGE reserved for bond payouts
    uint256 public totalEthOwed; // Sum of ETH owed across all bonds

    uint256 public priceMultiplier = 1e18; // dynamic price multiplier (1e18 = 1.0x)
    uint64 public lastDecayDay;
    uint256 public ethPool;
    uint256 public stEthPool;
    uint256 public bondPool;
    bool public purchasesEnabled = true;

    uint256 private nextId = 1;
    uint256 private nextClaimable = 1;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _tokenApproval;
    mapping(address => mapping(address => bool)) private _operatorApproval;
    mapping(uint256 => uint8) public riskOf;
    mapping(uint256 => bool) public claimReady;
    mapping(uint256 => bool) public claimed;
    mapping(uint256 => uint16) public winChanceBps; // basis points; capped at 10000
    mapping(uint256 => bool) public staked;

    uint256 public lowestUnresolved;
    uint256 public resolveBaseId;

    bool private entered;
    uint256 private stEthAccounted;

    uint256 private constant MULT_SCALE = 1e18;
    uint256 private constant DECAY_BPS = 9950; // 0.5% down daily
    uint256 private constant BPS_DENOM = 10_000;
    uint8 private constant MAX_RISK = 59; // Keeps 1 ether >> risk non-zero

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------------
    // Bond funding (replacement for burnie-style flows)
    // ---------------------------------------------------------------------

    /// @notice Accept ETH/stETH/coin inflows and resolve/burn bonds for the day using RNG.
    /// @param coinAmount Amount of coin credited alongside this call; 25% is added to the bondPool.
    /// @param stEthAddress Address of the stETH token used for accounting (must match configured stEthToken).
    /// @param rngWord Randomness for this resolution window (e.g., day's RNG).
    /// @param baseId Optional starting token id for this resolution pass (0 = continue from prior cursor).
    /// @param maxBonds Max bonds to resolve in this call (0 = default 25).
    function payBonds(
        uint256 coinAmount,
        address stEthAddress,
        uint256 rngWord,
        uint256 baseId,
        uint256 maxBonds
    ) external payable onlyOwner nonReentrant {
        ethPool += msg.value;

        uint256 bondAdded;
        if (coinAmount != 0) {
            if (coinToken == address(0)) revert ZeroAddress();
            if (!IERC20Minimal(coinToken).transferFrom(msg.sender, address(this), coinAmount)) revert CallFailed();
            bondAdded = coinAmount / 4; // 25%
            bondPool += bondAdded;
            bondCoin += bondAdded;
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

        // Resolution cursor
        if (baseId != 0) {
            resolveBaseId = baseId;
        } else if (resolveBaseId == 0) {
            resolveBaseId = nextClaimable;
        }
        uint256 tid = resolveBaseId;
        uint256 maxId = nextId - 1;
        uint256 limit = maxBonds == 0 ? 25 : maxBonds;
        uint256 processed;
        while (processed < limit && tid <= maxId) {
            if (!claimed[tid]) {
                _resolveBond(tid, rngWord);
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

        emit BondsPaid(msg.value, stAdded, bondAdded);
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
        lastDecayDay = uint64(block.timestamp / 1 days);
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

    function _buy(uint8 risk, bool stake) private returns (uint256 tokenId) {
        address recipient = fundRecipient;
        if (recipient == address(0)) revert ZeroAddress();
        if (!purchasesEnabled) revert PurchasesClosed();

        _syncMultiplier();
        uint256 price = _priceForRisk(risk);
        if (msg.value != price) revert WrongPrice();

        (bool ok, ) = payable(recipient).call{value: msg.value}("");
        if (!ok) revert CallFailed();

        tokenId = _mint(msg.sender, risk, price, stake);
        emit Purchased(msg.sender, tokenId, risk, price);

        _bumpMultiplier(msg.value);
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
        totalEthOwed += _basePrice(risk);

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
        if (token == address(0)) revert ZeroAddress();
        coinToken = token;
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

    function setRenderer(address renderer_) external onlyOwner {
        if (renderer_ == address(0)) revert ZeroAddress();
        renderer = renderer_;
    }

    function setPurchasesEnabled(bool enabled) external onlyOwner {
        purchasesEnabled = enabled;
        decayPaused = !enabled;
        if (enabled) {
            lastDecayDay = uint64(block.timestamp / 1 days);
        }
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
                uint256 basePrice = _basePrice(riskOf[tid]);
                if (basePrice < 1 ether) {
                    totalEthOwed += (1 ether - basePrice);
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

        uint256 ethShare = ethPool / supply;
        uint256 stShare = stEthPool / supply;
        uint256 bondShare;
        uint256 owed = totalEthOwed;
        if (owed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * 1 ether) / owed;
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
        emit Claimed(to, tokenId, ethShare, stShare, bondShare);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function balanceOf(address account) public view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balanceOf[account];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _ownerOf[tokenId];
        if (o == address(0)) revert InvalidToken();
        return o;
    }

    function totalSupply() external view returns (uint256) {
        return nextId - 1;
    }

    function pendingShares() external view returns (uint256 ethShare, uint256 stEthShare, uint256 bondShare) {
        uint256 supply = nextId - 1;
        if (supply == 0) return (0, 0, 0);
        ethShare = ethPool / supply;
        stEthShare = stEthPool / supply;
        uint256 owed = totalEthOwed;
        if (owed != 0 && bondCoin != 0) {
            bondShare = (bondCoin * 1 ether) / owed;
        }
    }

    function getApproved(uint256 tokenId) public view returns (address) {
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
        if (_ownerOf[tokenId] == address(0)) revert InvalidToken();
        address renderer_ = renderer;
        if (renderer_ == address(0)) revert ZeroAddress();
        return IPurgeBondRenderer(renderer_).bondTokenURI(tokenId);
    }

    function currentPrice(uint8 risk) external view returns (uint256) {
        return _priceForRiskWithMultiplier(risk, _multiplierWithDecay());
    }

    // ---------------------------------------------------------------------
    // Approvals
    // ---------------------------------------------------------------------

    function approve(address spender, uint256 tokenId) external {
        address holder = ownerOf(tokenId);
        if (staked[tokenId] || _isResolved(tokenId)) revert TransferBlocked();
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
        if (staked[tokenId] || _isResolved(tokenId)) revert TransferBlocked();
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
        address holder = _ownerOf[tokenId];
        if (holder == address(0)) revert InvalidToken();
        return (spender == holder || _tokenApproval[tokenId] == spender || _operatorApproval[holder][spender]);
    }

    function _syncMultiplier() private {
        if (decayPaused) return;
        uint64 day = uint64(block.timestamp / 1 days);
        uint64 last = lastDecayDay;
        if (day <= last) return;

        priceMultiplier = _applyDecay(priceMultiplier, uint256(day - last));
        lastDecayDay = day;
    }

    function _bumpMultiplier(uint256 paidWei) private {
        if (paidWei == 0) return;
        // +1% per ETH of purchases (pro-rata for partial ETH).
        // delta = multiplier * paidWei / (100 * 1e18)
        uint256 delta = (priceMultiplier * paidWei) / (100 * 1 ether);
        priceMultiplier += delta;
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
        return _applyDecay(priceMultiplier, uint256(day - last));
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
        return mult;
    }

    /// @notice Purely algorithmic bond outcome using RNG + token data; no state writes.
    function bondOutcome(
        uint256 tokenId,
        uint256 rngWord
    ) public view returns (bool win, uint16 chanceBps, uint256 roll) {
        chanceBps = winChanceBps[tokenId];
        if (chanceBps == 0) {
            chanceBps = 1; // minimal non-zero chance if none recorded
        }
        roll = uint256(keccak256(abi.encodePacked(rngWord, tokenId))) % 10_000;
        win = roll < chanceBps;
    }

    function _resolveBond(uint256 tokenId, uint256 rngWord) private {
        uint256 basePrice = _basePrice(riskOf[tokenId]);
        (bool win, uint16 chance, uint256 roll) = bondOutcome(tokenId, rngWord);
        if (win) {
            if (!claimReady[tokenId]) {
                claimReady[tokenId] = true;
                emit ClaimEnabled(tokenId);
                if (basePrice < 1 ether) {
                    totalEthOwed += (1 ether - basePrice);
                }
            }
        } else {
            totalEthOwed -= basePrice;
            claimed[tokenId] = true;
            emit BondBurned(tokenId);
        }
        emit BondResolved(tokenId, win, chance, roll);
    }

    function _burnInactiveUpTo(uint256 targetId) private {
        uint256 tid = lowestUnresolved;
        while (tid <= targetId) {
            if (!claimReady[tid]) {
                address holder = _ownerOf[tid];
                if (holder != address(0)) {
                    if (!claimed[tid]) {
                        totalEthOwed -= _basePrice(riskOf[tid]);
                    }
                    claimed[tid] = true;
                    _burnLikeMain(holder, tid);
                }
            }
            unchecked {
                ++tid;
            }
        }
        lowestUnresolved = tid;
    }

    // Mirror main NFT burn pattern: emit Transfer to address(0) and zero ownership.
    function _burnLikeMain(address owner_, uint256 tokenId) private {
        delete _tokenApproval[tokenId];
        _ownerOf[tokenId] = address(0);
        uint256 bal = _balanceOf[owner_];
        if (bal != 0) {
            _balanceOf[owner_] = bal - 1;
        }
        if (staked[tokenId]) {
            delete staked[tokenId];
        }
        emit Transfer(owner_, address(0), tokenId);
    }

    function _isResolved(uint256 tokenId) private view returns (bool) {
        return claimReady[tokenId] || claimed[tokenId];
    }
}

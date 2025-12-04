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

interface IPurgeBongRenderer {
    function bongTokenURI(
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
}

interface IPurgeCoinBongMinter {
    function bongPayment(uint256 amount) external;
    function notifyQuestBong(address player, uint256 basePerBongWei) external;
}

interface IPurgeAffiliateLike {
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external returns (uint256);
    function referralCodeOf(address player) external view returns (bytes32);
}

interface IPurgeGamePrice {
    function mintPrice() external view returns (uint256);
    function coinPriceUnit() external view returns (uint256);
}

interface IPurgeGameBongWinnings {
    function creditBongWinnings(address player) external payable;
}

interface IPurgeGameBongSinks {
    function bongRewardDeposit() external payable;
    function bongYieldDeposit() external payable;
}

interface IPurgeStonkReceiver {
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable;
}

/**
 * @title PurgeBongs
 * @notice A lightweight ERC721 implementation for gamified "bongs".
 * @dev
 * Core Mechanics:
 * 1. Minting: Users pay ETH to mint bongs. Price is dynamic (decay + demand bumps).
 * 2. Betting: Users choose a `basePrice`. Win chance = `basePrice / 1 ETH`.
 * 3. Payouts:
 *    - Winners get topped up to 1 ETH (or 1 stETH).
 *    - Winners get a share of the PURGE token pool.
 *    - Staked bongs are non-transferable; all bongs share the same PURGE token weight.
 * 4. Accounting:
 *    - `totalCoinOwed` tracks the SUM of all potential liabilities (Weighted).
 *    - This ensures the contract is always solvent for the winning scenario.
 */
contract PurgeBongs {
    // ===========================================================================
    // Errors
    // ===========================================================================
    error Unauthorized(); // 0x82b42900
    error ZeroAddress(); // 0xd92e233d
    error InvalidToken(); // 0xc1ab6dc1
    error CallFailed(); // 0x3204506f
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
    error AlreadyConfigured(); // 0x2e68d627
    error GameOver(); // 0x0e647580
    error ShutdownPendingResolution(); // 0x2306321e
    error InsufficientPayout(); // 0x8024d516
    error InvalidPrice(); // 0x3c7fd3c2

    // ===========================================================================
    // Events
    // ===========================================================================
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Purchased(address indexed buyer, uint256 indexed tokenId, uint256 basePrice, uint256 price);
    event ClaimEnabled(uint256 indexed tokenId);
    event Claimed(address indexed to, uint256 indexed tokenId, uint256 ethPaid, uint256 stEthPaid, uint256 bongPaid);
    event BongsPaid(uint256 ethAdded, uint256 stEthAdded, uint256 bongPoolAdded);
    event BongResolved(uint256 indexed tokenId, bool win, uint16 chanceBps, uint256 roll);
    event BongBurned(uint256 indexed tokenId);
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
    uint256 private constant DECAY_BPS = 9950; // 0.5% daily price decay
    uint256 private constant BPS_DENOM = 10_000;
    uint64 private constant DECAY_DELAY_DAYS = 7; // Bumps delay decay for 7 days
    uint256 private constant COIN_WEIGHT_UNMARKETABLE = 5; // Staked (non-transferable) weight
    uint256 private constant COIN_WEIGHT_MARKETABLE = 5; // Unstaked (transferable) weight (no penalty)
    uint256 private constant MIN_BASE_PRICE = 0.02 ether; // Minimum bong size
    uint256 private constant AUTO_RESOLVE_BATCH = 100;
    uint256 private constant SALES_BUMP_NUMERATOR = 1005; // +0.5% price per threshold
    uint256 private constant SALES_BUMP_DENOMINATOR = 1000;
    uint256 private constant PRESALE_PRICE_PER_1000_DEFAULT = 0.01 ether;
    uint256 private constant FALLBACK_MINT_PRICE = 0.025 ether;
    uint256 private constant DEFAULT_BASE_PER_BONG = 0.5 ether;
    uint256 private constant BONG_BASE_TICK_WEI = 0.01 ether;
    uint256 private constant BONG_BASE_TICK_BITS = 10;
    uint256 private constant BONG_BASE_TICK_MASK = (1 << BONG_BASE_TICK_BITS) - 1; // 0..1023
    uint256 private constant BONG_DISTANCE_MASK = (1 << 24) - 1; // supports multi-million distances

    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // ===========================================================================
    // State Variables
    // ===========================================================================

    // -- Metadata & Access --
    string public constant name = "Purge Bongs";
    string public constant symbol = "PBONG";
    address public owner;
    address public stEthToken; // The "Prime" asset for payouts
    address public coinToken; // The "Bonus" asset (PURGE)
    address public renderer;
    address public game; // The main PurgeGame contract
    address public affiliateProgram;
    address public stonk; // STONK share contract to receive stray funds

    // -- Financial Accounting --
    // `pool` variables track actual assets held.
    // `Owed` variables track liabilities (if everyone won).
    uint256 public bongCoin; // PURGE owed for bong payouts (tracking pool)
    uint256 public totalEthOwed; // Aggregate ETH liability
    uint256 public payoutObligation; // Aggregate ETH + stETH reserved for bong payouts
    uint256 public totalCoinOwed; // Aggregate weighted PURGE liability
    uint256 public rewardSeedEth; // Accumulator for game rewards from unwired state
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
    uint256 public shutdownBurnCursor;
    uint256 private shutdownSliceCursor;

    // -- Token Data --
    uint256 private nextClaimable;
    uint256 private burnedCount;
    uint256 public lowestUnresolved;
    uint256 public resolveBaseId;

    // ERC721A Packed Storage
    mapping(uint256 => uint256) private _packedOwnerships;
    mapping(address => uint256) private _packedAddressData;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // Bong Specific Data
    mapping(uint256 => uint64) internal bongMeta; // packed base/distance anchor per mint run

    // Multi-range minting (level-strided token ids)
    uint256 private constant LEVEL_STRIDE = 1_000_000_000_000;
    uint64 private constant BASE_RANGE_KEY = 0;

    struct RangeState {
        uint256 start; // inclusive start for the range (e.g., 1 or level * LEVEL_STRIDE)
        uint256 next; // next token id to mint within this range (exclusive upper bound)
        uint256 minted; // count of tokens minted in this range
    }

    struct ResolveSlice {
        uint64 range;
        uint128 start; // inclusive
        uint128 end; // inclusive
    }

    uint256 private _mintedTotal; // global minted count (across all ranges)
    mapping(uint64 => RangeState) private _ranges;
    ResolveSlice[] private _resolveQueue; // minted slices in chronological order
    uint256 private resolveQueueCursor; // index into _resolveQueue for the current front slice
    uint256 private resolveTokenCursor; // token id within the current front slice
    uint256 private claimSweepSliceCursor; // slice cursor for auto-claim sweeps
    // Warp detours: base cursor jumps to a level range at a pivot base token, resolves that range, then resumes base.
    struct Warp {
        uint256 pivot; // base tokenId to trigger the detour
        uint64 range; // level range key
        uint128 start; // level token start (inclusive)
        uint128 end; // level token end (inclusive)
        uint128 cursor; // next token to resolve inside the warp
        bool done;
    }
    Warp[] private warps;
    uint256 private warpCursor;

    // -- Configuration --
    bool public transfersLocked;
    uint16 public constant stakeRateBps = 10_000; // 100%

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

    receive() external payable {
        _forwardToStonk(msg.value, 0, 0);
    }

    fallback() external payable {
        if (msg.value != 0) {
            _forwardToStonk(msg.value, 0, 0);
        }
    }

    // ===========================================================================
    // Range / cursor helpers
    // ===========================================================================

    function _rangeStart(uint64 key) private pure returns (uint256) {
        return key == BASE_RANGE_KEY ? 1 : uint256(key) * LEVEL_STRIDE;
    }

    function _ensureRange(uint64 key) private returns (RangeState storage r) {
        r = _ranges[key];
        if (r.start == 0) {
            uint256 start = _rangeStart(key);
            r.start = start;
            r.next = start;
        }
    }

    function _rangeBounds(uint256 tokenId) private view returns (uint256 start, uint256 next) {
        uint64 key = uint64(tokenId / LEVEL_STRIDE);
        RangeState storage r = _ranges[key];
        start = r.start;
        next = r.next;
    }

    function _appendResolveSlice(uint64 rangeKey, uint256 start, uint256 end) private {
        uint256 len = _resolveQueue.length;
        if (len != 0) {
            ResolveSlice storage tail = _resolveQueue[len - 1];
            if (tail.range == rangeKey && uint256(tail.end) + 1 == start) {
                tail.end = uint128(end);
                if (lowestUnresolved == 0) {
                    resolveQueueCursor = len - 1;
                    resolveTokenCursor = tail.start;
                    lowestUnresolved = tail.start;
                    if (nextClaimable == 0) {
                        nextClaimable = tail.start;
                    }
                }
                return;
            }
        }
        _resolveQueue.push(ResolveSlice({range: rangeKey, start: uint128(start), end: uint128(end)}));
        if (lowestUnresolved == 0) {
            resolveQueueCursor = len;
            resolveTokenCursor = start;
            lowestUnresolved = start;
            if (nextClaimable == 0) {
                nextClaimable = start;
            }
        }
    }

    function _normalizeFront(uint256 desiredTokenId) private {
        uint256 len = _resolveQueue.length;
        if (len == 0) {
            resolveQueueCursor = 0;
            resolveTokenCursor = 0;
            lowestUnresolved = 0;
            nextClaimable = 0;
            return;
        }

        uint256 idx = resolveQueueCursor;
        if (idx >= len) {
            idx = len - 1;
        }

        if (desiredTokenId == 0) {
            desiredTokenId = resolveTokenCursor != 0 ? resolveTokenCursor : uint256(_resolveQueue[idx].start);
        }

        while (idx < len) {
            ResolveSlice storage slice = _resolveQueue[idx];
            if (desiredTokenId < slice.start) {
                desiredTokenId = slice.start;
                break;
            }
            if (desiredTokenId <= slice.end) {
                break;
            }
            unchecked {
                ++idx;
            }
            if (idx < len) {
                desiredTokenId = _resolveQueue[idx].start;
            }
        }

        if (idx >= len) {
            resolveQueueCursor = len;
            resolveTokenCursor = 0;
            lowestUnresolved = 0;
            nextClaimable = 0;
            return;
        }

        resolveQueueCursor = idx;
        resolveTokenCursor = desiredTokenId;
        lowestUnresolved = desiredTokenId;
        if (nextClaimable == 0 || nextClaimable < desiredTokenId) {
            nextClaimable = desiredTokenId;
        }
    }

    function _firstMintedToken() private view returns (uint256 tokenId) {
        if (_resolveQueue.length == 0) return 0;
        return _resolveQueue[0].start;
    }

    function _lastMintedToken() private view returns (uint256 tokenId) {
        uint256 len = _resolveQueue.length;
        if (len == 0) return 0;
        return _resolveQueue[len - 1].end;
    }

    function _pushWarp(uint256 pivotBaseId, uint64 rangeKey, uint256 start, uint256 end) private {
        if (pivotBaseId == 0 || start == 0 || end < start) revert InvalidToken();
        warps.push(
            Warp({
                pivot: pivotBaseId,
                range: rangeKey,
                start: uint128(start),
                end: uint128(end),
                cursor: 0,
                done: false
            })
        );
    }

    function _nextActiveWarp(uint256 baseCursor) private returns (bool found, uint256 idx, uint256 pivot) {
        uint256 len = warps.length;
        uint256 i = warpCursor;
        while (i < len) {
            Warp storage w = warps[i];
            if (w.done) {
                unchecked {
                    ++i;
                }
                continue;
            }
            pivot = w.pivot;
            idx = i;
            found = true;
            if (pivot < baseCursor) {
                // Base cursor already passed this pivot; process immediately.
                warpCursor = i;
            } else {
                warpCursor = i;
            }
            return (found, idx, pivot);
        }
        return (false, 0, 0);
    }

    // ===========================================================================
    // Funding & Resolution Ingest
    // ===========================================================================

    /**
     * @notice Main entry point to fund the contract and trigger bong resolution.
     * @dev Callable by the game only. Automatically batches resolution if budgets allow.
     *      Game profits (or shutdown drain) are expected to flow in here; bong purchases themselves are NOT reserved.
     *      Only ETH/stETH delivered via this function raises payoutObligation to back matured bongs.
     * @param coinAmount Amount of PURGE tokens being sent/credited.
     * @param stEthAmount Amount of stETH being credited by the caller.
     * @param rngDay The game day to fetch RNG for (if not provided via `rngWord`).
     * @param rngWord The random seed for resolution (overrides `rngDay` if non-zero).
     * @param maxBongs Resolution batch size limit.
     */
    function payBongs(
        uint256 coinAmount,
        uint256 stEthAmount,
        uint48 rngDay,
        uint256 rngWord,
        uint256 maxBongs
    ) external payable onlyGame {
        // 1. Ingest Coin (PURGE)
        uint256 coinMinted = coinAmount;
        if (coinMinted != 0) {
            address coin = coinToken;

            IPurgeCoinBongMinter(coin).bongPayment(coinMinted);
        }

        // 2. Ingest stETH
        uint256 stAdded;
        if (stEthAmount != 0) {
            IERC20Minimal(stEthToken).transferFrom(msg.sender, address(this), stEthAmount);
            stAdded = stEthAmount;
        }

        // If no bongs remain, immediately forward everything to the stonk contract.
        if (_noBongsAlive()) {
            _forwardToStonk(msg.value, coinMinted, stAdded);
            return;
        }

        bool pending = resolvePending;

        if (coinMinted != 0) {
            bongCoin += coinMinted;
        }

        uint256 budget = msg.value + stAdded;
        if (budget != 0) {
            payoutObligation += budget;
        }

        if (budget != 0 || coinMinted != 0) {
            emit BongsPaid(msg.value, stAdded, coinMinted);
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
                _scheduleResolve(startId, rngDay, wordToUse, maxBongs, budget);
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
                _resolvePendingInternal(_resolveLimit(maxBongs), false);
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
     * @notice Manual trigger to process pending bongs if auto-batching didn't finish.
     */
    function resolvePendingBongs(uint256 maxBongs) external {
        _resolvePendingInternal(_resolveLimit(maxBongs), true);
        // Auto-claim winners in live mode so players get swept to game credit without manual claims.
        if (!gameOver) {
            _autoClaimWinners(maxBongs);
        }
    }

    // ===========================================================================
    // Minting (Buying)
    // ===========================================================================

    function _purchaseStakeFlag() private view returns (bool) {
        // Post-presale (game wired) bongs default to staked/soulbound.
        return game != address(0) ? true : prizePoolFunded;
    }

    function _routePurchaseProceeds(uint256 amount) private {
        if (amount == 0) return;
        address game_ = game;
        // Presale / unwired: park 20% for the game and keep the rest on the bong contract.
        if (game_ == address(0)) {
            uint256 toFund = amount / 5; // 20%
            if (toFund != 0) {
                rewardSeedEth += toFund;
            }
            return;
        }

        if (game_.code.length == 0) return;

        // Wired: send 50% to the game (20% reward pool + 30% yield pool), retain 50% locally.
        uint256 rewardCut = amount / 5; // 20%
        uint256 yieldCut = (amount * 3) / 10; // 30%
        if (rewardCut != 0) {
            _markPrizePoolFunded();
            IPurgeGameBongSinks(game_).bongRewardDeposit{value: rewardCut}();
        }
        if (yieldCut != 0) {
            IPurgeGameBongSinks(game_).bongYieldDeposit{value: yieldCut}();
        }
    }

    function _notifyQuestBong(address buyer, uint256 basePerBong) private {
        address coin = coinToken;
        if (coin == address(0) || buyer == address(0) || basePerBong == 0) return;
        if (coin.code.length == 0) return;
        (bool ok, ) = coin.call(abi.encodeWithSelector(IPurgeCoinBongMinter.notifyQuestBong.selector, buyer, basePerBong));
        ok;
    }

    /**
     * @notice Purchase bongs.
     * @param baseWei The 'Principal' amount (affects win chance and payout).
     * @param quantity Number of bongs.
     * @param affiliateCode Referral code.
     */
    function buy(uint256 baseWei, uint256 quantity, bool /*stake*/, bytes32 affiliateCode) external payable {
        if (!purchasesEnabled) revert PurchasesClosed();
        if (transfersLocked) revert TransferBlocked();
        if (quantity == 0) revert InvalidQuantity();
        if (baseWei == 0 || baseWei > 1 ether) revert InvalidBase();

        _syncMultiplier();

        // Cap base price at 0.5 ETH (50% win chance max)
        uint256 basePerBong = baseWei / quantity;
        if (basePerBong > 0.5 ether) {
            basePerBong = 0.5 ether;
        }
        if (basePerBong < MIN_BASE_PRICE) revert InvalidBase();

        // Handle Affiliate
        _applyAffiliateCode(msg.sender, affiliateCode, msg.value);

        // Verify Price
        uint256 price = (basePerBong * priceMultiplier) / MULT_SCALE;
        uint256 totalPrice = price * quantity;
        // Strict equality check protects against precision gaming
        if (price == 0 || totalPrice / quantity != price || msg.value != totalPrice) revert WrongPrice();

        // Purchases are revenue, not escrow: only `payBongs` funding backs payouts.
        _routePurchaseProceeds(msg.value);

        bool stakeFlag = _purchaseStakeFlag();
        if (stakeFlag && msg.sender.code.length != 0) revert Unauthorized();

        bool marketableBonus = (game != address(0)) && (basePerBong * quantity >= 2.5 ether);
        if (marketableBonus && quantity > 1) {
            _mintBatch(msg.sender, quantity - 1, basePerBong, price, true, BASE_RANGE_KEY, true);
            _mintBatch(msg.sender, 1, basePerBong, price, false, BASE_RANGE_KEY, true);
        } else if (marketableBonus) {
            _mintBatch(msg.sender, 1, basePerBong, price, false, BASE_RANGE_KEY, true);
        } else {
            _mintBatch(msg.sender, quantity, basePerBong, price, stakeFlag, BASE_RANGE_KEY, true);
        }

        _notifyQuestBong(msg.sender, basePerBong);
        _bumpOnSales(msg.value);
    }

    /**
     * @notice Mint bongs using game-managed funds without sending ETH to the bongs contract.
     * @dev Access: game only. ETH should already be accounted for and retained on the game contract (untracked yield).
     *      Supports either a single recipient with a `quantity` > 1, or a 1:1 recipients list when `quantity` is zero or matches `recipients.length`.
     * @param recipients If length is 1, mints `quantity` bongs to that address. Otherwise, mints one bong per recipient.
     * @param quantity Number of bongs to mint when `recipients.length == 1`. Ignored otherwise (set to 0 to default to recipients length).
     * @param basePerBongWei Base value per bong (win odds), capped at 0.5 ETH and floored to the minimum.
     * @param stake Whether the minted bongs should be staked/soulbound.
     */
    function purchaseGameBongs(
        address[] calldata recipients,
        uint256 quantity,
        uint256 basePerBongWei,
        bool stake
    ) external onlyGame returns (uint256 startTokenId) {
        uint256 len = recipients.length;
        if (len == 0) revert InvalidQuantity();
        if (basePerBongWei == 0 || basePerBongWei > 1 ether) revert InvalidBase();

        _syncMultiplier();

        uint256 basePerBong = basePerBongWei;
        if (basePerBong > 0.5 ether) {
            basePerBong = 0.5 ether;
        }
        if (basePerBong < MIN_BASE_PRICE) revert InvalidBase();

        // Force staked defaults for game-driven mints post-presale.
        if (game != address(0)) {
            stake = true;
        }

        uint256 mintCount = quantity;
        if (len == 1) {
            if (mintCount == 0) mintCount = 1;
        } else {
            if (mintCount == 0) {
                mintCount = len;
            } else if (mintCount != len) {
                revert InvalidQuantity();
            }
        }

        if (len == 1) {
            address to = recipients[0];
            if (to == address(0)) revert ZeroAddress();
            startTokenId = _mintBatch(to, mintCount, basePerBong, 0, stake, BASE_RANGE_KEY, true);
        } else {
            for (uint256 i; i < mintCount; ) {
                address to = recipients[i];
                if (to == address(0)) revert ZeroAddress();
                uint256 mintedId = _mintBatch(to, 1, basePerBong, 0, stake, BASE_RANGE_KEY, true);
                if (i == 0) {
                    startTokenId = mintedId;
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    /**
     * @notice Mint free bongs for affiliates who earned reward tiers (no ETH required).
     * @dev Access: affiliate contract only.
     * @param to Recipient of the reward bongs.
     * @param quantity Number of bongs to mint.
     * @param basePerBongWei Base value per bong (win odds). Capped to 0.5 ETH.
     * @param stake Whether the bongs should be staked/soulbound.
     */
    function mintAffiliateReward(
        address to,
        uint256 quantity,
        uint256 basePerBongWei,
        bool stake
    ) external returns (uint256 startTokenId) {
        if (msg.sender != affiliateProgram) revert Unauthorized();

        uint256 basePerBong = basePerBongWei;
        if (basePerBong > 0.5 ether) {
            basePerBong = 0.5 ether;
        }
        if (basePerBong < MIN_BASE_PRICE) revert InvalidBase();

        startTokenId = _mintBatch(to, quantity, basePerBong, 0, stake, BASE_RANGE_KEY, true);
    }

    /**
     * @notice Mint bongs into a specific level-strided range (level * 1e12) and append them to the back of the resolution queue.
     * @dev Access: game only. Useful for level-dependent bond insertions that should not occupy the base range.
     * @param recipients If length is 1, mints `quantity` bongs to that address. Otherwise, mints one bong per recipient.
     * @param quantity Number of bongs to mint when `recipients.length == 1`. Ignored otherwise (set to 0 to default to recipients length).
     * @param basePerBongWei Base value per bong (win odds), capped at 0.5 ETH and floored to the minimum.
     * @param stake Whether the minted bongs should be staked/soulbound.
     * @param levelRange The level key to use for the range (token ids start at `levelRange * 1e12`).
     */
    function mintLevelRangeBongs(
        address[] calldata recipients,
        uint256 quantity,
        uint256 basePerBongWei,
        bool stake,
        uint64 levelRange,
        uint256 pivotBaseId
    ) external onlyGame returns (uint256 startTokenId) {
        uint256 len = recipients.length;
        if (len == 0) revert InvalidQuantity();
        if (basePerBongWei == 0 || basePerBongWei > 0.5 ether || basePerBongWei < MIN_BASE_PRICE) revert InvalidBase();
        if (pivotBaseId == 0) revert InvalidToken();

        _syncMultiplier();

        uint256 mintCount = quantity;
        if (len == 1) {
            if (mintCount == 0) mintCount = 1;
        } else {
            if (mintCount == 0) {
                mintCount = len;
            } else if (mintCount != len) {
                revert InvalidQuantity();
            }
        }

        if (len == 1) {
            address to = recipients[0];
            if (to == address(0)) revert ZeroAddress();
            startTokenId = _mintBatch(to, mintCount, basePerBongWei, 0, stake, levelRange, false);
        } else {
            for (uint256 i; i < mintCount; ) {
                address to = recipients[i];
                if (to == address(0)) revert ZeroAddress();
                uint256 mintedId = _mintBatch(to, 1, basePerBongWei, 0, stake, levelRange, false);
                if (i == 0) {
                    startTokenId = mintedId;
                }
                unchecked {
                    ++i;
                }
            }
        }

        uint256 endTokenId = startTokenId + mintCount - 1;
        _pushWarp(pivotBaseId, levelRange, startTokenId, endTokenId);
    }

    function _mintBatch(
        address to,
        uint256 quantity,
        uint256 basePrice,
        uint256 paidWei,
        bool stake,
        uint64 rangeKey,
        bool enqueue
    ) private returns (uint256 startTokenId) {
        if (to == address(0)) revert ZeroAddress();

        RangeState storage rangeState = _ensureRange(rangeKey);
        startTokenId = rangeState.next;
        uint256 endTokenId = startTokenId + quantity - 1;
        if (endTokenId < startTokenId) revert InvalidToken();
        rangeState.next = endTokenId + 1;
        rangeState.minted += quantity;
        _mintedTotal += quantity;

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
        uint256 end = endTokenId + 1;
        uint256 toMasked = uint256(uint160(to)) & _BITMASK_ADDRESS;
        uint256 dist = nextClaimable == 0 ? 1 : _currentDistance(tokenId);
        if (dist > BONG_DISTANCE_MASK) {
            dist = BONG_DISTANCE_MASK;
        }
        uint32 runDistance = uint32(dist);
        bongMeta[startTokenId] = _packBongMeta(basePrice, runDistance);
        if (enqueue) {
            _appendResolveSlice(rangeKey, startTokenId, endTokenId);
        }

        // Loop for per-token metadata setup (emit events / ERC721 receiver checks)
        do {
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
    }

    // ===========================================================================
    // Claiming
    // ===========================================================================

    /**
     * @notice Claim a winning bong.
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
        uint256 bongShare;
        // **CRITICAL**: Weighting determines share of the pot.
        uint256 coinWeight = _coinClaimWeight(packed);
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bongCoin != 0) {
            // Formula: (TotalPot * MyWeightedShare) / TotalWeightedShares
            bongShare = (bongCoin * coinWeight) / coinOwed;
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

        if (bongShare != 0) {
            if (bongCoin <= bongShare) {
                bongCoin = 0;
            } else {
                bongCoin -= bongShare;
            }
            IERC20Minimal(coinToken).transfer(to, bongShare);
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

        emit Claimed(to, tokenId, ethPaid, stEthPaid, bongShare);
    }

    /**
     * @notice Auto-claim matured winners in batches, paying coin directly and reporting winners for off-chain/game-side ETH credit.
     * @param maxClaims Max winners to process (0 => default batch size).
     */
    function _autoClaimWinners(uint256 maxClaims) private {
        if (gameOver) revert GameOver(); // After GG, claims must be handled directly on the bong contract.

        uint256 cursor = claimSweepCursor;
        uint256 sliceIdx = claimSweepSliceCursor;
        if (cursor == 0) {
            sliceIdx = resolveQueueCursor;
            cursor = lowestUnresolved;
            if (cursor == 0) {
                cursor = _firstMintedToken();
            }
        }
        if (sliceIdx >= _resolveQueue.length) {
            sliceIdx = 0;
        }

        uint256 maxId = _lastMintedToken();
        if (maxId == 0 || cursor == 0) {
            claimSweepCursor = 0;
            claimSweepSliceCursor = sliceIdx;
            return;
        }

        uint256 limit = _resolveLimit(maxClaims);
        uint256 claimed;
        uint256 coinPool = bongCoin;

        while (claimed < limit && sliceIdx < _resolveQueue.length) {
            ResolveSlice storage slice = _resolveQueue[sliceIdx];
            if (cursor < slice.start) {
                cursor = slice.start;
            }
            if (cursor > slice.end) {
                unchecked {
                    ++sliceIdx;
                }
                continue;
            }

            uint256 packed = _packedOwnershipAt(cursor);
            // Only handle claim-ready, non-burned tokens.
            if (packed != 0 && (packed & (_BITMASK_CLAIM_READY | _BITMASK_BURNED)) == _BITMASK_CLAIM_READY) {
                address holder = address(uint160(packed));
                if (holder != address(0)) {
                    uint256 coinWeight = _coinClaimWeight(packed);
                    uint256 bongShare;
                    uint256 coinOwed = totalCoinOwed;
                    if (coinOwed != 0 && coinPool != 0) {
                        bongShare = (coinPool * coinWeight) / coinOwed;
                        if (bongShare != 0) {
                            if (coinPool <= bongShare) {
                                coinPool = 0;
                            } else {
                                coinPool -= bongShare;
                            }
                            IERC20Minimal(coinToken).transfer(holder, bongShare);
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

                    emit Claimed(holder, cursor, paid, 0, bongShare);
                    unchecked {
                        ++claimed;
                    }
                }
            }
            unchecked {
                ++cursor;
            }
            if (cursor > slice.end) {
                unchecked {
                    ++sliceIdx;
                }
            }
        }

        bongCoin = coinPool;
        if (sliceIdx >= _resolveQueue.length) {
            claimSweepCursor = 0;
        } else {
            if (cursor < _resolveQueue[sliceIdx].start) {
                cursor = _resolveQueue[sliceIdx].start;
            }
            claimSweepCursor = cursor;
        }
        claimSweepSliceCursor = sliceIdx;
    }

    // ===========================================================================
    // Admin / Config
    // ===========================================================================

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setPresalePricePer1000(uint256 priceWeiPer1000) external onlyOwner {
        if (priceWeiPer1000 == 0) revert InvalidPrice();
        presalePricePer1000Wei = priceWeiPer1000;
    }

    function setStonk(address stonk_) external onlyOwner {
        _setStonk(stonk_);
    }

    function wire(address[] calldata addresses) external onlyOwner {
        _setCoinToken(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setAffiliate(addresses.length > 2 ? addresses[2] : address(0));
        if (addresses.length > 3 && addresses[3] != address(0)) {
            _setStonk(addresses[3]);
        }
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
        }

        if (shutdownBurnCursor == 0) {
            uint256 cursor = lowestUnresolved;
            if (cursor == 0) cursor = _firstMintedToken();
            shutdownBurnCursor = cursor;
            shutdownSliceCursor = resolveQueueCursor;
        }
        emit GameShutdown(shutdownBurnCursor);
    }

    /**
     * @notice Withdraws funds NOT reserved for bong payouts.
     */
    function sendAsset(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        address stToken = stEthToken;
        uint256 stBal = stToken == address(0) ? 0 : IERC20Minimal(stToken).balanceOf(address(this));
        uint256 totalBal = address(this).balance + stBal;
        // Only funds explicitly flowed in via `payBongs` (plus any queued reward seed) are reserved for payouts.
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
        // For coin, we only hold what's in `bongCoin`. Any excess is fair game.
        uint256 bal = IERC20Minimal(token).balanceOf(address(this));
        uint256 reservedCoin = bongCoin;
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
        if (locked && rngDay != 0 && pendingRngDay == 0 && !resolvePending) {
            pendingRngDay = rngDay;
        }
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
        return _packedAddressData[account] & _BITMASK_ADDRESS_DATA_ENTRY;
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return _requireActiveToken(tokenId);
    }

    function totalSupply() external view returns (uint256) {
        if (burnedCount >= _mintedTotal) return 0;
        return _mintedTotal - burnedCount;
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

    function _packBongMeta(uint256 baseWei, uint32 distance) private pure returns (uint64 packed) {
        uint256 ticks = baseWei == DEFAULT_BASE_PER_BONG ? 0 : (baseWei / BONG_BASE_TICK_WEI);
        if (ticks > BONG_BASE_TICK_MASK) {
            ticks = BONG_BASE_TICK_MASK;
        }
        if (distance > BONG_DISTANCE_MASK) {
            distance = uint32(BONG_DISTANCE_MASK);
        }
        packed = (uint64(distance) << uint64(BONG_BASE_TICK_BITS)) | uint64(ticks);
    }

    function _unpackBongMeta(uint64 packed) private pure returns (uint256 baseWei, uint32 distance) {
        uint256 ticks = uint256(packed & uint64(BONG_BASE_TICK_MASK));
        baseWei = ticks == 0 ? DEFAULT_BASE_PER_BONG : ticks * BONG_BASE_TICK_WEI;
        distance = uint32(packed >> BONG_BASE_TICK_BITS);
    }

    struct BongMetaCache {
        uint256 anchor;
        uint256 base;
        bool valid;
    }

    function _bongBaseForResolve(
        uint256 tokenId,
        BongMetaCache memory cache
    ) private view returns (uint256 baseWei, BongMetaCache memory newCache) {
        (uint256 rangeStart, uint256 rangeNext) = _rangeBounds(tokenId);
        if (rangeStart == 0 || tokenId < rangeStart || tokenId >= rangeNext) {
            return (DEFAULT_BASE_PER_BONG, cache);
        }
        newCache = cache;
        uint64 packed;
        if (cache.valid && tokenId > cache.anchor) {
            packed = bongMeta[tokenId];
            if (packed == 0) {
                return (cache.base, newCache);
            }
        } else {
            packed = bongMeta[tokenId];
        }

        if (packed != 0) {
            (uint256 base, ) = _unpackBongMeta(packed);
            newCache.anchor = tokenId;
            newCache.base = base;
            newCache.valid = true;
            return (base, newCache);
        }

        uint256 cursor = tokenId;
        while (cursor > rangeStart) {
            unchecked {
                --cursor;
            }
            packed = bongMeta[cursor];
            if (packed != 0) {
                (uint256 base, ) = _unpackBongMeta(packed);
                newCache.anchor = cursor;
                newCache.base = base;
                newCache.valid = true;
                return (base, newCache);
            }
        }

        baseWei = DEFAULT_BASE_PER_BONG;
        newCache.valid = false; // fallback path; do not reuse cache
        return (baseWei, newCache);
    }

    function _bongMetaFor(uint256 tokenId) private view returns (uint256 baseWei, uint32 distance) {
        (uint256 rangeStart, uint256 rangeNext) = _rangeBounds(tokenId);
        if (rangeStart == 0 || tokenId < rangeStart || tokenId >= rangeNext) {
            return (DEFAULT_BASE_PER_BONG, uint32(_currentDistance(tokenId)));
        }

        uint256 cursor = tokenId;
        while (cursor >= rangeStart) {
            uint64 packed = bongMeta[cursor];
            if (packed != 0) {
                return _unpackBongMeta(packed);
            }
            if (cursor == rangeStart) break;
            unchecked {
                --cursor;
            }
        }

        return (DEFAULT_BASE_PER_BONG, uint32(_currentDistance(tokenId)));
    }

    function _winChanceFromBase(uint256 base) private pure returns (uint16) {
        if (base == 0) return 0;
        uint256 c = (base * 1000) / 1 ether;
        if (c == 0) return 1;
        if (c > 1000) return 1000;
        return uint16(c);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        _requireActiveToken(tokenId);
        if (renderer == address(0)) revert ZeroAddress();

        (uint256 base, uint32 created) = _bongMetaFor(tokenId);
        uint32 current = uint32(_currentDistance(tokenId));
        uint16 chance = _winChanceFromBase(base);

        bool isStaked = (_packedOwnershipOf(tokenId) & _BITMASK_STAKED) != 0;
        return IPurgeBongRenderer(renderer).bongTokenURI(tokenId, created, current, chance, isStaked, 0);
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
        (, uint256 rangeNext) = _rangeBounds(tokenId);
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
                if (nextId < rangeNext && _packedOwnerships[nextId] == 0) {
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
        (uint256 start, uint256 next) = _rangeBounds(tokenId);
        if (start == 0 || tokenId < start || tokenId >= next) return 0;
        packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            unchecked {
                uint256 curr = tokenId;
                while (curr > start) {
                    --curr;
                    packed = _packedOwnerships[curr];
                    if (packed != 0) break;
                }
            }
        }
    }

    function _packedOwnershipOf(uint256 tokenId) private view returns (uint256 packed) {
        (uint256 start, uint256 next) = _rangeBounds(tokenId);
        if (start == 0 || tokenId < start || tokenId >= next) revert InvalidToken();
        packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            unchecked {
                uint256 curr = tokenId;
                while (curr > start) {
                    --curr;
                    packed = _packedOwnerships[curr];
                    if (packed != 0) break;
                }
            }
        }
        if ((packed & _BITMASK_BURNED) != 0 || (packed & _BITMASK_ADDRESS) == 0) revert InvalidToken();
        return packed;
    }

    function _isActiveToken(uint256 tokenId) private view returns (bool) {
        (uint256 start, uint256 next) = _rangeBounds(tokenId);
        if (start == 0 || tokenId < start || tokenId >= next) return false;
        // Quick check for burned/claimable using the fast cursor
        if (_isInactive(tokenId)) return false;

        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed == 0 || (packed & _BITMASK_BURNED) != 0) return false;
        return address(uint160(packed)) != address(0);
    }

    function _isInactive(uint256 tokenId) private view returns (bool) {
        uint256 floor = lowestUnresolved;
        if (floor == 0) return false;

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
            (, uint256 rangeNext) = _rangeBounds(tokenId);
            if (nextId < rangeNext && _packedOwnerships[nextId] == 0) {
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
        if (floor == 0) return 0;

        startId = resolveBaseId;
        if (startId == 0 || startId < floor) {
            startId = resolveTokenCursor != 0 ? resolveTokenCursor : floor;
        }
        resolveBaseId = startId;
    }

    // The Engine: Resolves a batch of bongs.
    function _resolvePendingInternal(uint256 maxBongs, bool requirePending) private {
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

        uint256 budget = pendingResolveBudget;
        if (budget == 0) revert InsufficientEthForResolve();
        if (pendingResolveBase == 0 || lowestUnresolved == 0) {
            resolvePending = false;
            pendingRngWord = 0;
            pendingResolveBase = 0;
            pendingResolveMax = 0;
            pendingResolveBudget = 0;
            pendingRngDay = 0;
            transfersLocked = false;
            return;
        }

        uint256 limit = maxBongs == 0 ? AUTO_RESOLVE_BATCH : maxBongs;
        bool halted;
        uint256 heldCoinTotal;
        uint256 heldEthTotal;
        BongMetaCache memory metaCache;
        uint256 processed;

        // Base cursors
        uint256 baseCursor = pendingResolveBase;
        uint256 baseSliceIdx = resolveQueueCursor;
        if (baseSliceIdx >= _resolveQueue.length) {
            resolvePending = false;
            pendingRngWord = 0;
            pendingResolveBase = 0;
            pendingResolveMax = 0;
            pendingResolveBudget = 0;
            pendingRngDay = 0;
            transfersLocked = false;
            return;
        }
        ResolveSlice storage baseSlice = _resolveQueue[baseSliceIdx];
        uint256 baseSliceEnd = baseSlice.end;
        if (baseCursor < baseSlice.start) {
            baseCursor = baseSlice.start;
        }

        while (!halted && processed < limit && budget != 0) {
            // Determine next warp pivot (if any) relative to current base cursor
            (bool warpFound, uint256 warpIdx, uint256 warpPivot) = _nextActiveWarp(baseCursor);
            uint256 chunkEnd = baseSliceEnd;
            bool warpInSlice = false;
            if (warpFound) {
                if (warpPivot <= baseCursor) {
                    warpInSlice = true;
                    chunkEnd = baseCursor - 1;
                } else if (warpPivot >= baseCursor && warpPivot <= baseSliceEnd) {
                    warpInSlice = true;
                    chunkEnd = warpPivot > baseCursor ? warpPivot - 1 : baseCursor - 1;
                }
            }

            // Resolve base chunk up to chunkEnd
            while (!halted && processed < limit && baseCursor <= chunkEnd) {
                (budget, halted, heldCoinTotal, heldEthTotal, metaCache) = _resolveSingle(
                    baseCursor,
                    rngWord,
                    budget,
                    heldCoinTotal,
                    heldEthTotal,
                    metaCache
                );
                if (!halted) {
                    unchecked {
                        ++baseCursor;
                        ++processed;
                    }
                }
            }

            if (halted || processed >= limit || budget == 0) {
                break;
            }

            // If we finished the current base slice, advance to the next slice.
            if (baseCursor > baseSliceEnd) {
                _normalizeFront(baseCursor);
                resolveBaseId = lowestUnresolved;
                if (lowestUnresolved == 0 || resolveQueueCursor >= _resolveQueue.length) {
                    break;
                }
                baseSliceIdx = resolveQueueCursor;
                baseSlice = _resolveQueue[baseSliceIdx];
                baseSliceEnd = baseSlice.end;
                if (baseCursor < baseSlice.start) {
                    baseCursor = baseSlice.start;
                }
                continue;
            }

            // Process warp if pivot reached within this slice
            if (warpInSlice && baseCursor == warpPivot && processed < limit && budget != 0) {
                Warp storage w = warps[warpIdx];
                uint256 warpTok = w.cursor == 0 ? w.start : uint256(w.cursor);
                if (warpTok < w.start) warpTok = w.start;
                while (!halted && processed < limit && warpTok <= w.end) {
                    (budget, halted, heldCoinTotal, heldEthTotal, metaCache) = _resolveSingle(
                        warpTok,
                        rngWord,
                        budget,
                        heldCoinTotal,
                        heldEthTotal,
                        metaCache
                    );
                    if (!halted) {
                        unchecked {
                            ++warpTok;
                            ++processed;
                        }
                    }
                }
                w.cursor = uint128(warpTok);
                if (warpTok > w.end) {
                    w.done = true;
                    if (warpIdx == warpCursor) {
                        unchecked {
                            ++warpCursor;
                        }
                    }
                }
                if (halted || processed >= limit || budget == 0) {
                    break;
                }
                // Resume base after the pivot token
                unchecked {
                    baseCursor = warpPivot + 1;
                }
            } else {
                // No warp in this slice; nothing left to do in current loop iteration.
                break;
            }
        }

        if (heldEthTotal != 0 || heldCoinTotal != 0) {
            _distributeHeldWins(heldEthTotal, heldCoinTotal);
        }

        // Update base cursor / lowestUnresolved
        if (baseCursor > lowestUnresolved) {
            _burnInactiveUpTo(baseCursor - 1);
        }
        _normalizeFront(baseCursor);
        resolveBaseId = lowestUnresolved;

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
        return limit;
    }

    function _scheduleResolve(
        uint256 startId,
        uint48 rngDay,
        uint256 rngWord,
        uint256 maxBongs,
        uint256 budgetWei
    ) private {
        if (resolvePending) revert ResolvePendingAlready();
        if (rngWord == 0 && rngDay == 0) revert InvalidRng();
        // Resolves run only when the game has injected ETH/stETH via `payBongs`.
        if (budgetWei == 0) revert InsufficientEthForResolve();

        if (_resolveQueue.length == 0) revert InvalidToken();
        if (startId == 0) startId = lowestUnresolved;
        if (startId == 0) revert InvalidToken();

        uint256 sliceIdx = resolveQueueCursor;
        if (sliceIdx >= _resolveQueue.length) revert InvalidToken();
        ResolveSlice storage slice = _resolveQueue[sliceIdx];
        uint256 sliceStart = slice.start;
        uint256 sliceEnd = slice.end;
        if (startId < sliceStart) {
            startId = sliceStart;
        } else if (startId > sliceEnd) {
            // Try to align to a later slice
            while (sliceIdx + 1 < _resolveQueue.length && startId > sliceEnd) {
                unchecked {
                    ++sliceIdx;
                }
                slice = _resolveQueue[sliceIdx];
                sliceStart = slice.start;
                sliceEnd = slice.end;
            }
            if (startId < sliceStart) {
                startId = sliceStart;
            }
            if (startId > sliceEnd) revert InvalidToken();
        }

        uint256 plannedMax = maxBongs == 0 ? sliceEnd : startId + maxBongs - 1;
        if (plannedMax > sliceEnd) plannedMax = sliceEnd;

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

    function _decreaseTotalCoinOwed(uint256 amount) private {
        if (amount == 0) return;
        uint256 owed = totalCoinOwed;
        if (owed <= amount) {
            totalCoinOwed = 0;
        } else {
            totalCoinOwed = owed - amount;
        }
    }
    function _applyAffiliateCode(address buyer, bytes32 affiliateCode, uint256 weiSpent) private {
        address affiliate = affiliateProgram;
        if (affiliate == address(0) || weiSpent == 0) return;

        if (affiliateCode == bytes32(0)) {
            affiliateCode = IPurgeAffiliateLike(affiliate).referralCodeOf(buyer);
            if (affiliateCode == bytes32(0)) return;
        }

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
            uint256 pricePer1000 = presalePricePer1000Wei;
            if (pricePer1000 == 0) {
                pricePer1000 = PRESALE_PRICE_PER_1000_DEFAULT;
            }
            coinBase = (weiSpent * 1000 * 1e6) / pricePer1000;
        }

        uint256 pct = usedFallbackPrice ? 10 : 0;
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
        _approveStonkAllowances();
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

    function _noBongsAlive() private view returns (bool) {
        if (_mintedTotal == 0) return true;
        return burnedCount >= _mintedTotal;
    }

    function _approveStonkAllowances() private {
        address stonk_ = stonk;
        if (stonk_ == address(0)) return;

        address coin_ = coinToken;
        if (coin_ != address(0)) {
            if (!IERC20Approve(coin_).approve(stonk_, type(uint256).max)) revert CallFailed();
        }
        address st = stEthToken;
        if (st != address(0)) {
            if (!IERC20Approve(st).approve(stonk_, type(uint256).max)) revert CallFailed();
        }
    }

    function _setStonk(address stonk_) private {
        if (stonk_ == address(0)) revert ZeroAddress();
        address current = stonk;
        if (current != address(0) && current != stonk_) revert AlreadyConfigured();
        stonk = stonk_;
        _approveStonkAllowances();
    }

    function _forwardToStonk(uint256 ethAmount, uint256 coinAmount, uint256 stEthAmount) private {
        if (ethAmount == 0 && coinAmount == 0 && stEthAmount == 0) return;
        address stonkAddr = stonk;
        if (stonkAddr == address(0)) revert ZeroAddress();
        (bool ok, ) = stonkAddr.call{value: ethAmount}(
            abi.encodeWithSelector(IPurgeStonkReceiver.deposit.selector, coinAmount, stEthAmount)
        );
        if (!ok) revert CallFailed();
    }

    function _inPendingWindow(uint256 tokenId) private view returns (bool) {
        if (!resolvePending) return false;
        uint256 start = pendingResolveBase;
        uint256 end = pendingResolveMax;
        if (start == 0 || end == 0) return false;
        return tokenId >= start && tokenId <= end;
    }

    function _transfersBlocked(uint256 tokenId) private view returns (bool) {
        uint256 packed = _packedOwnershipAt(tokenId);
        return transfersLocked || (packed & _BITMASK_STAKED) != 0 || _isResolved(tokenId) || _inPendingWindow(tokenId);
    }

    function _resolveBong(
        uint256 tokenId,
        uint256 rngWord,
        uint256 basePrice,
        uint256 packed
    ) private returns (uint8 outcome, uint256 heldCoin, uint256 heldEth) {
        uint256 weight = _coinWeightMultiplier(packed);
        address owner_ = address(uint160(packed));
        uint16 chance = _winChanceFromBase(basePrice);
        uint256 roll = uint256(keccak256(abi.encodePacked(rngWord, tokenId))) % 1000;
        bool win = roll < chance;
        if (win) {
            uint256 delta = basePrice < 1 ether ? 1 ether - basePrice : 0;
            if (owner_ == address(this)) {
                uint256 coinShare;
                uint256 coinOwed = totalCoinOwed;
                if (coinOwed != 0 && bongCoin != 0) {
                    coinShare = (bongCoin * weight) / coinOwed;
                }
                if (delta != 0) {
                    totalEthOwed += delta;
                    totalCoinOwed += delta * weight;
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
                    if (delta != 0) {
                        totalEthOwed += delta;
                        totalCoinOwed += delta * weight;
                    }
                }
                outcome = 1; // claimable (GG)
            } else {
                if (delta != 0) {
                    totalEthOwed += delta;
                    totalCoinOwed += delta * weight;
                }
                _payoutLiveWinner(tokenId, packed, owner_);
                outcome = 2; // paid directly to game credit
            }
        }
        // Losing bongs are handled in _burnInactiveUpTo
        emit BongResolved(tokenId, win, chance, roll);
    }

    function _distributeHeldWins(uint256 ethAmount, uint256 coinAmount) private {
        address game_ = game;
        if (game_ == address(0)) return;

        // Handle ETH portion
        if (ethAmount != 0) {
            uint256 toGame = (ethAmount * 40) / 100;
            uint256 toFund = (ethAmount * 40) / 100;
            uint256 toSlush = ethAmount - toGame - toFund;

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

        // Handle coin portion
        if (coinAmount != 0) {
            uint256 available = bongCoin < coinAmount ? bongCoin : coinAmount;
            if (available != 0) {
                bongCoin -= available;
                uint256 toFund = available / 2;
                uint256 toSlush = available - toFund;
                if (toFund != 0) {
                    bongCoin += toFund;
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
        uint256 heldEthAcc,
        BongMetaCache memory metaCache
    )
        private
        returns (uint256 newBudget, bool stop, uint256 heldCoin, uint256 heldEth, BongMetaCache memory cacheOut)
    {
        newBudget = budget;
        heldCoin = heldCoinAcc;
        heldEth = heldEthAcc;
        cacheOut = metaCache;
        uint256 packed = _packedOwnershipAt(tokenId);
        if (packed == 0 || (packed & _BITMASK_BURNED) != 0) {
            return (newBudget, false, heldCoin, heldEth, cacheOut);
        }

        uint256 basePrice;
        (basePrice, cacheOut) = _bongBaseForResolve(tokenId, cacheOut);
        uint256 delta = basePrice >= 1 ether ? 0 : (1 ether - basePrice);
        if (newBudget < delta) return (newBudget, true, heldCoin, heldEth, cacheOut);

        (uint8 outcome, uint256 heldCoinWin, uint256 heldEthWin) = _resolveBong(tokenId, rngWord, basePrice, packed);
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
        return (newBudget, false, heldCoin, heldEth, cacheOut);
    }

    function _payoutLiveWinner(uint256 tokenId, uint256 packed, address owner_) private {
        if (owner_ == address(0)) return;

        uint256 coinWeight = _coinClaimWeight(packed);
        uint256 bongShare;
        uint256 coinOwed = totalCoinOwed;
        if (coinOwed != 0 && bongCoin != 0) {
            bongShare = (bongCoin * coinWeight) / coinOwed;
            if (bongShare != 0) {
                if (bongCoin <= bongShare) {
                    bongCoin = 0;
                } else {
                    bongCoin -= bongShare;
                }
                IERC20Minimal(coinToken).transfer(owner_, bongShare);
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

        (bool ok, ) = game_.call{value: amount}(
            abi.encodeWithSelector(IPurgeGameBongWinnings.creditBongWinnings.selector, owner_)
        );
        if (!ok) revert CallFailed();

        emit Claimed(owner_, tokenId, amount, 0, bongShare);
    }

    function _burnUnmaturedFromCursor(
        uint256 maxIds
    ) private returns (uint256 processed, uint256 burned, bool complete) {
        uint256 tid = shutdownBurnCursor;
        uint256 sliceIdx = shutdownSliceCursor;
        if (tid == 0) {
            tid = lowestUnresolved != 0 ? lowestUnresolved : _firstMintedToken();
            sliceIdx = resolveQueueCursor;
        }
        if (sliceIdx >= _resolveQueue.length) {
            sliceIdx = 0;
        }

        uint256 maxId = _lastMintedToken();
        if (maxId == 0 || tid == 0 || tid > maxId) {
            shutdownBurnCursor = tid;
            shutdownSliceCursor = sliceIdx;
            return (0, 0, true);
        }

        uint256 limit = maxIds == 0 ? 500 : maxIds;
        address ownerCursor;
        uint256 ownerBurns;

        while (processed < limit && sliceIdx < _resolveQueue.length) {
            ResolveSlice storage slice = _resolveQueue[sliceIdx];
            if (tid < slice.start) {
                tid = slice.start;
            }
            if (tid > slice.end) {
                unchecked {
                    ++sliceIdx;
                }
                continue;
            }

            uint256 sliceCap = slice.end;
            while (processed < limit && tid <= sliceCap) {
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
                        (uint256 basePrice, ) = _bongMetaFor(tid);
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

                        emit BongBurned(tid);
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

            if (tid > sliceCap) {
                unchecked {
                    ++sliceIdx;
                }
            }
        }

        if (ownerCursor != address(0) && ownerBurns != 0) {
            _applyBurnAccounting(ownerCursor, ownerBurns);
        }
        if (burned != 0) {
            burnedCount += burned;
        }

        shutdownBurnCursor = tid;
        shutdownSliceCursor = resolveQueueCursor;
        _normalizeFront(tid);

        uint256 lastMinted = _lastMintedToken();
        uint256 front = lowestUnresolved;
        if (front != 0) {
            shutdownBurnCursor = front;
        }
        complete = (sliceIdx >= _resolveQueue.length) || front == 0 || front > lastMinted;
    }

    // Cleans up losers behind the resolution cursor
    function _burnInactiveUpTo(uint256 targetId) private {
        uint256 tid = lowestUnresolved;
        uint256 sliceIdx = resolveQueueCursor;
        if (tid == 0 || targetId < tid) return;

        uint256 burned;
        address ownerCursor;
        uint256 ownerBurns;

        while (sliceIdx < _resolveQueue.length && tid <= targetId) {
            ResolveSlice storage slice = _resolveQueue[sliceIdx];
            if (tid < slice.start) {
                tid = slice.start;
            }
            if (tid > slice.end) {
                unchecked {
                    ++sliceIdx;
                }
                continue;
            }
            uint256 sliceTarget = targetId < slice.end ? targetId : slice.end;
            while (tid <= sliceTarget) {
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
                    (uint256 basePrice, ) = _bongMetaFor(tid);
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

                    emit BongBurned(tid);
                    emit Transfer(holder, address(0), tid);
                    unchecked {
                        ++burned;
                    }
                }
                unchecked {
                    ++tid;
                }
            }

            if (tid > slice.end) {
                unchecked {
                    ++sliceIdx;
                }
            }
        }

        if (ownerCursor != address(0) && ownerBurns != 0) {
            _applyBurnAccounting(ownerCursor, ownerBurns);
        }
        if (burned != 0) {
            burnedCount += burned;
        }
        _normalizeFront(tid);
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

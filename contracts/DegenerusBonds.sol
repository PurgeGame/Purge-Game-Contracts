// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoin} from "./interfaces/IDegenerusCoin.sol";
import {DegenerusBondsScoringLib} from "./libraries/DegenerusBondsScoringLib.sol";

/// @notice Minimal view into the core game to read the current level.
interface IDegenerusGameLevel {
    function level() external view returns (uint24);
    function ethMintStats(address player) external view returns (uint24 lvl, uint24 levelCount, uint24 streak);
}

/// @notice Minimal view into the game for bond banking (ETH pooling + claim credit).
interface IDegenerusGameBondBank is IDegenerusGameLevel {
    function bondDeposit(bool trackPool) external payable;
    function bondCreditToClaimable(address player, uint256 amount) external;
    function bondCreditToClaimableBatch(address[] calldata players, uint256[] calldata amounts) external;
    function bondSpendToMaps(address player, uint256 amount, uint32 quantity) external;
    function bondAvailable() external view returns (uint256);
    function mintPrice() external view returns (uint256);
}

/// @notice Minimal VRF coordinator surface for V2+ random word requests.
interface IVRFCoordinatorV2Like {
    function requestRandomWords(
        bytes32 keyHash,
        uint256 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

interface IStETHLike {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IVaultLike {
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable;
}

interface ICoinFlipCreditor {
    function creditFlip(address player, uint256 amount) external;
}

interface IDegenerusGamePricing {
    function purchaseInfo()
        external
        view
        returns (uint24 lvl, uint8 gameState, bool lastPurchaseDay, bool rngLocked, uint256 priceWei);
}

interface IAffiliatePayer {
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl,
        uint8 gameState,
        bool rngLocked
    ) external returns (uint256);
}

interface IAffiliatePresaleShutdown {
    function shutdownPresale() external;
}

interface IAffiliatePresaleStatus {
    function presaleActive() external view returns (bool);
}

/**
 * @title BondToken
 * @notice Minimal mintable/burnable ERC20 representing liquid bonds for a specific maturity level.
 */
contract BondToken {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error InsufficientBalance();
    error Disabled();
    error ZeroAddress();
    error AlreadySet();
    error InsufficientAllowance();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------
    // Immutable data
    // ---------------------------------------------------------------------
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    address private immutable minter;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool private disabled;
    address private vault;
    uint256 private _vaultMintAllowance = 50 ether; // seed vault escrow with 50 ETH worth

    constructor(string memory name_, string memory symbol_, address minter_) {
        name = name_;
        symbol = symbol_;
        minter = minter_;
    }

    // ------------------------------------------------------------------
    // ERC20 core
    // ------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _requireActive();
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _requireActive();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert Unauthorized();
        if (allowed != type(uint256).max) {
            unchecked {
                uint256 newAllowed = allowed - amount;
                allowance[from][msg.sender] = newAllowed;
                emit Approval(from, msg.sender, newAllowed);
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    // ------------------------------------------------------------------
    // Mint / burn (minter-gated mint, holder/approved burn)
    // ------------------------------------------------------------------

    function mint(address to, uint256 amount) external {
        _requireActive();
        if (msg.sender != minter) revert Unauthorized();
        unchecked {
            totalSupply += amount;
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        _requireActive();
        // The bond controller (minter) can burn without allowance; all other callers need approval.
        if (msg.sender != minter && from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed < amount) revert Unauthorized();
            if (allowed != type(uint256).max) {
                unchecked {
                    uint256 newAllowed = allowed - amount;
                    allowance[from][msg.sender] = newAllowed;
                    emit Approval(from, msg.sender, newAllowed);
                }
            }
        }
        _burn(from, amount);
    }

    // ------------------------------------------------------------------
    // Vault escrow / mint allowance
    // ------------------------------------------------------------------

    function setVault(address vault_) external {
        _requireActive();
        if (msg.sender != minter) revert Unauthorized();
        if (vault_ == address(0)) revert ZeroAddress();
        address current = vault;
        if (current == vault_) return;
        if (current != address(0)) revert AlreadySet();
        vault = vault_;
    }

    function vaultMintAllowance() external view returns (uint256) {
        return _vaultMintAllowance;
    }

    function supplyIncUncirculated() external view returns (uint256) {
        return totalSupply + _vaultMintAllowance;
    }

    function vaultEscrow(uint256 amount) external {
        _requireActive();
        if (amount == 0) return;
        address sender = msg.sender;
        if (sender != minter && sender != vault) revert Unauthorized();
        _vaultMintAllowance += amount;
    }

    function vaultMintTo(address to, uint256 amount) external {
        _requireActive();
        if (msg.sender != vault) revert Unauthorized();
        if (amount == 0) return;
        uint256 allowanceVault = _vaultMintAllowance;
        if (amount > allowanceVault) revert InsufficientAllowance();
        unchecked {
            _vaultMintAllowance = allowanceVault - amount;
            totalSupply += amount;
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _requireActive() private view {
        if (disabled) revert Disabled();
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 fromBal = balanceOf[from];
        if (fromBal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) private {
        uint256 fromBal = balanceOf[from];
        if (fromBal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /// @notice Permanently disable transfers/mint/burn; callable only by the minter (bond controller).
    function nuke() external {
        if (msg.sender != minter) revert Unauthorized();
        disabled = true;
    }
}

/**
 * @title DegenerusBonds
 * @notice Bond system wired for the Degenerus game:
 *         - Bonds mature every 10 levels (ending in 0); sales open for 5 levels per cycle.
 *         - Payout budget = series raise * growth multiplier (finalized on the last emission run).
 *         - Deposits award a score (multiplier stub) used for jackpots.
 *         - Five jackpot days mint the shared ERC20 (DGNRS); total mint equals payout budget.
 *         - Burning the ERC20 enters a two-lane final jackpot at maturity; payout ~pro-rata to burned amount.
 */
contract DegenerusBonds {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error SaleClosed();
    error InsufficientScore();
    error AlreadyResolved();
    error AlreadySet();
    error BankCallFailed();
    error PurchasesDisabled();
    error MinimumDeposit();
    error PresaleClosed();
    error NotExpired();
    error VrfLocked();
    error NotReady();
    error InvalidBps();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event BondSeriesCreated(uint24 indexed maturityLevel, uint24 saleStartLevel, address token, uint256 payoutBudget);
    event BondDeposit(address indexed player, uint24 indexed maturityLevel, uint256 amount, uint256 scoreAwarded);
    event BondJackpot(uint24 indexed maturityLevel, uint8 indexed dayIndex, uint256 mintedAmount, uint256 rngWord);
    event BondBurned(
        address indexed player,
        uint24 indexed maturityLevel,
        uint8 lane,
        uint256 amount,
        bool boostedScore
    );
    event BondSeriesResolved(
        uint24 indexed maturityLevel,
        uint8 winningLane,
        uint256 payoutEth,
        uint256 remainingToken
    );
    event BondGameOver(uint256 poolSpent, uint24 partialMaturity);
    event BondCoinJackpot(address indexed player, uint256 amount, uint24 maturityLevel, uint8 lane);
    event ExpiredSweep(uint256 ethAmount, uint256 stEthAmount);
    event PresaleBondDeposit(address indexed buyer, uint256 amount, uint256 scoreAwarded);
    event PresaleJackpot(uint8 indexed round, uint256 mintedTotal, uint256 rngWord);
    event PresaleJackpotVrfRequested(uint256 indexed requestId);

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    // Default work budget for maintenance; each unit roughly covers one series tick or archive step.
    uint32 private constant BOND_MAINT_WORK_CAP = 3;
    uint8 private constant JACKPOT_SPOTS = 100;
    uint8 private constant TOP_PCT_1 = 20;
    uint8 private constant TOP_PCT_2 = 10;
    uint8 private constant TOP_PCT_3 = 5;
    uint8 private constant TOP_PCT_4 = 5;
    uint256 private constant MIN_DEPOSIT = 0.01 ether;
    uint8 private constant PRESALE_MAX_RUNS = 5;
    uint8 private constant PRESALE_JACKPOT_SPOTS = 100; // single presale draw per round; doubled winner count
    uint256 private constant PRESALE_PREV_RAISE = 50 ether;
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;
    uint8 private constant AUTO_BURN_UNSET = 0;
    uint8 private constant AUTO_BURN_ENABLED = 1;
    uint8 private constant AUTO_BURN_DISABLED = 2;
    // ---------------------------------------------------------------------
    // Data structures
    // ---------------------------------------------------------------------
    struct LaneEntry {
        address player;
        uint256 amount;
    }

    struct Lane {
        uint256 total;
        LaneEntry[] entries;
        uint256[] cumulative;
        mapping(address => uint256) burnedAmount;
    }

    struct WireConfig {
        address game;
        address vault;
        address coin;
        address vrfCoordinator;
        uint256 vrfSubId;
        bytes32 vrfKeyHash;
        address questModule;
        address trophies;
        address affiliate;
    }

    struct BondSeries {
        uint24 maturityLevel;
        uint24 saleStartLevel;
        uint256 payoutBudget;
        uint256 mintedBudget;
        uint256 raised;
        uint8 jackpotsRun;
        uint24 lastJackpotLevel;
        uint256 totalScore;
        BondToken token;
        address[] jackpotParticipants;
        uint256[] jackpotCumulative;
        Lane[2] lanes;
        bool resolved;
        uint8 winningLane;
        uint256 decSharePrice;
        uint256 unclaimedBudget;
    }

    struct PresaleSeries {
        uint256 payoutBudget;
        uint256 mintedBudget;
        uint256 raised;
        uint8 jackpotsRun;
        uint256 totalScore;
        address[] jackpotParticipants;
        uint256[] jackpotCumulative;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    mapping(uint24 => BondSeries) internal series;
    uint24[] internal maturities;
    uint24 private activeMaturityIndex;
    uint256 private resolvedUnclaimedTotal;
    IDegenerusGameLevel private game;
    uint256 private coinOwed; // running total of BURNIE owed for bond jackpots
    address private immutable admin;
    uint256 private lastIssuanceRaise;
    uint24 private lastBondMaintenanceLevel; // last level where bondMaintenance() ran (used for burn routing at maturity boundaries)
    address private vrfCoordinator;
    bytes32 private vrfKeyHash;
    uint256 private vrfSubscriptionId;
    uint256 private vrfRequestId;
    uint256 private vrfPendingWord;
    bool private vrfRequestPending;
    uint256 private presaleVrfRequestId;
    uint256 private presaleVrfPendingWord;
    bool private presaleVrfRequestPending;
    bool private firstSeriesBudgetFinalized;
    bool public gameOverStarted; // true after game signals shutdown; disables new deposits and bank pushes
    uint48 private gameOverTimestamp; // timestamp when game over was triggered
    bool public gameOverEntropyAttempted; // true after gameOver() attempts to fetch entropy (request or failure)
    bool private rngLock; // true while game has locked RNG usage (pauses deposits/burns)
    uint16 public rewardStakeTargetBps; // target share of stETH (in bps) for game-held reward liquidity
    uint16 private constant AFFILIATE_BOND_BPS = 300; // 3% on bond purchases
    uint16 private constant AFFILIATE_PRESALE_BPS = 1000; // 10% on presale bond purchases
    uint256 private constant PRICE_WEI = 0.025 ether;
    uint256 private constant PRICE_COIN_UNIT = 1_000_000_000;
    uint256 private constant PRESALE_COIN_ALLOCATION = 2_000 * PRICE_COIN_UNIT; // 2m BURNIE (6 decimals)
    address private vault;
    address private coin;
    address private affiliate;
    address private questModule;
    address private trophies;
    BondToken private tokenDGNRS;
    mapping(address => uint8) private autoBurnDgnrsPref;
    address private immutable steth;
    uint256 private presalePendingRewardEth;
    uint256 private presalePendingYieldEth;
    PresaleSeries private presale;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address admin_, address steth_) {
        if (admin_ == address(0)) revert Unauthorized();
        if (steth_ == address(0)) revert Unauthorized();
        admin = admin_;
        steth = steth_;
        rewardStakeTargetBps = 10_000;

        // Predeploy the shared bond token used across all active maturities.
        tokenDGNRS = new BondToken("Degenerus Bond DGNRS", "DGNRS", address(this));
    }

    modifier onlyGame() {
        if (msg.sender != address(game)) revert Unauthorized();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------------
    // External write API
    // ---------------------------------------------------------------------

    /// @notice Wire bonds like other modules: [game, vault, coin, vrfCoordinator, questModule, trophies, affiliate] + subId/keyHash (partial allowed).
    function wire(address[] calldata addresses, uint256 vrfSubId, bytes32 vrfKeyHash_) external onlyAdmin {
        _wire(
            WireConfig({
                game: addresses.length > 0 ? addresses[0] : address(0),
                vault: addresses.length > 1 ? addresses[1] : address(0),
                coin: addresses.length > 2 ? addresses[2] : address(0),
                vrfCoordinator: addresses.length > 3 ? addresses[3] : address(0),
                questModule: addresses.length > 4 ? addresses[4] : address(0),
                trophies: addresses.length > 5 ? addresses[5] : address(0),
                affiliate: addresses.length > 6 ? addresses[6] : address(0),
                vrfSubId: vrfSubId,
                vrfKeyHash: vrfKeyHash_
            })
        );
    }

    /// @notice Emergency VRF rewire; callable only by the admin contract.
    /// @dev Intended to be called from the admin's emergencyRecover flow once the game has been declared stalled.
    function emergencySetVrf(address coordinator_, uint256 subId, bytes32 keyHash_) external onlyAdmin {
        if (coordinator_ == address(0) || keyHash_ == bytes32(0) || subId == 0) revert Unauthorized();

        vrfCoordinator = coordinator_;
        vrfSubscriptionId = subId;
        vrfKeyHash = keyHash_;

        // Clear any pending request from a dead coordinator so a fresh request can be issued.
        vrfRequestPending = false;
        vrfRequestId = 0;
        vrfPendingWord = 0;
        presaleVrfRequestPending = false;
        presaleVrfRequestId = 0;
        presaleVrfPendingWord = 0;
    }

    /// @notice Configure the target stETH share (in bps) for game-held liquidity; 0 disables staking.
    function setRewardStakeTargetBps(uint16 bps) external onlyAdmin {
        if (bps > 10_000) revert InvalidBps();
        rewardStakeTargetBps = bps;
    }

    /// @notice Game hook to pause/resume bond purchases and burns while RNG is locked for jackpots.
    function setRngLock(bool locked) external onlyGame {
        rngLock = locked;
    }

    /// @notice Player toggle to auto-burn any DGNRS minted from bond jackpots.
    /// @dev Defaults to disabled during presale; defaults to enabled once presale ends.
    function setAutoBurnDgnrs(bool enabled) external {
        autoBurnDgnrsPref[msg.sender] = enabled ? AUTO_BURN_ENABLED : AUTO_BURN_DISABLED;
    }

    /// @notice Presale-only bond purchase; splits ETH 30% vault / 50% rewardPool / 20% yieldPool and records score for manual jackpots.
    /// @dev Gated by the affiliate presale flag; callable before full wiring when presale bonuses accrue as off-chain credits.
    function presaleDeposit(address beneficiary) external payable returns (uint256 scoreAwarded) {
        if (gameOverStarted) revert SaleClosed();
        uint256 amount = msg.value;
        if (amount < MIN_DEPOSIT) revert MinimumDeposit();
        if (rngLock) revert PurchasesDisabled();

        address aff = affiliate;
        if (aff == address(0) || !IAffiliatePresaleStatus(aff).presaleActive()) revert PresaleClosed();

        _getOrCreateSeries(0);

        address vaultAddr = vault;
        address gameAddr = address(game);
        if (vaultAddr == address(0)) revert NotReady();

        uint256 vaultShare = (amount * 30) / 100;
        uint256 rewardShare = (amount * 50) / 100;
        uint256 yieldShare = amount - vaultShare - rewardShare; // 20%

        IVaultLike(vaultAddr).deposit{value: vaultShare}(0, 0);
        // Presale should not depend on the game being wired; cache the game shares until wiring.
        if (gameAddr == address(0)) {
            if (rewardShare != 0) presalePendingRewardEth += rewardShare;
            if (yieldShare != 0) presalePendingYieldEth += yieldShare;
        } else {
            _sendEthOrRevert(gameAddr, rewardShare);
            if (yieldShare != 0) {
                IDegenerusGameBondBank(gameAddr).bondDeposit{value: yieldShare}(false);
            }
        }

        address ben = beneficiary == address(0) ? msg.sender : beneficiary;
        _payAffiliateReward(ben, amount, AFFILIATE_PRESALE_BPS);
        scoreAwarded = amount;

        PresaleSeries storage p = presale;
        p.totalScore = _recordScore(p.jackpotParticipants, p.jackpotCumulative, p.totalScore, ben, scoreAwarded);
        p.raised += amount;
        if (p.payoutBudget < p.raised) {
            p.payoutBudget = p.raised;
        }

        emit PresaleBondDeposit(ben, amount, scoreAwarded);
    }

    /// @notice Run one presale jackpot round (0-4); mints DGNRS to weighted winners.
    /// @dev Manual trigger; callable only by the admin contract. Final round applies a growth multiplier
    ///      anchored to a fixed previous raise of 50 ETH.
    function runPresaleJackpot() external onlyAdmin returns (bool advanced) {
        (uint256 rngWord, bool requested) = _prepareEntropy(0, true);
        if (rngWord == 0) {
            if (requested) return false;
            revert NotReady();
        }

        PresaleSeries storage p = presale;
        uint8 run = p.jackpotsRun;
        if (run >= PRESALE_MAX_RUNS) revert AlreadyResolved();
        uint24 currLevel = _presaleActive() ? 0 : _currentLevelOrZero();

        if (p.payoutBudget < p.raised) {
            p.payoutBudget = p.raised;
        }
        bool isFinalRun = (run + 1 == PRESALE_MAX_RUNS);

        if (run != 0) {
            uint256 coinPayout;
            if (run == 1) {
                coinPayout = PRESALE_COIN_ALLOCATION / 20; // 5%
            } else {
                coinPayout = PRESALE_COIN_ALLOCATION / 10; // 10% for runs 2-4
            }
            if (coinPayout != 0) _payCoinJackpot(coinPayout, rngWord, true);
        }

        if (isFinalRun) {
            uint256 finalBudget = _targetBudget(p.raised, PRESALE_PREV_RAISE);
            if (finalBudget == 0) return false;
            p.payoutBudget = finalBudget;
            if (p.mintedBudget >= finalBudget) return false;

            uint256 toMint = finalBudget - p.mintedBudget;
            if (toMint != 0 && p.totalScore != 0) {
                _runMintJackpotToken(
                    tokenDGNRS,
                    p.jackpotParticipants,
                    p.jackpotCumulative,
                    p.totalScore,
                    rngWord,
                    toMint,
                    PRESALE_JACKPOT_SPOTS,
                    currLevel
                );
                p.mintedBudget = finalBudget;
                uint256 vaultMint = finalBudget / 10;
                if (vaultMint != 0) {
                    tokenDGNRS.vaultEscrow(vaultMint);
                }
                emit PresaleJackpot(run, toMint, rngWord);
            }
        } else {
            if (p.payoutBudget == 0 || p.mintedBudget >= p.payoutBudget) return false;

            uint256 pct = _emissionPct(0, run, true);
            if (pct == 0) return false;

            uint256 toMint = (p.raised * pct) / 100;
            uint256 available = p.payoutBudget - p.mintedBudget;
            if (toMint > available) toMint = available;

            if (toMint != 0 && p.totalScore != 0) {
                _runMintJackpotToken(
                    tokenDGNRS,
                    p.jackpotParticipants,
                    p.jackpotCumulative,
                    p.totalScore,
                    rngWord,
                    toMint,
                    PRESALE_JACKPOT_SPOTS,
                    currLevel
                );
                p.mintedBudget += toMint;
                emit PresaleJackpot(run, toMint, rngWord);
            }
        }

        p.jackpotsRun = run + 1;
        return true;
    }

    /// @notice Close presale and lock the presale payout budget to presale raise * growth factor.
    /// @dev Calls affiliate.shutdownPresale() (best effort) and finalizes once; reverts if no presale raise.
    function shutdownPresale() external onlyAdmin {
        if (firstSeriesBudgetFinalized) revert AlreadySet();

        (uint256 rngWord, bool requested) = _prepareEntropy(0, true);
        if (rngWord == 0) {
            if (requested) return;
            revert NotReady();
        }
        uint256 coinPayout = (PRESALE_COIN_ALLOCATION * 13) / 20; // 65%
        if (coinPayout != 0) {
            _payCoinJackpot(coinPayout, rngWord, true);
        }

        // Attempt to close presale on the affiliate contract.
        address affiliateAddr = affiliate;
        if (affiliateAddr != address(0)) {
            try IAffiliatePresaleShutdown(affiliateAddr).shutdownPresale() {} catch {}
        }

        PresaleSeries storage p = presale;
        uint256 raised = p.raised;
        if (raised == 0) revert NotReady();

        uint256 target = _targetBudget(raised, PRESALE_PREV_RAISE);
        if (target > p.payoutBudget) {
            p.payoutBudget = target;
        }

        address gameAddr = address(game);
        if ((presalePendingRewardEth != 0 || presalePendingYieldEth != 0) && gameAddr == address(0)) revert NotReady();
        if (gameAddr != address(0)) {
            _flushPresaleProceedsToGame(gameAddr);
        }
        firstSeriesBudgetFinalized = true;
    }

    /// @notice Unified deposit: external callers route ETH into the current maturity.
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded) {
        if (msg.sender == address(game)) revert Unauthorized(); // game should use depositFromGame; split handled in-game
        address ben = beneficiary == address(0) ? msg.sender : beneficiary;
        uint256 amount = msg.value;
        scoreAwarded = _processDeposit(ben, amount, false);
    }

    /// @notice Game-only deposit that credits the current maturity; ETH split is handled in-game.
    function depositFromGame(address beneficiary, uint256 amount) external returns (uint256 scoreAwarded) {
        if (msg.sender != address(game)) revert Unauthorized();
        scoreAwarded = _processDeposit(beneficiary, amount, true);
    }

    /// @notice Funding shim used by the game to accrue jackpot coin for bonds.
    /// @dev During normal operation ETH/stETH are forwarded to the vault; during shutdown they stay here for `gameOver()`.
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable onlyGame {
        uint256 pulledStEth;
        if (stEthAmount != 0) {
            uint256 beforeBal = _stEthBalance();
            try IStETHLike(steth).transferFrom(msg.sender, address(this), stEthAmount) {} catch {}
            uint256 afterBal = _stEthBalance();
            if (afterBal > beforeBal) {
                pulledStEth = afterBal - beforeBal;
            }
        }
        if (coinAmount != 0) {
            coinOwed += coinAmount;
        }
        _runCoinJackpot(rngWord);
        if (gameOverStarted) return;
        if (msg.value != 0 || pulledStEth != 0) {
            IVaultLike(vault).deposit{value: msg.value}(0, pulledStEth);
        }
    }

    // ---------------------------------------------------------------------
    // Internals (coin jackpot)
    // ---------------------------------------------------------------------

    function _runCoinJackpot(uint256 rngWord) private {
        if (rngWord == 0) return;
        uint256 bankroll = coinOwed >> 1; // pay half of the accrued coin
        if (bankroll == 0) return;
        bool paid = _payCoinJackpot(bankroll, rngWord, false);
        if (paid) {
            coinOwed -= bankroll;
        }
    }

    function _payCoinJackpot(uint256 amount, uint256 rngWord, bool isPresale) private returns (bool paid) {
        if (amount == 0 || rngWord == 0) return false;
        address coinAddr = coin;

        BondSeries storage target;
        uint24 targetMat;
        if (isPresale) {
            targetMat = 0;
            target = series[0];
            if (target.resolved) return false;
        } else {
            uint24 currLevel = _currentLevel();
            (target, targetMat) = _selectActiveSeries(currLevel);
            if (targetMat == 0) return false;
        }

        // Pick a lane with entries.
        (uint8 lane, bool ok) = _pickNonEmptyLane(target.lanes, rngWord);
        if (!ok) return false;

        address winner = _weightedLanePick(target.lanes[lane], rngWord);
        if (winner == address(0)) return false;

        ICoinFlipCreditor(coinAddr).creditFlip(winner, amount);
        emit BondCoinJackpot(winner, amount, targetMat, lane);
        return true;
    }

    function _selectActiveSeries(uint24 currLevel) private view returns (BondSeries storage s, uint24 maturityLevel) {
        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; ) {
            BondSeries storage iter = series[maturities[i]];
            // Consider unresolved series that can still accept burns (before maturity) or are in grace window.
            if (!iter.resolved && currLevel < iter.maturityLevel) {
                maturityLevel = iter.maturityLevel;
                return (iter, maturityLevel);
            }
            unchecked {
                ++i;
            }
        }
        s = series[0]; // dummy slot; caller checks maturityLevel==0 before use
        maturityLevel = 0;
        return (s, maturityLevel);
    }

    function notifyGameOver() external {
        if (msg.sender != address(game)) revert Unauthorized();
        if (!gameOverStarted) {
            gameOverStarted = true;
            gameOverTimestamp = uint48(block.timestamp);
        }
    }

    /// @notice Used by jackpot bond buys; when false, jackpots should pay ETH instead of bonds.
    function purchasesEnabled() external view returns (bool) {
        if (gameOverStarted) return false;
        if (address(game) == address(0)) return false;
        return _bondPurchasesOpen(_currentLevel());
    }

    /// @notice Emergency shutdown path: consume all ETH/stETH and resolve maturities in order, partially paying the last one.
    /// @dev If no entropy is ready, this requests VRF (if configured) and exits; call again once fulfilled.
    function gameOver() external payable {
        if (msg.sender != address(game) && !gameOverStarted) revert Unauthorized();
        if (!gameOverStarted) {
            gameOverStarted = true;
            gameOverTimestamp = uint48(block.timestamp);
        }

        (uint256 entropy, ) = _prepareEntropy(0, false);
        gameOverEntropyAttempted = true;
        if (entropy == 0) return;

        uint256 initialEth = address(this).balance;
        uint256 initialStEth = _stEthBalance();
        uint256 rollingEntropy = entropy;
        uint24 partialMaturity;

        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; ) {
            BondSeries storage s = series[maturities[i]];
            unchecked {
                ++i;
            }
            if (s.resolved) continue;

            uint256 burned = s.lanes[0].total + s.lanes[1].total;
            if (burned == 0) {
                s.resolved = true;
                continue;
            }

            uint256 availableValue = address(this).balance + _stEthBalance();
            if (availableValue == 0) {
                partialMaturity = s.maturityLevel;
                s.resolved = true;
                break;
            }

            uint256 payout = burned <= availableValue ? burned : availableValue;
            uint256 paid = _resolveSeriesGameOver(s, rollingEntropy, payout);
            rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "go")));

            s.resolved = true;

            if (paid < burned) {
                partialMaturity = s.maturityLevel;
                break;
            }
        }

        // Mark any remaining series as resolved and nuke their tokens.
        for (uint24 j = activeMaturityIndex; j < len; ) {
            BondSeries storage rem = series[maturities[j]];
            unchecked {
                ++j;
            }
            if (rem.resolved) continue;
            rem.resolved = true;
        }

        uint256 remainingEth = address(this).balance;
        uint256 remainingStEth = _stEthBalance();
        uint256 spent = (initialEth + initialStEth) - (remainingEth + remainingStEth);

        uint256 totalReserved = resolvedUnclaimedTotal;
        for (uint24 k = activeMaturityIndex; k < len; ) {
            totalReserved += series[maturities[k]].unclaimedBudget;
            unchecked {
                ++k;
            }
        }

        // Any surplus after resolving in order is forwarded to the vault if configured (stETH preferred).
        if (remainingEth > totalReserved && vault != address(0)) {
            uint256 surplus = remainingEth - totalReserved;
            if (surplus != 0) {
                address gameAddr = address(game);
                uint256 stBal = _stEthBalance();
                if (stBal >= surplus && gameAddr != address(0)) {
                    IDegenerusGameBondBank(gameAddr).bondDeposit{value: surplus}(false);
                    IVaultLike(vault).deposit{value: 0}(0, surplus);
                } else {
                    IVaultLike(vault).deposit{value: surplus}(0, 0);
                }
                remainingEth -= surplus;
            }
        }

        emit BondGameOver(spent, partialMaturity);
    }

    /// @notice Sweep all funds (ETH + stETH) to the vault 1 year after game over.
    /// @dev Callable by anyone; destination is fixed to the vault.
    function sweepExpiredPools() external {
        if (gameOverTimestamp == 0) revert Unauthorized();
        if (block.timestamp <= gameOverTimestamp + 365 days) revert NotExpired();

        address v = vault;
        if (v == address(0)) revert BankCallFailed();

        uint256 ethBal = address(this).balance;
        uint256 stBal = _stEthBalance();
        if (ethBal != 0 || stBal != 0) {
            IVaultLike(v).deposit{value: ethBal}(0, stBal);
        }

        emit ExpiredSweep(ethBal, stBal);
    }

    function _processDeposit(
        address beneficiary,
        uint256 amount,
        bool fromGame
    ) private returns (uint256 scoreAwarded) {
        if (amount == 0) revert SaleClosed();
        if (!fromGame && amount < MIN_DEPOSIT) revert MinimumDeposit();
        if (gameOverStarted) revert SaleClosed();
        if (!fromGame && rngLock) revert PurchasesDisabled();

        (uint24 currLevel, uint24 mintLevelCount, uint24 mintStreak) = game.ethMintStats(beneficiary);
        if (!_bondPurchasesOpen(currLevel)) revert PurchasesDisabled();
        uint24 maturityLevel = _activeMaturityAt(currLevel);
        BondSeries storage s = _getOrCreateSeries(maturityLevel);

        if (!fromGame) {
            // Split ETH: direct purchases (40% vault, preferring stETH from game; 20% bondPool, 10% reward,
            // 30% yield). If we pay the vault in stETH, route the vault-share ETH back to the game as a swap.
            uint256 vaultShare = (amount * 40) / 100;
            uint256 bondShare = (amount * 20) / 100;
            uint256 rewardShare = (amount * 10) / 100;
            uint256 yieldShare = amount - bondShare - rewardShare - vaultShare;

            address vaultAddr = vault;
            if (vaultAddr == address(0)) revert BankCallFailed();
            address gameAddr = address(game);

            bool usedStEth;
            if (vaultShare != 0 && gameAddr != address(0)) {
                uint256 stBal;
                try IStETHLike(steth).balanceOf(gameAddr) returns (uint256 b) {
                    stBal = b;
                } catch {}
                if (stBal >= vaultShare) {
                    bool pulled;
                    try IStETHLike(steth).transferFrom(gameAddr, address(this), vaultShare) returns (bool ok) {
                        pulled = ok;
                    } catch {}
                    if (pulled) {
                        IVaultLike(vaultAddr).deposit{value: 0}(0, vaultShare);
                        usedStEth = true;
                    }
                }
            }
            if (vaultShare != 0 && !usedStEth) {
                IVaultLike(vaultAddr).deposit{value: vaultShare}(0, 0);
            } else if (vaultShare != 0) {
                // Swap path: vault got stETH; send the vault-share ETH to the game.
                IDegenerusGameBondBank(gameAddr).bondDeposit{value: vaultShare}(false);
            }

            if (bondShare != 0) {
                IDegenerusGameBondBank(gameAddr).bondDeposit{value: bondShare}(true);
            }
            if (yieldShare != 0) {
                IDegenerusGameBondBank(gameAddr).bondDeposit{value: yieldShare}(false);
            }
            if (rewardShare != 0) {
                _sendEthOrRevert(gameAddr, rewardShare);
            }
        }

        scoreAwarded = _scoreWithMultiplier(beneficiary, amount, currLevel, mintLevelCount, mintStreak);
        if (!fromGame) {
            _payAffiliateReward(beneficiary, amount, AFFILIATE_BOND_BPS);
            address coinAddr = coin;
            if (coinAddr != address(0)) {
                IDegenerusCoin(coinAddr).notifyQuestBond(beneficiary, amount);
            }
        }

        // Append new weight slice for jackpot selection (append-only cumulative for O(log N) sampling).
        s.totalScore = _recordScore(s.jackpotParticipants, s.jackpotCumulative, s.totalScore, beneficiary, scoreAwarded);
        s.raised += amount;
        // Ensure payout budget never trails total deposits for this maturity.
        if (s.payoutBudget < s.raised) {
            s.payoutBudget = s.raised;
        }

        emit BondDeposit(beneficiary, maturityLevel, amount, scoreAwarded);
    }

    function _payAffiliateReward(address buyer, uint256 ethAmount, uint16 bps) private {
        if (bps == 0 || ethAmount == 0) return;
        address aff = affiliate;
        if (aff == address(0)) return;

        uint24 level;
        uint256 priceWei;
        uint8 gameState;
        bool rngLocked;
        address gameAddr = address(game);
        if (gameAddr != address(0)) {
            (level, gameState, , rngLocked, priceWei) = IDegenerusGamePricing(gameAddr).purchaseInfo();
        } else {
            priceWei = PRICE_WEI;
        }

        uint256 coinEquivalent = (ethAmount * PRICE_COIN_UNIT) / priceWei;
        uint256 reward = (coinEquivalent * uint256(bps)) / 10_000;

        IAffiliatePayer(aff).payAffiliate(reward, bytes32(0), buyer, level, gameState, rngLocked);
    }

    function _activeMaturityAt(uint24 currLevel) private view returns (uint24 maturityLevel) {
        if (_presaleActive()) {
            return 0; // presale burns route into the level-0 maturity
        }
        if (currLevel < 10) {
            return 10; // pregame levels route into the first maturity (level 10)
        }
        // Single-token bond cycle is 10 levels wide: maturities are levels ending in 0.
        maturityLevel = ((currLevel / 10) + 1) * 10;
    }

    function _bondPurchasesOpen(uint24 currLevel) private pure returns (bool open) {
        // Real game levels are 1-indexed; treat level 0 as a closed window.
        if (currLevel == 0) return false;
        // Bootstrap window: levels 1-5 sell into maturity 10 (stop at 6).
        if (currLevel < 10) return currLevel < 6;
        // Thereafter: open for 5 levels per 10 (e.g., 10-14, 20-24, ...).
        return (currLevel % 10) < 5;
    }

    /// @notice Run bond maintenance for the current level (create series, run jackpots, resolve funded maturities).
    /// @param rngWord Entropy used for jackpots and lane selection.
    /// @param workCapOverride Optional work budget override; 0 uses the built-in default.
    ///        Budget units are coarse “work ticks” (series iterations/archive steps), not gas.
    /// @return done True when the maintenance pass completed without hitting the work cap.
    function bondMaintenance(uint256 rngWord, uint32 workCapOverride) external onlyGame returns (bool done) {
        uint32 workCap = workCapOverride == 0 ? BOND_MAINT_WORK_CAP : workCapOverride;
        uint32 workUsed;
        uint24 currLevel = _currentLevel();
        lastBondMaintenanceLevel = currLevel;
        bool hitCap;

        // Ensure the active series exists.
        _getOrCreateSeries(_activeMaturityAt(currLevel));
        uint256 rollingEntropy = rngWord;
        bool backlogPending;
        // Run jackpots and resolve matured series.
        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; ) {
            if (workUsed >= workCap) {
                hitCap = true;
                break;
            }

            BondSeries storage s = series[maturities[i]];
            unchecked {
                ++i;
            }
            if (s.resolved) continue;
            bool consumedWork;

            uint8 maxRuns = _maxEmissionRuns(s.maturityLevel);
            uint24 emissionStop = s.maturityLevel > 5 ? s.maturityLevel - 5 : 0; // stop 5 levels before maturity
            if (s.maturityLevel == 10) emissionStop = 6; // bootstrap window: levels 1-5
            if (
                currLevel >= s.saleStartLevel &&
                currLevel < emissionStop &&
                s.jackpotsRun < maxRuns &&
                s.lastJackpotLevel != currLevel
            ) {
                _runJackpotsForDay(s, rollingEntropy, currLevel);
                rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, s.jackpotsRun)));
                consumedWork = true;
            }

            if (currLevel >= s.maturityLevel && !s.resolved) {
                if (_isFunded(s) && !backlogPending) {
                    bool resolved = _resolveSeries(s, rollingEntropy);
                    if (resolved) {
                        rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "resolve")));
                    } else {
                        backlogPending = true;
                    }
                } else {
                    backlogPending = true; // enforce oldest-first resolution
                }
                consumedWork = true;
            }

            if (consumedWork) {
                unchecked {
                    ++workUsed;
                }
            }
        }

        // Archive fully resolved series to save gas on future iterations
        while (!hitCap && activeMaturityIndex < len) {
            if (workUsed >= workCap) {
                hitCap = true;
                break;
            }

            BondSeries storage s = series[maturities[activeMaturityIndex]];
            if (s.resolved) {
                resolvedUnclaimedTotal += s.unclaimedBudget;
                unchecked {
                    ++activeMaturityIndex;
                    ++workUsed;
                }
            } else {
                break;
            }
        }

        // Sweep excess if possible; does not affect work flag.
        if (!hitCap) {
            _sweepExcessToVault();
        }

        // Note: rngLock is controlled by the game to prevent post-RNG manipulation windows.
        done = !hitCap;
        return done;
    }

    /// @notice Burn DGNRS to enter the active jackpot.
    function burnDGNRS(uint256 amount) external {
        if (amount == 0) revert InsufficientScore();
        if (gameOverStarted) revert SaleClosed();
        if (rngLock) revert PurchasesDisabled();

        bool presaleActive = _presaleActive();
        uint24 currLevel;
        uint24 mintLevelCount;
        uint24 mintStreak;
        if (presaleActive) {
            currLevel = 0;
        } else {
            if (address(game) == address(0)) revert NotReady();
            (currLevel, mintLevelCount, mintStreak) = game.ethMintStats(msg.sender);
        }
        _burnDgnrsFor(msg.sender, amount, currLevel, mintLevelCount, mintStreak, true);
    }

    /// @dev bondMaintenance runs mid-level; before the first maintenance pass for the current level,
    ///      treat burns as if they occurred on the prior level so burns can still enter the maturity
    ///      that is about to resolve.
    function _burnEffectiveLevel(uint24 currLevel) private view returns (uint24 level) {
        level = currLevel;
        if (currLevel != 0 && lastBondMaintenanceLevel < currLevel) {
            unchecked {
                level = currLevel - 1;
            }
        }
    }

    function _burnDgnrsFor(
        address player,
        uint256 amount,
        uint24 currLevel,
        uint24 mintLevelCount,
        uint24 mintStreak,
        bool burnToken
    ) private {
        uint24 burnLevel = _burnEffectiveLevel(currLevel);
        uint24 targetMat = _activeMaturityAt(burnLevel);
        (BondSeries storage target, uint24 resolvedTargetMat) = _nextActiveSeries(targetMat, burnLevel);
        if (burnToken) {
            tokenDGNRS.burn(player, amount);
        }

        (uint8 lane, bool boosted) = _registerBurn(
            target,
            resolvedTargetMat,
            amount,
            currLevel,
            player,
            mintLevelCount,
            mintStreak
        );
        emit BondBurned(player, resolvedTargetMat, lane, amount, boosted);
    }

    /// @notice Claim Decimator share for a resolved bond series.
    function claim(uint24 maturityLevel) external {
        BondSeries storage s = series[maturityLevel];
        if (!s.resolved) revert SaleClosed(); // Reusing SaleClosed or similar "NotReady" error

        uint256 price = s.decSharePrice;
        if (price == 0) return;

        uint8 lane = s.winningLane;
        uint256 burned = s.lanes[lane].burnedAmount[msg.sender];
        if (burned == 0) return;

        s.lanes[lane].burnedAmount[msg.sender] = 0;
        uint256 payout = (burned * price) / 1e18;

        uint256 budgetBefore = s.unclaimedBudget;
        if (s.unclaimedBudget >= payout) {
            s.unclaimedBudget -= payout;
        } else {
            s.unclaimedBudget = 0;
        }

        uint256 delta = budgetBefore - s.unclaimedBudget;
        if (delta != 0) {
            // If this series is archived (skipped in main loops), update the global tracker.
            bool isArchived = false;
            uint24 head = activeMaturityIndex;
            if (head > 0) {
                if (head == maturities.length) {
                    isArchived = true;
                } else if (maturityLevel < series[maturities[head]].maturityLevel) {
                    isArchived = true;
                }
            }
            if (isArchived) {
                resolvedUnclaimedTotal -= delta;
            }
        }

        if (!_creditPayout(msg.sender, payout)) {
            // If payout fails, revert state (though _creditPayout mostly handles failure by returning false)
            // Here we just revert to allow retry later if it was a transient failure
            revert BankCallFailed();
        }
    }

    function _nextActiveSeries(
        uint24 maturityLevel,
        uint24 effectiveLevel
    ) private returns (BondSeries storage target, uint24 targetMaturity) {
        targetMaturity = maturityLevel;
        target = _getOrCreateSeries(targetMaturity);
        if (targetMaturity == 0) {
            if (_presaleActive() && !target.resolved) {
                return (target, targetMaturity);
            }
            unchecked {
                targetMaturity = 10;
            }
            target = _getOrCreateSeries(targetMaturity);
        }
        // Once a maturity has arrived or been resolved, redirect new burns to the next (+10) maturity.
        while (effectiveLevel >= targetMaturity || target.resolved) {
            unchecked {
                targetMaturity += 10;
            }
            target = _getOrCreateSeries(targetMaturity);
        }
    }

    function _registerBurn(
        BondSeries storage s,
        uint24 maturityLevel,
        uint256 amount,
        uint24 currLevel,
        address player,
        uint24 mintLevelCount,
        uint24 mintStreak
    ) private returns (uint8 lane, bool boosted) {
        // Deterministic lane assignment based on maturity level and player address (laneHint ignored).
        lane = uint8(uint256(keccak256(abi.encodePacked(maturityLevel, player))) & 1);

        s.lanes[lane].entries.push(LaneEntry({player: player, amount: amount}));
        s.lanes[lane].total += amount;
        s.lanes[lane].burnedAmount[player] += amount;
        s.lanes[lane].cumulative.push(s.lanes[lane].total);

        // While DGNRS is still being minted for this series, count burns toward mint jackpot score as well.
        if (currLevel == 0) {
            if (_presaleActive()) {
                PresaleSeries storage p = presale;
                p.totalScore = _recordScore(p.jackpotParticipants, p.jackpotCumulative, p.totalScore, player, amount);
                boosted = true;
            }
        } else if (currLevel < s.maturityLevel && s.jackpotsRun < 5 && s.mintedBudget < s.payoutBudget) {
            uint256 boostedScore = _scoreWithMultiplier(player, amount, currLevel, mintLevelCount, mintStreak);
            s.totalScore = _recordScore(s.jackpotParticipants, s.jackpotCumulative, s.totalScore, player, boostedScore);
            boosted = true;
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function dgnrsToken() external view returns (address) {
        return address(tokenDGNRS);
    }

    /// @notice Required cover with early stop if the total exceeds stopAt (0 disables early stop).
    function requiredCoverNext(uint256 stopAt) external view returns (uint256 required) {
        return _requiredCoverNext(stopAt);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _requiredCoverNext(uint256 stopAt) private view returns (uint256 required) {
        uint24 currLevel = _currentLevel();
        uint256 dgnrsSupply = tokenDGNRS.supplyIncUncirculated();
        uint256 upcomingBurned = _upcomingBurnedCover(currLevel);
        if (stopAt == 0) {
            uint256 maturedOwedAll = _maturedOwedCover(currLevel, 0);
            return maturedOwedAll + dgnrsSupply + upcomingBurned;
        }
        uint256 overhead = dgnrsSupply + upcomingBurned;
        if (overhead > stopAt) return _capStopAt(stopAt);
        uint256 stopAtAdj = stopAt - overhead;
        uint256 maturedOwedAdj = _maturedOwedCover(currLevel, stopAtAdj);
        if (maturedOwedAdj > stopAtAdj) return _capStopAt(stopAt);
        return maturedOwedAdj + overhead;
    }

    function _maturedOwedCover(uint24 currLevel, uint256 stopAt) private view returns (uint256 owed) {
        owed = resolvedUnclaimedTotal;
        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; ) {
            BondSeries storage s = series[maturities[i]];
            if (s.maturityLevel > currLevel) break;
            if (s.resolved) {
                owed += s.unclaimedBudget;
            } else {
                owed += s.lanes[0].total + s.lanes[1].total;
            }
            if (stopAt != 0 && owed > stopAt) {
                return _capStopAt(stopAt);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _upcomingBurnedCover(uint24 currLevel) private view returns (uint256 burned) {
        uint24 burnLevel = _burnEffectiveLevel(currLevel);
        uint24 targetMat = _activeMaturityAt(burnLevel);
        if (targetMat == 0) {
            BondSeries storage presaleSeries = series[targetMat];
            if (_presaleActive() && !presaleSeries.resolved) {
                return presaleSeries.lanes[0].total + presaleSeries.lanes[1].total;
            }
            targetMat = 10;
        }
        while (burnLevel >= targetMat || series[targetMat].resolved) {
            unchecked {
                targetMat += 10;
            }
        }
        BondSeries storage target = series[targetMat];
        burned = target.lanes[0].total + target.lanes[1].total;
    }

    function _capStopAt(uint256 stopAt) private pure returns (uint256 capped) {
        return stopAt == type(uint256).max ? stopAt : stopAt + 1;
    }

    function _wire(WireConfig memory cfg) private {
        _setGame(cfg.game);
        _setVault(cfg.vault);
        _setCoin(cfg.coin);
        _setAffiliate(cfg.affiliate);
        _setQuestModule(cfg.questModule);
        _setTrophies(cfg.trophies);
        _setVrf(cfg.vrfCoordinator, cfg.vrfSubId, cfg.vrfKeyHash);
    }

    function _currentLevel() private view returns (uint24) {
        return game.level();
    }

    function _currentLevelOrZero() private view returns (uint24) {
        IDegenerusGameLevel g = game;
        if (address(g) == address(0)) return 0;
        return g.level();
    }

    function _presaleActive() private view returns (bool active) {
        address aff = affiliate;
        if (aff == address(0)) return false;
        try IAffiliatePresaleStatus(aff).presaleActive() returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _scoreWithMultiplier(
        address player,
        uint256 baseScore,
        uint24 currLevel,
        uint24 mintLevelCount,
        uint24 mintStreak
    ) private view returns (uint256) {
        return
            DegenerusBondsScoringLib.scoreWithMultiplier(
                affiliate,
                questModule,
                trophies,
                player,
                baseScore,
                currLevel,
                mintLevelCount,
                mintStreak
            );
    }

    function _prepareEntropy(uint256 provided, bool isPresale) private returns (uint256 entropy, bool requested) {
        if (provided != 0) return (provided, false);

        if (isPresale) {
            entropy = presaleVrfPendingWord;
            if (entropy != 0) {
                presaleVrfPendingWord = 0;
                rngLock = false;
                return (entropy, false);
            }
            if (presaleVrfRequestPending) return (0, true);
        } else {
            entropy = vrfPendingWord;
            if (entropy != 0) {
                vrfPendingWord = 0;
                return (entropy, false);
            }
            if (vrfRequestPending) return (0, true);
        }

        if (vrfCoordinator == address(0) || vrfSubscriptionId == 0 || vrfKeyHash == bytes32(0)) return (0, false);

        try
            IVRFCoordinatorV2Like(vrfCoordinator).requestRandomWords(
                vrfKeyHash,
                vrfSubscriptionId,
                VRF_REQUEST_CONFIRMATIONS,
                VRF_CALLBACK_GAS_LIMIT,
                1
            )
        returns (uint256 reqId) {
            if (isPresale) {
                presaleVrfRequestPending = true;
                presaleVrfRequestId = reqId;
                rngLock = true;
                emit PresaleJackpotVrfRequested(reqId);
            } else {
                vrfRequestPending = true;
                vrfRequestId = reqId;
            }
            return (0, true);
        } catch {
            return (0, false);
        }
    }

    function _isFunded(BondSeries storage s) private view returns (bool) {
        uint24 currLevel = _currentLevel();
        uint256 available = _availableBank();
        (uint256 totalRequired, ) = _requiredCoverTotals(s, currLevel, available);
        return available >= totalRequired;
    }

    function _requiredCover(BondSeries storage s, uint24 currLevel) private view returns (uint256 required) {
        if (s.resolved) return s.unclaimedBudget;

        uint256 burned = s.lanes[0].total + s.lanes[1].total;
        if (currLevel >= s.maturityLevel) {
            required = burned; // maturity reached/past: cover actual burns only
        } else {
            // Upcoming maturity: cover all potential burns (full budget for that cycle).
            required = s.payoutBudget;
        }
    }

    function _requiredCoverTotals(
        BondSeries storage target,
        uint24 currLevel,
        uint256 stopAt
    ) private view returns (uint256 total, uint256 current) {
        total = resolvedUnclaimedTotal;
        uint24 len = uint24(maturities.length);
        uint24 targetMat = target.maturityLevel;
        for (uint24 i = activeMaturityIndex; i < len; ) {
            BondSeries storage iter = series[maturities[i]];
            unchecked {
                ++i;
            }
            uint256 req = _requiredCover(iter, currLevel);
            total += req;
            if (iter.maturityLevel == targetMat) {
                current = req;
            }
            if (stopAt != 0 && total > stopAt) {
                // Signal that we already exceed the available cover; caller will bail early.
                uint256 capped = stopAt == type(uint256).max ? stopAt : stopAt + 1;
                return (capped, current);
            }
        }
    }

    function _availableBank() private view returns (uint256 available) {
        if (!gameOverStarted) {
            return IDegenerusGameBondBank(address(game)).bondAvailable();
        }
        return address(this).balance + _stEthBalance();
    }

    function _stEthBalance() private view returns (uint256 bal) {
        try IStETHLike(steth).balanceOf(address(this)) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _sendEthOrRevert(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert BankCallFailed();
    }

    function _sweepExcessToVault() private returns (bool swept) {
        address v = vault;
        if (v == address(0)) return false;
        if (!gameOverStarted) return false;

        uint256 required = resolvedUnclaimedTotal;
        uint256 bal = address(this).balance;
        if (bal <= required) return false;
        uint24 currLevel = _currentLevel();
        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; ) {
            BondSeries storage s = series[maturities[i]];
            unchecked {
                ++i;
            }
            required += _requiredCover(s, currLevel);
            if (required >= bal) {
                return false;
            }
        }

        uint256 excess = bal - required;
        address gameAddr = address(game);
        uint256 stBal = _stEthBalance();
        if (stBal >= excess && gameAddr != address(0)) {
            IDegenerusGameBondBank(gameAddr).bondDeposit{value: excess}(false);
            IVaultLike(v).deposit{value: 0}(0, excess);
            swept = true;
        } else {
            IVaultLike(v).deposit{value: excess}(0, 0);
            swept = true;
        }
    }

    function _createSeries(uint24 maturityLevel) private {
        BondSeries storage s = series[maturityLevel];
        s.maturityLevel = maturityLevel;
        if (maturityLevel == 10) {
            s.saleStartLevel = 1;
        } else {
            s.saleStartLevel = maturityLevel > 10 ? maturityLevel - 10 : 0;
        }

        // Budget starts at 0 and is derived from this series' own raise (tracked on deposits).
        s.payoutBudget = 0;

        // Single shared ERC20 across all active series.
        s.token = tokenDGNRS;

        maturities.push(maturityLevel);
        emit BondSeriesCreated(maturityLevel, s.saleStartLevel, address(s.token), 0);
    }

    function _setGame(address game_) private {
        if (game_ == address(0)) return;
        address current = address(game);
        if (current != address(0)) revert AlreadySet();
        game = IDegenerusGameLevel(game_);
    }

    function _flushPresaleProceedsToGame(address gameAddr) private {
        if (gameAddr == address(0)) revert NotReady();
        uint256 rewardEth = presalePendingRewardEth;
        uint256 yieldEth = presalePendingYieldEth;
        if (rewardEth == 0 && yieldEth == 0) return;

        presalePendingRewardEth = 0;
        presalePendingYieldEth = 0;

        _sendEthOrRevert(gameAddr, rewardEth);
        if (yieldEth != 0) {
            IDegenerusGameBondBank(gameAddr).bondDeposit{value: yieldEth}(false);
        }

    }

    function _setVault(address vault_) private {
        if (vault_ == address(0)) return;
        address current = vault;
        if (current != address(0)) revert AlreadySet();
        vault = vault_;
        tokenDGNRS.setVault(vault_);
        if (!IStETHLike(steth).approve(vault_, type(uint256).max)) revert BankCallFailed();
    }

    function _setCoin(address coin_) private {
        if (coin_ == address(0)) return;
        address current = coin;
        if (current != address(0)) revert AlreadySet();
        coin = coin_;
    }

    function _setAffiliate(address affiliate_) private {
        if (affiliate_ == address(0)) return;
        address current = affiliate;
        if (current != address(0)) revert AlreadySet();
        affiliate = affiliate_;
    }

    function _setQuestModule(address questModule_) private {
        if (questModule_ == address(0)) return;
        address current = questModule;
        if (current != address(0)) revert AlreadySet();
        questModule = questModule_;
    }

    function _setTrophies(address trophies_) private {
        if (trophies_ == address(0)) return;
        address current = trophies;
        if (current != address(0)) revert AlreadySet();
        trophies = trophies_;
    }

    function _setVrf(address coordinator_, uint256 subId, bytes32 keyHash_) private {
        if (coordinator_ == address(0) && keyHash_ == bytes32(0) && subId == 0) return;
        if (coordinator_ == address(0) || keyHash_ == bytes32(0) || subId == 0) revert Unauthorized();

        address currentCoord = vrfCoordinator;
        bytes32 currentKey = vrfKeyHash;
        uint256 currentSub = vrfSubscriptionId;

        // Initial wiring when unset.
        if (currentCoord == address(0)) {
            vrfCoordinator = coordinator_;
            vrfSubscriptionId = subId;
            vrfKeyHash = keyHash_;
            return;
        }

        // No-op if unchanged.
        if (coordinator_ == currentCoord && keyHash_ == currentKey && subId == currentSub) {
            return;
        }

        revert VrfLocked(); // Rewiring after initial set is disallowed; use the admin emergency path.
    }

    function _getOrCreateSeries(uint24 maturityLevel) private returns (BondSeries storage s) {
        s = series[maturityLevel];
        if (address(s.token) == address(0)) {
            _createSeries(maturityLevel);
            s = series[maturityLevel];
        }
    }

    function _recordScore(
        address[] storage participants,
        uint256[] storage cumulative,
        uint256 totalScore,
        address player,
        uint256 score
    ) private returns (uint256 newTotal) {
        if (player == address(0) || score == 0) return totalScore;
        newTotal = totalScore + score;
        participants.push(player);
        cumulative.push(newTotal);
    }

    function _runJackpotsForDay(BondSeries storage s, uint256 rngWord, uint24 currLevel) private {
        uint8 maxRuns = _maxEmissionRuns(s.maturityLevel);
        bool isFinalRun = (s.jackpotsRun + 1 == maxRuns);

        // Emissions:
        // - First runs: mint a % of ETH raised so far (new money in).
        // - Final run: set payoutBudget = raised * multiplier and mint the remaining amount.
        if (isFinalRun) {
            uint256 finalBudget = _targetBudget(s.raised, lastIssuanceRaise);
            if (finalBudget == 0) return;
            s.payoutBudget = finalBudget;
            if (s.mintedBudget >= finalBudget) return;

            uint256 toMint = finalBudget - s.mintedBudget;
            if (toMint != 0 && s.totalScore != 0) {
                s.mintedBudget = finalBudget;
                _runMintJackpotToken(
                    s.token,
                    s.jackpotParticipants,
                    s.jackpotCumulative,
                    s.totalScore,
                    rngWord,
                    toMint,
                    JACKPOT_SPOTS,
                    currLevel
                );
                uint256 vaultMint = finalBudget / 10;
                if (vaultMint != 0) {
                    tokenDGNRS.vaultEscrow(vaultMint);
                }
                emit BondJackpot(s.maturityLevel, s.jackpotsRun, toMint, rngWord);
            }
        } else {
            if (s.payoutBudget == 0 || s.mintedBudget >= s.payoutBudget) return;

            uint256 pct = _emissionPct(s.maturityLevel, s.jackpotsRun, false);
            if (pct == 0) return;

            uint256 toMint = (s.raised * pct) / 100;
            uint256 available = s.payoutBudget - s.mintedBudget;
            if (toMint > available) toMint = available;

            if (toMint != 0 && s.totalScore != 0) {
                s.mintedBudget += toMint;
                _runMintJackpotToken(
                    s.token,
                    s.jackpotParticipants,
                    s.jackpotCumulative,
                    s.totalScore,
                    rngWord,
                    toMint,
                    JACKPOT_SPOTS,
                    currLevel
                );
                emit BondJackpot(s.maturityLevel, s.jackpotsRun, toMint, rngWord);
            }
        }

        unchecked {
            s.jackpotsRun += 1;
        }
        s.lastJackpotLevel = currLevel;
    }

    function _emissionPct(uint24 maturityLevel, uint8 run, bool isPresale) private pure returns (uint256) {
        maturityLevel; // reserved for future schedule tweaks
        if (isPresale) {
            if (run < 4) return 10;
            return 0;
        }
        if (run == 0) return 10;
        if (run == 1) return 10;
        if (run == 2) return 10;
        if (run == 3) return 10;
        if (run == 4) return 60;
        return 0;
    }

    function _maxEmissionRuns(uint24 maturityLevel) private pure returns (uint8) {
        maturityLevel; // reserved for future schedule tweaks
        return 5;
    }

    // Piecewise sliding multiplier: 3x at 0.5x prior raise, 2x at 1x, 1x at 2x; clamped outside.
    function _growthMultiplierBpsWithPrev(uint256 raised, uint256 prevRaise) private pure returns (uint256) {
        if (prevRaise == 0 || raised == 0) return 20000;

        uint256 ratio = (raised * 1e18) / prevRaise; // 1e18 == 1.0
        if (ratio <= 5e17) return 30000; // <=0.5x -> 3.0x
        if (ratio <= 1e18) {
            // Linear from 3.0x at 0.5 to 2.0x at 1.0: 4 - 2r
            return 40000 - (20000 * ratio) / 1e18;
        }
        if (ratio <= 2e18) {
            // Linear from 2.0x at 1.0 to 1.0x at 2.0: 3 - r
            return 20000 - (10000 * (ratio - 1e18)) / 1e18;
        }
        return 10000; // >=2x -> 1.0x
    }

    function _targetBudget(uint256 raised, uint256 prevRaise) private pure returns (uint256) {
        uint256 growthBps = _growthMultiplierBpsWithPrev(raised, prevRaise);
        uint256 target = (raised * growthBps) / 10000;
        return target < raised ? raised : target;
    }


    function _jackpotPayouts(uint256 toMint, uint8 spots) private pure returns (uint256[6] memory payouts) {
        if (toMint == 0) return payouts;
        payouts[0] = (toMint * TOP_PCT_1) / 100;
        payouts[1] = (toMint * TOP_PCT_2) / 100;
        payouts[2] = (toMint * TOP_PCT_3) / 100;
        payouts[3] = (toMint * TOP_PCT_4) / 100;
        uint256 rest = toMint - payouts[0] - payouts[1] - payouts[2] - payouts[3];
        uint256 totalSpots = uint256(spots);
        if (totalSpots <= 4) {
            // Degenerate case: no "other" spots. (We only call with >= 50.)
            payouts[3] += rest;
            return payouts;
        }
        uint256 otherCount = totalSpots - 4;
        if (otherCount == 0) {
            payouts[5] = rest;
            return payouts;
        }
        payouts[4] = rest / otherCount;
        if (otherCount <= 1) {
            payouts[5] = rest;
        } else {
            payouts[5] = rest - (payouts[4] * (otherCount - 1));
        }
    }

    function _autoBurnEnabled(address player, bool presaleActive) private view returns (bool enabled) {
        uint8 pref = autoBurnDgnrsPref[player];
        if (pref == AUTO_BURN_ENABLED) return true;
        if (pref == AUTO_BURN_DISABLED) return false;
        return !presaleActive;
    }

    function _runMintJackpotToken(
        BondToken token,
        address[] storage participants,
        uint256[] storage cumulative,
        uint256 totalScore,
        uint256 rngWord,
        uint256 toMint,
        uint8 spots,
        uint24 currLevel
    ) private {
        uint256[6] memory payouts = _jackpotPayouts(toMint, spots);
        uint256 entropy = rngWord;
        bool presaleActive = _presaleActive();
        bool canAutoBurn = currLevel != 0 || presaleActive;

        for (uint256 i; i < 4; ) {
            uint256 amount = payouts[i];
            if (amount != 0) {
                address winner = _weightedPickFrom(participants, cumulative, totalScore, entropy);
                if (canAutoBurn && _autoBurnEnabled(winner, presaleActive)) {
                    if (currLevel == 0) {
                        _burnDgnrsFor(winner, amount, currLevel, 0, 0, false);
                    } else {
                        (, uint24 mintLevelCount, uint24 mintStreak) = game.ethMintStats(winner);
                        _burnDgnrsFor(winner, amount, currLevel, mintLevelCount, mintStreak, false);
                    }
                } else {
                    token.mint(winner, amount);
                }
            }
            unchecked {
                ++i;
            }
            if (i < 4) {
                entropy = _nextEntropy(entropy, i);
            }
        }

        uint256 totalSpots = uint256(spots);
        for (uint256 i = 4; i < totalSpots; ) {
            entropy = _nextEntropy(entropy, i);
            uint256 amount = (i == totalSpots - 1) ? payouts[5] : payouts[4];
            if (amount != 0) {
                address winner = _weightedPickFrom(participants, cumulative, totalScore, entropy);
                if (canAutoBurn && _autoBurnEnabled(winner, presaleActive)) {
                    if (currLevel == 0) {
                        _burnDgnrsFor(winner, amount, currLevel, 0, 0, false);
                    } else {
                        (, uint24 mintLevelCount, uint24 mintStreak) = game.ethMintStats(winner);
                        _burnDgnrsFor(winner, amount, currLevel, mintLevelCount, mintStreak, false);
                    }
                } else {
                    token.mint(winner, amount);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _pickNonEmptyLane(Lane[2] storage lanes, uint256 rngWord) private view returns (uint8 lane, bool ok) {
        lane = uint8(rngWord & 1);
        if (lanes[lane].total == 0) {
            uint8 other = lane ^ 1;
            if (lanes[other].total != 0) lane = other;
        }
        ok = lanes[lane].total != 0;
    }

    function _drawBuckets(uint256 drawPool) private pure returns (uint256[14] memory buckets) {
        if (drawPool == 0) return buckets;
        uint256 ones = drawPool / 100; // 1%
        buckets[0] = (drawPool * 20) / 100;
        buckets[1] = (drawPool * 10) / 100;
        buckets[2] = (drawPool * 5) / 100;
        buckets[3] = (drawPool * 5) / 100;
        for (uint256 i = 4; i < 14; ) {
            buckets[i] = ones;
            unchecked {
                ++i;
            }
        }
    }

    function _payDrawBuckets(
        Lane storage chosen,
        uint8 lane,
        uint256 rngWord,
        uint256 drawPool,
        bool liveGame
    ) private returns (uint256 paid) {
        if (drawPool == 0) return 0;
        uint256[14] memory buckets = _drawBuckets(drawPool);

        address[] memory payoutWinners;
        uint256[] memory payoutAmounts;
        uint256 payoutCount;
        uint256 mapPrice;
        uint8 mapParity;
        if (liveGame) {
            payoutWinners = new address[](14);
            payoutAmounts = new uint256[](14);
            mapPrice = IDegenerusGameBondBank(address(game)).mintPrice() / 4;
            mapParity = uint8(rngWord & 1);
        }

        uint256 localEntropy = rngWord;
        for (uint256 k = 0; k < 14; ) {
            uint256 bucketIdx = k;
            uint256 prize = buckets[bucketIdx];
            unchecked {
                ++k;
            }
            if (prize == 0) continue;
            localEntropy = uint256(keccak256(abi.encode(localEntropy, k, lane)));
            address winner = _weightedLanePick(chosen, localEntropy);
            if (winner == address(0)) continue;

            if (liveGame) {
                bool isSmallBucket = bucketIdx >= 4;
                // Convert half of the 1% buckets into MAP rewards during live play.
                bool mapBucket = isSmallBucket && (((bucketIdx - 4) & 1) == mapParity);
                if (mapBucket && mapPrice != 0) {
                    uint256 qty = prize / mapPrice;
                    if (qty != 0) {
                        if (qty > type(uint32).max) qty = type(uint32).max;
                        IDegenerusGameBondBank(address(game)).bondSpendToMaps(winner, prize, uint32(qty));
                        paid += prize;
                        continue;
                    }
                }
                payoutWinners[payoutCount] = winner;
                payoutAmounts[payoutCount] = prize;
                unchecked {
                    ++payoutCount;
                }
                paid += prize;
            } else if (_creditPayout(winner, prize)) {
                paid += prize;
            }
        }

        if (liveGame && payoutCount != 0) {
            _creditPayoutBatch(payoutWinners, payoutAmounts, payoutCount);
        }
    }

    function _resolveSeriesGameOver(
        BondSeries storage s,
        uint256 rngWord,
        uint256 payout
    ) private returns (uint256 paid) {
        if (payout == 0) return 0;
        (uint8 lane, bool ok) = _pickNonEmptyLane(s.lanes, rngWord);
        if (!ok) return 0;

        Lane storage chosen = s.lanes[lane];
        uint256 decPool = payout / 2;
        uint256 drawPool = payout - decPool;

        // Decimator slice: proportional to burned amount (score).
        s.winningLane = lane;
        if (chosen.total > 0) {
            s.decSharePrice = (decPool * 1e18) / chosen.total;
            s.unclaimedBudget = decPool;
            paid += decPool;
        }

        // Ticketed draws on the remaining pool: 20%, 10%, 5%, 5%, 1% x10.
        if (drawPool != 0) {
            paid += _payDrawBuckets(chosen, lane, rngWord, drawPool, false);
        }
    }

    function _resolveSeries(BondSeries storage s, uint256 rngWord) private returns (bool resolved) {
        if (s.resolved) return true;
        uint24 currLevel = _currentLevel();
        uint256 burned = s.lanes[0].total + s.lanes[1].total;
        uint256 available = _availableBank();
        (uint256 totalRequired, uint256 currentRequired) = _requiredCoverTotals(s, currLevel, available);
        if (available < totalRequired) return false;

        uint256 otherRequired = totalRequired - currentRequired;
        uint256 maxSpend = available - otherRequired;
        uint256 payout = burned;
        if (payout > maxSpend) return false;

        if (burned == 0) {
            s.resolved = true;
            uint256 raised = s.raised;
            if (raised != 0) lastIssuanceRaise = raised;
            emit BondSeriesResolved(s.maturityLevel, 0, 0, 0);
            return true;
        }

        uint256 distributable = burned;

        (uint8 lane, bool ok) = _pickNonEmptyLane(s.lanes, rngWord);
        if (!ok) return false;

        Lane storage chosen = s.lanes[lane];
        uint256 paid;
        if (distributable != 0) {
            uint256 decPool = distributable / 2;
            uint256 drawPool = distributable - decPool;

            // Decimator slice: proportional to burned amount (score).
            // Converted to Pull/Claim pattern to avoid O(N) loop.
            s.winningLane = lane;
            if (chosen.total > 0) {
                s.decSharePrice = (decPool * 1e18) / chosen.total;
                s.unclaimedBudget = decPool;
            }

            // Ticketed draws on the remaining pool: 20%, 10%, 5%, 5%, 1% x10.
            if (drawPool != 0) {
                bool liveGame = !gameOverStarted;
                paid += _payDrawBuckets(chosen, lane, rngWord, drawPool, liveGame);
            }
        }

        s.resolved = true;
        uint256 raisedFinal = s.raised;
        if (raisedFinal != 0) lastIssuanceRaise = raisedFinal;
        emit BondSeriesResolved(s.maturityLevel, lane, paid, 0);
        return true;
    }

    function _weightedLanePick(Lane storage lane, uint256 entropy) private view returns (address) {
        uint256 total = lane.total;
        if (total == 0) return address(0);
        uint256 len = lane.cumulative.length;
        if (len == 0) return address(0);
        uint256 target = entropy % total;
        uint256 idx = _upperBound(lane.cumulative, target);
        if (idx >= len) return lane.entries[len - 1].player;
        return lane.entries[idx].player;
    }

    function _creditPayout(address player, uint256 amount) private returns (bool) {
        if (amount == 0) return true;
        if (!gameOverStarted) {
            IDegenerusGameBondBank(address(game)).bondCreditToClaimable(player, amount);
            return true;
        }
        uint256 remaining = amount;
        uint256 ethBal = address(this).balance;
        if (ethBal != 0) {
            uint256 toSend = ethBal >= remaining ? remaining : ethBal;
            (bool sent, ) = player.call{value: toSend}("");
            if (sent) {
                remaining -= toSend;
            }
        }
        if (remaining != 0) {
            address stEthToken = steth;
            try IStETHLike(stEthToken).transfer(player, remaining) returns (bool ok) {
                if (!ok) return false;
            } catch {
                return false;
            }
        }
        return true;
    }

    function _creditPayoutBatch(address[] memory winners, uint256[] memory amounts, uint256 count) private {
        if (count == 0) return;
        assembly {
            mstore(winners, count)
            mstore(amounts, count)
        }
        IDegenerusGameBondBank(address(game)).bondCreditToClaimableBatch(winners, amounts);
    }

    function _upperBound(uint256[] storage arr, uint256 target) private view returns (uint256 idx) {
        uint256 low;
        uint256 high = arr.length;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (arr[mid] > target) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    function _weightedPickFrom(
        address[] storage participants,
        uint256[] storage cumulative,
        uint256 totalScore,
        uint256 entropy
    ) private view returns (address) {
        if (totalScore == 0) return address(0);
        uint256 len = cumulative.length;
        if (len == 0) return address(0);
        uint256 target = entropy % totalScore;
        uint256 idx = _upperBound(cumulative, target);
        if (idx >= len) return participants[len - 1];
        return participants[idx];
    }

    function _nextEntropy(uint256 entropy, uint256 salt) private pure returns (uint256) {
        unchecked {
            entropy ^= entropy << 32;
            entropy ^= entropy >> 13;
            entropy ^= entropy << 7;
            return entropy ^ (salt * 0x9E3779B97F4A7C15);
        }
    }

    /// @notice VRF callback entrypoint.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != vrfCoordinator) revert Unauthorized();
        if (randomWords.length == 0) return;

        if (presaleVrfRequestPending && requestId == presaleVrfRequestId) {
            presaleVrfRequestPending = false;
            presaleVrfPendingWord = randomWords[0];
            return;
        }

        if (!vrfRequestPending || requestId != vrfRequestId) return;
        vrfRequestPending = false;
        vrfPendingWord = randomWords[0];
    }
}

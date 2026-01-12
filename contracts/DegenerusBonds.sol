// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoin} from "./interfaces/IDegenerusCoin.sol";
import {IStETH} from "./interfaces/IStETH.sol";
import {ContractAddresses} from "./ContractAddresses.sol";

/// @title DegenerusBonds - Bond system with 10-level maturity cycles and two-lane resolution
/// @author Burnie Degenerus

/// @notice Minimal view into the core game to read the current level.
/// @dev Used by bonds to determine which series is active and player multipliers.
interface IDegenerusGameLevel {
    /// @notice Get the current game level (1-indexed).
    function level() external view returns (uint24);
    /// @notice Get a player's bonus multiplier (bps, 10000 = 1x).
    function playerBonusMultiplier(address player) external view returns (uint256);
    /// @notice Get the prize pool target for the current cycle.
    function prizePoolTargetView() external view returns (uint256);
    /// @notice Get the prize pool accumulated for the next level.
    function nextPrizePoolView() external view returns (uint256);
}

/// @notice Minimal game interface for RNG access.
interface IDegenerusGameRng {
    function lastRngWord() external view returns (uint256);
    function rngLocked() external view returns (bool);
}

/// @notice Extended game interface for bond banking operations.
/// @dev Used for ETH pooling, claim credits, and map purchases.
interface IDegenerusGameBondBank is IDegenerusGameLevel {
    /// @notice Deposit ETH to game pools.
    /// @param trackPool If true, adds to tracked bond pool; if false, to general yield pool.
    function bondDeposit(bool trackPool) external payable;
    /// @notice Credit claimable winnings to a player.
    function bondCreditToClaimable(address player, uint256 amount) external;
    /// @notice Batch credit claimable winnings to multiple players.
    function bondCreditToClaimableBatch(address[] calldata players, uint256[] calldata amounts) external;
    /// @notice Spend bond pool funds to purchase maps for a player.
    function bondSpendToMaps(address player, uint256 amount, uint32 quantity) external;
    /// @notice Get available ETH in the bond pool.
    function bondAvailable() external view returns (uint256);
    /// @notice Get current mint price per map.
    function mintPrice() external view returns (uint256);
}

/// @notice Vault interface for depositing ETH and stETH.
interface IVaultLike {
    /// @notice Deposit ETH and/or stETH to the vault.
    /// @param coinAmount Unused (reserved for future coin deposits).
    /// @param stEthAmount Amount of stETH to deposit (requires prior approval).
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable;
}

/// @notice Game interface for pricing and state information.
interface IDegenerusGamePricing {
    /// @notice Get current purchase info for affiliate reward calculation.
    /// @return lvl Current game level.
    /// @return gameState Current FSM state.
    /// @return lastPurchaseDay Whether this is the last purchase day of the level.
    /// @return rngLocked Whether VRF is locked.
    /// @return priceWei Current mint price in wei.
    function purchaseInfo()
        external
        view
        returns (uint24 lvl, uint8 gameState, bool lastPurchaseDay, bool rngLocked, uint256 priceWei);
}

/// @notice Affiliate interface for paying referral rewards.
interface IAffiliatePayer {
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl
    ) external returns (uint256);
}

/// @notice Affiliate interface for shutting down presale.
interface IAffiliatePresaleShutdown {
    function shutdownPresale() external;
}

/// @notice Affiliate interface for checking presale status.
interface IAffiliatePresaleStatus {
    function presaleActive() external view returns (uint8);
}

// ===================================================================================================
//                                     BOND TOKEN (ERC20)
// ===================================================================================================

/**
 * @title BondToken
 * @notice Minimal mintable/burnable ERC20 representing liquid bonds (DGNRS).
 * @dev Shared across all bond series. Predeployed with the bonds contract as ContractAddresses.BONDS.
 *
 * FEATURES:
 * - Standard ERC20 (transfer, transferFrom, approve)
 * - Minter-controlled mint/burn
 * - Vault escrow system for pre-allocated liquidity
 * - Nuke function to permanently disable all operations
 *
 * SECURITY:
 * - Only ContractAddresses.BONDS (DegenerusBonds) can mint tokens
 * - Only ContractAddresses.BONDS can burn without approval
 * - Vault mint allowance provides capped liquidity provision
 * - Disabled flag prevents all operations after game shutdown
 */
contract BondToken {
    // =====================================================================
    //                              ERRORS
    // =====================================================================

    /// @notice Thrown when caller lacks permission for the operation.
    error Unauthorized();
    /// @notice Thrown when transfer/burn amount exceeds balance.
    error InsufficientBalance();
    /// @notice Thrown when operations attempted after token is nuked.
    error Disabled();
    /// @notice Thrown when vault mint exceeds allowance.
    error InsufficientAllowance();

    // =====================================================================
    //                              EVENTS
    // =====================================================================

    /// @notice Emitted on token transfer (including mint/burn with zero addresses).
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted on approval changes.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // =====================================================================
    //                          IMMUTABLE DATA
    // =====================================================================

    /// @notice Token name ("Degenerus Bond DGNRS").
    string public constant name = "Degenerus Bond";
    /// @notice Token symbol ("DGNRS").
    string public constant symbol = "DGNRS";
    /// @notice Token decimals (18, standard ERC20).
    uint8 public constant decimals = 18;
    /// @notice The only address allowed to mint tokens (DegenerusBonds contract).

    // =====================================================================
    //                            STORAGE
    // =====================================================================

    /// @notice Total tokens in circulation (excludes vault allowance).
    uint256 public totalSupply;
    /// @notice Token balance per address.
    mapping(address => uint256) public balanceOf;
    /// @notice Spending allowances (owner → spender → amount).
    mapping(address => mapping(address => uint256)) public allowance;
    /// @notice When true, all operations are permanently disabled.
    bool private disabled;
    /// @notice Pre-allocated mint allowance for vault liquidity provision.
    /// @dev Starts at 50 ETH equivalent; vault can mint up to this without new allocation.
    uint256 private _vaultMintAllowance = 50 ether;

    // =====================================================================
    //                           ERC20 CORE
    // =====================================================================

    /**
     * @notice Approve a spender to transfer tokens on behalf of the caller.
     * @dev Standard ERC20 approve. No active check (approvals work even when disabled).
     * @param spender Address authorized to spend.
     * @param amount Maximum amount spender can transfer.
     * @return Always returns true.
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Transfer tokens to another address.
     * @dev Reverts if token is disabled or insufficient balance.
     * @param to Recipient address.
     * @param amount Amount to transfer.
     * @return Always returns true on success.
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        _requireActive();
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfer tokens on behalf of another address (requires approval).
     * @dev Reverts if token is disabled, insufficient balance, or insufficient allowance.
     *      Infinite allowance (type(uint256).max) is not decremented.
     * @param from Address to transfer from.
     * @param to Recipient address.
     * @param amount Amount to transfer.
     * @return Always returns true on success.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _requireActive();
        uint256 allowed = allowance[from][msg.sender];
        // SECURITY: Check allowance before spending.
        if (allowed < amount) revert Unauthorized();
        // Gas optimization: don't update infinite allowance.
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

    // =====================================================================
    //                        MINT / BURN
    // =====================================================================

    /**
     * @notice Mint new tokens to an address.
     * @dev Only callable by ContractAddresses.BONDS (DegenerusBonds). Reverts if disabled.
     *      Used for jackpot emissions.
     * @param to Recipient address.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external {
        _requireActive();
        // SECURITY: Only ContractAddresses.BONDS can create new tokens.
        if (msg.sender != ContractAddresses.BONDS) revert Unauthorized();
        unchecked {
            totalSupply += amount;
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn tokens from an address.
     * @dev Minter can burn without approval; others need approval or self-burn.
     *      Reverts if disabled.
     * @param from Address to burn from.
     * @param amount Amount to burn.
     */
    function burn(address from, uint256 amount) external {
        _requireActive();
        // SECURITY: Minter can burn without allowance (for bond redemption).
        // Others need to be the owner or have sufficient allowance.
        if (msg.sender != ContractAddresses.BONDS && from != msg.sender) {
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

    // =====================================================================
    //                     VAULT ESCROW / MINT ALLOWANCE
    // =====================================================================

    /**
     * @notice Get the current vault mint allowance.
     * @return The amount the vault can still mint.
     */
    function vaultMintAllowance() external view returns (uint256) {
        return _vaultMintAllowance;
    }

    /**
     * @notice Get total supply including uncirculated vault allowance.
     * @dev Used for reserve calculations (total potential supply).
     * @return Total circulating + vault allowance.
     */
    function supplyIncUncirculated() external view returns (uint256) {
        return totalSupply + _vaultMintAllowance;
    }

    /**
     * @notice Add to the vault's mint allowance (escrow more tokens).
     * @dev Only callable by ContractAddresses.BONDS or vault. Used when new series needs liquidity.
     * @param amount Amount to add to vault allowance.
     */
    function vaultEscrow(uint256 amount) external {
        _requireActive();
        if (amount == 0) return;
        address sender = msg.sender;
        // SECURITY: Only ContractAddresses.BONDS or vault can increase allowance.
        if (sender != ContractAddresses.BONDS && sender != ContractAddresses.VAULT) revert Unauthorized();
        _vaultMintAllowance += amount;
    }

    /**
     * @notice Mint tokens using vault's pre-allocated allowance.
     * @dev Only callable by vault. Allowance decremented before mint.
     * @param to Recipient address.
     * @param amount Amount to mint.
     */
    function vaultMintTo(address to, uint256 amount) external {
        _requireActive();
        // SECURITY: Only vault can use its allowance.
        if (msg.sender != ContractAddresses.VAULT) revert Unauthorized();
        if (amount == 0) return;
        uint256 allowanceVault = _vaultMintAllowance;
        // SECURITY: Cannot exceed pre-allocated allowance.
        if (amount > allowanceVault) revert InsufficientAllowance();
        unchecked {
            _vaultMintAllowance = allowanceVault - amount;
            totalSupply += amount;
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    // =====================================================================
    //                           INTERNALS
    // =====================================================================

    /**
     * @notice Check that the token is not disabled.
     * @dev Reverts with Disabled() if nuked.
     */
    function _requireActive() private view {
        if (disabled) revert Disabled();
    }

    /**
     * @notice Internal transfer implementation.
     * @dev Reverts if insufficient balance.
     * @param from Sender address.
     * @param to Recipient address.
     * @param amount Amount to transfer.
     */
    function _transfer(address from, address to, uint256 amount) private {
        uint256 fromBal = balanceOf[from];
        if (fromBal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    /**
     * @notice Internal burn implementation.
     * @dev Reverts if insufficient balance.
     * @param from Address to burn from.
     * @param amount Amount to burn.
     */
    function _burn(address from, uint256 amount) private {
        uint256 fromBal = balanceOf[from];
        if (fromBal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /**
     * @notice Permanently disable all token operations.
     * @dev Only callable by ContractAddresses.BONDS. Used during game shutdown.
     *      IRREVERSIBLE - once nuked, token cannot be reactivated.
     */
    function nuke() external {
        // SECURITY: Only ContractAddresses.BONDS can nuke.
        if (msg.sender != ContractAddresses.BONDS) revert Unauthorized();
        disabled = true;
    }
}

// ===================================================================================================
//                                    DEGENERUS BONDS (MAIN)
// ===================================================================================================

/**
 * @title DegenerusBonds
 * @notice Bond system with 10-level maturity cycles, DGNRS token jackpots, and two-lane resolution.
 * @dev See file header for detailed architecture documentation.
 *
 * KEY FUNCTIONS:
 * - presaleDeposit(): Buy bonds during presale phase
 * - depositCurrentFor(): Buy bonds during normal game
 * - burnDGNRS(): Enter the two-lane system for maturity payouts
 * - claim(): Claim pro-rata Decimator winnings after resolution
 * - bondMaintenance(): Game-called to run jackpots and resolve maturities
 * - gameOver(): Emergency shutdown and fund distribution
 */
abstract contract DegenerusBondsStorage {
    // =====================================================================
    //                              ERRORS
    // =====================================================================

    /// @notice Thrown when caller lacks permission.
    error Unauthorized();
    /// @notice Thrown when bond sales are not open.
    error SaleClosed();
    /// @notice Thrown when burn amount is zero.
    error InsufficientScore();
    /// @notice Thrown when ETH transfer to game/bank fails.
    error BankCallFailed();
    /// @notice Thrown when bond purchases are disabled (wrong level window).
    error PurchasesDisabled();
    /// @notice Thrown when deposit below minimum (0.01 ETH).
    error MinimumDeposit();
    /// @notice Thrown when presale is closed but presale function called.
    error PresaleClosed();
    /// @notice Thrown when sweep attempted before 1-year expiry.
    error NotExpired();
    /// @notice Thrown when bps value exceeds 10000.
    error InvalidBps();
    /// @notice Thrown when series not yet resolved for claim.
    error SeriesNotResolved();
    /// @notice Thrown when beneficiary address is zero.
    error InvalidBeneficiary();
    /// @notice Thrown when stETH or vault approval fails.
    error ApprovalFailed();

    // =====================================================================
    //                              EVENTS
    // =====================================================================

    /// @notice Emitted when a new bond series is created.
    /// @param maturityLevel The level at which this series matures.
    /// @param saleStartLevel The level when sales open.
    /// @param token The DGNRS token address (same for all series).
    /// @param payoutBudget Initial payout budget (0, set later).
    event BondSeriesCreated(uint24 indexed maturityLevel, uint24 saleStartLevel, address token, uint256 payoutBudget);

    /// @notice Emitted on each bond deposit.
    /// @param player The depositor address.
    /// @param maturityLevel The series the deposit goes into.
    /// @param amount ETH amount deposited.
    /// @param scoreAwarded Score (amount * player multiplier) for jackpot weighting.
    event BondDeposit(address indexed player, uint24 indexed maturityLevel, uint256 amount, uint256 scoreAwarded);

    /// @notice Emitted when DGNRS tokens are minted via jackpot.
    /// @param maturityLevel The series running the jackpot.
    /// @param dayIndex Which emission run (0-4).
    /// @param mintedAmount Total DGNRS minted this run.
    /// @param rngWord The entropy used for winner selection.
    event BondJackpot(uint24 indexed maturityLevel, uint8 indexed dayIndex, uint256 mintedAmount, uint256 rngWord);

    /// @notice Emitted when DGNRS is burned to enter a lane.
    /// @param player The burner address.
    /// @param maturityLevel The target series.
    /// @param lane Which lane (0 or 1) the burn entered.
    /// @param amount DGNRS burned.
    /// @param boostedScore Whether this burn also counted toward jackpot score.
    event BondBurned(
        address indexed player,
        uint24 indexed maturityLevel,
        uint8 lane,
        uint256 amount,
        bool boostedScore
    );

    /// @notice Emitted when a series is resolved at maturity.
    /// @param maturityLevel The resolved series.
    /// @param winningLane Which lane won (0 or 1).
    /// @param payoutEth Total ETH distributed.
    /// @param remainingToken Unused (always 0).
    event BondSeriesResolved(
        uint24 indexed maturityLevel,
        uint8 winningLane,
        uint256 payoutEth,
        uint256 remainingToken
    );

    /// @notice Emitted during gameOver() resolution.
    /// @param poolSpent Total ETH/stETH spent resolving series.
    /// @param partialMaturity If non-zero, the last series was only partially paid.
    event BondGameOver(uint256 poolSpent, uint24 partialMaturity);

    /// @notice Emitted when FLIP coin is awarded from bond pool.
    /// @param player Winner address.
    /// @param amount FLIP amount.
    /// @param maturityLevel The series the jackpot came from.
    /// @param lane The lane the winner was in.
    event BondCoinJackpot(address indexed player, uint256 amount, uint24 maturityLevel, uint8 lane);

    /// @notice Emitted when expired pools are swept to vault.
    /// @param ethAmount ETH swept.
    /// @param stEthAmount stETH swept.
    event ExpiredSweep(uint256 ethAmount, uint256 stEthAmount);

    /// @notice Emitted on presale bond deposit.
    /// @param buyer The depositor.
    /// @param amount ETH deposited.
    /// @param scoreAwarded Score for presale jackpots.
    event PresaleBondDeposit(address indexed buyer, uint256 amount, uint256 scoreAwarded);

    /// @notice Emitted when presale shutdown is queued.
    /// @param queuedDay Day index when queued.
    /// @param stopDay Day index when presale will end.
    event PresaleStopQueued(uint48 indexed queuedDay, uint48 indexed stopDay);

    /// @notice Emitted when presale daily payouts run.
    /// @param day Day index processed.
    /// @param buyerCoin BURNIE paid to buyer lane.
    /// @param burnCoin BURNIE paid to burn lanes.
    /// @param ticketCoin BURNIE paid to mint tickets.
    /// @param dgnrsMinted DGNRS minted for the day.
    /// @param rngWord Entropy used.
    /// @param finalDay True if presale finalized this day.
    /// @param dgnrsLane Lane index (0 or 1) that received DGNRS.
    /// @param burnieLane Lane index (0 or 1) that received BURNIE.
    event PresaleDailyPayout(
        uint48 indexed day,
        uint256 buyerCoin,
        uint256 burnCoin,
        uint256 ticketCoin,
        uint256 dgnrsMinted,
        uint256 rngWord,
        bool finalDay,
        uint8 dgnrsLane,
        uint8 burnieLane
    );

    /// @notice Emitted when BURNIE is awarded to a presale buyer lane.
    /// @param player Winner address.
    /// @param amount BURNIE amount credited.
    /// @param lane Buyer lane index.
    event PresaleBuyerCoinJackpot(address indexed player, uint256 amount, uint8 lane);

    /// @notice Emitted when reward stake target is changed.
    /// @param newBps New target bps (10000 = 100%).
    event RewardStakeTargetChanged(uint16 newBps);

    // =====================================================================
    //                            CONSTANTS
    // =====================================================================

    /// @notice Default work budget for bondMaintenance() per call.
    /// @dev Each unit covers roughly one series tick or archive step.
    uint32 internal constant BOND_MAINT_WORK_CAP = 3;

    /// @notice Number of jackpot winners per emission run.
    uint8 internal constant JACKPOT_SPOTS = 100;

    /// @notice Top 4 jackpot prize percentages (20%, 10%, 5%, 5%).
    uint8 internal constant TOP_PCT_1 = 20;
    uint8 internal constant TOP_PCT_2 = 10;
    uint8 internal constant TOP_PCT_3 = 5;
    uint8 internal constant TOP_PCT_4 = 5;

    /// @notice Minimum bond deposit (0.01 ETH on mainnet, divided by COST_DIVISOR on testnet).
    uint256 internal constant MIN_DEPOSIT = 0.01 ether / ContractAddresses.COST_DIVISOR;

    /// @notice Day index anchor (matches game/coin).
    uint48 internal constant JACKPOT_RESET_TIME = 82620;

    /// @notice Presale ETH threshold to auto-schedule shutdown (100 ETH on mainnet, divided by COST_DIVISOR on testnet).
    uint256 internal constant PRESALE_AUTO_STOP_THRESHOLD = 100 ether / ContractAddresses.COST_DIVISOR;

    /// @notice Presale ETH cap for DGNRS budget (200 ETH on mainnet, divided by COST_DIVISOR on testnet).
    uint256 internal constant PRESALE_DGNRS_CAP = 200 ether / ContractAddresses.COST_DIVISOR;

    /// @notice Total presale DGNRS budget multiplier (1.2x = 12000 bps).
    uint16 internal constant PRESALE_DGNRS_BPS = 12_000;

    /// @notice Force presale shutdown after this many days if threshold not reached.
    uint48 internal constant PRESALE_FORCE_STOP_DAYS = 49;

    /// @notice Daily DGNRS payout from previous-day ETH input (60%).
    uint16 internal constant PRESALE_DAILY_DGNRS_BPS = 6000;

    /// @notice Daily BURNIE payout to presale buyer lane (20k).
    uint256 internal constant PRESALE_DAILY_BURNIE_BUYER = 20 * PRICE_COIN_UNIT;

    /// @notice Daily BURNIE payout to presale burn lane (20k).
    uint256 internal constant PRESALE_DAILY_BURNIE_BURN = 20 * PRICE_COIN_UNIT;

    /// @notice Lane selector seed for presale buyer assignments.
    bytes32 internal constant PRESALE_LANE_SEED = keccak256("PRESALE_LANE");

    /// @notice Winner count for presale jackpots (normal days).
    uint8 internal constant PRESALE_JACKPOT_SPOTS = 35;

    /// @notice Winner count for presale jackpots on final day.
    uint8 internal constant PRESALE_JACKPOT_SPOTS_FINAL = 50;

    /// @notice Maximum total presale entries (combined across both lanes).
    /// @dev Caps gas usage for jackpot winner selection. 10k entries = ~15M gas with dual jackpots.
    uint16 internal constant PRESALE_MAX_ENTRIES = 10_000;

    /// @notice Coin jackpot payout schedule (basis points of bankroll per winner).
    uint16 internal constant COIN_JACKPOT_TOP_BPS = 1500; // 15% to 1 winner
    uint16 internal constant COIN_JACKPOT_MID_BPS = 500; // 5% to each of 7 winners (was 5)
    uint16 internal constant COIN_JACKPOT_LOW_BPS = 200; // 2% to each of 5 winners
    uint16 internal constant COIN_JACKPOT_TINY_BPS = 100; // 1% to each of 40 winners (was 50)
    uint8 internal constant COIN_JACKPOT_MID_COUNT = 7; // Increased from 5
    uint8 internal constant COIN_JACKPOT_LOW_COUNT = 5;
    uint8 internal constant COIN_JACKPOT_TINY_COUNT = 40; // Reduced from 50


    /// @notice Auto-burn preference: enabled.
    uint8 internal constant AUTO_BURN_ENABLED = 1;
    /// @notice Auto-burn preference: disabled.
    uint8 internal constant AUTO_BURN_DISABLED = 2;
    // =====================================================================
    //                         DATA STRUCTURES
    // =====================================================================

    /**
     * @notice A single burn entry in a lane.
     * @dev Used for tracking individual burns for draw prizes.
     */
    struct LaneEntry {
        address player; // Who burned
        uint256 amount; // How much DGNRS burned
    }

    /**
     * @notice One of two lanes in the two-lane resolution system.
     * @dev Players are deterministically assigned to lanes based on hash(maturity, address).
     *      At resolution, one lane wins and splits the payout pool.
     */
    struct Lane {
        uint256 total; // Total DGNRS burned in this lane
        LaneEntry[] entries; // All burn entries (for draw prizes)
        uint256[] cumulative; // Cumulative totals for O(log N) weighted picks
        mapping(address => uint256) burnedAmount; // Per-player burned amount (for Decimator claims)
    }

    /**
     * @notice A bond series tied to a specific maturity level.
     * @dev Created when sales open for that maturity; resolved at maturity.
     *
     * LIFECYCLE:
     * 1. Created with saleStartLevel = maturity - 10 (or 1 for first series)
     * 2. Deposits during sale window add to raised and totalScore
     * 3. Jackpots run each level during sale window (5 runs total)
     * 4. Burns accepted until maturity
     * 5. At maturity, if funded, pick winning lane and distribute
     */
    struct BondSeries {
        uint24 maturityLevel; // Level at which this series matures (10, 20, 30, ...)
        uint24 saleStartLevel; // Level when sales opened
        uint256 payoutBudget; // Target DGNRS to mint (raised * growth multiplier)
        uint256 mintedBudget; // DGNRS already minted via jackpots
        uint256 raised; // Total ETH deposited into this series
        uint8 jackpotsRun; // Number of jackpot runs completed (0-5)
        uint24 lastJackpotLevel; // Last level a jackpot ran (prevents double-run)
        uint256 totalScore; // Sum of all weighted scores for jackpot draws
        BondToken token; // DGNRS token reference (same for all series)
        address[] jackpotParticipants; // Depositors eligible for jackpots
        uint256[] jackpotCumulative; // Cumulative scores for O(log N) picks
        Lane[2] lanes; // Two-lane burn tracking
        bool resolved; // True after maturity payout completed
        uint8 winningLane; // Which lane won (0 or 1)
        uint256 decSharePrice; // Price per DGNRS for Decimator claims (scaled by 1e18)
        uint256 unclaimedBudget; // ETH reserved for unclaimed payouts (Decimator + gameOver draw claims)
        mapping(address => uint256) drawClaimable; // Draw claims recorded during gameOver resolution
    }

    /**
     * @notice Presale-specific series data.
     * @dev Tracks daily presale jackpots and buyer lanes (maturity = 0).
     */
    struct PresaleSeries {
        uint256 payoutBudget; // Target DGNRS to mint
        uint256 mintedBudget; // DGNRS already minted
        uint256 raised; // Total ETH deposited
        uint48 lastPaidDay; // Last presale day processed (RNG cycle counter)
        uint48 stopDay; // Presale day index when presale should end (after jackpot)
        uint256 coinPaid; // Total presale BURNIE paid out
        Lane[2] buyerLanes; // Two-lane presale buyer tracking
        uint48 startDayPlusOne; // Presale start day index + 1 (0 = unset)
        bool stopPending; // Stop queued; finalize on next RNG-driven advance
    }


    // =====================================================================
    //                            STORAGE
    // =====================================================================

    /// @notice All bond series by maturity level.
    mapping(uint24 => BondSeries) internal series;

    /// @notice List of all created maturity levels in order.
    uint24[] internal maturities;

    /// @notice Index into maturities[] of the oldest non-archived series.
    /// @dev Series before this index are fully resolved and archived.
    uint24 internal activeMaturityIndex;

    /// @notice Sum of unclaimedBudget for archived (resolved) series.
    /// @dev Used for reserve calculations to ensure funds cover all claims.
    uint256 internal resolvedUnclaimedTotal;

    /// @notice Running total of FLIP coin owed for bond jackpots.
    /// @dev Accumulated via payBonds(), paid out in _runCoinJackpot().
    uint256 internal coinOwed;

    /// @notice ETH raised in the previous series (for growth multiplier).
    uint256 internal lastIssuanceRaise;

    /// @notice Last level where bondMaintenance() ran.
    /// @dev Used to handle burn routing at maturity boundaries.
    uint24 internal lastBondMaintenanceLevel;

    // ---------------------------------------------------------------------
    // State Flags
    // ---------------------------------------------------------------------

    /// @notice True once presale shutdown has finalized.
    bool internal presaleFinalized;

    /// @notice True after game signals shutdown; disables deposits and bank pushes.
    bool public gameOverStarted;

    /// @notice Timestamp when game over was triggered (for 1-year expiry).
    uint48 internal gameOverTimestamp;

    /// @notice True after gameOver() attempts to fetch entropy.
    bool public gameOverEntropyAttempted;

    /// @notice True once gamepiece/MAP purchases have been enabled (gated by jackpot timing).
    bool internal gamepiecePurchasesEnabledFlag;

    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------

    /// @notice Target share of stETH (in bps) for game-held reward liquidity.
    uint16 public rewardStakeTargetBps = 10_000; // Default: 100% stETH preference

    /// @notice Affiliate reward for normal bond purchases (3% = 300 bps).
    uint16 internal constant AFFILIATE_BOND_BPS = 300;

    /// @notice Affiliate reward for presale purchases (10% = 1000 bps).
    uint16 internal constant AFFILIATE_PRESALE_BPS = 1000;

    /// @notice Coin unit (18 decimals).
    uint256 internal constant PRICE_COIN_UNIT = 1000 ether;

    /// @notice Total FLIP allocated for presale coin jackpots (2M tokens).
    uint256 internal constant PRESALE_COIN_ALLOCATION = 2_000 * PRICE_COIN_UNIT;

    // ---------------------------------------------------------------------
    // Wired Contracts
    // ---------------------------------------------------------------------

    /// @notice DGNRS bond token (shared across all series).
    /// @dev Constant wrapper saves ~100 gas per read vs storage variable.
    BondToken internal constant tokenDGNRS = BondToken(ContractAddresses.DGNRS);

    /// @notice DegenerusVault contract reference (used 7x).
    IVaultLike internal constant vault = IVaultLike(ContractAddresses.VAULT);

    /// @notice BurnieCoin contract reference (used 3x).
    IDegenerusCoin internal constant coin = IDegenerusCoin(ContractAddresses.COIN);

    /// @notice Game bond bank interface (used 10x; also includes level queries via inheritance).
    IDegenerusGameBondBank internal constant gameBondBank = IDegenerusGameBondBank(ContractAddresses.GAME);

    /// @notice Game RNG interface (used 2x).
    IDegenerusGameRng internal constant gameRng = IDegenerusGameRng(ContractAddresses.GAME);

    /// @notice Affiliate presale status interface (used 2x).
    IAffiliatePresaleStatus internal constant affiliatePresaleStatus =
        IAffiliatePresaleStatus(ContractAddresses.AFFILIATE);

    /// @notice Lido stETH token interface (used 5x).
    IStETH internal constant steth = IStETH(ContractAddresses.STETH_TOKEN);

    // ---------------------------------------------------------------------
    // Per-Player State
    // ---------------------------------------------------------------------

    /// @notice Player preference for auto-burning jackpot DGNRS.
    /// @dev 0 = unset (use default), 1 = enabled, 2 = disabled.
    mapping(address => uint8) internal autoBurnDgnrsPref;

    // ---------------------------------------------------------------------
    // Presale State
    // ---------------------------------------------------------------------


    /// @notice ETH raised per presale day (RNG cycle index).
    mapping(uint48 => uint256) internal presaleDailyRaised;

    /// @notice Presale series data.
    PresaleSeries internal presale;
}

abstract contract DegenerusBondsModule is DegenerusBondsStorage {
    modifier onlyGame() {
        if (msg.sender != ContractAddresses.GAME) revert Unauthorized();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != ContractAddresses.ADMIN) revert Unauthorized();
        _;
    }

    /**
     * @notice Check if gamepiece/MAP purchases are enabled (presale gating).
     * @dev Purchases enabled at first jackpot time after presale raised > 40 ETH OR presale ended.
     * @return True if gamepiece/MAP purchases are enabled, false otherwise.
     */
    function gamepiecePurchasesEnabled() external view returns (bool) {
        return gamepiecePurchasesEnabledFlag;
    }

    function presaleDeposit(address beneficiary) external payable returns (uint256 scoreAwarded) {
        if (gameOverStarted) revert SaleClosed();
        if (presaleFinalized) revert PresaleClosed();
        uint256 amount = msg.value;
        if (amount < MIN_DEPOSIT) revert MinimumDeposit();
        if (_gameRngLocked()) revert PurchasesDisabled();

        _getOrCreateSeries(0);
        PresaleSeries storage p = presale;
        uint48 day;
        unchecked {
            day = p.lastPaidDay + 1;
        }

        uint256 vaultShare = (amount * 30) / 100;
        uint256 rewardShare = (amount * 50) / 100;
        uint256 yieldShare = amount - vaultShare - rewardShare; // 20%

        vault.deposit{value: vaultShare}(0, 0);
        _sendEthOrRevert(ContractAddresses.GAME, rewardShare);
        if (yieldShare != 0) {
            gameBondBank.bondDeposit{value: yieldShare}(false);
        }

        address ben = beneficiary == address(0) ? msg.sender : beneficiary;
        _payAffiliateReward(ben, amount, AFFILIATE_PRESALE_BPS);
        scoreAwarded = amount;

        p.raised += amount;
        presaleDailyRaised[day] += amount;
        if (p.startDayPlusOne == 0) {
            unchecked {
                p.startDayPlusOne = day + 1;
            }
        }
        if (p.raised >= PRESALE_AUTO_STOP_THRESHOLD) {
            _queuePresaleStop(day);
        }

        uint8 lane = uint8(uint256(keccak256(abi.encodePacked(PRESALE_LANE_SEED, ben))) & 1);
        Lane storage buyerLane = p.buyerLanes[lane];

        // Cap total entries to prevent gas exhaustion during jackpot resolution
        uint256 totalEntries = p.buyerLanes[0].entries.length + p.buyerLanes[1].entries.length;
        if (totalEntries >= PRESALE_MAX_ENTRIES) revert PresaleClosed();

        buyerLane.entries.push(LaneEntry({player: ben, amount: amount}));
        buyerLane.total += amount;
        buyerLane.cumulative.push(buyerLane.total);

        emit PresaleBondDeposit(ben, amount, scoreAwarded);
    }

    /// @notice Queue presale shutdown after the next jackpot time.
    /// @dev Manual flag; does not end presale until the next daily run.
    function shutdownPresale() external onlyAdmin {
        PresaleSeries storage p = presale;
        uint48 day;
        unchecked {
            day = p.lastPaidDay + 1;
        }
        _queuePresaleStop(day);
    }

    /// @notice Run daily presale payouts using game-supplied entropy.
    /// @dev Access: game only. Pays buyer lane BURNIE, burn-lane BURNIE, and DGNRS lane.
    /// @param rngWord VRF entropy for jackpot selection.
    /// @param ignoredDay Ignored; presale day is tracked internally for testnet day simulation.
    /// @param lastPurchaseDay True if prize pool target was met today.
    function runPresaleDailyFromGame(
        uint256 rngWord,
        uint48 ignoredDay,
        bool lastPurchaseDay
    ) external onlyGame returns (bool advanced) {
        if (rngWord == 0) return false;
        if (presaleFinalized) return false;

        ignoredDay;
        PresaleSeries storage p = presale;
        // Track presale days by RNG cycles so testnets can advance without timestamp changes.
        uint48 day;
        unchecked {
            day = p.lastPaidDay + 1;
        }
        p.lastPaidDay = day;

        if (p.startDayPlusOne == 0) {
            unchecked {
                p.startDayPlusOne = day + 1;
            }
        }
        _maybeQueuePresaleStop(day, p);

        // Final day triggers: lastPurchaseDay (prize pool target met) OR reaching stop day.
        bool finalDay = lastPurchaseDay || (p.stopDay != 0 && day >= p.stopDay);
        uint256 prevRaised;
        if (day != 0) {
            prevRaised = presaleDailyRaised[day - 1];
        }

        uint256 targetBudget = _presaleTargetBudget(p.raised);
        p.payoutBudget = targetBudget;

        uint256 remainingDgnrs = targetBudget > p.mintedBudget ? targetBudget - p.mintedBudget : 0;
        uint256 dailyDgnrs = (prevRaised * PRESALE_DAILY_DGNRS_BPS) / 10_000;
        uint256 dgnrsToMint = dailyDgnrs > remainingDgnrs ? remainingDgnrs : dailyDgnrs;

        // On final day, pay ALL remaining DGNRS
        if (finalDay && remainingDgnrs > dgnrsToMint) {
            dgnrsToMint = remainingDgnrs;
        }

        uint256 entropy = rngWord;

        // Randomize which lane gets DGNRS vs BURNIE each day
        uint8 dgnrsLane = uint8(entropy & 1);  // 0 or 1
        uint8 burnieLane = 1 - dgnrsLane;      // opposite lane

        uint256 minted;
        if (dgnrsToMint != 0) {
            // Try selected lane first, fall back to other lane if empty
            Lane storage selectedLane = p.buyerLanes[dgnrsLane];
            if (selectedLane.total == 0) {
                // Selected lane empty, try the other lane
                dgnrsLane = burnieLane;
                burnieLane = 1 - dgnrsLane;
                selectedLane = p.buyerLanes[dgnrsLane];
            }

            // Only attempt distribution if lane has entries
            if (selectedLane.total != 0) {
                minted = _runPresaleDgnrsLaneJackpot(
                    selectedLane,
                    dgnrsToMint,
                    _nextEntropy(entropy, 1),
                    0,
                    finalDay
                );
                if (minted != 0) {
                    p.mintedBudget += minted;
                }
            }
        }

        uint256 remainingCoin = PRESALE_COIN_ALLOCATION > p.coinPaid ? PRESALE_COIN_ALLOCATION - p.coinPaid : 0;
        uint256 buyerAmount;
        uint256 burnAmount;

        if (finalDay) {
            // On final day, pay ALL remaining BURNIE (split 50/50)
            uint256 half = remainingCoin / 2;
            buyerAmount = half;
            burnAmount = remainingCoin - half;
        } else {
            // Normal daily payout
            uint256 baseTotal = PRESALE_DAILY_BURNIE_BUYER + PRESALE_DAILY_BURNIE_BURN;
            if (remainingCoin != 0 && baseTotal != 0) {
                if (remainingCoin < baseTotal) {
                    buyerAmount = (PRESALE_DAILY_BURNIE_BUYER * remainingCoin) / baseTotal;
                    burnAmount = remainingCoin - buyerAmount;
                } else {
                    buyerAmount = PRESALE_DAILY_BURNIE_BUYER;
                    burnAmount = PRESALE_DAILY_BURNIE_BURN;
                }
            }
        }

        uint256 buyerPaid;
        uint256 burnPaid;
        if (buyerAmount != 0) {
            bool paid = _payPresaleBuyerCoinJackpot(buyerAmount, _nextEntropy(entropy, 2), burnieLane);
            if (paid) {
                p.coinPaid += buyerAmount;
                buyerPaid = buyerAmount;
            }
        }
        if (burnAmount != 0) {
            bool paid = _payCoinJackpot(burnAmount, _nextEntropy(entropy, 3), true);
            if (paid) {
                p.coinPaid += burnAmount;
                burnPaid = burnAmount;
            }
        }

        // Enable gamepiece/MAP purchases at first jackpot time after 40 ETH raised or presale ending
        if (!gamepiecePurchasesEnabledFlag && (p.raised > (40 ether / ContractAddresses.COST_DIVISOR) || finalDay)) {
            gamepiecePurchasesEnabledFlag = true;
        }

        emit PresaleDailyPayout(
            day,
            buyerPaid,
            burnPaid,
            0, // ticketPaid removed - tickets handled by normal jackpots
            minted,
            rngWord,
            finalDay,
            dgnrsLane,
            burnieLane
        );

        if (finalDay) {
            p.stopPending = false;
            presaleFinalized = true;
            try IAffiliatePresaleShutdown(ContractAddresses.AFFILIATE).shutdownPresale() {} catch {}
        }
        return true;
    }

    /// @notice Unified deposit: external callers route ETH into the current maturity.
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable onlyGame {
        uint256 pulledStEth;
        if (stEthAmount != 0) {
            uint256 beforeBal = _stEthBalance();
            try steth.transferFrom(msg.sender, address(this), stEthAmount) {} catch {}
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
            vault.deposit{value: msg.value}(0, pulledStEth);
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

        Lane storage chosen = target.lanes[lane];
        return _distributeLotteryPayout(chosen, amount, rngWord, targetMat, lane, true);
    }

    function _payPresaleBuyerCoinJackpot(uint256 amount, uint256 rngWord, uint8 lane) private returns (bool paid) {
        if (amount == 0 || rngWord == 0) return false;
        PresaleSeries storage p = presale;
        Lane storage chosen = p.buyerLanes[lane];
        if (chosen.total == 0) return false;

        return _distributeLotteryPayout(chosen, amount, rngWord, 0, lane, false);
    }

    /// @notice Generic lottery payout distributor for coin jackpots.
    /// @dev Shared logic for both normal and presale coin jackpots.
    /// @param lane Storage reference to the lane to pick winners from.
    /// @param amount Total BURNIE amount to distribute.
    /// @param rngWord Entropy source for winner selection.
    /// @param maturityLevel Series maturity (for event emission, 0 for presale).
    /// @param laneIndex Lane index (for event emission).
    /// @param isSeriesJackpot True for series jackpots, false for presale buyer jackpots.
    /// @return success True if payout was distributed.
    function _distributeLotteryPayout(
        Lane storage lane,
        uint256 amount,
        uint256 rngWord,
        uint24 maturityLevel,
        uint8 laneIndex,
        bool isSeriesJackpot
    ) private returns (bool success) {
        // Calculate prize buckets
        uint256 top = (amount * COIN_JACKPOT_TOP_BPS) / 10_000;
        uint256 mid = (amount * COIN_JACKPOT_MID_BPS) / 10_000;
        uint256 low = (amount * COIN_JACKPOT_LOW_BPS) / 10_000;
        uint256 tiny = (amount * COIN_JACKPOT_TINY_BPS) / 10_000;
        uint256 distributed = top +
            (mid * COIN_JACKPOT_MID_COUNT) +
            (low * COIN_JACKPOT_LOW_COUNT) +
            (tiny * COIN_JACKPOT_TINY_COUNT);

        // Add rounding dust to top prize
        if (distributed < amount) {
            unchecked {
                top += amount - distributed;
            }
        }

        // Pick and credit top winner
        uint256 entropy = rngWord;
        address winner = _weightedLanePick(lane, entropy);
        if (winner == address(0)) return false;

        if (isSeriesJackpot) {
            _creditCoinJackpot(winner, top, maturityLevel, laneIndex);
        } else {
            _creditPresaleBuyerCoinJackpot(winner, top, laneIndex);
        }

        // Distribute mid-tier prizes
        uint256 salt = 1;
        if (mid != 0) {
            for (uint256 i; i < COIN_JACKPOT_MID_COUNT; ) {
                entropy = _nextEntropy(entropy, salt);
                winner = _weightedLanePick(lane, entropy);
                if (isSeriesJackpot) {
                    _creditCoinJackpot(winner, mid, maturityLevel, laneIndex);
                } else {
                    _creditPresaleBuyerCoinJackpot(winner, mid, laneIndex);
                }
                unchecked {
                    ++i;
                    ++salt;
                }
            }
        }

        // Distribute low-tier prizes
        if (low != 0) {
            for (uint256 i; i < COIN_JACKPOT_LOW_COUNT; ) {
                entropy = _nextEntropy(entropy, salt);
                winner = _weightedLanePick(lane, entropy);
                if (isSeriesJackpot) {
                    _creditCoinJackpot(winner, low, maturityLevel, laneIndex);
                } else {
                    _creditPresaleBuyerCoinJackpot(winner, low, laneIndex);
                }
                unchecked {
                    ++i;
                    ++salt;
                }
            }
        }

        // Distribute tiny-tier prizes
        if (tiny != 0) {
            for (uint256 i; i < COIN_JACKPOT_TINY_COUNT; ) {
                entropy = _nextEntropy(entropy, salt);
                winner = _weightedLanePick(lane, entropy);
                if (isSeriesJackpot) {
                    _creditCoinJackpot(winner, tiny, maturityLevel, laneIndex);
                } else {
                    _creditPresaleBuyerCoinJackpot(winner, tiny, laneIndex);
                }
                unchecked {
                    ++i;
                    ++salt;
                }
            }
        }

        return true;
    }

    function _creditCoinJackpot(address winner, uint256 amount, uint24 maturityLevel, uint8 lane) private {
        if (winner == address(0) || amount == 0) return;
        coin.creditFlip(winner, amount);
        emit BondCoinJackpot(winner, amount, maturityLevel, lane);
    }

    function _creditPresaleBuyerCoinJackpot(address winner, uint256 amount, uint8 lane) private {
        if (winner == address(0) || amount == 0) return;
        coin.creditFlip(winner, amount);
        emit PresaleBuyerCoinJackpot(winner, amount, lane);
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
        bool triedResolution;
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
                // Limit: max 1 resolution attempt per transaction
                if (!triedResolution) {
                    if (_isFunded(s) && !backlogPending) {
                        _resolveSeries(s, rollingEntropy);
                        rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "resolve")));
                        if (!s.resolved) {
                            backlogPending = true;
                        }
                    } else {
                        backlogPending = true;
                    }
                    triedResolution = true;
                } else {
                    backlogPending = true;
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

        // Note: RNG lock is enforced by reading gameBondBank.rngLocked().
        done = !hitCap;
        return done;
    }

    /// @notice Burn DGNRS to enter the active jackpot.
    function gameOver() external payable {
        uint256 entropy = _prepareEntropy(0);
        _runGameOver(entropy);
    }

    /// @notice Resolve game-over using game-supplied entropy.
    /// @dev Access: game only. Used by advanceGame to centralize RNG.
    function gameOverWithEntropy(uint256 entropy) external payable onlyGame {
        _runGameOver(entropy);
    }

    function _runGameOver(uint256 entropy) private {
        if (msg.sender != ContractAddresses.GAME && !gameOverStarted) revert Unauthorized();
        if (!gameOverStarted) {
            gameOverStarted = true;
            gameOverTimestamp = uint48(block.timestamp);
        }

        gameOverEntropyAttempted = true;
        if (entropy == 0) return;

        // Calculate available funds after accounting for existing obligations
        uint256 currentEth = address(this).balance;
        uint256 currentStEth = _stEthBalance();
        uint256 totalAssets = currentEth + currentStEth;

        uint256 totalReserved = resolvedUnclaimedTotal;
        uint24 len = uint24(maturities.length);
        for (uint24 k = activeMaturityIndex; k < len; ) {
            totalReserved += series[maturities[k]].unclaimedBudget;
            unchecked {
                ++k;
            }
        }

        uint256 remainingValue = totalAssets > totalReserved ? totalAssets - totalReserved : 0;

        // Resolve one maturity per call
        bool resolvedOne;
        uint24 partialMaturity;
        for (uint24 i = activeMaturityIndex; i < len; ) {
            BondSeries storage s = series[maturities[i]];
            unchecked {
                ++i;
            }
            if (s.resolved) continue;

            uint256 burned = s.lanes[0].total + s.lanes[1].total;
            if (burned == 0) {
                s.resolved = true;
                resolvedOne = true;
                break;
            }

            if (remainingValue == 0) {
                partialMaturity = s.maturityLevel;
                s.resolved = true;
                resolvedOne = true;
                break;
            }

            uint256 payout = burned <= remainingValue ? burned : remainingValue;
            _resolveSeriesGameOver(s, entropy, payout);
            s.resolved = true;
            resolvedOne = true;

            if (payout < burned) {
                partialMaturity = s.maturityLevel;
            }
            break; // Only resolve one per call
        }

        // After all series resolved, sweep any surplus to vault
        if (!resolvedOne) {
            // No unresolved series found - final surplus sweep
            uint256 surplus = totalAssets > totalReserved ? totalAssets - totalReserved : 0;
            if (surplus != 0) {
                uint256 stSend = currentStEth < surplus ? currentStEth : surplus;
                uint256 ethSend = surplus - stSend;
                if (stSend != 0 || ethSend != 0) {
                    vault.deposit{value: ethSend}(0, stSend);
                }
            }
        }

        if (resolvedOne) {
            emit BondGameOver(0, partialMaturity);
        }
    }

    /// @notice Sweep all funds (ETH + stETH) to the vault 1 year after game over.
    /// @dev Callable by anyone; destination is fixed to the vault.
    function sweepExpiredPools() external {
        if (gameOverTimestamp == 0) revert Unauthorized();
        if (block.timestamp <= gameOverTimestamp + 365 days) revert NotExpired();

        address v = ContractAddresses.VAULT;

        uint256 ethBal = address(this).balance;
        uint256 stBal = _stEthBalance();
        if (ethBal != 0 || stBal != 0) {
            IVaultLike(v).deposit{value: ethBal}(0, stBal);
        }

        emit ExpiredSweep(ethBal, stBal);
    }

    function claim(uint24 maturityLevel) external {
        BondSeries storage s = series[maturityLevel];
        if (!s.resolved) revert SeriesNotResolved();

        uint256 payout;
        uint8 lane = s.winningLane;
        uint256 price = s.decSharePrice;
        if (price != 0) {
            uint256 burned = s.lanes[lane].burnedAmount[msg.sender];
            if (burned != 0) {
                s.lanes[lane].burnedAmount[msg.sender] = 0;
                payout = (burned * price) / 1e18;
            }
        }

        uint256 draw = s.drawClaimable[msg.sender];
        if (draw != 0) {
            s.drawClaimable[msg.sender] = 0;
            payout += draw;
        }

        if (payout == 0) return;

        uint256 budgetBefore = s.unclaimedBudget;
        if (budgetBefore >= payout) {
            s.unclaimedBudget = budgetBefore - payout;
        } else {
            s.unclaimedBudget = 0;
        }

        uint256 delta = budgetBefore - s.unclaimedBudget;
        if (delta != 0) {
            // If this series is archived (skipped in main loops), update the global tracker.
            bool isArchived = false;
            uint24 head = activeMaturityIndex;
            if (head > 0) {
                if (head >= maturities.length) {
                    isArchived = true;
                } else if (head < maturities.length && maturityLevel < series[maturities[head]].maturityLevel) {
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

    function _burnEffectiveLevel(uint24 currLevel) internal view returns (uint24 level) {
        level = currLevel;
        if (currLevel != 0 && lastBondMaintenanceLevel < currLevel) {
            unchecked {
                level = currLevel - 1;
            }
        }
    }

    /// @dev Internal burn handler: burns tokens, routes to correct maturity series, and assigns to a lane.
    ///      Used by both burnDGNRS() and mintJackpotDgnrs() (when auto-burn enabled).
    function _burnDgnrsFor(address player, uint256 amount, uint24 currLevel, bool burnToken) internal {
        uint24 burnLevel = _burnEffectiveLevel(currLevel);
        uint24 targetMat = _activeMaturityAt(burnLevel);
        (BondSeries storage target, uint24 resolvedTargetMat) = _nextActiveSeries(targetMat, burnLevel);
        if (burnToken) {
            tokenDGNRS.burn(player, amount);
        }

        (uint8 lane, bool boosted) = _registerBurn(target, resolvedTargetMat, amount, currLevel, player);
        emit BondBurned(player, resolvedTargetMat, lane, amount, boosted);
    }

    function _nextActiveSeries(
        uint24 maturityLevel,
        uint24 effectiveLevel
    ) internal returns (BondSeries storage target, uint24 targetMaturity) {
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

    /// @dev Register a burn in a series lane with deterministic lane assignment.
    ///      Also records score for jackpot eligibility if within emission window.
    function _registerBurn(
        BondSeries storage s,
        uint24 maturityLevel,
        uint256 amount,
        uint24 currLevel,
        address player
    ) internal returns (uint8 lane, bool boosted) {
        // Deterministic lane assignment based on maturity level and player address (laneHint ignored).
        lane = uint8(uint256(keccak256(abi.encodePacked(maturityLevel, player))) & 1);

        s.lanes[lane].entries.push(LaneEntry({player: player, amount: amount}));
        s.lanes[lane].total += amount;
        s.lanes[lane].burnedAmount[player] += amount;
        s.lanes[lane].cumulative.push(s.lanes[lane].total);

        // While DGNRS is still being minted for this series, count burns toward mint jackpot score as well.
        if (currLevel != 0 && currLevel < s.maturityLevel && s.jackpotsRun < 5 && s.mintedBudget < s.payoutBudget) {
            uint256 boostedScore = _scoreWithMultiplier(player, amount);
            s.totalScore = _recordScore(s.jackpotParticipants, s.jackpotCumulative, s.totalScore, player, boostedScore);
            boosted = true;
        }
    }

    function _currentLevel() internal view returns (uint24) {
        return gameBondBank.level();
    }

    function _maybeQueuePresaleStop(uint48 day, PresaleSeries storage p) private {
        if (p.raised < PRESALE_AUTO_STOP_THRESHOLD) {
            uint48 startDayPlusOne = p.startDayPlusOne;
            if (startDayPlusOne != 0) {
                uint48 startDay = startDayPlusOne - 1;
                uint48 deadline;
                unchecked {
                    deadline = startDay + PRESALE_FORCE_STOP_DAYS;
                }
                if (day >= deadline) {
                    _queuePresaleStop(day);
                }
            }
        }

        // DISABLED: Let presale continue to 100 ETH regardless of bond pool target
        // uint256 targetPool = gameBondBank.prizePoolTargetView();
        // if (targetPool != 0) {
        //     uint256 nextPool = gameBondBank.nextPrizePoolView();
        //     if (nextPool >= targetPool) {
        //         _queuePresaleStop(day);
        //     }
        // }
    }

    function _queuePresaleStop(uint48 day) private {
        if (presaleFinalized) return;
        PresaleSeries storage p = presale;
        uint48 stopDay;
        unchecked {
            stopDay = day + 1;
        }
        uint48 existing = p.stopDay;
        if (existing == 0 || stopDay < existing) {
            p.stopDay = stopDay;
            p.stopPending = true;
            emit PresaleStopQueued(day, stopDay);
        }
    }

    function _presaleActive() internal view returns (bool active) {
        try affiliatePresaleStatus.presaleActive() returns (uint8 ok) {
            return ok != 0;
        } catch {
            return false;
        }
    }

    function _scoreWithMultiplier(address player, uint256 baseScore) internal view returns (uint256) {
        uint256 multBps = gameBondBank.playerBonusMultiplier(player);
        return (baseScore * multBps) / 10000;
    }

    function _presaleTargetBudget(uint256 raised) private pure returns (uint256 target) {
        uint256 capped = raised > PRESALE_DGNRS_CAP ? PRESALE_DGNRS_CAP : raised;
        target = (capped * PRESALE_DGNRS_BPS) / 10_000;
    }

    function _prepareEntropy(uint256 provided) private view returns (uint256 entropy) {
        if (provided != 0) return provided;
        return gameRng.lastRngWord();
    }

    function _gameRngLocked() internal view returns (bool locked) {
        return gameRng.rngLocked();
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
            return gameBondBank.bondAvailable();
        }
        return address(this).balance + _stEthBalance();
    }

    function _stEthBalance() private view returns (uint256 bal) {
        try steth.balanceOf(address(this)) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _sendEthOrRevert(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert BankCallFailed();
    }

    function _sweepExcessToVault() private returns (bool swept) {
        address v = ContractAddresses.VAULT;
        if (!gameOverStarted) return false;

        uint256 required = resolvedUnclaimedTotal;
        uint256 ethBal = address(this).balance;
        uint256 stBal = _stEthBalance();
        uint256 totalAssets = ethBal + stBal;
        if (totalAssets <= required) return false;
        uint24 currLevel = _currentLevel();
        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; ) {
            BondSeries storage s = series[maturities[i]];
            unchecked {
                ++i;
            }
            required += _requiredCover(s, currLevel);
            if (required >= totalAssets) {
                return false;
            }
        }

        uint256 excess = totalAssets - required;
        uint256 stSend = stBal < excess ? stBal : excess;
        uint256 ethSend = excess - stSend;
        if (stSend != 0 || ethSend != 0) {
            IVaultLike(v).deposit{value: ethSend}(0, stSend);
            swept = true;
        }
    }

    function _createSeries(uint24 maturityLevel) internal {
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

    function _getOrCreateSeries(uint24 maturityLevel) internal returns (BondSeries storage s) {
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
    ) internal returns (uint256 newTotal) {
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

    function _autoBurnEnabled(address player) internal view returns (bool enabled) {
        uint8 pref = autoBurnDgnrsPref[player];
        if (pref == AUTO_BURN_ENABLED) return true;
        if (pref == AUTO_BURN_DISABLED) return false;
        return true;
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
                if (canAutoBurn && _autoBurnEnabled(winner)) {
                    _burnDgnrsFor(winner, amount, currLevel, false);
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
                if (canAutoBurn && _autoBurnEnabled(winner)) {
                    _burnDgnrsFor(winner, amount, currLevel, false);
                } else {
                    token.mint(winner, amount);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _runPresaleDgnrsLaneJackpot(
        Lane storage lane,
        uint256 toMint,
        uint256 rngWord,
        uint24 currLevel,
        bool finalDay
    ) private returns (uint256 minted) {
        if (toMint == 0 || rngWord == 0) return 0;
        if (lane.total == 0) return 0;
        if (lane.cumulative.length == 0) return 0;

        uint8 spots = finalDay ? PRESALE_JACKPOT_SPOTS_FINAL : PRESALE_JACKPOT_SPOTS;
        uint256[6] memory payouts = _jackpotPayouts(toMint, spots);
        uint256 entropy = rngWord;
        bool presaleActive = _presaleActive();
        bool canAutoBurn = currLevel != 0 || presaleActive;
        for (uint256 i; i < 4; ) {
            uint256 amount = payouts[i];
            if (amount != 0) {
                address winner = _weightedLanePick(lane, entropy);
                if (winner != address(0)) {
                    if (canAutoBurn && _autoBurnEnabled(winner)) {
                        _burnDgnrsFor(winner, amount, currLevel, false);
                    } else {
                        tokenDGNRS.mint(winner, amount);
                    }
                    minted += amount;
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
                address winner = _weightedLanePick(lane, entropy);
                if (winner != address(0)) {
                    if (canAutoBurn && _autoBurnEnabled(winner)) {
                        _burnDgnrsFor(winner, amount, currLevel, false);
                    } else {
                        tokenDGNRS.mint(winner, amount);
                    }
                    minted += amount;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Award 5 additional MAP ticket winners (4 tickets each)
        for (uint256 i; i < 5; ) {
            entropy = _nextEntropy(entropy, totalSpots + i);
            address winner = _weightedLanePick(lane, entropy);
            if (winner != address(0)) {
                gameBondBank.bondSpendToMaps(winner, 0, 4);
            }
            unchecked {
                ++i;
            }
        }

        return minted;
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
            mapPrice = gameBondBank.mintPrice() / 4;
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
                        gameBondBank.bondSpendToMaps(winner, prize, uint32(qty));
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

    function _recordDrawClaims(
        BondSeries storage s,
        Lane storage chosen,
        uint8 lane,
        uint256 rngWord,
        uint256 drawPool
    ) private returns (uint256 recorded) {
        if (drawPool == 0) return 0;
        uint256[14] memory buckets = _drawBuckets(drawPool);

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
            s.drawClaimable[winner] += prize;
            recorded += prize;
        }
    }

    function _resolveSeriesGameOver(
        BondSeries storage s,
        uint256 rngWord,
        uint256 payout
    ) private returns (uint256 reserved) {
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
        }

        // Ticketed draws recorded as claims during gameOver (no payouts).
        uint256 drawRecorded = _recordDrawClaims(s, chosen, lane, rngWord, drawPool);
        reserved = decPool + drawRecorded;
        s.unclaimedBudget = reserved;
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
            gameBondBank.bondCreditToClaimable(player, amount);
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
            try steth.transfer(player, remaining) returns (bool ok) {
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
        gameBondBank.bondCreditToClaimableBatch(winners, amounts);
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

    function _payAffiliateReward(address buyer, uint256 ethAmount, uint16 bps) internal {
        if (bps == 0 || ethAmount == 0) return;
        (uint24 level, , , , uint256 priceWei) = IDegenerusGamePricing(
            ContractAddresses.GAME
        ).purchaseInfo();

        uint256 coinEquivalent = (ethAmount * PRICE_COIN_UNIT) / priceWei;
        uint256 reward = (coinEquivalent * uint256(bps)) / 10_000;

        uint256 rakeback = IAffiliatePayer(ContractAddresses.AFFILIATE).payAffiliate(
            reward,
            bytes32(0),
            buyer,
            level
        );
        if (rakeback != 0) {
            coin.creditFlip(buyer, rakeback);
        }
    }

    function _activeMaturityAt(uint24 currLevel) internal view returns (uint24 maturityLevel) {
        if (_presaleActive()) {
            return 0; // presale burns route into the level-0 maturity
        }
        if (currLevel < 10) {
            return 10; // setup levels route into the first maturity (level 10)
        }
        // Single-token bond cycle is 10 levels wide: maturities are levels ending in 0.
        maturityLevel = ((currLevel / 10) + 1) * 10;
    }

    function _bondPurchasesOpen(uint24 currLevel) internal pure returns (bool open) {
        // Real game levels are 1-indexed; treat level 0 as a closed window.
        if (currLevel == 0) return false;
        // Bootstrap window: levels 1-5 sell into maturity 10 (stop at 6).
        if (currLevel < 10) return currLevel < 6;
        // Thereafter: open for 5 levels per 10 (e.g., 10-14, 20-24, ...).
        return (currLevel % 10) < 5;
    }
}

contract DegenerusBonds is DegenerusBondsModule {
    // =====================================================================
    //                           CONSTRUCTOR
    // =====================================================================

    /**
     * @notice Initialize the bond system with precomputed dependencies.
     * @dev Wires the predeployed DGNRS token and fixed addresses from ContractAddresses.
     *
     * DEPLOYMENT ORDER:
     * 1. Deploy BondToken (DGNRS) with ContractAddresses.BONDS set to the precomputed bonds address
     * 2. Deploy DegenerusBonds
     *
     * RNG is sourced from the game; bonds no longer request VRF directly.
     */
    constructor() {
        // Approve vault to spend stETH for yield management
        if (!steth.approve(ContractAddresses.VAULT, type(uint256).max)) {
            revert ApprovalFailed();
        }
    }

    // =====================================================================
    //                       EXTERNAL WRITE API
    // =====================================================================

    /// @notice Configure the target stETH share (in bps) for game-held liquidity; 0 disables staking.
    /// @param bps Basis points (0-10000, where 10000 = 100% stETH preference)
    function setRewardStakeTargetBps(uint16 bps) external onlyAdmin {
        if (bps > 10_000) revert InvalidBps();
        rewardStakeTargetBps = bps;
        emit RewardStakeTargetChanged(bps);
    }

    /// @notice Player toggle to auto-burn any DGNRS minted from bond jackpots.
    /// @dev Defaults to enabled at all times unless explicitly disabled.
    /// @param enabled True to enable auto-burn, false to disable
    function setAutoBurnDgnrs(bool enabled) external {
        autoBurnDgnrsPref[msg.sender] = enabled ? AUTO_BURN_ENABLED : AUTO_BURN_DISABLED;
    }

    /// @notice Unified deposit: external callers route ETH into the current maturity.
    /// @param beneficiary Address to credit with bond score (uses msg.sender if zero address)
    /// @return scoreAwarded Amount of score awarded based on deposit and player multiplier
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded) {
        if (msg.sender == ContractAddresses.GAME) revert Unauthorized(); // game should use depositFromGame; split handled in-game
        address ben = beneficiary == address(0) ? msg.sender : beneficiary;
        uint256 amount = msg.value;
        scoreAwarded = _processDeposit(ben, amount, false);
    }

    /// @notice Game-only deposit that credits the current maturity; ETH split is handled in-game.
    /// @param beneficiary Address to credit with bond score
    /// @param amount Amount of ETH (in wei) to credit as score
    /// @return scoreAwarded Amount of score awarded based on amount and player multiplier
    function depositFromGame(address beneficiary, uint256 amount) external returns (uint256 scoreAwarded) {
        if (msg.sender != ContractAddresses.GAME) revert Unauthorized();
        scoreAwarded = _processDeposit(beneficiary, amount, true);
    }

    /// @notice Unified entry point for game-awarded bond prizes.
    /// @dev Routes to depositFromGame when purchases are open, mintJackpotDgnrs when closed.
    /// @param beneficiary Address receiving the bond prize.
    /// @param amount ETH amount to convert into bonds.
    /// @param lvl Current game level for DGNRS mint routing (when purchases closed).
    /// @return bondPoolShare Amount the game should add to bondPool (full amount in current flow).
    function awardFromGame(
        address beneficiary,
        uint256 amount,
        uint24 lvl
    ) external onlyGame returns (uint256 bondPoolShare) {
        if (amount == 0 || beneficiary == address(0)) return 0;
        if (!gameOverStarted && _bondPurchasesOpen(lvl)) {
            _processDeposit(beneficiary, amount, true);
            return amount;
        }
        mintJackpotDgnrs(beneficiary, amount, lvl);
        return amount;
    }

    /// @notice Mint DGNRS 1:1 for jackpot bond prizes when purchases are closed.
    /// @dev Game-only. Respects auto-burn preference; if enabled, registers burns directly.
    /// @param beneficiary Address to receive DGNRS tokens (or have burns registered if auto-burn enabled)
    /// @param amount Amount of DGNRS to mint/burn
    /// @param currLevel Current game level (used for routing burns to correct maturity)
    function mintJackpotDgnrs(address beneficiary, uint256 amount, uint24 currLevel) public onlyGame {
        if (amount == 0) return;
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (gameOverStarted) revert SaleClosed();

        bool presaleActive = _presaleActive();
        bool canAutoBurn = currLevel != 0 || presaleActive;
        if (canAutoBurn && _autoBurnEnabled(beneficiary)) {
            _burnDgnrsFor(beneficiary, amount, currLevel, false);
        } else {
            tokenDGNRS.mint(beneficiary, amount);
        }
    }

    /// @notice Called by game to signal game over and start the shutdown process.
    /// @dev Sets gameOverStarted flag and records timestamp for expiry calculations.
    function notifyGameOver() external {
        if (msg.sender != ContractAddresses.GAME) revert Unauthorized();
        if (!gameOverStarted) {
            gameOverStarted = true;
            gameOverTimestamp = uint48(block.timestamp);
        }
    }

    /// @notice Used by jackpot bond buys; when false, jackpots should pay ETH instead of bonds.
    /// @return True if bond purchases are currently enabled, false otherwise
    function purchasesEnabled() external view returns (bool) {
        if (gameOverStarted) return false;
        return _bondPurchasesOpen(_currentLevel());
    }

    /// @dev Internal deposit processing shared between external and game deposits.
    ///      Handles validation, ETH routing, score calculation, and series updates.
    function _processDeposit(
        address beneficiary,
        uint256 amount,
        bool fromGame
    ) private returns (uint256 scoreAwarded) {
        if (amount == 0) revert SaleClosed();
        if (!fromGame && amount < MIN_DEPOSIT) revert MinimumDeposit();
        if (gameOverStarted) revert SaleClosed();
        if (!fromGame && _gameRngLocked()) revert PurchasesDisabled();

        uint24 currLevel = gameBondBank.level();
        if (!fromGame && !_bondPurchasesOpen(currLevel)) revert PurchasesDisabled();
        uint24 maturityLevel = _activeMaturityAt(currLevel);
        BondSeries storage s = _getOrCreateSeries(maturityLevel);

        if (!fromGame) {
            // Split ETH: direct purchases (40% vault, preferring stETH from game; 20% bondPool, 10% reward,
            // 30% yield). If we pay the vault in stETH, route the vault-share ETH back to the game as a swap.
            uint256 vaultShare = (amount * 40) / 100;
            uint256 bondShare = (amount * 20) / 100;
            uint256 rewardShare = (amount * 10) / 100;
            uint256 yieldShare = amount - bondShare - rewardShare - vaultShare;

            address vaultAddr = ContractAddresses.VAULT;
            address gameAddr = ContractAddresses.GAME;

            uint256 stUsed;
            if (vaultShare != 0) {
                uint256 stBal;
                try steth.balanceOf(gameAddr) returns (uint256 b) {
                    stBal = b;
                } catch {}
                if (stBal != 0) {
                    uint256 stPull = stBal < vaultShare ? stBal : vaultShare;
                    bool pulled;
                    try steth.transferFrom(gameAddr, address(this), stPull) returns (
                        bool ok
                    ) {
                        pulled = ok;
                    } catch {}
                    if (pulled) {
                        stUsed = stPull;
                    }
                }
            }
            if (stUsed != 0) {
                IVaultLike(vaultAddr).deposit{value: 0}(0, stUsed);
            }
            uint256 vaultEthShare = vaultShare - stUsed;
            if (vaultEthShare != 0) {
                IVaultLike(vaultAddr).deposit{value: vaultEthShare}(0, 0);
            }
            if (stUsed != 0) {
                // Swap path: vault got stETH; send the swapped ETH to the game.
                gameBondBank.bondDeposit{value: stUsed}(false);
            }

            if (bondShare != 0) {
                gameBondBank.bondDeposit{value: bondShare}(true);
            }
            if (yieldShare != 0) {
                gameBondBank.bondDeposit{value: yieldShare}(false);
            }
            if (rewardShare != 0) {
                _sendEthOrRevert(gameAddr, rewardShare);
            }
        }

        scoreAwarded = _scoreWithMultiplier(beneficiary, amount);
        if (!fromGame) {
            _payAffiliateReward(beneficiary, amount, AFFILIATE_BOND_BPS);
            coin.notifyQuestBond(beneficiary, amount);
        }

        // Append new weight slice for jackpot selection (append-only cumulative for O(log N) sampling).
        s.totalScore = _recordScore(
            s.jackpotParticipants,
            s.jackpotCumulative,
            s.totalScore,
            beneficiary,
            scoreAwarded
        );
        s.raised += amount;
        // Ensure payout budget never trails total deposits for this maturity.
        if (s.payoutBudget < s.raised) {
            s.payoutBudget = s.raised;
        }

        emit BondDeposit(beneficiary, maturityLevel, amount, scoreAwarded);
    }

    /// @notice Burn DGNRS to enter the active jackpot.
    /// @dev Burns are routed to the appropriate maturity series based on current level.
    ///      Lane assignment is deterministic based on hash(maturity, player).
    /// @param amount Amount of DGNRS tokens to burn
    function burnDGNRS(uint256 amount) external {
        if (amount == 0) revert InsufficientScore();
        if (gameOverStarted) revert SaleClosed();
        if (_gameRngLocked()) revert PurchasesDisabled();

        bool presaleActive = _presaleActive();
        uint24 currLevel;
        if (presaleActive) {
            currLevel = 0;
        } else {
            currLevel = gameBondBank.level();
        }
        _burnDgnrsFor(msg.sender, amount, currLevel, true);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Required cover with early stop if the total exceeds stopAt (0 disables early stop).
    /// @dev Used by the game to check if sufficient liquidity exists for bond operations.
    /// @param stopAt Maximum required cover to calculate; returns stopAt+1 if exceeded (0 = no limit)
    /// @return required Total ETH required to cover all bond obligations
    function requiredCoverNext(uint256 stopAt) external view returns (uint256 required) {
        return _requiredCoverNext(stopAt);
    }

    /// @notice Get bond lane info for a specific maturity and lane.
    /// @param maturityLevel The maturity level to query.
    /// @param laneIndex The lane index (0 or 1).
    /// @return total Total DGNRS burned in this lane.
    /// @return entryCount Number of burn entries in this lane.
    function getBondLaneInfo(uint24 maturityLevel, uint8 laneIndex)
        external
        view
        returns (uint256 total, uint256 entryCount)
    {
        require(laneIndex < 2, "Invalid lane index");
        BondSeries storage s = series[maturityLevel];
        Lane storage lane = s.lanes[laneIndex];
        return (lane.total, lane.entries.length);
    }

    /// @notice Get maturity info for a bond series.
    /// @param maturityLevel The maturity level to query.
    /// @return maturity The maturity level.
    /// @return saleStartLevel The level when sales opened.
    /// @return raised Total ETH deposited.
    /// @return resolved Whether the series has been resolved.
    /// @return winningLane The winning lane (0 or 1, only valid if resolved).
    function getMaturityInfo(uint24 maturityLevel)
        external
        view
        returns (
            uint24 maturity,
            uint24 saleStartLevel,
            uint256 raised,
            bool resolved,
            uint8 winningLane
        )
    {
        BondSeries storage s = series[maturityLevel];
        return (
            s.maturityLevel,
            s.saleStartLevel,
            s.raised,
            s.resolved,
            s.winningLane
        );
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
}

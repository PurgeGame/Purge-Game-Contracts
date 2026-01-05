// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";

// ═══════════════════════════════════════════════════════════════════════════════════════════════════
// @title DegenerusAffiliate
// @author Burnie Degenerus
// @notice Multi-tier affiliate referral system with presale support and leaderboard tracking.
//
// ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
// │ ARCHITECTURE OVERVIEW                                                                           │
// ├─────────────────────────────────────────────────────────────────────────────────────────────────┤
// │                                                                                                 │
// │  1. AFFILIATE CODES                                                                             │
// │     • Players create codes with configurable rakeback (0-25%)                                   │
// │     • Rakeback = portion of affiliate reward returned to the referred player                    │
// │     • Codes are permanent once created; owner cannot be changed                                 │
// │                                                                                                 │
// │  2. REFERRAL CHAIN (3 tiers)                                                                    │
// │     Player → Affiliate (direct) → Upline1 (20%) → Upline2 (4%)                                  │
// │                                                                                                 │
// │     Example with 1000 FLIP reward and 10% rakeback:                                             │
// │       - Player rakeback: 100 FLIP (10% of 1000)                                                 │
// │       - Affiliate: 900 FLIP (1000 - 100)                                                        │
// │       - Upline1: 200 FLIP (20% of 1000)                                                         │
// │       - Upline2: 40 FLIP (20% of 200)                                                           │
// │                                                                                                 │
// │  3. PRESALE vs POST-PRESALE                                                                     │
// │     ┌──────────────────────┬──────────────────────────────────────┐                             │
// │     │ PRESALE ACTIVE       │ POST-PRESALE                         │                             │
// │     ├──────────────────────┼──────────────────────────────────────┤                             │
// │     │ Rewards → presale-   │ Rewards → creditFlip() immediate     │                             │
// │     │ CoinEarned mapping   │ mint + quest rewards                 │                             │
// │     │ Only bonds can pay   │ coin, bonds, gamepieces can pay      │                             │
// │     │ Claimed via coin's   │ Auto-distributed on each purchase    │                             │
// │     │ claimPresale()       │                                      │                             │
// │     └──────────────────────┴──────────────────────────────────────┘                             │
// │                                                                                                 │
// │  4. REFERRAL DECAY (anti-gaming)                                                                │
// │     • Full rewards for first 50 levels after joining                                            │
// │     • Linear decay from 100% → 25% over next 100 levels                                         │
// │     • Minimum 25% rewards thereafter                                                            │
// │     • Prevents early players from earning full rewards indefinitely                             │
// │                                                                                                 │
// │  5. LEADERBOARD TRACKING                                                                        │
// │     • Tracks top affiliate per game level                                                       │
// │     • Used to calculate bonus points for mint trait rolls                                       │
// │     • Score = whole tokens earned (6 decimal precision truncated)                               │
// │                                                                                                 │
// │  6. MAP AUTO-PURCHASE (post-presale)                                                            │
// │     • If affiliate reward ≥ 2× map cost, half is used for map purchases                         │
// │     • Only when gameState != 3 (not in burn phase) and RNG not locked                           │
// │     • Provides passive gamepiece accumulation for active affiliates                             │
// │                                                                                                 │
// └─────────────────────────────────────────────────────────────────────────────────────────────────┘
//
// ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
// │ SECURITY CONSIDERATIONS                                                                         │
// ├─────────────────────────────────────────────────────────────────────────────────────────────────┤
// │                                                                                                 │
// │  1. ACCESS CONTROL                                                                              │
// │     • payAffiliate(): coin, bonds, or gamepieces only                                           │
// │     • consumePresaleCoin(): coin only                                                           │
// │     • addPresaleCoinCredit(): coin, bonds, or bondsAdmin                                        │
// │     • shutdownPresale(): bonds only                                                             │
// │     • wire(): bondsAdmin only                                                                   │
// │                                                                                                 │
// │  2. ONE-TIME WIRING                                                                             │
// │     • Each external contract address can only be set once                                       │
// │     • Prevents malicious re-pointing after deployment                                           │
// │     • AlreadyConfigured guard on all setters                                                    │
// │                                                                                                 │
// │  3. REFERRAL LOCKING                                                                            │
// │     • Invalid referral attempts (self-referral, unknown code) lock the slot                     │
// │     • Locked slots use REF_CODE_LOCKED sentinel (bytes32(1))                                    │                        │
// │     • Locking only active after game is wired (referralLocksActive)                             │
// │                                                                                                 │
// │  4. CEI PATTERN                                                                                 │
// │     • consumePresaleCoin(): zeros balance before returning amount                               │
// │     • Protects against reentrancy even though caller is trusted                                 │
// │                                                                                                 │
// │  5. ETH HANDLING                                                                                │
// │     • receive() forwards all ETH to bonds contract                                              │
// │     • Prevents accidental ETH from being stuck                                                  │
// │                                                                                                 │
// │  6. OVERFLOW PROTECTION                                                                         │
// │     • _score96(): caps at type(uint96).max to prevent truncation errors                         │
// │     • All arithmetic in Solidity 0.8+ with automatic overflow checks                            │
// │                                                                                                 │
// └─────────────────────────────────────────────────────────────────────────────────────────────────┘
//
// ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
// │ TRUST ASSUMPTIONS                                                                               │
// ├─────────────────────────────────────────────────────────────────────────────────────────────────┤
// │                                                                                                 │
// │  • bonds: Trusted to call payAffiliate with correct amounts/parameters                          │
// │  • bondsAdmin: Trusted to wire dependencies and apply admin credits                             │
// │  • coin: Trusted to correctly process creditFlip and affiliateQuestReward                       │
// │  • gamepieces: Trusted to call payAffiliate with valid purchase data                            │
// │  • degenerusGame: Trusted to return accurate level() for join tracking                          │
// │                                                                                                 │
// │  These contracts form a closed trust perimeter; no external untrusted calls are made.           │
// │                                                                                                 │
// └─────────────────────────────────────────────────────────────────────────────────────────────────┘
//
// ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
// │ GAS OPTIMIZATION NOTES                                                                          │
// ├─────────────────────────────────────────────────────────────────────────────────────────────────┤
// │                                                                                                 │
// │  • PlayerScore struct packs (address, uint96) into single slot                                  │
// │  • AffiliateCodeInfo packs (address, uint8) into single slot                                    │
// │  • creditFlipBatch() used when multiple recipients (saves gas vs individual calls)              │
// │  • Local variable caching (coinAddr, gamepiecesAddr) to minimize SLOAD                          │
// │  • unchecked blocks for safe increments (cursor++)                                              │
// │                                                                                                 │
// └─────────────────────────────────────────────────────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════════════════════════════════════

/// @notice Interface for crediting FLIP tokens to players via the coin contract.
/// @dev Called post-presale to distribute affiliate rewards.
interface IDegenerusCoinAffiliate {
    /// @notice Credit FLIP to a single player.
    /// @param player Recipient address.
    /// @param amount Amount of FLIP (6 decimals).
    function creditFlip(address player, uint256 amount) external;

    /// @notice Credit FLIP to up to 3 players in a single call (gas optimization).
    /// @param players Array of 3 recipient addresses (unused slots should be address(0)).
    /// @param amounts Array of 3 amounts corresponding to each player.
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;

    /// @notice Calculate and record quest progress for affiliate earnings.
    /// @param player The affiliate receiving the base reward.
    /// @param amount The base affiliate amount (before quest bonus).
    /// @return Additional quest reward amount to add to the payout.
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256);
}

/// @notice Interface for purchasing maps on behalf of affiliates.
/// @dev Used for auto-purchase feature when affiliate rewards are large enough.
interface IDegenerusGamepiecesAffiliate {
    /// @notice Purchase maps for an affiliate using their earned rewards.
    /// @param buyer The affiliate who will receive the maps.
    /// @param quantity Number of maps to purchase.
    function purchaseMapForAffiliate(address buyer, uint256 quantity) external;
}

/**
 * @title DegenerusAffiliate
 * @notice Multi-tier affiliate referral system with presale support and leaderboard tracking.
 * @dev Central hub for all affiliate-related operations in the Degenerus ecosystem.
 *
 * INTEGRATION POINTS:
 * - DegenerusBonds: Calls payAffiliate() for bond purchases, addPresaleCoinCredit() for rewards
 * - DegenerusCoin: Calls consumePresaleCoin() for presale claims
 * - DegenerusGamepieces: Calls payAffiliate() for map purchases
 * - DegenerusAdmin: Can call addPresaleCoinCredit() for LINK donation rewards
 */
contract DegenerusAffiliate {
    // =====================================================================
    //                              EVENTS
    // =====================================================================

    /// @notice Emitted on affiliate code creation, referral registration, and reward payouts.
    /// @param amount Context-dependent: 1 = code created, 0 = player referred, >1 = reward amount.
    /// @param code The affiliate code involved (indexed for efficient log filtering).
    /// @param sender The player or affiliate address involved.
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);

    // =====================================================================
    //                              ERRORS
    // =====================================================================

    /// @notice Thrown when a function restricted to bonds is called by another address.
    error OnlyBonds();

    /// @notice Thrown when a function restricted to admin is called by another address.
    error OnlyAdmin();

    /// @notice Thrown when caller is not in the authorized set (coin, bonds, bondsAdmin, gamepieces).
    error OnlyAuthorized();

    /// @notice Thrown when attempting to re-wire an already-configured contract address.
    error AlreadyConfigured();

    /// @notice Thrown when attempting to create an affiliate code with zero or reserved value.
    error Zero();

    /// @notice Generic insufficient condition error (code taken, invalid referral, ETH forward fail).
    error Insufficient();

    /// @notice Thrown when rakeback percentage exceeds the maximum allowed (25%).
    error InvalidRakeback();

    /// @notice Thrown when a required address parameter is zero.
    error ZeroAddress();

    // =====================================================================
    //                              TYPES
    // =====================================================================

    /**
     * @notice Packed struct for leaderboard tracking (fits in single slot).
     * @dev Used in affiliateTopByLevel mapping to track best performer per level.
     *
     * STORAGE LAYOUT (32 bytes):
     * ┌────────────────────────────────────────────────────┐
     * │ [0:20]  player   address   Top affiliate address   │
     * │ [20:32] score    uint96    Whole tokens earned     │
     * └────────────────────────────────────────────────────┘
     */
    struct PlayerScore {
        address player; // 20 bytes - address of top affiliate
        uint96 score;   // 12 bytes - whole tokens (truncated from 6-decimal amounts)
    }

    /**
     * @notice Affiliate code ownership and rakeback configuration.
     * @dev Packed into single storage slot for gas efficiency.
     *
     * STORAGE LAYOUT (32 bytes, 11 bytes used):
     * ┌────────────────────────────────────────────────────┐
     * │ [0:20]  owner     address   Code owner/recipient   │
     * │ [20:21] rakeback  uint8     Rakeback % (0-25)      │
     * │ [21:32] unused    ---       11 bytes padding       │
     * └────────────────────────────────────────────────────┘
     */
    struct AffiliateCodeInfo {
        address owner;    // 20 bytes - receives affiliate rewards
        uint8 rakeback;   // 1 byte - percentage returned to referred player (0-25)
    }

    // =====================================================================
    //                            CONSTANTS
    // =====================================================================

    /// @notice Token decimal multiplier (FLIP has 6 decimals).
    /// @dev Used to convert between raw amounts and whole token counts for scoring.
    uint256 private constant MILLION = 1e6;

    /// @notice Maximum bonus points an affiliate can earn from leaderboard position.
    /// @dev Applied to mint trait rolls; top 20% of leaderboard earns this max.
    uint256 private constant AFFILIATE_BONUS_MAX = 25;

    /// @notice Scaling factor for bonus calculation: top 20% earns max bonus.
    /// @dev Formula: (playerScore * SCALE) / topScore, capped at MAX.
    ///      125 = 25 * 5, meaning you need 20% of top score to hit max.
    uint256 private constant AFFILIATE_BONUS_SCALE = AFFILIATE_BONUS_MAX * 5;

    /// @notice Base unit for coin pricing calculations.
    /// @dev 1 billion = 1e9, represents the ETH-to-coin conversion base.
    uint256 private constant PRICE_COIN_UNIT = 1_000_000_000;

    /// @notice Sentinel value indicating a player's referral slot is permanently locked.
    /// @dev Set when a player makes an invalid referral attempt (self-referral, unknown code)
    ///      after the game has started. Prevents gaming by trying multiple codes.
    bytes32 private constant REF_CODE_LOCKED = bytes32(uint256(1));

    // =====================================================================
    //                      IMMUTABLE / WIRING
    // =====================================================================

    /// @notice DegenerusBonds contract address (set at construction, immutable).
    /// @dev Primary caller for payAffiliate() during bond purchases.
    ///      Also authorized for shutdownPresale() and addPresaleCoinCredit().
    address public immutable bonds;

    /// @notice DegenerusAdmin address (set at construction, immutable).
    /// @dev Authorized for wire() and addPresaleCoinCredit() as fallback admin.
    address public immutable bondsAdmin;

    /// @notice DegenerusCoin contract for FLIP token operations.
    /// @dev Set once via wire(). Used for creditFlip/creditFlipBatch/affiliateQuestReward.
    ///      SECURITY: One-time wiring prevents malicious re-pointing.
    IDegenerusCoinAffiliate private coin;

    /// @notice DegenerusGame contract for level queries.
    /// @dev Set once via wire(). Used to record referralJoinLevel and enable referral locking.
    ///      SECURITY: One-time wiring prevents malicious re-pointing.
    IDegenerusGame private degenerusGame;

    /// @notice DegenerusGamepieces contract for map purchases.
    /// @dev Set once via wire(). Used for auto-purchasing maps for affiliates.
    ///      SECURITY: One-time wiring prevents malicious re-pointing.
    IDegenerusGamepiecesAffiliate private degenerusGamepieces;

    // =====================================================================
    //                        AFFILIATE STATE
    // =====================================================================

    /// @notice Mapping from affiliate code (bytes32) to ownership info.
    /// @dev codes are permanent once created; owner cannot be changed.
    ///      Reserved value: bytes32(0) = invalid, bytes32(1) = REF_CODE_LOCKED sentinel.
    mapping(bytes32 => AffiliateCodeInfo) public affiliateCode;

    /// @notice Per-level earnings tracking: level → affiliate → raw token amount.
    /// @dev Used for leaderboard calculations and bonus point determination.
    ///      Amounts include 6 decimal places; divide by MILLION for whole tokens.
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;

    /// @notice Player's chosen referral code (or REF_CODE_LOCKED if locked).
    /// @dev Private to prevent external manipulation; use referralCodeOf() view.
    ///      bytes32(0) = not yet set, REF_CODE_LOCKED = permanently locked.
    mapping(address => bytes32) private playerReferralCode;

    /// @notice Records the game level when a player's referral was established.
    /// @dev Used by _referralRewardScaleBps() to calculate reward decay.
    ///      Level 0 = presale/unwired join; decay starts after 50 levels.
    mapping(address => uint24) public referralJoinLevel;

    /// @notice Presale-era affiliate earnings awaiting claim.
    /// @dev Accumulated during presale, claimable via coin.claimPresale() after shutdown.
    ///      Cleared to 0 when consumePresaleCoin() is called.
    mapping(address => uint256) public presaleCoinEarned;

    /// @notice Top affiliate per game level for bonus calculations.
    /// @dev Private storage; use affiliateTop() view to read.
    ///      Updated in _updateTopAffiliate() when affiliate exceeds current top.
    mapping(uint24 => PlayerScore) private affiliateTopByLevel;

    /// @notice Total unclaimed presale coin across all players.
    /// @dev Invariant: sum(presaleCoinEarned[*]) == presaleClaimableTotal.
    ///      Used for accounting verification; decremented on consume.
    uint256 public presaleClaimableTotal;

    /// @notice Flag indicating presale period has ended.
    /// @dev Set permanently via shutdownPresale(). Once true:
    ///      - payAffiliate() switches from presale accumulation to direct creditFlip()
    ///      - consumePresaleCoin() becomes functional
    ///      - Cannot be unset (one-way state transition)
    bool private presaleShutdown;

    /// @notice Flag enabling referral slot locking on invalid attempts.
    /// @dev Activated when degenerusGame is wired (game has started).
    ///      When true, invalid referral attempts lock the slot permanently.
    ///      Prevents gaming by repeatedly trying codes until finding valid one.
    bool private referralLocksActive;

    // =====================================================================
    //                           CONSTRUCTOR
    // =====================================================================

    /**
     * @notice Initialize affiliate contract with trusted contract addresses.
     * @dev Both addresses are immutable after deployment.
     *
     * DEPLOYMENT ORDER:
     * 1. Deploy DegenerusBonds
     * 2. Deploy DegenerusAffiliate(bonds, bondsAdmin)
     * 3. Call wire() to connect coin, game, gamepieces
     *
     * @param bonds_ Address of DegenerusBonds contract (primary caller).
     * @param bondsAdmin_ Address of DegenerusAdmin (admin fallback).
     */
    constructor(address bonds_, address bondsAdmin_) {
        // SECURITY: Prevent zero addresses which would brick access control.
        if (bonds_ == address(0) || bondsAdmin_ == address(0)) revert ZeroAddress();
        bonds = bonds_;
        bondsAdmin = bondsAdmin_;
    }

    // =====================================================================
    //                            WIRING
    // =====================================================================

    /**
     * @notice Wire external contract dependencies via an address array.
     * @dev Called by bondsAdmin during ecosystem setup.
     *
     * ARRAY FORMAT: [coin, game, gamepieces]
     * - Index 0: DegenerusCoin address
     * - Index 1: DegenerusGame address
     * - Index 2: DegenerusGamepieces address
     *
     * SECURITY:
     * - Each address can only be set once (AlreadyConfigured guard)
     * - Passing existing address is allowed (idempotent)
     * - Passing address(0) skips that slot (except coin which requires valid addr)
     *
     * @param addresses Array of contract addresses to wire.
     */
    function wire(address[] calldata addresses) external {
        // SECURITY: Only bondsAdmin can wire contracts.
        address admin = bondsAdmin;
        if (msg.sender != admin) revert OnlyAdmin();
        _setCoin(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setGamepieces(addresses.length > 2 ? addresses[2] : address(0));
    }

    /**
     * @notice Internal setter for coin contract address.
     * @dev Requires non-zero address if coin not yet set.
     *      SECURITY: One-time wiring pattern prevents malicious re-pointing.
     * @param coinAddr Address of DegenerusCoin contract.
     */
    function _setCoin(address coinAddr) private {
        if (coinAddr == address(0)) {
            // Zero passed but coin already set = no-op; zero with no coin = error.
            if (address(coin) == address(0)) revert ZeroAddress();
            return;
        }
        address current = address(coin);
        if (current == address(0)) {
            coin = IDegenerusCoinAffiliate(coinAddr);
        } else if (coinAddr != current) {
            // SECURITY: Prevent re-pointing to different address.
            revert AlreadyConfigured();
        }
        // Same address = idempotent, no error.
    }

    /**
     * @notice Internal setter for game contract address.
     * @dev Activates referralLocksActive when first set.
     *      SECURITY: One-time wiring pattern prevents malicious re-pointing.
     * @param gameAddr Address of DegenerusGame contract.
     */
    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return; // Skip if not provided.
        address current = address(degenerusGame);
        if (current == address(0)) {
            degenerusGame = IDegenerusGame(gameAddr);
            // IMPORTANT: Enable referral locking once game is live.
            // This prevents players from repeatedly trying codes until finding a valid one.
            referralLocksActive = true;
        } else if (gameAddr != current) {
            // SECURITY: Prevent re-pointing to different address.
            revert AlreadyConfigured();
        }
    }

    /**
     * @notice Internal setter for gamepieces contract address.
     * @dev SECURITY: One-time wiring pattern prevents malicious re-pointing.
     * @param gamepiecesAddr Address of DegenerusGamepieces contract.
     */
    function _setGamepieces(address gamepiecesAddr) private {
        if (gamepiecesAddr == address(0)) return; // Skip if not provided.
        address current = address(degenerusGamepieces);
        if (current == address(0)) {
            degenerusGamepieces = IDegenerusGamepiecesAffiliate(gamepiecesAddr);
        } else if (gamepiecesAddr != current) {
            // SECURITY: Prevent re-pointing to different address.
            revert AlreadyConfigured();
        }
    }

    // =====================================================================
    //                    EXTERNAL PLAYER ENTRYPOINTS
    // =====================================================================

    /**
     * @notice Create a new affiliate code owned by the caller.
     * @dev Anyone can create an affiliate code. Codes are permanent and cannot be
     *      transferred or deleted. The rakeback percentage determines how much of
     *      the affiliate reward is returned to referred players as an incentive.
     *
     * VALIDATION:
     * - code_ != bytes32(0) (reserved for "no code")
     * - code_ != REF_CODE_LOCKED (reserved sentinel value)
     * - code_ not already taken
     * - rakebackPct <= 25 (max 25% rakeback)
     *
     * @param code_ The affiliate code to claim (typically a short string cast to bytes32).
     * @param rakebackPct Percentage of rewards returned to referred players (0-25).
     */
    function createAffiliateCode(bytes32 code_, uint8 rakebackPct) external {
        // SECURITY: Prevent reserved values from being claimed.
        if (code_ == bytes32(0) || code_ == REF_CODE_LOCKED) revert Zero();
        // SECURITY: Cap rakeback to prevent affiliate from giving away all rewards.
        if (rakebackPct > 25) revert InvalidRakeback();
        AffiliateCodeInfo storage info = affiliateCode[code_];
        // SECURITY: First-come-first-served; codes cannot be overwritten.
        if (info.owner != address(0)) revert Insufficient();
        affiliateCode[code_] = AffiliateCodeInfo({owner: msg.sender, rakeback: rakebackPct});
        emit Affiliate(1, code_, msg.sender); // 1 = code created
    }

    /**
     * @notice Register the caller as referred by an affiliate code.
     * @dev This is the explicit user-initiated way to set a referrer.
     *      Alternatively, referrers can be set implicitly during payAffiliate().
     *      Once set (or locked), cannot be changed.
     *
     * VALIDATION:
     * - code_ must exist (owner != address(0))
     * - code_ owner must not be the caller (no self-referral)
     * - caller must not already have a referral code set
     *
     * @param code_ The affiliate code to register under.
     */
    function referPlayer(bytes32 code_) external {
        AffiliateCodeInfo storage info = affiliateCode[code_];
        address referrer = info.owner;
        // SECURITY: Prevent invalid codes and self-referral.
        if (referrer == address(0) || referrer == msg.sender) revert Insufficient();
        bytes32 existing = playerReferralCode[msg.sender];
        // SECURITY: Only allow setting referrer once.
        if (existing != bytes32(0)) revert Insufficient();
        playerReferralCode[msg.sender] = code_;
        // Record the level at which the player joined (for reward decay calculation).
        address gameAddr = address(degenerusGame);
        if (gameAddr != address(0)) {
            _recordReferralJoinLevel(msg.sender, degenerusGame.level());
        } else {
            // Presale/unwired: record join at level 0 for decay tracking.
            _recordReferralJoinLevel(msg.sender, 0);
        }
        emit Affiliate(0, code_, msg.sender); // 0 = player referred
    }

    /**
     * @notice Get the referrer address for a player.
     * @dev Returns address(0) if player has no valid referrer.
     * @param player The player to look up.
     * @return The referrer's address, or address(0) if none.
     */
    function getReferrer(address player) external view returns (address) {
        return _referrerAddress(player);
    }

    /**
     * @notice Check if presale period is still active.
     * @dev Returns true until shutdownPresale() is called by bonds.
     *      During presale, affiliate rewards are deferred (not immediately minted).
     * @return True if presale is active, false if shutdown.
     */
    function presaleActive() external view returns (bool) {
        return !presaleShutdown;
    }

    /**
     * @notice Permanently close the presale period.
     * @dev Can only be called by bonds contract. One-way state transition.
     *      After shutdown:
     *      - payAffiliate() switches to direct creditFlip() distribution
     *      - consumePresaleCoin() becomes claimable
     *
     * ACCESS: bonds only.
     */
    function shutdownPresale() external {
        // SECURITY: Only bonds can shutdown presale.
        if (msg.sender != bonds) revert OnlyBonds();
        presaleShutdown = true;
    }

    // =====================================================================
    //                    GAMEPLAY ENTRYPOINTS
    // =====================================================================

    /**
     * @notice Process affiliate rewards for a purchase or gameplay action.
     * @dev Core payout logic. Handles referral resolution, reward scaling,
     *      multi-tier distribution, and presale vs post-presale logic.
     *
     * ACCESS: coin, bonds, or gamepieces only.
     *
     * REWARD FLOW:
     * ┌────────────────────────────────────────────────────────────────────┐
     * │ 1. Resolve referral code (stored or provided)                      │
     * │ 2. Apply reward decay based on levels since join                   │
     * │ 3. Calculate rakeback (returned to player)                         │
     * │ 4. Pay direct affiliate (base - rakeback)                          │
     * │ 5. Pay upline1 (20% of scaled amount)                              │
     * │ 6. Pay upline2 (20% of upline1 share = 4%)                         │
     * │ 7. Quest rewards added on top (post-presale only)                  │
     * │ 8. Map auto-purchase if conditions met (post-presale only)         │
     * └────────────────────────────────────────────────────────────────────┘
     *
     * PRESALE vs POST-PRESALE:
     * - Presale: Rewards deferred to presaleCoinEarned mapping
     * - Post-presale: Rewards immediately distributed via creditFlip()
     *
     * @param amount Base reward amount (6 decimals).
     * @param code Affiliate code provided with the transaction (may be bytes32(0)).
     * @param sender The player making the purchase.
     * @param lvl Current game level (for join tracking and leaderboard).
     * @param gameState Current game FSM state (3 = burn phase, blocks map purchase).
     * @param rngLocked Whether VRF is pending (blocks map purchase).
     * @return playerRakeback Amount of rakeback credited to the player.
     */
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl,
        uint8 gameState,
        bool rngLocked
    ) external returns (uint256 playerRakeback) {
        // ─────────────────────────────────────────────────────────────────
        // ACCESS CONTROL
        // ─────────────────────────────────────────────────────────────────
        address caller = msg.sender;
        address coinAddr = address(coin);
        address gamepiecesAddr = address(degenerusGamepieces);
        // SECURITY: Only trusted contracts can distribute affiliate rewards.
        if (caller != coinAddr && caller != bonds && caller != gamepiecesAddr) revert OnlyAuthorized();

        // ─────────────────────────────────────────────────────────────────
        // PRESALE GATE
        // ─────────────────────────────────────────────────────────────────
        bool presaleOpen = !presaleShutdown;
        if (presaleOpen) {
            // During presale, only bond purchases accrue rewards.
            // This keeps presale distribution anchored to bond purchases.
            if (caller != bonds) return 0;
        } else {
            // Post-presale requires coin to be wired for distribution.
            if (coinAddr == address(0)) return 0;
        }

        // ─────────────────────────────────────────────────────────────────
        // REFERRAL RESOLUTION
        // ─────────────────────────────────────────────────────────────────
        bytes32 storedCode = playerReferralCode[sender];
        // SECURITY: Locked slots cannot earn or generate affiliate rewards.
        if (storedCode == REF_CODE_LOCKED) return 0;

        AffiliateCodeInfo storage info;
        if (storedCode == bytes32(0)) {
            // Bonds never pass a code; don't lock or set a referral on "no code" paths.
            if (code == bytes32(0) && caller == bonds) return 0;
            // No stored code - try to use the provided code.
            AffiliateCodeInfo storage candidate = affiliateCode[code];
            if (candidate.owner == address(0) || candidate.owner == sender) {
                // Invalid code or self-referral: lock slot if game is active.
                // SECURITY: Prevents gaming by trying codes until one works.
                if (referralLocksActive) {
                    playerReferralCode[sender] = REF_CODE_LOCKED;
                }
                return 0;
            }
            // Valid code: store it permanently.
            playerReferralCode[sender] = code;
            info = candidate;
            storedCode = code;
            _recordReferralJoinLevel(sender, lvl);
        } else {
            // Use the stored code.
            info = affiliateCode[storedCode];
            if (info.owner == address(0)) {
                // Edge case: stored code became invalid (shouldn't happen).
                // Lock or clear the slot.
                playerReferralCode[sender] = referralLocksActive ? REF_CODE_LOCKED : bytes32(0);
                return 0;
            }
        }

        // ─────────────────────────────────────────────────────────────────
        // FINAL VALIDATION
        // ─────────────────────────────────────────────────────────────────
        address affiliateAddr = info.owner;
        // SECURITY: Double-check no self-referral (belt-and-suspenders).
        if (affiliateAddr == address(0) || affiliateAddr == sender) {
            playerReferralCode[sender] = referralLocksActive ? REF_CODE_LOCKED : bytes32(0);
            return 0;
        }
        uint8 rakebackPct = info.rakeback;

        // ─────────────────────────────────────────────────────────────────
        // REWARD CALCULATION
        // ─────────────────────────────────────────────────────────────────
        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];

        // Apply decay based on how many levels since the referral was established.
        // Full rewards for 50 levels, then linear decay to 25% over next 100 levels.
        uint256 rewardScaleBps = _referralRewardScaleBps(sender, lvl);
        uint256 scaledAmount = rewardScaleBps == 10_000 ? amount : (amount * rewardScaleBps) / 10_000;

        // Calculate rakeback (returned to player) and affiliate share.
        uint256 rakebackShare = (scaledAmount * uint256(rakebackPct)) / 100;
        uint256 affiliateShareBase = scaledAmount - rakebackShare;

        // Update leaderboard tracking (uses base amount, ignores quest bonuses).
        uint256 newTotal = earned[affiliateAddr] + affiliateShareBase;
        earned[affiliateAddr] = newTotal;
        _updateTopAffiliate(affiliateAddr, newTotal, lvl);
        playerRakeback = rakebackShare;

        // ─────────────────────────────────────────────────────────────────
        // DISTRIBUTION (POST-PRESALE)
        // ─────────────────────────────────────────────────────────────────
        if (!presaleOpen) {
            // Batch recipients for gas efficiency.
            address[3] memory players;
            uint256[3] memory amounts;
            uint256 cursor;

            // Add quest reward bonus on top of base affiliate share.
            uint256 questReward = coin.affiliateQuestReward(affiliateAddr, affiliateShareBase);
            uint256 totalFlipAward = affiliateShareBase + questReward;

            // ─────────────────────────────────────────────────────────────
            // MAP AUTO-PURCHASE
            // ─────────────────────────────────────────────────────────────
            // If reward is large enough and game conditions allow, auto-purchase maps.
            // Conditions: not in burn phase (gameState != 3) and VRF not pending.
            if (gameState != 3 && !rngLocked) {
                IDegenerusGamepiecesAffiliate gp = degenerusGamepieces;
                if (address(gp) != address(0)) {
                    uint256 mapCost = PRICE_COIN_UNIT / 4; // 0.25 FLIP per map
                    // Only auto-purchase if reward covers at least 2 maps (use half for maps).
                    if (totalFlipAward >= mapCost * 2) {
                        uint256 mapBudget = totalFlipAward / 2;
                        uint256 potentialMaps = mapBudget / mapCost;
                        uint32 mapQty = uint32(potentialMaps);
                        uint256 mapSpend = mapCost * uint256(mapQty);
                        totalFlipAward -= mapSpend;
                        gp.purchaseMapForAffiliate(affiliateAddr, mapQty);
                    }
                }
            }

            players[cursor] = affiliateAddr;
            amounts[cursor] = totalFlipAward;
            unchecked {
                ++cursor;
            }

            // ─────────────────────────────────────────────────────────────
            // UPLINE TIER 1 (20% of scaled amount)
            // ─────────────────────────────────────────────────────────────
            address upline = _referrerAddress(affiliateAddr);
            if (upline != address(0) && upline != sender) {
                uint256 baseBonus = scaledAmount / 5; // 20%
                uint256 questRewardUpline = coin.affiliateQuestReward(upline, baseBonus);
                uint256 totalUpline = baseBonus + questRewardUpline;
                earned[upline] = earned[upline] + baseBonus;

                players[cursor] = upline;
                amounts[cursor] = totalUpline;
                unchecked {
                    ++cursor;
                }

                // ─────────────────────────────────────────────────────────
                // UPLINE TIER 2 (20% of tier 1 = 4% of original)
                // ─────────────────────────────────────────────────────────
                address upline2 = _referrerAddress(upline);
                if (upline2 != address(0)) {
                    uint256 bonus2 = baseBonus / 5; // 20% of 20% = 4%
                    uint256 questReward2 = coin.affiliateQuestReward(upline2, bonus2);
                    uint256 totalUpline2 = bonus2 + questReward2;
                    earned[upline2] = earned[upline2] + bonus2;

                    players[cursor] = upline2;
                    amounts[cursor] = totalUpline2;
                    unchecked {
                        ++cursor;
                    }
                }
            }

            // Distribute rewards (single call vs batch for gas efficiency).
            if (cursor != 0) {
                if (cursor == 1) {
                    coin.creditFlip(players[0], amounts[0]);
                } else {
                    coin.creditFlipBatch(players, amounts);
                }
            }
        } else {
            // ─────────────────────────────────────────────────────────────
            // DISTRIBUTION (PRESALE)
            // ─────────────────────────────────────────────────────────────
            // Defer all rewards to presaleCoinEarned mapping.
            // No quest rewards or map purchases during presale.
            uint256 presaleTotalIncrease = affiliateShareBase;
            presaleCoinEarned[affiliateAddr] += affiliateShareBase;

            // Upline tier 1 (20% of scaled amount).
            address uplinePre = _referrerAddress(affiliateAddr);
            if (uplinePre != address(0) && uplinePre != sender) {
                uint256 baseBonusPre = scaledAmount / 5;
                earned[uplinePre] = earned[uplinePre] + baseBonusPre;
                presaleCoinEarned[uplinePre] += baseBonusPre;
                presaleTotalIncrease += baseBonusPre;

                // Upline tier 2 (20% of tier 1).
                address upline2Pre = _referrerAddress(uplinePre);
                if (upline2Pre != address(0)) {
                    uint256 bonus2Pre = baseBonusPre / 5;
                    earned[upline2Pre] = earned[upline2Pre] + bonus2Pre;
                    presaleCoinEarned[upline2Pre] += bonus2Pre;
                    presaleTotalIncrease += bonus2Pre;
                }
            }

            // Credit rakeback to the purchasing player during presale.
            if (playerRakeback != 0) {
                presaleCoinEarned[sender] += playerRakeback;
                presaleTotalIncrease += playerRakeback;
            }

            // Update global presale total for accounting invariant.
            if (presaleTotalIncrease != 0) {
                presaleClaimableTotal += presaleTotalIncrease;
            }
        }

        emit Affiliate(amount, storedCode, sender);
        return playerRakeback;
    }

    /**
     * @notice Consume and return a player's accrued presale coin for minting.
     * @dev Called by DegenerusCoin.claimPresale() to convert deferred rewards to tokens.
     *
     * ACCESS: coin only.
     *
     * CEI PATTERN:
     * 1. Read amount
     * 2. Zero the balance (effect)
     * 3. Return amount (caller handles minting)
     *
     * INVARIANT: presaleClaimableTotal is decremented to maintain sum consistency.
     *
     * @param player The player claiming their presale rewards.
     * @return amount The amount to mint for the player.
     */
    function consumePresaleCoin(address player) external returns (uint256 amount) {
        // SECURITY: Only coin contract can consume presale balances.
        if (msg.sender != address(coin)) revert OnlyAuthorized();
        // Only claimable after presale ends.
        if (!presaleShutdown) return 0;

        amount = presaleCoinEarned[player];
        if (amount != 0) {
            // CEI: Zero balance before returning (even though caller is trusted).
            presaleCoinEarned[player] = 0;
            // Maintain invariant: presaleClaimableTotal = sum(presaleCoinEarned).
            // Defensive: handle edge case where total drifted (shouldn't happen).
            if (amount <= presaleClaimableTotal) {
                presaleClaimableTotal -= amount;
            } else {
                presaleClaimableTotal = 0;
            }
        }
    }

    /**
     * @notice Credit presale coin from external sources (e.g., LINK donation rewards).
     * @dev Allows coin, bonds, or bondsAdmin to add presale credits for special cases.
     *
     * ACCESS: coin, bonds, or bondsAdmin.
     *
     * USE CASES:
     * - LINK donation rewards via DegenerusAdmin
     * - Manual corrections by admin
     * - Bonus distributions
     *
     * @param player The player to credit.
     * @param amount The amount to credit (6 decimals).
     */
    function addPresaleCoinCredit(address player, uint256 amount) external {
        address caller = msg.sender;
        // SECURITY: Only trusted contracts can add presale credits.
        if (caller != address(coin) && caller != bonds && caller != bondsAdmin) revert OnlyAuthorized();
        // Skip no-op calls.
        if (player == address(0) || amount == 0) return;
        presaleCoinEarned[player] += amount;
        presaleClaimableTotal += amount;
    }

    /**
     * @notice Forward any received ETH to the bonds contract.
     * @dev Prevents ETH from being accidentally stuck in this contract.
     *      This contract should not hold ETH; all ETH flows through bonds.
     *
     * SECURITY: Reverts if forward fails, preventing silent loss of funds.
     */
    receive() external payable {
        (bool ok, ) = payable(bonds).call{value: msg.value}("");
        if (!ok) revert Insufficient();
    }

    // =====================================================================
    //                              VIEWS
    // =====================================================================

    /**
     * @notice Get the top affiliate for a given game level.
     * @dev Returns the affiliate with the highest earnings for that level.
     *      Used for bonus point calculations in mint trait rolls.
     * @param lvl The game level to query.
     * @return player Address of the top affiliate.
     * @return score Their score in whole tokens (6-decimal amount / MILLION).
     */
    function affiliateTop(uint24 lvl) public view returns (address player, uint96 score) {
        PlayerScore memory stored = affiliateTopByLevel[lvl];
        return (stored.player, stored.score);
    }

    /**
     * @notice Get leaderboard info for bonus calculations.
     * @dev Returns both the top score and the queried player's score.
     *      Used by frontends to show relative position.
     * @param lvl The game level to query.
     * @param player The player to get score for.
     * @return topScore The highest score for this level.
     * @return playerScore The queried player's score (whole tokens).
     */
    function affiliateBonusInfo(uint24 lvl, address player) external view returns (uint96 topScore, uint256 playerScore) {
        topScore = affiliateTopByLevel[lvl].score;
        if (topScore == 0 || player == address(0)) return (topScore, 0);
        uint256 earned = affiliateCoinEarned[lvl][player];
        if (earned == 0) return (topScore, 0);
        playerScore = earned / MILLION;
    }

    /**
     * @notice Calculate the best affiliate bonus points for a player.
     * @dev Checks both the previous level and two levels back, returns the better result.
     *      This allows players to benefit from good performance in recent levels.
     *
     * BONUS CALCULATION:
     * - Points = (playerScore * AFFILIATE_BONUS_SCALE) / topScore
     * - Capped at AFFILIATE_BONUS_MAX (25 points)
     * - Top 20% of leaderboard earns maximum bonus
     *
     * @param currLevel The current game level.
     * @param player The player to calculate bonus for.
     * @return points Bonus points (0 to AFFILIATE_BONUS_MAX).
     */
    function affiliateBonusPointsBest(uint24 currLevel, address player) external view returns (uint256 points) {
        if (player == address(0) || currLevel == 0) return 0;
        unchecked {
            uint24 prevLevel = currLevel - 1;
            uint256 best = _affiliateBonusPointsAt(prevLevel, player);
            // Early return if already at max or only one level of history.
            if (best == AFFILIATE_BONUS_MAX || currLevel == 1) return best;
            // Check two levels back for potentially better performance.
            uint256 alt = _affiliateBonusPointsAt(prevLevel - 1, player);
            return alt > best ? alt : best;
        }
    }

    // =====================================================================
    //                        INTERNAL HELPERS
    // =====================================================================

    /**
     * @notice Get a player's valid referral code (or bytes32(0) if invalid/locked).
     * @dev Validates that the code exists and has an owner.
     * @param player The player to look up.
     * @return code The valid referral code, or bytes32(0).
     */
    function _referralCode(address player) private view returns (bytes32 code) {
        code = playerReferralCode[player];
        // Return zero for unset or locked slots.
        if (code == bytes32(0) || code == REF_CODE_LOCKED) return bytes32(0);
        // Return zero if the code's owner was somehow cleared (shouldn't happen).
        if (affiliateCode[code].owner == address(0)) return bytes32(0);
        return code;
    }

    /**
     * @notice External view to get a player's referral code.
     * @dev Wrapper around _referralCode for external access.
     * @param player The player to look up.
     * @return code The valid referral code, or bytes32(0).
     */
    function referralCodeOf(address player) external view returns (bytes32 code) {
        return _referralCode(player);
    }

    /**
     * @notice Get the referrer's address for a player.
     * @dev Returns address(0) if player has no valid referrer.
     * @param player The player to look up.
     * @return The referrer's address.
     */
    function _referrerAddress(address player) private view returns (address) {
        bytes32 code = _referralCode(player);
        if (code == bytes32(0)) return address(0);
        return affiliateCode[code].owner;
    }

    /**
     * @notice Record the level at which a player's referral was established.
     * @dev Only records if not already set (first referral wins).
     *      Used for calculating reward decay over time (level 0 allowed for presale).
     * @param player The player being referred.
     * @param lvl The current game level.
     */
    function _recordReferralJoinLevel(address player, uint24 lvl) private {
        if (player == address(0)) return;
        // Only record the first join level (immutable after set).
        if (referralJoinLevel[player] == 0) {
            referralJoinLevel[player] = lvl;
        }
    }

    /**
     * @notice Calculate the reward scaling factor based on levels since join.
     * @dev Implements anti-gaming decay to prevent early referrers from
     *      earning full rewards indefinitely.
     *
     * DECAY SCHEDULE:
     * ┌─────────────────────────────────────────────────────────────────┐
     * │ Levels since join    │ Scale (bps)  │ Percentage               │
     * ├─────────────────────────────────────────────────────────────────┤
     * │ 0 - 50               │ 10,000       │ 100% (full rewards)      │
     * │ 51 - 150             │ linear decay │ 100% → 25% (-0.75%/lvl)  │
     * │ 151+                 │ 2,500        │ 25% (minimum floor)      │
     * └─────────────────────────────────────────────────────────────────┘
     *
     * @param player The player whose rewards are being calculated.
     * @param currentLevel The current game level.
     * @return scaleBps Scaling factor in basis points (2500-10000).
     */
    function _referralRewardScaleBps(address player, uint24 currentLevel) private view returns (uint256 scaleBps) {
        uint24 joinLevel = referralJoinLevel[player];
        // At/before join = full rewards (presale join level can be 0).
        if (currentLevel <= joinLevel) return 10_000;

        uint256 delta = uint256(currentLevel - joinLevel);
        // Grace period: first 50 levels = full rewards.
        if (delta <= 50) return 10_000;
        // After 150 levels = minimum 25%.
        if (delta >= 150) return 2_500;

        // Linear decay zone: 51-150 levels since join.
        uint256 decayLevels = delta - 50; // 0 at start of decay window
        uint256 reduction = decayLevels * 75; // 0.75% per level (75 bps)
        scaleBps = 10_000 - reduction;
        // Defensive floor (should be unreachable but belt-and-suspenders).
        if (scaleBps < 2_500) {
            scaleBps = 2_500;
        }
    }

    /**
     * @notice Convert a raw amount to a uint96 score in whole tokens.
     * @dev Caps at uint96 max to prevent overflow/truncation errors.
     *      uint96 max ≈ 79 billion whole tokens, far exceeding realistic supply.
     * @param s Raw amount (6 decimals).
     * @return Whole token count as uint96.
     */
    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        // SECURITY: Cap at max to prevent truncation errors.
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    /**
     * @notice Calculate bonus points for a player at a specific level.
     * @dev Points are proportional to player's score relative to top score.
     *      Top 20% of leaderboard earns maximum bonus.
     *
     * FORMULA: points = min(AFFILIATE_BONUS_MAX, (playerScore * SCALE) / topScore)
     *
     * @param lvl The game level to calculate for.
     * @param player The player to calculate bonus for.
     * @return points Bonus points (0 to AFFILIATE_BONUS_MAX).
     */
    function _affiliateBonusPointsAt(uint24 lvl, address player) private view returns (uint256 points) {
        uint96 topScore = affiliateTopByLevel[lvl].score;
        if (topScore == 0) return 0;
        uint256 earned = affiliateCoinEarned[lvl][player];
        if (earned == 0) return 0;
        uint256 playerScore = earned / MILLION;
        if (playerScore == 0) return 0;
        unchecked {
            // Scale: playerScore * 125 / topScore, capped at 25.
            // This means 20% of top score = max bonus.
            uint256 scaled = (playerScore * AFFILIATE_BONUS_SCALE) / uint256(topScore);
            return scaled > AFFILIATE_BONUS_MAX ? AFFILIATE_BONUS_MAX : scaled;
        }
    }

    /**
     * @notice Update the top affiliate for a level if the new score beats current.
     * @dev Only updates storage if score exceeds current top.
     *      Leaderboard tracking is per-level (resets each level).
     * @param player The affiliate whose score is being checked.
     * @param total The affiliate's new total earnings (raw, 6 decimals).
     * @param lvl The game level.
     */
    function _updateTopAffiliate(address player, uint256 total, uint24 lvl) private {
        uint96 score = _score96(total);
        PlayerScore memory current = affiliateTopByLevel[lvl];
        if (score > current.score) {
            affiliateTopByLevel[lvl] = PlayerScore({player: player, score: score});
        }
    }
}

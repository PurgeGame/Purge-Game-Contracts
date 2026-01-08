// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";
import {ContractAddresses} from "./ContractAddresses.sol";

/**
 * @title DegenerusAffiliate
 * @author Burnie Degenerus
 * @notice Multi-tier affiliate referral system with configurable rakeback and decay mechanics.
 *
 * @dev ARCHITECTURE:
 *      - 3-tier referral: Player → Affiliate (base) → Upline1 (20%) → Upline2 (4%)
 *      - Rakeback: 0-25% of reward returned to referred player
 *      - Presale: immediate creditFlip (ContractAddresses.BONDS only); Post-presale: immediate creditFlip()
 *      - Decay: 100% rewards (levels 0-50) → linear decay to 25% (levels 51-150) → 25% floor
 *      - Leaderboard: tracks top affiliate per level for mint trait bonus
 *
 * @dev SECURITY:
 *      - Access control: payAffiliate (coin/ContractAddresses.BONDS/gamepieces), consumePresaleCoin (coin only)
 *      - Referral locking: invalid codes lock slot post-presale (REF_CODE_LOCKED sentinel)
 *      - CEI pattern in consumePresaleCoin (zeros balance before return)
 *      - Fixed contract addresses at deploy (no re-pointing)
 */

/// @notice Interface for crediting FLIP tokens to players via the coin contract.
/// @dev Called post-presale to distribute affiliate rewards.
interface IDegenerusCoinAffiliate {
    /// @notice Credit FLIP to a single player.
    /// @param player Recipient address.
    /// @param amount Amount of FLIP (18 decimals).
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

/**
 * @title DegenerusAffiliate
 * @notice Multi-tier affiliate referral system with presale support and leaderboard tracking.
 * @dev Central hub for all affiliate-related operations in the Degenerus ecosystem.
 *
 * INTEGRATION POINTS:
 * - DegenerusBonds: Calls payAffiliate() for bond purchases, addPresaleCoinCredit() for rewards
 * - BurnieCoin: Calls consumePresaleCoin() for presale claims
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

    /// @notice Thrown when a function restricted to ContractAddresses.BONDS is called by another address.
    error OnlyBonds();

    /// @notice Thrown when caller is not in the authorized set (coin, ContractAddresses.BONDS, ContractAddresses.ADMIN, gamepieces).
    error OnlyAuthorized();

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
     * +----------------------------------------------------+
     * | [0:20]  player   address   Top affiliate address   |
     * | [20:32] score    uint96    Raw BURNIE earned       |
     * +----------------------------------------------------+
     */
    struct PlayerScore {
        address player; // 20 bytes - address of top affiliate
        uint96 score; // 12 bytes - raw 18-decimal amount (capped to uint96 max)
    }

    /**
     * @notice Affiliate code ownership and rakeback configuration.
     * @dev Packed into single storage slot for gas efficiency.
     *
     * STORAGE LAYOUT (32 bytes, 11 bytes used):
     * +----------------------------------------------------+
     * | [0:20]  owner     address   Code owner/recipient   |
     * | [20:21] rakeback  uint8     Rakeback % (0-25)      |
     * | [21:32] unused    ---       11 bytes padding       |
     * +----------------------------------------------------+
     */
    struct AffiliateCodeInfo {
        address owner; // 20 bytes - receives affiliate rewards
        uint8 rakeback; // 1 byte - percentage returned to referred player (0-25)
    }

    // =====================================================================
    //                            CONSTANTS
    // =====================================================================

    /// @notice Maximum bonus points an affiliate can earn from leaderboard position.
    /// @dev Applied to mint trait rolls; top 20% of leaderboard earns this max.
    uint256 private constant AFFILIATE_BONUS_MAX = 25;

    /// @notice Scaling factor for bonus calculation: top 20% earns max bonus.
    /// @dev Formula: (playerScore * SCALE) / topScore, capped at MAX.
    ///      125 = 25 * 5, meaning you need 20% of top score to hit max.
    uint256 private constant AFFILIATE_BONUS_SCALE = AFFILIATE_BONUS_MAX * 5;

    /// @notice Sentinel value indicating a player's referral slot is permanently locked.
    /// @dev Set when a player makes an invalid referral attempt (self-referral, unknown code)
    ///      after the game has started. Prevents gaming by trying multiple codes.
    bytes32 private constant REF_CODE_LOCKED = bytes32(uint256(1));

    /// @notice BurnieCoin contract for FLIP token operations (constant).
    IDegenerusCoinAffiliate private constant coin = IDegenerusCoinAffiliate(ContractAddresses.COIN);

    /// @notice DegenerusGame contract for level queries (constant).
    IDegenerusGame private constant degenerusGame = IDegenerusGame(ContractAddresses.GAME);

    // =====================================================================
    //                        AFFILIATE STATE
    // =====================================================================

    /// @notice Mapping from affiliate code (bytes32) to ownership info.
    /// @dev codes are permanent once created; owner cannot be changed.
    ///      Reserved value: bytes32(0) = invalid, bytes32(1) = REF_CODE_LOCKED sentinel.
    mapping(bytes32 => AffiliateCodeInfo) public affiliateCode;

    /// @notice Per-level earnings tracking: level → affiliate → raw token amount.
    /// @dev Used for leaderboard calculations and bonus point determination.
    ///      Amounts include 18 decimal places; divide by 1 ether for whole tokens.
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;

    /// @notice Player's chosen referral code (or REF_CODE_LOCKED if locked).
    /// @dev Private to prevent external manipulation; use referralCodeOf() view.
    ///      bytes32(0) = not yet set, REF_CODE_LOCKED = permanently locked.
    mapping(address => bytes32) private playerReferralCode;

    /// @notice Records the game level when a player's referral was established.
    /// @dev Used by _referralRewardScaleBps() to calculate reward decay.
    ///      Level 0 = presale/early join; decay starts after 50 levels.
    mapping(address => uint24) public referralJoinLevel;

    /// @notice Presale-era affiliate earnings awaiting claim.
    /// @dev Deprecated: presale rewards are now paid immediately.
    ///      Preserved for storage compatibility.
    mapping(address => uint256) private presaleCoinEarned;

    /// @notice Top affiliate per game level for bonus calculations.
    /// @dev Private storage; use affiliateTop() view to read.
    ///      Updated in _updateTopAffiliate() when affiliate exceeds current top.
    mapping(uint24 => PlayerScore) private affiliateTopByLevel;

    /// @notice Total unclaimed presale coin across all players.
    /// @dev Deprecated: preserved for storage compatibility.
    uint256 private presaleClaimableTotal;

    /// @notice Flag indicating presale period has ended.
    /// @dev Set permanently via shutdownPresale(). Once true:
    ///      - payAffiliate() continues direct creditFlip() distribution
    ///      - consumePresaleCoin() is deprecated
    ///      - Cannot be unset (one-way state transition)
    bool private presaleShutdown;

    /**
     * @notice Initialize affiliate contract with trusted contract addresses.
     * @dev All dependencies are fixed at deploy time via ContractAddresses.
     */
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
        _recordReferralJoinLevel(msg.sender, degenerusGame.level());
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
     * @dev Returns true until shutdownPresale() is called by ContractAddresses.BONDS.
     *      During presale, affiliate rewards are paid immediately (ContractAddresses.BONDS only).
     * @return True if presale is active, false if shutdown.
     */
    function presaleActive() external view returns (bool) {
        return !presaleShutdown;
    }

    /**
     * @notice Permanently close the presale period.
     * @dev Can only be called by ContractAddresses.BONDS contract. One-way state transition.
     *      After shutdown:
     *      - payAffiliate() continues direct creditFlip() distribution
     *      - consumePresaleCoin() is deprecated
     *
     * ACCESS: ContractAddresses.BONDS only.
     */
    function shutdownPresale() external {
        // SECURITY: Only ContractAddresses.BONDS can shutdown presale.
        if (msg.sender != ContractAddresses.BONDS) revert OnlyBonds();
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
     * ACCESS: coin, ContractAddresses.BONDS, or gamepieces only.
     *
     * REWARD FLOW:
     * +--------------------------------------------------------------------+
     * | 1. Resolve referral code (stored or provided)                      |
     * | 2. Apply reward decay based on levels since join                   |
     * | 3. Calculate rakeback (returned to player)                         |
     * | 4. Pay direct affiliate (base - rakeback)                          |
     * | 5. Pay upline1 (20% of scaled amount)                              |
     * | 6. Pay upline2 (20% of upline1 share = 4%)                         |
     * | 7. Quest rewards added on top (post-presale only)                  |
     * +--------------------------------------------------------------------+
     *
     * PRESALE vs POST-PRESALE:
     * - Presale: Rewards immediately distributed via creditFlip() (ContractAddresses.BONDS only)
     * - Post-presale: Rewards immediately distributed via creditFlip()
     *
     * @param amount Base reward amount (18 decimals).
     * @param code Affiliate code provided with the transaction (may be bytes32(0)).
     * @param sender The player making the purchase.
     * @param lvl Current game level (for join tracking and leaderboard).
     * @param gameState Current game FSM state (unused; retained for interface compatibility).
     * @param rngLocked Whether VRF is pending (unused; retained for interface compatibility).
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
        // -----------------------------------------------------------------
        // ACCESS CONTROL
        // -----------------------------------------------------------------
        gameState;
        rngLocked;
        // SECURITY: Only trusted contracts can distribute affiliate rewards.
        if (msg.sender != ContractAddresses.COIN && msg.sender != ContractAddresses.BONDS && msg.sender != ContractAddresses.GAMEPIECES) revert OnlyAuthorized();

        // -----------------------------------------------------------------
        // PRESALE GATE
        // -----------------------------------------------------------------
        bool presaleOpen = !presaleShutdown;
        if (presaleOpen) {
            // During presale, only bond purchases accrue rewards.
            // This keeps presale distribution anchored to bond purchases.
            if (msg.sender != ContractAddresses.BONDS) return 0;
        }

        // -----------------------------------------------------------------
        // REFERRAL RESOLUTION
        // -----------------------------------------------------------------
        bytes32 storedCode = playerReferralCode[sender];
        // SECURITY: Locked slots cannot earn or generate affiliate rewards.
        if (storedCode == REF_CODE_LOCKED) return 0;

        AffiliateCodeInfo storage info;
        if (storedCode == bytes32(0)) {
            // No referral provided: don't lock or set a referral on "no code" paths.
            if (code == bytes32(0)) return 0;
            // No stored code - try to use the provided code.
            AffiliateCodeInfo storage candidate = affiliateCode[code];
            if (candidate.owner == address(0) || candidate.owner == sender) {
                // Invalid code or self-referral: lock slot after presale.
                // SECURITY: Prevents gaming by trying codes until one works.
                if (!presaleOpen) {
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
                playerReferralCode[sender] = presaleOpen ? bytes32(0) : REF_CODE_LOCKED;
                return 0;
            }
        }

        // -----------------------------------------------------------------
        // REWARD CALCULATION SETUP
        // -----------------------------------------------------------------
        address affiliateAddr = info.owner;
        uint8 rakebackPct = info.rakeback;

        // -----------------------------------------------------------------
        // REWARD CALCULATION
        // -----------------------------------------------------------------
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

        // -----------------------------------------------------------------
        // DISTRIBUTION (POST-PRESALE)
        // -----------------------------------------------------------------
        if (!presaleOpen) {
            // Batch recipients for gas efficiency.
            address[3] memory players;
            uint256[3] memory amounts;
            uint256 cursor;

            // Add quest reward bonus on top of base affiliate share.
            uint256 questReward = coin.affiliateQuestReward(affiliateAddr, affiliateShareBase);
            uint256 totalFlipAward = affiliateShareBase + questReward;

            players[cursor] = affiliateAddr;
            amounts[cursor] = totalFlipAward;
            unchecked {
                ++cursor;
            }

            // -------------------------------------------------------------
            // UPLINE TIER 1 (20% of scaled amount)
            // -------------------------------------------------------------
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

                // ---------------------------------------------------------
                // UPLINE TIER 2 (20% of tier 1 = 4% of original)
                // ---------------------------------------------------------
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
            // -------------------------------------------------------------
            // DISTRIBUTION (PRESALE)
            // -------------------------------------------------------------
            // Directly credit flip stakes; no quest rewards during presale.
            address[3] memory players;
            uint256[3] memory amounts;
            uint256 cursor;

            players[cursor] = affiliateAddr;
            amounts[cursor] = affiliateShareBase;
            unchecked {
                ++cursor;
            }

            // Upline tier 1 (20% of scaled amount).
            address uplinePre = _referrerAddress(affiliateAddr);
            if (uplinePre != address(0) && uplinePre != sender) {
                uint256 baseBonusPre = scaledAmount / 5;
                earned[uplinePre] = earned[uplinePre] + baseBonusPre;
                players[cursor] = uplinePre;
                amounts[cursor] = baseBonusPre;
                unchecked {
                    ++cursor;
                }

                // Upline tier 2 (20% of tier 1).
                address upline2Pre = _referrerAddress(uplinePre);
                if (upline2Pre != address(0)) {
                    uint256 bonus2Pre = baseBonusPre / 5;
                    earned[upline2Pre] = earned[upline2Pre] + bonus2Pre;
                    players[cursor] = upline2Pre;
                    amounts[cursor] = bonus2Pre;
                    unchecked {
                        ++cursor;
                    }
                }
            }

            if (cursor != 0) {
                if (cursor == 1) {
                    coin.creditFlip(players[0], amounts[0]);
                } else {
                    coin.creditFlipBatch(players, amounts);
                }
            }

            if (playerRakeback != 0) {
                coin.creditFlip(sender, playerRakeback);
            }
        }

        emit Affiliate(amount, storedCode, sender);
        return playerRakeback;
    }

    /**
     * @notice Consume and return a player's accrued presale coin for minting.
     * @dev Deprecated: presale rewards are paid immediately.
     *
     * ACCESS: coin only.
     *
     * @param player The player claiming their presale rewards.
     * @return amount The amount to mint for the player (legacy only).
     */
    function consumePresaleCoin(address player) external returns (uint256 amount) {
        // SECURITY: Only coin contract can consume presale balances.
        if (msg.sender != ContractAddresses.COIN) revert OnlyAuthorized();
        // Only claimable after presale ends.
        if (!presaleShutdown) return 0;

        amount = presaleCoinEarned[player];
        if (amount != 0) {
            // CEI: Zero balance before returning (even though caller is trusted).
            presaleCoinEarned[player] = 0;
            presaleClaimableTotal -= amount;
        }
    }

    /**
     * @notice Credit presale coin from external sources (e.g., LINK donation rewards).
     * @dev Deprecated: credits are paid immediately as flip stakes.
     *
     * ACCESS: coin, ContractAddresses.BONDS, or ContractAddresses.ADMIN.
     *
     * @param player The player to credit.
     * @param amount The amount to credit (18 decimals).
     */
    function addPresaleCoinCredit(address player, uint256 amount) external {
        // SECURITY: Only trusted contracts can add presale credits.
        if (msg.sender != ContractAddresses.COIN && msg.sender != ContractAddresses.BONDS && msg.sender != ContractAddresses.ADMIN) revert OnlyAuthorized();
        // Skip no-op calls.
        if (player == address(0) || amount == 0) return;
        coin.creditFlip(player, amount);
    }

    /**
     * @notice Forward any received ETH to the ContractAddresses.BONDS contract.
     * @dev Prevents ETH from being accidentally stuck in this contract.
     *      This contract should not hold ETH; all ETH flows through ContractAddresses.BONDS.
     *
     * SECURITY: Reverts if forward fails, preventing silent loss of funds.
     */
    receive() external payable {
        (bool ok, ) = payable(ContractAddresses.BONDS).call{value: msg.value}("");
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
     * @return score Their score in BURNIE base units (18 decimals).
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
     * @return playerScore The queried player's score (18 decimals).
     */
    function affiliateBonusInfo(
        uint24 lvl,
        address player
    ) external view returns (uint96 topScore, uint256 playerScore) {
        topScore = affiliateTopByLevel[lvl].score;
        if (topScore == 0 || player == address(0)) return (topScore, 0);
        uint256 earned = affiliateCoinEarned[lvl][player];
        if (earned == 0) return (topScore, 0);
        playerScore = earned;
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
     * +-----------------------------------------------------------------+
     * | Levels since join    | Scale (bps)  | Percentage               |
     * +-----------------------------------------------------------------+
     * | 0 - 50               | 10,000       | 100% (full rewards)      |
     * | 51 - 150             | linear decay | 100% → 25% (-0.75%/lvl)  |
     * | 151+                 | 2,500        | 25% (minimum floor)      |
     * +-----------------------------------------------------------------+
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
        return 10_000 - reduction;
    }

    /**
     * @notice Convert a raw amount to a uint96 score in base units.
     * @dev Caps at uint96 max to prevent overflow/truncation errors.
     *      uint96 max ≈ 7.9e28 base units (~79 billion tokens).
     * @param s Raw amount (18 decimals).
     * @return Raw token amount (18 decimals) as uint96.
     */
    function _score96(uint256 s) private pure returns (uint96) {
        // SECURITY: Cap at max to prevent truncation errors.
        if (s > type(uint96).max) {
            return type(uint96).max;
        }
        return uint96(s);
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
        uint256 playerScore = affiliateCoinEarned[lvl][player];
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
     * @param total The affiliate's new total earnings (raw, 18 decimals).
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
